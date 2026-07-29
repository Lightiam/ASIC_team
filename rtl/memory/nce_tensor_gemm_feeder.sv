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
// Tensor-memory to tiled-GEMM feeder.
//
// Memory layout expected by this transport:
//
//   Activation memory: compact row-major 8 x K
//   Weight memory:     compact row-major K x 8
//
// The pair reader emits 8*K sequential activation/weight pairs. This feeder
// converts those compact indices into the existing tiled-GEMM source layout:
//
//   A destination = {row[2:0], k[2:0]}       = row*8 + k
//   B destination = {k[2:0], column[2:0]}    = k*8 + column
//
// This correctly produces the sparse A validity pattern required for K < 8
// while B occupies the first K complete rows.
// -----------------------------------------------------------------------------

module nce_tensor_gemm_feeder #(
    parameter int unsigned BANK_COUNT = 4,
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned PORT_COUNT = 4,

    parameter int unsigned BANK_INDEX_WIDTH =
        (BANK_COUNT <= 1)
        ? 1
        : $clog2(BANK_COUNT),

    parameter int unsigned BANK_ADDR_WIDTH =
        (WORDS_PER_BANK <= 1)
        ? 1
        : $clog2(WORDS_PER_BANK),

    parameter int unsigned FLAT_ADDR_WIDTH =
        BANK_INDEX_WIDTH + BANK_ADDR_WIDTH,

    parameter int unsigned TOTAL_WORDS =
        BANK_COUNT * WORDS_PER_BANK,

    parameter int unsigned WORD_COUNT_WIDTH =
        (TOTAL_WORDS <= 1)
        ? 1
        : $clog2(TOTAL_WORDS + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // -------------------------------------------------------------------------
    // High-level tensor GEMM command
    // -------------------------------------------------------------------------

    input  logic start_i,
    output logic start_ready_o,

    input  logic [FLAT_ADDR_WIDTH-1:0] activation_base_addr_i,
    input  logic [FLAT_ADDR_WIDTH-1:0] weight_base_addr_i,

    input  logic [1:0] precision_i,
    input  logic [3:0] k_token_count_i,

    // -------------------------------------------------------------------------
    // Activation scratchpad read interface
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] activation_read_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] activation_read_addr_o,

    input  logic [PORT_COUNT-1:0] activation_read_ready_i,
    input  logic [PORT_COUNT-1:0] activation_read_conflict_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] activation_read_data_i,

    input  logic [PORT_COUNT-1:0] activation_read_valid_i,

    // -------------------------------------------------------------------------
    // Weight scratchpad read interface
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] weight_read_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] weight_read_addr_o,

    input  logic [PORT_COUNT-1:0] weight_read_ready_i,
    input  logic [PORT_COUNT-1:0] weight_read_conflict_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] weight_read_data_i,

    input  logic [PORT_COUNT-1:0] weight_read_valid_i,

    // -------------------------------------------------------------------------
    // Existing tiled-GEMM controller operand interface
    // -------------------------------------------------------------------------

    output logic tiled_a_write_enable_o,
    output logic [5:0] tiled_a_write_addr_o,
    output logic [31:0] tiled_a_write_data_o,

    output logic tiled_b_write_enable_o,
    output logic [5:0] tiled_b_write_addr_o,
    output logic [31:0] tiled_b_write_data_o,

    output logic tiled_start_o,
    input  logic tiled_start_ready_i,

    output logic [1:0] tiled_precision_o,
    output logic [3:0] tiled_k_token_count_o,

    input  logic tiled_busy_i,
    input  logic tiled_done_i,
    input  logic tiled_error_i,
    input  logic [2:0] tiled_error_code_i,

    // -------------------------------------------------------------------------
    // Feeder status
    // -------------------------------------------------------------------------

    output logic busy_o,
    output logic done_o,
    output logic error_o,
    output logic [2:0] error_code_o,
    output logic [2:0] error_detail_o,

    output logic [WORD_COUNT_WIDTH-1:0] words_loaded_o
);

    localparam logic [1:0] INT8X4_PRECISION = 2'b00;
    localparam logic [1:0] BF16X2_PRECISION = 2'b01;
    localparam logic [1:0] BF24_PRECISION   = 2'b10;

    localparam logic [2:0] STATE_IDLE  = 3'd0;
    localparam logic [2:0] STATE_LOAD  = 3'd1;
    localparam logic [2:0] STATE_START = 3'd2;
    localparam logic [2:0] STATE_WAIT  = 3'd3;

    localparam logic [2:0] ERROR_NONE              = 3'd0;
    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_READER            = 3'd3;
    localparam logic [2:0] ERROR_TILED_GEMM        = 3'd4;
    localparam logic [2:0] ERROR_INTERNAL_STATE    = 3'd5;

    logic [2:0] state_q;

    logic [1:0] precision_q;
    logic [3:0] k_token_count_q;

    // A traversal: row-major compact 8 x K.
    logic [2:0] a_row_q;
    logic [2:0] a_k_q;

    // B traversal: row-major compact K x 8.
    logic [2:0] b_k_q;
    logic [2:0] b_column_q;

    logic precision_valid;
    logic k_count_valid;
    logic [2:0] configuration_error;

    logic command_accept;

    // -------------------------------------------------------------------------
    // Pair-reader interface
    // -------------------------------------------------------------------------

    logic reader_start;
    logic reader_start_ready;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] reader_word_count;

    logic reader_pair_valid;
    logic reader_pair_ready;

    logic [5:0] reader_pair_index;
    logic [31:0] reader_activation_word;
    logic [31:0] reader_weight_word;
    logic reader_pair_last;

    logic reader_busy;
    logic reader_done;
    logic reader_error;
    logic [2:0] reader_error_code;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] reader_words_emitted;

    logic pair_accept;
    logic tiled_start_accept;

    assign busy_o =
        (state_q != STATE_IDLE);

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        (state_q == STATE_IDLE) &&
        reader_start_ready &&
        !tiled_busy_i;

    assign command_accept =
        start_i &&
        start_ready_o;

    assign reader_word_count =
        WORD_COUNT_WIDTH'(k_token_count_i) << 3;

    assign reader_start =
        command_accept &&
        (configuration_error == ERROR_NONE);

    assign reader_pair_ready =
        (state_q == STATE_LOAD);

    assign pair_accept =
        reader_pair_valid &&
        reader_pair_ready;

    assign tiled_a_write_enable_o =
        pair_accept;

    assign tiled_a_write_addr_o =
        {
            a_row_q,
            a_k_q
        };

    assign tiled_a_write_data_o =
        reader_activation_word;

    assign tiled_b_write_enable_o =
        pair_accept;

    assign tiled_b_write_addr_o =
        {
            b_k_q,
            b_column_q
        };

    assign tiled_b_write_data_o =
        reader_weight_word;

    assign tiled_start_o =
        (state_q == STATE_START);

    assign tiled_start_accept =
        tiled_start_o &&
        tiled_start_ready_i;

    assign tiled_precision_o =
        precision_q;

    assign tiled_k_token_count_o =
        k_token_count_q;

    assign words_loaded_o =
        reader_words_emitted;

    // Keep otherwise useful reader status signals visible to synthesis.
    logic reader_status_unused;

    assign reader_status_unused =
        (^reader_pair_index) ^
        reader_pair_last ^
        reader_busy ^
        reader_done;

    // -------------------------------------------------------------------------
    // Command validation
    // -------------------------------------------------------------------------

    always @* begin
        precision_valid =
            (precision_i == INT8X4_PRECISION) ||
            (precision_i == BF16X2_PRECISION) ||
            (precision_i == BF24_PRECISION);

        k_count_valid =
            (k_token_count_i >= 4'd1) &&
            (k_token_count_i <= 4'd8);

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
    end

    // -------------------------------------------------------------------------
    // Feeder control
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <=
                STATE_IDLE;

            precision_q <=
                INT8X4_PRECISION;

            k_token_count_q <=
                4'd0;

            a_row_q <=
                3'd0;

            a_k_q <=
                3'd0;

            b_k_q <=
                3'd0;

            b_column_q <=
                3'd0;

            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_code_o <=
                ERROR_NONE;

            error_detail_o <=
                3'd0;
        end
        else if (clear_i) begin
            state_q <=
                STATE_IDLE;

            precision_q <=
                INT8X4_PRECISION;

            k_token_count_q <=
                4'd0;

            a_row_q <=
                3'd0;

            a_k_q <=
                3'd0;

            b_k_q <=
                3'd0;

            b_column_q <=
                3'd0;

            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_code_o <=
                ERROR_NONE;

            error_detail_o <=
                3'd0;
        end
        else begin
            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_code_o <=
                ERROR_NONE;

            error_detail_o <=
                3'd0;

            case (state_q)
                STATE_IDLE: begin
                    if (command_accept) begin
                        a_row_q <=
                            3'd0;

                        a_k_q <=
                            3'd0;

                        b_k_q <=
                            3'd0;

                        b_column_q <=
                            3'd0;

                        if (
                            configuration_error !=
                            ERROR_NONE
                        ) begin
                            error_o <=
                                1'b1;

                            error_code_o <=
                                configuration_error;
                        end
                        else begin
                            precision_q <=
                                precision_i;

                            k_token_count_q <=
                                k_token_count_i;

                            state_q <=
                                STATE_LOAD;
                        end
                    end
                end

                STATE_LOAD: begin
                    if (reader_error) begin
                        state_q <=
                            STATE_IDLE;

                        error_o <=
                            1'b1;

                        error_code_o <=
                            ERROR_READER;

                        error_detail_o <=
                            reader_error_code;
                    end
                    else if (pair_accept) begin
                        // A compact order:
                        //   (row 0, k 0..K-1), ... (row 7, k 0..K-1)
                        if (
                            (
                                {1'b0, a_k_q} +
                                4'd1
                            ) >=
                            k_token_count_q
                        ) begin
                            a_k_q <=
                                3'd0;

                            a_row_q <=
                                a_row_q +
                                3'd1;
                        end
                        else begin
                            a_k_q <=
                                a_k_q +
                                3'd1;
                        end

                        // B compact order:
                        //   (k 0, columns 0..7), ... (k K-1, columns 0..7)
                        if (b_column_q == 3'd7) begin
                            b_column_q <=
                                3'd0;

                            b_k_q <=
                                b_k_q +
                                3'd1;
                        end
                        else begin
                            b_column_q <=
                                b_column_q +
                                3'd1;
                        end

                        if (reader_pair_last) begin
                            state_q <=
                                STATE_START;
                        end
                    end
                end

                STATE_START: begin
                    if (tiled_start_accept) begin
                        state_q <=
                            STATE_WAIT;
                    end
                end

                STATE_WAIT: begin
                    if (tiled_error_i) begin
                        state_q <=
                            STATE_IDLE;

                        error_o <=
                            1'b1;

                        error_code_o <=
                            ERROR_TILED_GEMM;

                        error_detail_o <=
                            tiled_error_code_i;
                    end
                    else if (tiled_done_i) begin
                        state_q <=
                            STATE_IDLE;

                        done_o <=
                            1'b1;
                    end
                end

                default: begin
                    state_q <=
                        STATE_IDLE;

                    error_o <=
                        1'b1;

                    error_code_o <=
                        ERROR_INTERNAL_STATE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Synchronized tensor pair reader
    // -------------------------------------------------------------------------

    nce_tensor_pair_reader #(
        .BANK_COUNT          (BANK_COUNT),
        .WORDS_PER_BANK      (WORDS_PER_BANK),
        .DATA_WIDTH          (DATA_WIDTH),
        .PORT_COUNT          (PORT_COUNT),
        .BANK_INDEX_WIDTH    (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH     (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH     (FLAT_ADDR_WIDTH),
        .TOTAL_WORDS         (TOTAL_WORDS),
        .WORD_COUNT_WIDTH    (WORD_COUNT_WIDTH),
        .MAX_TRANSFER_WORDS  (64),
        .PAIR_INDEX_WIDTH    (6)
    ) u_pair_reader (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (reader_start),
        .start_ready_o               (reader_start_ready),

        .activation_base_addr_i      (activation_base_addr_i),
        .weight_base_addr_i          (weight_base_addr_i),
        .word_count_i                (reader_word_count),

        .activation_read_enable_o    (activation_read_enable_o),
        .activation_read_addr_o      (activation_read_addr_o),
        .activation_read_ready_i     (activation_read_ready_i),
        .activation_read_conflict_i  (activation_read_conflict_i),
        .activation_read_data_i      (activation_read_data_i),
        .activation_read_valid_i     (activation_read_valid_i),

        .weight_read_enable_o        (weight_read_enable_o),
        .weight_read_addr_o          (weight_read_addr_o),
        .weight_read_ready_i         (weight_read_ready_i),
        .weight_read_conflict_i      (weight_read_conflict_i),
        .weight_read_data_i          (weight_read_data_i),
        .weight_read_valid_i         (weight_read_valid_i),

        .pair_valid_o                (reader_pair_valid),
        .pair_ready_i                (reader_pair_ready),
        .pair_index_o                (reader_pair_index),
        .activation_word_o           (reader_activation_word),
        .weight_word_o               (reader_weight_word),
        .pair_last_o                 (reader_pair_last),

        .busy_o                      (reader_busy),
        .done_o                      (reader_done),
        .error_o                     (reader_error),
        .error_code_o                (reader_error_code),
        .words_emitted_o             (reader_words_emitted)
    );

endmodule

`default_nettype wire
