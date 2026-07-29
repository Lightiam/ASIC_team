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
// 8x8 M/N/K tile controller using an externally supplied 4x4 GEMM engine.
//
// Source buffers:
//
//   A: 8 rows x 8 packed-K tokens
//   B: 8 packed-K tokens x 8 columns
//
// Output:
//
//   C: 8 rows x 8 FP32 values
//
// The controller traverses:
//
//   M tile = 0..1
//   N tile = 0..1
//   K tile = 0..ceil(K_token_count / 4)-1
//
// A and B entries are 32-bit packed operands:
//
//   INT8X4: each token carries four scalar K terms
//   BF16X2: each token carries two scalar K terms
//   BF24:   each token carries one scalar K term
// -----------------------------------------------------------------------------

module nce_tiled_gemm_8x8_controller #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic          clk_i,
    input  logic          rst_ni,
    input  logic          clear_i,

    // A address = row * 8 + packed_k
    input  logic          a_write_enable_i,
    input  logic [5:0]    a_write_addr_i,
    input  logic [31:0]   a_write_data_i,

    // B address = packed_k * 8 + column
    input  logic          b_write_enable_i,
    input  logic [5:0]    b_write_addr_i,
    input  logic [31:0]   b_write_data_i,

    output logic [63:0]   a_valid_mask_o,
    output logic [63:0]   b_valid_mask_o,

    input  logic          start_i,
    output logic          start_ready_o,

    input  logic [1:0]    precision_i,

    // Number of packed K tokens, supported range 1..8.
    input  logic [3:0]    k_token_count_i,

    output logic          busy_o,
    output logic          done_o,
    output logic          error_o,
    output logic [2:0]    error_code_o,

    output logic          m_tile_o,
    output logic          n_tile_o,
    output logic          k_tile_o,

    // Sixty-four row-major FP32 results.
    output logic [2047:0] accumulator_o,
    output logic [63:0]   accumulator_valid_o,

    output logic [63:0]   invalid_o,
    output logic [63:0]   overflow_o,
    output logic [63:0]   underflow_o,
    output logic [63:0]   inexact_o,

    // Availability of the shared physical GEMM resource.
    input  logic          engine_available_i,

    // Requests from this controller to the physical 4x4 GEMM engine.
    output logic          engine_clear_o,

    output logic          engine_a_write_enable_o,
    output logic [3:0]    engine_a_write_addr_o,
    output logic [31:0]   engine_a_write_data_o,

    output logic          engine_b_write_enable_o,
    output logic [3:0]    engine_b_write_addr_o,
    output logic [31:0]   engine_b_write_data_o,

    output logic          engine_start_o,
    input  logic          engine_start_ready_i,

    output logic [1:0]    engine_precision_o,
    output logic [2:0]    engine_k_count_o,
    output logic          engine_accumulate_o,

    // Responses returned by the physical 4x4 GEMM engine.
    input  logic          engine_busy_i,
    input  logic          engine_done_i,
    input  logic          engine_error_i,
    input  logic [2:0]    engine_error_code_i,

    input  logic [511:0]  engine_accumulator_i,
    input  logic [15:0]   engine_accumulator_valid_i,

    input  logic [15:0]   engine_invalid_i,
    input  logic [15:0]   engine_overflow_i,
    input  logic [15:0]   engine_underflow_i,
    input  logic [15:0]   engine_inexact_i
);

    localparam logic [2:0] ERROR_NONE              = 3'd0;
    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_A_MATRIX_INVALID  = 3'd3;
    localparam logic [2:0] ERROR_B_MATRIX_INVALID  = 3'd4;
    localparam logic [2:0] ERROR_ENGINE_FAILURE    = 3'd5;

    localparam logic [2:0] STATE_IDLE    = 3'd0;
    localparam logic [2:0] STATE_LOAD    = 3'd1;
    localparam logic [2:0] STATE_START   = 3'd2;
    localparam logic [2:0] STATE_WAIT    = 3'd3;
    localparam logic [2:0] STATE_CAPTURE = 3'd4;

    logic [2:0] state_q;

    // -------------------------------------------------------------------------
    // Complete 8x8 token-matrix source storage
    // -------------------------------------------------------------------------

    logic [31:0] a_matrix_q [0:63];
    logic [31:0] b_matrix_q [0:63];

    logic [63:0] a_valid_q;
    logic [63:0] b_valid_q;

    integer source_index;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            a_valid_q <= 64'd0;
            b_valid_q <= 64'd0;

            for (
                source_index = 0;
                source_index < 64;
                source_index = source_index + 1
            ) begin
                a_matrix_q[source_index] <= 32'd0;
                b_matrix_q[source_index] <= 32'd0;
            end
        end
        else if (clear_i) begin
            a_valid_q <= 64'd0;
            b_valid_q <= 64'd0;

            for (
                source_index = 0;
                source_index < 64;
                source_index = source_index + 1
            ) begin
                a_matrix_q[source_index] <= 32'd0;
                b_matrix_q[source_index] <= 32'd0;
            end
        end
        else begin
            if (
                a_write_enable_i &&
                !busy_o
            ) begin
                a_matrix_q[a_write_addr_i] <=
                    a_write_data_i;

                a_valid_q[a_write_addr_i] <=
                    1'b1;
            end

            if (
                b_write_enable_i &&
                !busy_o
            ) begin
                b_matrix_q[b_write_addr_i] <=
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

    function automatic logic [7:0] k_prefix_mask (
        input logic [3:0] count
    );
        begin
            case (count)
                4'd1: k_prefix_mask = 8'h01;
                4'd2: k_prefix_mask = 8'h03;
                4'd3: k_prefix_mask = 8'h07;
                4'd4: k_prefix_mask = 8'h0F;
                4'd5: k_prefix_mask = 8'h1F;
                4'd6: k_prefix_mask = 8'h3F;
                4'd7: k_prefix_mask = 8'h7F;
                4'd8: k_prefix_mask = 8'hFF;

                default:
                    k_prefix_mask = 8'h00;
            endcase
        end
    endfunction

    function automatic logic [63:0] b_required_mask (
        input logic [3:0] count
    );
        begin
            case (count)
                4'd1: b_required_mask = 64'h0000_0000_0000_00FF;
                4'd2: b_required_mask = 64'h0000_0000_0000_FFFF;
                4'd3: b_required_mask = 64'h0000_0000_00FF_FFFF;
                4'd4: b_required_mask = 64'h0000_0000_FFFF_FFFF;
                4'd5: b_required_mask = 64'h0000_00FF_FFFF_FFFF;
                4'd6: b_required_mask = 64'h0000_FFFF_FFFF_FFFF;
                4'd7: b_required_mask = 64'h00FF_FFFF_FFFF_FFFF;
                4'd8: b_required_mask = 64'hFFFF_FFFF_FFFF_FFFF;

                default:
                    b_required_mask = 64'd0;
            endcase
        end
    endfunction

    logic precision_valid;
    logic k_count_valid;

    logic [63:0] required_a_mask;
    logic [63:0] required_b_mask;

    logic required_a_valid;
    logic required_b_valid;

    logic [2:0] configuration_error;

    always @* begin
        precision_valid =
            (precision_i == INT8X4_PRECISION) ||
            (precision_i == BF16X2_PRECISION) ||
            (precision_i == BF24_PRECISION);

        k_count_valid =
            (k_token_count_i >= 4'd1) &&
            (k_token_count_i <= 4'd8);

        required_a_mask =
            {
                8{k_prefix_mask(k_token_count_i)}
            };

        required_b_mask =
            b_required_mask(k_token_count_i);

        required_a_valid =
            (a_valid_q & required_a_mask) ==
            required_a_mask;

        required_b_valid =
            (b_valid_q & required_b_mask) ==
            required_b_mask;

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
                ERROR_A_MATRIX_INVALID;
        end
        else if (!required_b_valid) begin
            configuration_error =
                ERROR_B_MATRIX_INVALID;
        end
    end

    // -------------------------------------------------------------------------
    // Tiled operation state
    // -------------------------------------------------------------------------

    logic [1:0] precision_q;
    logic [3:0] k_token_count_q;

    logic m_tile_q;
    logic n_tile_q;
    logic k_tile_q;

    logic [3:0] load_index_q;

    logic [2:0] engine_k_count;

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        engine_available_i &&
        (state_q == STATE_IDLE);

    assign busy_o =
        (state_q != STATE_IDLE);

    assign m_tile_o =
        m_tile_q;

    assign n_tile_o =
        n_tile_q;

    assign k_tile_o =
        k_tile_q;

    always @* begin
        if (!k_tile_q) begin
            if (k_token_count_q > 4'd4) begin
                engine_k_count = 3'd4;
            end
            else begin
                engine_k_count =
                    k_token_count_q[2:0];
            end
        end
        else begin
            engine_k_count =
                k_token_count_q[2:0] -
                3'd4;
        end
    end

    // -------------------------------------------------------------------------
    // Tile-buffer loading
    //
    // Engine A address:
    //
    //   local row * 4 + local K
    //
    // Engine B address:
    //
    //   local K * 4 + local column
    // -------------------------------------------------------------------------

    logic        engine_a_write_enable;
    logic [3:0]  engine_a_write_addr;
    logic [31:0] engine_a_write_data;

    logic        engine_b_write_enable;
    logic [3:0]  engine_b_write_addr;
    logic [31:0] engine_b_write_data;

    logic [2:0] a_global_row;
    logic [2:0] a_global_k;

    logic [2:0] b_global_k;
    logic [2:0] b_global_column;

    assign a_global_row =
        {
            m_tile_q,
            load_index_q[3:2]
        };

    assign a_global_k =
        {
            k_tile_q,
            load_index_q[1:0]
        };

    assign b_global_k =
        {
            k_tile_q,
            load_index_q[3:2]
        };

    assign b_global_column =
        {
            n_tile_q,
            load_index_q[1:0]
        };

    assign engine_a_write_enable =
        (state_q == STATE_LOAD);

    assign engine_a_write_addr =
        load_index_q;

    assign engine_a_write_data =
        a_matrix_q[
            {
                a_global_row,
                a_global_k
            }
        ];

    assign engine_b_write_enable =
        (state_q == STATE_LOAD);

    assign engine_b_write_addr =
        load_index_q;

    assign engine_b_write_data =
        b_matrix_q[
            {
                b_global_k,
                b_global_column
            }
        ];

    // -------------------------------------------------------------------------
    // External shared 4x4 GEMM-engine interface
    // -------------------------------------------------------------------------

    logic engine_start;

    logic engine_start_ready;
    logic engine_busy;
    logic engine_done;
    logic engine_error;
    logic [2:0] engine_error_code;

    logic [511:0] engine_accumulator;
    logic [15:0]  engine_accumulator_valid;

    logic [15:0] engine_invalid;
    logic [15:0] engine_overflow;
    logic [15:0] engine_underflow;
    logic [15:0] engine_inexact;

    assign engine_start =
        (state_q == STATE_START) &&
        engine_start_ready;

    // Controller requests.
    assign engine_clear_o =
        clear_i;

    assign engine_a_write_enable_o =
        engine_a_write_enable;

    assign engine_a_write_addr_o =
        engine_a_write_addr;

    assign engine_a_write_data_o =
        engine_a_write_data;

    assign engine_b_write_enable_o =
        engine_b_write_enable;

    assign engine_b_write_addr_o =
        engine_b_write_addr;

    assign engine_b_write_data_o =
        engine_b_write_data;

    assign engine_start_o =
        engine_start;

    assign engine_precision_o =
        precision_q;

    assign engine_k_count_o =
        engine_k_count;

    assign engine_accumulate_o =
        k_tile_q;

    // Physical-engine responses.
    assign engine_start_ready =
        engine_start_ready_i;

    assign engine_busy =
        engine_busy_i;

    assign engine_done =
        engine_done_i;

    assign engine_error =
        engine_error_i;

    assign engine_error_code =
        engine_error_code_i;

    assign engine_accumulator =
        engine_accumulator_i;

    assign engine_accumulator_valid =
        engine_accumulator_valid_i;

    assign engine_invalid =
        engine_invalid_i;

    assign engine_overflow =
        engine_overflow_i;

    assign engine_underflow =
        engine_underflow_i;

    assign engine_inexact =
        engine_inexact_i;

    // -------------------------------------------------------------------------
    // Complete 8x8 result storage
    // -------------------------------------------------------------------------

    logic [2047:0] result_q;
    logic [63:0]   result_valid_q;

    logic [63:0] result_invalid_q;
    logic [63:0] result_overflow_q;
    logic [63:0] result_underflow_q;
    logic [63:0] result_inexact_q;

    assign accumulator_o =
        result_q;

    assign accumulator_valid_o =
        result_valid_q;

    assign invalid_o =
        result_invalid_q;

    assign overflow_o =
        result_overflow_q;

    assign underflow_o =
        result_underflow_q;

    assign inexact_o =
        result_inexact_q;

    // -------------------------------------------------------------------------
    // M/N/K tile traversal FSM
    // -------------------------------------------------------------------------

    integer capture_row;
    integer capture_column;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;

            precision_q     <= INT8X4_PRECISION;
            k_token_count_q <= 4'd0;

            m_tile_q <= 1'b0;
            n_tile_q <= 1'b0;
            k_tile_q <= 1'b0;

            load_index_q <= 4'd0;

            done_o       <= 1'b0;
            error_o      <= 1'b0;
            error_code_o <= ERROR_NONE;

            result_q       <= 2048'd0;
            result_valid_q <= 64'd0;

            result_invalid_q   <= 64'd0;
            result_overflow_q  <= 64'd0;
            result_underflow_q <= 64'd0;
            result_inexact_q   <= 64'd0;
        end
        else begin
            done_o  <= 1'b0;
            error_o <= 1'b0;

            if (clear_i) begin
                state_q <= STATE_IDLE;

                precision_q     <= INT8X4_PRECISION;
                k_token_count_q <= 4'd0;

                m_tile_q <= 1'b0;
                n_tile_q <= 1'b0;
                k_tile_q <= 1'b0;

                load_index_q <= 4'd0;

                error_code_o <= ERROR_NONE;

                result_q       <= 2048'd0;
                result_valid_q <= 64'd0;

                result_invalid_q   <= 64'd0;
                result_overflow_q  <= 64'd0;
                result_underflow_q <= 64'd0;
                result_inexact_q   <= 64'd0;
            end
            else begin
                case (state_q)
                    STATE_IDLE: begin
                        if (
                            start_i &&
                            engine_available_i
                        ) begin
                            error_code_o <=
                                configuration_error;

                            if (
                                configuration_error !=
                                ERROR_NONE
                            ) begin
                                error_o <= 1'b1;
                            end
                            else begin
                                precision_q <=
                                    precision_i;

                                k_token_count_q <=
                                    k_token_count_i;

                                m_tile_q <= 1'b0;
                                n_tile_q <= 1'b0;
                                k_tile_q <= 1'b0;

                                load_index_q <=
                                    4'd0;

                                result_q       <= 2048'd0;
                                result_valid_q <= 64'd0;

                                result_invalid_q   <= 64'd0;
                                result_overflow_q  <= 64'd0;
                                result_underflow_q <= 64'd0;
                                result_inexact_q   <= 64'd0;

                                state_q <=
                                    STATE_LOAD;
                            end
                        end
                    end

                    STATE_LOAD: begin
                        // Tile writes occur through combinational write
                        // enables during this state.
                        if (load_index_q == 4'd15) begin
                            load_index_q <=
                                4'd0;

                            state_q <=
                                STATE_START;
                        end
                        else begin
                            load_index_q <=
                                load_index_q +
                                4'd1;
                        end
                    end

                    STATE_START: begin
                        if (engine_start_ready) begin
                            state_q <=
                                STATE_WAIT;
                        end
                    end

                    STATE_WAIT: begin
                        if (engine_error) begin
                            error_o <= 1'b1;

                            error_code_o <=
                                ERROR_ENGINE_FAILURE;

                            state_q <=
                                STATE_IDLE;
                        end
                        else if (engine_done) begin
                            if (
                                !k_tile_q &&
                                (k_token_count_q > 4'd4)
                            ) begin
                                // Load and accumulate K tile one.
                                k_tile_q <= 1'b1;

                                load_index_q <=
                                    4'd0;

                                state_q <=
                                    STATE_LOAD;
                            end
                            else begin
                                state_q <=
                                    STATE_CAPTURE;
                            end
                        end
                    end

                    STATE_CAPTURE: begin
                        // Copy one completed 4x4 output tile into its
                        // row-major location in the complete 8x8 result.
                        for (
                            capture_row = 0;
                            capture_row < 4;
                            capture_row = capture_row + 1
                        ) begin
                            for (
                                capture_column = 0;
                                capture_column < 4;
                                capture_column = capture_column + 1
                            ) begin
                                // Local row-major 4x4 index:
                                //
                                //   {local_row[1:0], local_column[1:0]}
                                //
                                // Global row-major 8x8 index:
                                //
                                //   {
                                //       M-tile,
                                //       local_row[1:0],
                                //       N-tile,
                                //       local_column[1:0]
                                //   }
                                //
                                // Appending five zeros converts an element
                                // index directly into its 32-bit vector offset.

                                result_q[
                                    {
                                        m_tile_q,
                                        capture_row[1:0],
                                        n_tile_q,
                                        capture_column[1:0],
                                        5'b00000
                                    } +: 32
                                ] <=
                                    engine_accumulator[
                                        {
                                            capture_row[1:0],
                                            capture_column[1:0],
                                            5'b00000
                                        } +: 32
                                    ];

                                result_valid_q[
                                    {
                                        m_tile_q,
                                        capture_row[1:0],
                                        n_tile_q,
                                        capture_column[1:0]
                                    }
                                ] <=
                                    engine_accumulator_valid[
                                        {
                                            capture_row[1:0],
                                            capture_column[1:0]
                                        }
                                    ];

                                result_invalid_q[
                                    {
                                        m_tile_q,
                                        capture_row[1:0],
                                        n_tile_q,
                                        capture_column[1:0]
                                    }
                                ] <=
                                    engine_invalid[
                                        {
                                            capture_row[1:0],
                                            capture_column[1:0]
                                        }
                                    ];

                                result_overflow_q[
                                    {
                                        m_tile_q,
                                        capture_row[1:0],
                                        n_tile_q,
                                        capture_column[1:0]
                                    }
                                ] <=
                                    engine_overflow[
                                        {
                                            capture_row[1:0],
                                            capture_column[1:0]
                                        }
                                    ];

                                result_underflow_q[
                                    {
                                        m_tile_q,
                                        capture_row[1:0],
                                        n_tile_q,
                                        capture_column[1:0]
                                    }
                                ] <=
                                    engine_underflow[
                                        {
                                            capture_row[1:0],
                                            capture_column[1:0]
                                        }
                                    ];

                                result_inexact_q[
                                    {
                                        m_tile_q,
                                        capture_row[1:0],
                                        n_tile_q,
                                        capture_column[1:0]
                                    }
                                ] <=
                                    engine_inexact[
                                        {
                                            capture_row[1:0],
                                            capture_column[1:0]
                                        }
                                    ];
                            end
                        end

                        k_tile_q <= 1'b0;
                        load_index_q <= 4'd0;

                        if (!n_tile_q) begin
                            n_tile_q <= 1'b1;

                            state_q <=
                                STATE_LOAD;
                        end
                        else if (!m_tile_q) begin
                            m_tile_q <= 1'b1;
                            n_tile_q <= 1'b0;

                            state_q <=
                                STATE_LOAD;
                        end
                        else begin
                            done_o       <= 1'b1;
                            error_code_o <= ERROR_NONE;

                            state_q <=
                                STATE_IDLE;
                        end
                    end

                    default: begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_ENGINE_FAILURE;

                        state_q <=
                            STATE_IDLE;
                    end
                endcase
            end
        end
    end

    // Engine busy and error-code details are observed indirectly through the
    // traversal state and engine error pulse.
    /* verilator lint_off UNUSEDSIGNAL */
    logic engine_busy_unused;
    logic [2:0] engine_error_code_unused;

    assign engine_busy_unused =
        engine_busy;

    assign engine_error_code_unused =
        engine_error_code;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
