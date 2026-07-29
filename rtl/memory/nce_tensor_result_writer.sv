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
// Tiled-GEMM result writer.
//
// A command reserves a consecutive output-memory range. The writer then waits
// for one capture pulse containing the complete row-major 8x8 FP32 result:
//
//   result index = row * 8 + column
//
// After capture, up to four consecutive words are written per cycle. Each lane
// is retired independently, allowing safe retry under partial ready/conflict
// conditions without duplicating already accepted writes.
// -----------------------------------------------------------------------------

module nce_tensor_result_writer #(
    parameter int unsigned BANK_COUNT = 4,
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned PORT_COUNT = 4,
    parameter int unsigned RESULT_WORDS = 64,

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

    parameter int unsigned RESULT_INDEX_WIDTH =
        (RESULT_WORDS <= 1)
        ? 1
        : $clog2(RESULT_WORDS),

    parameter int unsigned RESULT_COUNT_WIDTH =
        (RESULT_WORDS <= 1)
        ? 1
        : $clog2(RESULT_WORDS + 1),

    parameter int unsigned BYTE_COUNT =
        DATA_WIDTH / 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // Reserve an output-memory destination.
    input  logic start_i,
    output logic start_ready_o,

    input  logic [
        FLAT_ADDR_WIDTH-1:0
    ] output_base_addr_i,

    // Complete tiled-GEMM result capture.
    input  logic capture_i,

    input  logic [
        (RESULT_WORDS * DATA_WIDTH)-1:0
    ] result_data_i,

    input  logic [
        RESULT_WORDS-1:0
    ] result_valid_i,

    // Output/PSUM scratchpad write interface.
    output logic [
        PORT_COUNT-1:0
    ] output_write_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_write_addr_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_write_data_o,

    output logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] output_write_strb_o,

    input  logic [
        PORT_COUNT-1:0
    ] output_write_ready_i,

    input  logic [
        PORT_COUNT-1:0
    ] output_write_conflict_i,

    output logic busy_o,
    output logic waiting_for_result_o,

    output logic done_o,
    output logic error_o,
    output logic [2:0] error_code_o,

    output logic [
        RESULT_COUNT_WIDTH-1:0
    ] words_written_o
);

    localparam logic [1:0] STATE_IDLE  = 2'd0;
    localparam logic [1:0] STATE_WAIT  = 2'd1;
    localparam logic [1:0] STATE_WRITE = 2'd2;

    localparam logic [2:0] ERROR_NONE            = 3'd0;
    localparam logic [2:0] ERROR_OUTPUT_RANGE    = 3'd1;
    localparam logic [2:0] ERROR_RESULT_INVALID  = 3'd2;
    localparam logic [2:0] ERROR_INTERNAL_STATE  = 3'd3;

    localparam int unsigned RANGE_WIDTH =
        (
            FLAT_ADDR_WIDTH > RESULT_COUNT_WIDTH
        )
        ? FLAT_ADDR_WIDTH + 1
        : RESULT_COUNT_WIDTH + 1;

    localparam logic [RANGE_WIDTH-1:0] TOTAL_WORDS_EXT =
        RANGE_WIDTH'(TOTAL_WORDS);

    logic [1:0] state_q;

    logic [
        FLAT_ADDR_WIDTH-1:0
    ] output_base_addr_q;

    logic [
        RESULT_INDEX_WIDTH-1:0
    ] write_word_index_q;

    logic [
        PORT_COUNT-1:0
    ] pending_lane_q;

    logic [
        DATA_WIDTH-1:0
    ] result_buffer_q [0:RESULT_WORDS-1];

    logic [
        PORT_COUNT-1:0
    ] write_accept_mask;

    logic [
        PORT_COUNT-1:0
    ] pending_after_accept;

    logic [
        RESULT_COUNT_WIDTH-1:0
    ] accepted_word_count;

    logic [
        RANGE_WIDTH-1:0
    ] output_end_ext;

    logic output_range_valid;
    logic capture_valid;

    logic start_accept;
    logic capture_accept;
    logic batch_complete;
    logic final_batch;

    integer write_lane_index;
    integer capture_word_index;
    integer reset_word_index;

    function automatic logic [
        PORT_COUNT-1:0
    ] make_batch_mask (
        input logic [
            RESULT_INDEX_WIDTH-1:0
        ] base_index
    );
        integer mask_lane_index;

        begin
            make_batch_mask = '0;

            for (
                mask_lane_index = 0;
                mask_lane_index < PORT_COUNT;
                mask_lane_index = mask_lane_index + 1
            ) begin
                if (
                    (
                        RESULT_COUNT_WIDTH'(base_index) +
                        RESULT_COUNT_WIDTH'(mask_lane_index)
                    ) <
                    RESULT_COUNT_WIDTH'(RESULT_WORDS)
                ) begin
                    make_batch_mask[mask_lane_index] =
                        1'b1;
                end
            end
        end
    endfunction

    function automatic logic [
        RESULT_COUNT_WIDTH-1:0
    ] count_accepted_words (
        input logic [PORT_COUNT-1:0] lane_mask
    );
        integer count_lane_index;

        begin
            count_accepted_words = '0;

            for (
                count_lane_index = 0;
                count_lane_index < PORT_COUNT;
                count_lane_index = count_lane_index + 1
            ) begin
                if (lane_mask[count_lane_index]) begin
                    count_accepted_words =
                        count_accepted_words +
                        RESULT_COUNT_WIDTH'(1);
                end
            end
        end
    endfunction

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        (state_q == STATE_IDLE);

    assign start_accept =
        start_i &&
        start_ready_o;

    assign capture_accept =
        capture_i &&
        (state_q == STATE_WAIT);

    assign busy_o =
        (state_q != STATE_IDLE);

    assign waiting_for_result_o =
        (state_q == STATE_WAIT);

    assign output_end_ext =
        RANGE_WIDTH'(output_base_addr_i) +
        RANGE_WIDTH'(RESULT_WORDS);

    assign output_range_valid =
        output_end_ext <=
        TOTAL_WORDS_EXT;

    assign capture_valid =
        result_valid_i ==
        {RESULT_WORDS{1'b1}};

    // -------------------------------------------------------------------------
    // Scratchpad write generation
    // -------------------------------------------------------------------------

    always @* begin
        output_write_enable_o = '0;
        output_write_addr_o   = '0;
        output_write_data_o   = '0;
        output_write_strb_o   = '0;

        if (state_q == STATE_WRITE) begin
            for (
                write_lane_index = 0;
                write_lane_index < PORT_COUNT;
                write_lane_index = write_lane_index + 1
            ) begin
                if (pending_lane_q[write_lane_index]) begin
                    output_write_enable_o[
                        write_lane_index
                    ] = 1'b1;

                    output_write_addr_o[
                        (
                            write_lane_index *
                            FLAT_ADDR_WIDTH
                        ) +:
                        FLAT_ADDR_WIDTH
                    ] =
                        output_base_addr_q +
                        FLAT_ADDR_WIDTH'(write_word_index_q) +
                        FLAT_ADDR_WIDTH'(write_lane_index);

                    output_write_data_o[
                        (
                            write_lane_index *
                            DATA_WIDTH
                        ) +:
                        DATA_WIDTH
                    ] =
                        result_buffer_q[
                            write_word_index_q +
                            RESULT_INDEX_WIDTH'(write_lane_index)
                        ];

                    output_write_strb_o[
                        (
                            write_lane_index *
                            BYTE_COUNT
                        ) +:
                        BYTE_COUNT
                    ] =
                        {BYTE_COUNT{1'b1}};
                end
            end
        end
    end

    assign write_accept_mask =
        output_write_enable_o &
        output_write_ready_i &
        ~output_write_conflict_i;

    assign pending_after_accept =
        pending_lane_q &
        ~write_accept_mask;

    assign accepted_word_count =
        count_accepted_words(
            write_accept_mask
        );

    assign batch_complete =
        (state_q == STATE_WRITE) &&
        (pending_after_accept == '0);

    assign final_batch =
        (
            RESULT_COUNT_WIDTH'(write_word_index_q) +
            RESULT_COUNT_WIDTH'(PORT_COUNT)
        ) >=
        RESULT_COUNT_WIDTH'(RESULT_WORDS);

    // -------------------------------------------------------------------------
    // State and result storage
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <=
                STATE_IDLE;

            output_base_addr_q <=
                '0;

            write_word_index_q <=
                '0;

            pending_lane_q <=
                '0;

            words_written_o <=
                '0;

            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_code_o <=
                ERROR_NONE;

            for (
                reset_word_index = 0;
                reset_word_index < RESULT_WORDS;
                reset_word_index = reset_word_index + 1
            ) begin
                result_buffer_q[
                    reset_word_index
                ] <= '0;
            end
        end
        else if (clear_i) begin
            state_q <=
                STATE_IDLE;

            output_base_addr_q <=
                '0;

            write_word_index_q <=
                '0;

            pending_lane_q <=
                '0;

            words_written_o <=
                '0;

            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_code_o <=
                ERROR_NONE;

            for (
                reset_word_index = 0;
                reset_word_index < RESULT_WORDS;
                reset_word_index = reset_word_index + 1
            ) begin
                result_buffer_q[
                    reset_word_index
                ] <= '0;
            end
        end
        else begin
            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_code_o <=
                ERROR_NONE;

            case (state_q)
                STATE_IDLE: begin
                    if (start_accept) begin
                        words_written_o <=
                            '0;

                        write_word_index_q <=
                            '0;

                        pending_lane_q <=
                            '0;

                        if (!output_range_valid) begin
                            error_o <=
                                1'b1;

                            error_code_o <=
                                ERROR_OUTPUT_RANGE;
                        end
                        else begin
                            output_base_addr_q <=
                                output_base_addr_i;

                            state_q <=
                                STATE_WAIT;
                        end
                    end
                end

                STATE_WAIT: begin
                    if (capture_accept) begin
                        if (!capture_valid) begin
                            state_q <=
                                STATE_IDLE;

                            error_o <=
                                1'b1;

                            error_code_o <=
                                ERROR_RESULT_INVALID;
                        end
                        else begin
                            for (
                                capture_word_index = 0;
                                capture_word_index < RESULT_WORDS;
                                capture_word_index =
                                    capture_word_index + 1
                            ) begin
                                result_buffer_q[
                                    capture_word_index
                                ] <=
                                    result_data_i[
                                        (
                                            capture_word_index *
                                            DATA_WIDTH
                                        ) +:
                                        DATA_WIDTH
                                    ];
                            end

                            write_word_index_q <=
                                '0;

                            pending_lane_q <=
                                make_batch_mask('0);

                            state_q <=
                                STATE_WRITE;
                        end
                    end
                end

                STATE_WRITE: begin
                    words_written_o <=
                        words_written_o +
                        accepted_word_count;

                    if (batch_complete) begin
                        if (final_batch) begin
                            state_q <=
                                STATE_IDLE;

                            pending_lane_q <=
                                '0;

                            done_o <=
                                1'b1;
                        end
                        else begin
                            write_word_index_q <=
                                write_word_index_q +
                                RESULT_INDEX_WIDTH'(PORT_COUNT);

                            pending_lane_q <=
                                make_batch_mask(
                                    write_word_index_q +
                                    RESULT_INDEX_WIDTH'(PORT_COUNT)
                                );
                        end
                    end
                    else begin
                        pending_lane_q <=
                            pending_after_accept;
                    end
                end

                default: begin
                    state_q <=
                        STATE_IDLE;

                    pending_lane_q <=
                        '0;

                    error_o <=
                        1'b1;

                    error_code_o <=
                        ERROR_INTERNAL_STATE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
