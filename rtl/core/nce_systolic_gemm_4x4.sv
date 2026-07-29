// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Autonomous native 4x4 systolic GEMM engine.
//
// Stores one:
//   A tile: 4 x 4 x 32 bits
//   B tile: 4 x 4 x 32 bits
//
// For a configured K count, the controller automatically generates:
//
//   A[row][k] injection cycle = k + row
//   B[k][col] injection cycle = k + col
//
// The physical systolic array then produces:
//
//   PE(row,col) compute cycle = k + row + col
//
// Dataflow:
//   activations: left to right
//   weights:     top to bottom
//   partial sums: stationary inside each PE
// -----------------------------------------------------------------------------

module nce_systolic_gemm_4x4 #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Clears controller state, tile validity and array state.
    input  logic         clear_i,

    // -------------------------------------------------------------------------
    // A tile write interface
    //
    // Address mapping:
    //   address = row * 4 + k
    // -------------------------------------------------------------------------

    input  logic         a_write_enable_i,
    input  logic [3:0]   a_write_addr_i,
    input  logic [31:0]  a_write_data_i,

    // -------------------------------------------------------------------------
    // B tile write interface
    //
    // Address mapping:
    //   address = k * 4 + column
    // -------------------------------------------------------------------------

    input  logic         b_write_enable_i,
    input  logic [3:0]   b_write_addr_i,
    input  logic [31:0]  b_write_data_i,

    output logic [15:0]  a_valid_mask_o,
    output logic [15:0]  b_valid_mask_o,

    // -------------------------------------------------------------------------
    // GEMM operation interface
    // -------------------------------------------------------------------------

    input  logic         start_i,
    output logic         start_ready_o,

    input  logic [1:0]   precision_i,
    input  logic [2:0]   k_count_i,

    // 0: begin a new C tile and clear all PE accumulators
    // 1: preserve the current C tile and accumulate another K tile
    input  logic         accumulate_i,

    output logic         busy_o,
    output logic         done_o,
    output logic         error_o,
    output logic [2:0]   error_code_o,

    output logic [3:0]   wavefront_cycle_o,

    // -------------------------------------------------------------------------
    // Systolic outputs
    // -------------------------------------------------------------------------

    output logic [511:0] accumulator_o,
    output logic [15:0]  accumulator_valid_o,
    output logic [15:0]  accumulator_update_o,

    output logic [15:0]  mac_fire_mask_o,

    output logic [15:0]  invalid_o,
    output logic [15:0]  overflow_o,
    output logic [15:0]  underflow_o,
    output logic [15:0]  inexact_o
);

    localparam logic [2:0] ERROR_NONE              = 3'd0;
    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_A_TILE_INVALID    = 3'd3;
    localparam logic [2:0] ERROR_B_TILE_INVALID    = 3'd4;
    localparam logic [2:0] ERROR_ACCUMULATE_INVALID = 3'd5;

    localparam logic [2:0] STATE_IDLE         = 3'd0;
    localparam logic [2:0] STATE_ARRAY_CLEAR  = 3'd1;
    localparam logic [2:0] STATE_INJECT       = 3'd2;
    localparam logic [2:0] STATE_DRAIN        = 3'd3;

    logic [2:0] state_q;

    // -------------------------------------------------------------------------
    // Local tile buffers
    // -------------------------------------------------------------------------

    logic [31:0] a_tile_q [0:15];
    logic [31:0] b_tile_q [0:15];

    logic [15:0] a_valid_q;
    logic [15:0] b_valid_q;

    integer tile_index;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            a_valid_q <= 16'd0;
            b_valid_q <= 16'd0;

            for (
                tile_index = 0;
                tile_index < 16;
                tile_index = tile_index + 1
            ) begin
                a_tile_q[tile_index] <= 32'd0;
                b_tile_q[tile_index] <= 32'd0;
            end
        end
        else if (clear_i) begin
            a_valid_q <= 16'd0;
            b_valid_q <= 16'd0;

            for (
                tile_index = 0;
                tile_index < 16;
                tile_index = tile_index + 1
            ) begin
                a_tile_q[tile_index] <= 32'd0;
                b_tile_q[tile_index] <= 32'd0;
            end
        end
        else begin
            if (
                a_write_enable_i &&
                !busy_o
            ) begin
                a_tile_q[a_write_addr_i] <=
                    a_write_data_i;

                a_valid_q[a_write_addr_i] <=
                    1'b1;
            end

            if (
                b_write_enable_i &&
                !busy_o
            ) begin
                b_tile_q[b_write_addr_i] <=
                    b_write_data_i;

                b_valid_q[b_write_addr_i] <=
                    1'b1;
            end
        end
    end

    assign a_valid_mask_o =
        a_valid_q;

    assign b_valid_mask_o =
        b_valid_q;

    // -------------------------------------------------------------------------
    // Configuration validation
    // -------------------------------------------------------------------------

    logic precision_valid;
    logic k_count_valid;

    logic required_a_valid;
    logic required_b_valid;

    logic [2:0] configuration_error;

    integer validation_row;
    integer validation_column;
    integer validation_k;

    always_comb begin
        precision_valid =
            (precision_i == INT8X4_PRECISION) ||
            (precision_i == BF16X2_PRECISION) ||
            (precision_i == BF24_PRECISION);

        k_count_valid =
            (k_count_i >= 3'd1) &&
            (k_count_i <= 3'd4);

        required_a_valid = 1'b1;
        required_b_valid = 1'b1;

        for (
            validation_row = 0;
            validation_row < 4;
            validation_row = validation_row + 1
        ) begin
            for (
                validation_k = 0;
                validation_k < 4;
                validation_k = validation_k + 1
            ) begin
                if (
                    validation_k < k_count_i &&
                    !a_valid_q[
                        (validation_row * 4) +
                        validation_k
                    ]
                ) begin
                    required_a_valid = 1'b0;
                end
            end
        end

        for (
            validation_k = 0;
            validation_k < 4;
            validation_k = validation_k + 1
        ) begin
            for (
                validation_column = 0;
                validation_column < 4;
                validation_column = validation_column + 1
            ) begin
                if (
                    validation_k < k_count_i &&
                    !b_valid_q[
                        (validation_k * 4) +
                        validation_column
                    ]
                ) begin
                    required_b_valid = 1'b0;
                end
            end
        end

        configuration_error =
            ERROR_NONE;

        if (!precision_valid) begin
            configuration_error =
                ERROR_INVALID_PRECISION;
        end
        else if (!k_count_valid) begin
            configuration_error =
                ERROR_INVALID_K;
        end
        else if (!required_a_valid) begin
            configuration_error =
                ERROR_A_TILE_INVALID;
        end
        else if (!required_b_valid) begin
            configuration_error =
                ERROR_B_TILE_INVALID;
        end
        else if (
            accumulate_i &&
            !(&accumulator_valid_o)
        ) begin
            // Accumulation is legal only after every PE has produced
            // a valid initial C-tile value.
            configuration_error =
                ERROR_ACCUMULATE_INVALID;
        end
    end

    // -------------------------------------------------------------------------
    // Operation state
    // -------------------------------------------------------------------------

    logic [1:0] precision_q;
    logic [2:0] k_count_q;
    logic [3:0] wavefront_cycle_q;

    logic [3:0] last_wavefront_cycle;

    assign last_wavefront_cycle =
        {1'b0, k_count_q} +
        4'd5;

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        (state_q == STATE_IDLE);

    assign busy_o =
        (state_q != STATE_IDLE);

    assign wavefront_cycle_o =
        wavefront_cycle_q;

    // -------------------------------------------------------------------------
    // Native skewed boundary generation
    // -------------------------------------------------------------------------

    logic [127:0] row_activation;
    logic [3:0]   row_activation_valid;

    logic [127:0] column_weight;
    logic [3:0]   column_weight_valid;

    // -------------------------------------------------------------------------
    // Synthesis-safe native skew generation
    //
    // A[row][k] enters row 'row' at cycle:
    //
    //     cycle = k + row
    //
    // B[k][column] enters column 'column' at cycle:
    //
    //     cycle = k + column
    //
    // The four rows and columns are written explicitly to avoid procedural
    // integer loop variables being interpreted as inferred storage by Yosys.
    // -------------------------------------------------------------------------

    logic [3:0] row_k_index_0;
    logic [3:0] row_k_index_1;
    logic [3:0] row_k_index_2;
    logic [3:0] row_k_index_3;

    logic [3:0] column_k_index_0;
    logic [3:0] column_k_index_1;
    logic [3:0] column_k_index_2;
    logic [3:0] column_k_index_3;

    assign row_k_index_0 =
        wavefront_cycle_q;

    assign row_k_index_1 =
        wavefront_cycle_q - 4'd1;

    assign row_k_index_2 =
        wavefront_cycle_q - 4'd2;

    assign row_k_index_3 =
        wavefront_cycle_q - 4'd3;

    assign column_k_index_0 =
        wavefront_cycle_q;

    assign column_k_index_1 =
        wavefront_cycle_q - 4'd1;

    assign column_k_index_2 =
        wavefront_cycle_q - 4'd2;

    assign column_k_index_3 =
        wavefront_cycle_q - 4'd3;

    // -------------------------------------------------------------------------
    // Row 0 activation injection
    // -------------------------------------------------------------------------

    assign row_activation_valid[0] =
        (state_q == STATE_INJECT) &&
        (row_k_index_0 < {1'b0, k_count_q});

    assign row_activation[31:0] =
        row_activation_valid[0]
        ? a_tile_q[
            {2'b00, row_k_index_0[1:0]}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Row 1 activation injection
    // -------------------------------------------------------------------------

    assign row_activation_valid[1] =
        (state_q == STATE_INJECT) &&
        (wavefront_cycle_q >= 4'd1) &&
        (row_k_index_1 < {1'b0, k_count_q});

    assign row_activation[63:32] =
        row_activation_valid[1]
        ? a_tile_q[
            {2'b01, row_k_index_1[1:0]}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Row 2 activation injection
    // -------------------------------------------------------------------------

    assign row_activation_valid[2] =
        (state_q == STATE_INJECT) &&
        (wavefront_cycle_q >= 4'd2) &&
        (row_k_index_2 < {1'b0, k_count_q});

    assign row_activation[95:64] =
        row_activation_valid[2]
        ? a_tile_q[
            {2'b10, row_k_index_2[1:0]}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Row 3 activation injection
    // -------------------------------------------------------------------------

    assign row_activation_valid[3] =
        (state_q == STATE_INJECT) &&
        (wavefront_cycle_q >= 4'd3) &&
        (row_k_index_3 < {1'b0, k_count_q});

    assign row_activation[127:96] =
        row_activation_valid[3]
        ? a_tile_q[
            {2'b11, row_k_index_3[1:0]}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Column 0 weight injection
    // -------------------------------------------------------------------------

    assign column_weight_valid[0] =
        (state_q == STATE_INJECT) &&
        (column_k_index_0 < {1'b0, k_count_q});

    assign column_weight[31:0] =
        column_weight_valid[0]
        ? b_tile_q[
            {column_k_index_0[1:0], 2'b00}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Column 1 weight injection
    // -------------------------------------------------------------------------

    assign column_weight_valid[1] =
        (state_q == STATE_INJECT) &&
        (wavefront_cycle_q >= 4'd1) &&
        (column_k_index_1 < {1'b0, k_count_q});

    assign column_weight[63:32] =
        column_weight_valid[1]
        ? b_tile_q[
            {column_k_index_1[1:0], 2'b01}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Column 2 weight injection
    // -------------------------------------------------------------------------

    assign column_weight_valid[2] =
        (state_q == STATE_INJECT) &&
        (wavefront_cycle_q >= 4'd2) &&
        (column_k_index_2 < {1'b0, k_count_q});

    assign column_weight[95:64] =
        column_weight_valid[2]
        ? b_tile_q[
            {column_k_index_2[1:0], 2'b10}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Column 3 weight injection
    // -------------------------------------------------------------------------

    assign column_weight_valid[3] =
        (state_q == STATE_INJECT) &&
        (wavefront_cycle_q >= 4'd3) &&
        (column_k_index_3 < {1'b0, k_count_q});

    assign column_weight[127:96] =
        column_weight_valid[3]
        ? b_tile_q[
            {column_k_index_3[1:0], 2'b11}
        ]
        : 32'd0;

    // -------------------------------------------------------------------------
    // Native 4x4 systolic array
    // -------------------------------------------------------------------------

    logic array_clear;
    logic array_step;
    logic array_ready;
    logic array_precision_supported;

    assign array_clear =
        clear_i ||
        (state_q == STATE_ARRAY_CLEAR);

    assign array_step =
        (state_q == STATE_INJECT) &&
        array_ready;

    nce_systolic_array_4x4 #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_systolic_array (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .clear_i                  (array_clear),

        .step_i                   (array_step),
        .ready_o                  (array_ready),

        .precision_i              (precision_q),
        .precision_supported_o    (
            array_precision_supported
        ),

        .row_activation_i         (row_activation),
        .row_activation_valid_i   (row_activation_valid),

        .column_weight_i          (column_weight),
        .column_weight_valid_i    (column_weight_valid),

        .accumulator_o            (accumulator_o),
        .accumulator_valid_o      (accumulator_valid_o),
        .accumulator_update_o     (accumulator_update_o),

        .mac_fire_mask_o          (mac_fire_mask_o),

        .invalid_o                (invalid_o),
        .overflow_o               (overflow_o),
        .underflow_o              (underflow_o),
        .inexact_o                (inexact_o)
    );

    // -------------------------------------------------------------------------
    // Per-PE completion tracking
    // -------------------------------------------------------------------------

    logic [2:0] pe_update_count_q [0:15];
    logic       all_pes_complete;

    integer completion_index;

    always_comb begin
        all_pes_complete = 1'b1;

        for (
            completion_index = 0;
            completion_index < 16;
            completion_index = completion_index + 1
        ) begin
            if (
                pe_update_count_q[completion_index] !=
                k_count_q
            ) begin
                all_pes_complete = 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // GEMM control FSM
    // -------------------------------------------------------------------------

    integer counter_index;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;

            precision_q        <= INT8X4_PRECISION;
            k_count_q          <= 3'd0;
            wavefront_cycle_q  <= 4'd0;

            done_o       <= 1'b0;
            error_o      <= 1'b0;
            error_code_o <= ERROR_NONE;

            for (
                counter_index = 0;
                counter_index < 16;
                counter_index = counter_index + 1
            ) begin
                pe_update_count_q[counter_index] <=
                    3'd0;
            end
        end
        else begin
            done_o  <= 1'b0;
            error_o <= 1'b0;

            if (clear_i) begin
                state_q <= STATE_IDLE;

                precision_q        <= INT8X4_PRECISION;
                k_count_q          <= 3'd0;
                wavefront_cycle_q  <= 4'd0;

                error_code_o <= ERROR_NONE;

                for (
                    counter_index = 0;
                    counter_index < 16;
                    counter_index = counter_index + 1
                ) begin
                    pe_update_count_q[counter_index] <=
                        3'd0;
                end
            end
            else begin
                // Count completed arithmetic updates during execution/drain.
                if (
                    state_q == STATE_INJECT ||
                    state_q == STATE_DRAIN
                ) begin
                    for (
                        counter_index = 0;
                        counter_index < 16;
                        counter_index = counter_index + 1
                    ) begin
                        if (
                            accumulator_update_o[
                                counter_index
                            ]
                        ) begin
                            pe_update_count_q[
                                counter_index
                            ] <=
                                pe_update_count_q[
                                    counter_index
                                ] +
                                3'd1;
                        end
                    end
                end

                case (state_q)
                    STATE_IDLE: begin
                        if (start_i) begin
                            error_code_o <=
                                configuration_error;

                            if (
                                configuration_error !=
                                ERROR_NONE
                            ) begin
                                error_o <= 1'b1;
                            end
                            else begin
                                precision_q <= precision_i;
                                k_count_q   <= k_count_i;

                                wavefront_cycle_q <=
                                    4'd0;

                                for (
                                    counter_index = 0;
                                    counter_index < 16;
                                    counter_index = counter_index + 1
                                ) begin
                                    pe_update_count_q[
                                        counter_index
                                    ] <= 3'd0;
                                end

                                // A new C tile clears every local PE
                                // accumulator. A continuation K tile starts
                                // directly because the previous wavefront has
                                // already drained all internal link valids.
                                if (accumulate_i) begin
                                    state_q <=
                                        STATE_INJECT;
                                end
                                else begin
                                    state_q <=
                                        STATE_ARRAY_CLEAR;
                                end
                            end
                        end
                    end

                    STATE_ARRAY_CLEAR: begin
                        wavefront_cycle_q <=
                            4'd0;

                        state_q <=
                            STATE_INJECT;
                    end

                    STATE_INJECT: begin
                        if (array_step) begin
                            if (
                                wavefront_cycle_q ==
                                last_wavefront_cycle
                            ) begin
                                state_q <=
                                    STATE_DRAIN;
                            end
                            else begin
                                wavefront_cycle_q <=
                                    wavefront_cycle_q +
                                    4'd1;
                            end
                        end
                    end

                    STATE_DRAIN: begin
                        if (all_pes_complete) begin
                            done_o       <= 1'b1;
                            error_code_o <= ERROR_NONE;
                            state_q      <= STATE_IDLE;
                        end
                    end

                    default: begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_INVALID_K;
                        state_q      <= STATE_IDLE;
                    end
                endcase
            end
        end
    end

    // Retained for structural consistency checking.
    /* verilator lint_off UNUSEDSIGNAL */
    logic array_precision_supported_unused;

    assign array_precision_supported_unused =
        array_precision_supported;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
