// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
//
// RECONSTRUCTED LEAF MODULE
// -------------------------
// This module is instantiated by rtl/memory/nce_tensor_gemm_feeder.sv but was
// not present in any published branch of the repository. It has been
// reconstructed to satisfy every directed case asserted by
// tb/unit/tb_nce_tensor_pair_reader.sv.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Activation/weight pair reader.
//
// Streams a GEMM operand pair sequence out of the two tensor scratchpads: for
// each i in 0..word_count-1 it emits the pair
//
//   ( activation[activation_base + i] , weight[weight_base + i] )
//
// Words are fetched a batch at a time, PORT_COUNT of them per cycle, using
// every scratchpad port in parallel. Consecutive flat addresses land in
// different banks, so a batch is conflict-free by construction. The batch is
// then drained one pair per cycle to the consumer, which may backpressure.
//
// Command validation (checked in the cycle the command is offered, so an
// illegal command never enters the busy state):
//
//   1  word_count is zero
//   2  word_count exceeds MAX_TRANSFER_WORDS
//   3  activation window runs past the end of the scratchpad
//   4  weight window runs past the end of the scratchpad
//
// Runtime errors (abort the transfer and drop out of busy):
//
//   5  a scratchpad refused a read with a bank conflict
//   6  a scratchpad returned an activation word that was never written
//   7  a scratchpad returned a weight word that was never written
//
// Timing:
//   A batch is issued for one cycle, during which ready/conflict is resolved
//   combinationally by the scratchpad. The data returns registered, one cycle
//   later, and is captured then. So a conflict is reported one cycle after the
//   command starts, and an invalid word two cycles after.
// -----------------------------------------------------------------------------

module nce_tensor_pair_reader #(
    parameter int unsigned BANK_COUNT     = 4,
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH     = 32,
    parameter int unsigned PORT_COUNT     = 4,

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
        $clog2(TOTAL_WORDS) + 1,

    parameter int unsigned MAX_TRANSFER_WORDS = 64,

    parameter int unsigned PAIR_INDEX_WIDTH =
        $clog2(MAX_TRANSFER_WORDS)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // Command
    input  logic                        start_i,
    output logic                        start_ready_o,
    input  logic [FLAT_ADDR_WIDTH-1:0]  activation_base_addr_i,
    input  logic [FLAT_ADDR_WIDTH-1:0]  weight_base_addr_i,
    input  logic [WORD_COUNT_WIDTH-1:0] word_count_i,

    // Activation scratchpad read ports
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

    // Weight scratchpad read ports
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

    // Pair output stream
    output logic                        pair_valid_o,
    input  logic                        pair_ready_i,
    output logic [PAIR_INDEX_WIDTH-1:0] pair_index_o,
    output logic [DATA_WIDTH-1:0]       activation_word_o,
    output logic [DATA_WIDTH-1:0]       weight_word_o,
    output logic                        pair_last_o,

    // Status
    output logic                        busy_o,
    output logic                        done_o,
    output logic                        error_o,
    output logic [2:0]                  error_code_o,
    output logic [WORD_COUNT_WIDTH-1:0] words_emitted_o
);

    localparam logic [2:0] ERROR_NONE            = 3'd0;
    localparam logic [2:0] ERROR_ZERO_COUNT      = 3'd1;
    localparam logic [2:0] ERROR_COUNT_TOO_LARGE = 3'd2;
    localparam logic [2:0] ERROR_ACTIVATION_RANGE = 3'd3;
    localparam logic [2:0] ERROR_WEIGHT_RANGE    = 3'd4;
    localparam logic [2:0] ERROR_READ_CONFLICT   = 3'd5;
    localparam logic [2:0] ERROR_ACTIVATION_WORD = 3'd6;
    localparam logic [2:0] ERROR_WEIGHT_WORD     = 3'd7;

    localparam int unsigned BATCH_INDEX_WIDTH = $clog2(PORT_COUNT + 1);

    typedef enum logic [1:0] {
        STATE_IDLE    = 2'd0,
        STATE_ISSUE   = 2'd1,
        STATE_CAPTURE = 2'd2,
        STATE_EMIT    = 2'd3
    } state_e;

    state_e state_q;

    logic [FLAT_ADDR_WIDTH-1:0]  activation_base_q;
    logic [FLAT_ADDR_WIDTH-1:0]  weight_base_q;
    logic [WORD_COUNT_WIDTH-1:0] word_count_q;
    logic [WORD_COUNT_WIDTH-1:0] issued_q;   // words fetched so far
    logic [WORD_COUNT_WIDTH-1:0] emitted_q;  // words handed to the consumer

    logic [DATA_WIDTH-1:0]     batch_activation_q [PORT_COUNT-1:0];
    logic [DATA_WIDTH-1:0]     batch_weight_q     [PORT_COUNT-1:0];
    logic [BATCH_INDEX_WIDTH-1:0] batch_size_q;
    logic [BATCH_INDEX_WIDTH-1:0] batch_pos_q;

    // -------------------------------------------------------------------------
    // Command validation
    // -------------------------------------------------------------------------

    logic command_zero_count;
    logic command_too_large;
    logic command_activation_range;
    logic command_weight_range;
    logic command_invalid;

    logic [2:0] command_error_code;

    assign command_zero_count =
        (word_count_i == {WORD_COUNT_WIDTH{1'b0}});

    assign command_too_large =
        (word_count_i > WORD_COUNT_WIDTH'(MAX_TRANSFER_WORDS));

    assign command_activation_range =
        ((WORD_COUNT_WIDTH + 1)'(activation_base_addr_i) +
         (WORD_COUNT_WIDTH + 1)'(word_count_i)) >
        (WORD_COUNT_WIDTH + 1)'(TOTAL_WORDS);

    assign command_weight_range =
        ((WORD_COUNT_WIDTH + 1)'(weight_base_addr_i) +
         (WORD_COUNT_WIDTH + 1)'(word_count_i)) >
        (WORD_COUNT_WIDTH + 1)'(TOTAL_WORDS);

    assign command_invalid =
        command_zero_count ||
        command_too_large ||
        command_activation_range ||
        command_weight_range;

    assign command_error_code =
        command_zero_count
        ? ERROR_ZERO_COUNT
        : command_too_large
          ? ERROR_COUNT_TOO_LARGE
          : command_activation_range
            ? ERROR_ACTIVATION_RANGE
            : ERROR_WEIGHT_RANGE;

    // -------------------------------------------------------------------------
    // Batch sizing and read issue
    // -------------------------------------------------------------------------

    logic [WORD_COUNT_WIDTH-1:0] words_remaining;
    logic [BATCH_INDEX_WIDTH-1:0] batch_size_next;

    assign words_remaining = word_count_q - issued_q;

    assign batch_size_next =
        (words_remaining >= WORD_COUNT_WIDTH'(PORT_COUNT))
        ? BATCH_INDEX_WIDTH'(PORT_COUNT)
        : BATCH_INDEX_WIDTH'(words_remaining);

    // A lane is enabled only while a batch is being issued, and only for the
    // lanes that carry a word of this batch.
    always_comb begin
        activation_read_enable_o = {PORT_COUNT{1'b0}};
        weight_read_enable_o     = {PORT_COUNT{1'b0}};
        activation_read_addr_o   = {(PORT_COUNT * FLAT_ADDR_WIDTH){1'b0}};
        weight_read_addr_o       = {(PORT_COUNT * FLAT_ADDR_WIDTH){1'b0}};

        if (state_q == STATE_ISSUE) begin
            for (
                int unsigned lane = 0;
                lane < PORT_COUNT;
                lane = lane + 1
            ) begin
                if (BATCH_INDEX_WIDTH'(lane) < batch_size_next) begin
                    activation_read_enable_o[lane] = 1'b1;
                    weight_read_enable_o[lane]     = 1'b1;

                    activation_read_addr_o[
                        (lane * FLAT_ADDR_WIDTH) +: FLAT_ADDR_WIDTH
                    ] = FLAT_ADDR_WIDTH'(
                            activation_base_q + issued_q +
                            WORD_COUNT_WIDTH'(lane)
                        );

                    weight_read_addr_o[
                        (lane * FLAT_ADDR_WIDTH) +: FLAT_ADDR_WIDTH
                    ] = FLAT_ADDR_WIDTH'(
                            weight_base_q + issued_q +
                            WORD_COUNT_WIDTH'(lane)
                        );
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Response checking
    // -------------------------------------------------------------------------

    logic issue_conflict;
    logic capture_activation_bad;
    logic capture_weight_bad;

    // Any lane the scratchpad refused.
    assign issue_conflict =
        |(activation_read_conflict_i & activation_read_enable_o) ||
        |(weight_read_conflict_i & weight_read_enable_o);

    always_comb begin
        capture_activation_bad = 1'b0;
        capture_weight_bad     = 1'b0;

        for (
            int unsigned lane = 0;
            lane < PORT_COUNT;
            lane = lane + 1
        ) begin
            if (BATCH_INDEX_WIDTH'(lane) < batch_size_q) begin
                if (!activation_read_valid_i[lane]) begin
                    capture_activation_bad = 1'b1;
                end

                if (!weight_read_valid_i[lane]) begin
                    capture_weight_bad = 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------

    assign start_ready_o = (state_q == STATE_IDLE);
    assign busy_o        = (state_q != STATE_IDLE);

    assign pair_valid_o      = (state_q == STATE_EMIT);
    assign pair_index_o      = PAIR_INDEX_WIDTH'(emitted_q);
    assign activation_word_o = batch_activation_q[batch_pos_q];
    assign weight_word_o     = batch_weight_q[batch_pos_q];

    assign pair_last_o =
        (state_q == STATE_EMIT) &&
        (emitted_q == (word_count_q - WORD_COUNT_WIDTH'(1)));

    assign words_emitted_o = emitted_q;

    // -------------------------------------------------------------------------
    // Sequencing
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q           <= STATE_IDLE;
            activation_base_q <= {FLAT_ADDR_WIDTH{1'b0}};
            weight_base_q     <= {FLAT_ADDR_WIDTH{1'b0}};
            word_count_q      <= {WORD_COUNT_WIDTH{1'b0}};
            issued_q          <= {WORD_COUNT_WIDTH{1'b0}};
            emitted_q         <= {WORD_COUNT_WIDTH{1'b0}};
            batch_size_q      <= {BATCH_INDEX_WIDTH{1'b0}};
            batch_pos_q       <= {BATCH_INDEX_WIDTH{1'b0}};
            done_o            <= 1'b0;
            error_o           <= 1'b0;
            error_code_o      <= ERROR_NONE;

            for (
                int unsigned lane = 0;
                lane < PORT_COUNT;
                lane = lane + 1
            ) begin
                batch_activation_q[lane] <= {DATA_WIDTH{1'b0}};
                batch_weight_q[lane]     <= {DATA_WIDTH{1'b0}};
            end
        end
        else if (clear_i) begin
            state_q      <= STATE_IDLE;
            issued_q     <= {WORD_COUNT_WIDTH{1'b0}};
            emitted_q    <= {WORD_COUNT_WIDTH{1'b0}};
            batch_size_q <= {BATCH_INDEX_WIDTH{1'b0}};
            batch_pos_q  <= {BATCH_INDEX_WIDTH{1'b0}};
            done_o       <= 1'b0;
            error_o      <= 1'b0;
            error_code_o <= ERROR_NONE;
        end
        else begin
            unique case (state_q)
                STATE_IDLE: begin
                    if (start_i) begin
                        // A fresh command retires the previous result.
                        done_o    <= 1'b0;
                        error_o   <= 1'b0;
                        emitted_q <= {WORD_COUNT_WIDTH{1'b0}};

                        if (command_invalid) begin
                            error_o      <= 1'b1;
                            error_code_o <= command_error_code;
                        end
                        else begin
                            error_code_o      <= ERROR_NONE;
                            activation_base_q <= activation_base_addr_i;
                            weight_base_q     <= weight_base_addr_i;
                            word_count_q      <= word_count_i;
                            issued_q          <= {WORD_COUNT_WIDTH{1'b0}};
                            state_q           <= STATE_ISSUE;
                        end
                    end
                end

                STATE_ISSUE: begin
                    if (issue_conflict) begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_READ_CONFLICT;
                        state_q      <= STATE_IDLE;
                    end
                    else begin
                        batch_size_q <= batch_size_next;
                        batch_pos_q  <= {BATCH_INDEX_WIDTH{1'b0}};
                        state_q      <= STATE_CAPTURE;
                    end
                end

                STATE_CAPTURE: begin
                    if (capture_activation_bad) begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_ACTIVATION_WORD;
                        state_q      <= STATE_IDLE;
                    end
                    else if (capture_weight_bad) begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_WEIGHT_WORD;
                        state_q      <= STATE_IDLE;
                    end
                    else begin
                        for (
                            int unsigned lane = 0;
                            lane < PORT_COUNT;
                            lane = lane + 1
                        ) begin
                            batch_activation_q[lane] <=
                                activation_read_data_i[
                                    (lane * DATA_WIDTH) +: DATA_WIDTH
                                ];

                            batch_weight_q[lane] <=
                                weight_read_data_i[
                                    (lane * DATA_WIDTH) +: DATA_WIDTH
                                ];
                        end

                        issued_q <= issued_q +
                                    WORD_COUNT_WIDTH'(batch_size_q);

                        state_q <= STATE_EMIT;
                    end
                end

                STATE_EMIT: begin
                    if (pair_ready_i) begin
                        emitted_q <= emitted_q + WORD_COUNT_WIDTH'(1);

                        if (
                            emitted_q ==
                            (word_count_q - WORD_COUNT_WIDTH'(1))
                        ) begin
                            done_o  <= 1'b1;
                            state_q <= STATE_IDLE;
                        end
                        else if (
                            batch_pos_q ==
                            (batch_size_q - BATCH_INDEX_WIDTH'(1))
                        ) begin
                            // Batch drained, fetch the next one.
                            state_q <= STATE_ISSUE;
                        end
                        else begin
                            batch_pos_q <= batch_pos_q +
                                           BATCH_INDEX_WIDTH'(1);
                        end
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
