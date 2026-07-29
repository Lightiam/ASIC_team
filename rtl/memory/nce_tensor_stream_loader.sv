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
// Burst-capable tensor stream loader.
//
// The loader accepts one streaming beat containing up to PORT_COUNT consecutive
// 32-bit words and converts it into parallel flat-address scratchpad writes.
//
// Default configuration:
//
//   Scratchpad size:       1024 words / 4 KB
//   Stream beat width:     4 x 32 bits = 128 bits
//   Maximum throughput:    4 words per clock
//
// The requested transfer is defined by:
//
//   base_addr_i
//   word_count_i
//
// The producer must assert stream_last_i on the final transfer beat.
//
// Error codes:
//
//   0: no error
//   1: zero transfer length
//   2: transfer exceeds scratchpad range
//   3: stream_last asserted too early
//   4: stream_last missing on final beat
//   5: zero byte-strobe on an active word
//
// The loader does not contain storage. It connects to nce_tensor_scratchpad or
// another flat-address memory through the memory-write interface.
// -----------------------------------------------------------------------------

module nce_tensor_stream_loader #(
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
        : $clog2(TOTAL_WORDS + 1),

    parameter int unsigned BYTE_COUNT =
        DATA_WIDTH / 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // -------------------------------------------------------------------------
    // Transfer command
    // -------------------------------------------------------------------------

    input  logic start_i,
    output logic start_ready_o,

    input  logic [FLAT_ADDR_WIDTH-1:0] base_addr_i,
    input  logic [WORD_COUNT_WIDTH-1:0] word_count_i,

    // -------------------------------------------------------------------------
    // Streaming input
    // -------------------------------------------------------------------------

    input  logic stream_valid_i,
    output logic stream_ready_o,
    input  logic stream_last_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] stream_data_i,

    input  logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] stream_strb_i,

    // -------------------------------------------------------------------------
    // Flat-address scratchpad writes
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] memory_write_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] memory_write_addr_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] memory_write_data_o,

    output logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] memory_write_strb_o,

    input  logic [PORT_COUNT-1:0] memory_write_ready_i,

    // -------------------------------------------------------------------------
    // Status
    // -------------------------------------------------------------------------

    output logic busy_o,
    output logic done_o,
    output logic error_o,
    output logic [2:0] error_code_o,

    output logic [
        WORD_COUNT_WIDTH-1:0
    ] words_written_o
);

    localparam logic [2:0] ERROR_NONE         = 3'd0;
    localparam logic [2:0] ERROR_ZERO_LENGTH  = 3'd1;
    localparam logic [2:0] ERROR_RANGE        = 3'd2;
    localparam logic [2:0] ERROR_EARLY_LAST   = 3'd3;
    localparam logic [2:0] ERROR_MISSING_LAST = 3'd4;
    localparam logic [2:0] ERROR_ZERO_STROBE  = 3'd5;

    localparam logic [WORD_COUNT_WIDTH:0] TOTAL_WORDS_EXT =
        {
            1'b0,
            WORD_COUNT_WIDTH'(TOTAL_WORDS)
        };

    logic busy_q;

    logic [FLAT_ADDR_WIDTH-1:0] next_addr_q;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] words_remaining_q;

    logic [PORT_COUNT-1:0] active_lane;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] beat_word_count;

    logic expected_last;
    logic last_ok;
    logic strobe_ok;
    logic memory_ready_all;
    logic malformed_beat;
    logic beat_accept;

    logic [WORD_COUNT_WIDTH:0] base_addr_ext;
    logic [WORD_COUNT_WIDTH:0] transfer_end_ext;

    // Separate procedural loop counters prevent event-driven simulators
    // from repeatedly triggering one combinational block from another.
    integer request_lane_index;
    integer ready_lane_index;

    assign busy_o = busy_q;

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        !busy_q;

    assign base_addr_ext =
        {
            {
                (
                    WORD_COUNT_WIDTH + 1 -
                    FLAT_ADDR_WIDTH
                )
                {1'b0}
            },
            base_addr_i
        };

    assign transfer_end_ext =
        base_addr_ext +
        {1'b0, word_count_i};

    // -------------------------------------------------------------------------
    // Beat construction and memory-write request generation
    //
    // This logic does not depend on memory_write_ready_i. Write-valid/request
    // must be generated independently of downstream ready.
    // -------------------------------------------------------------------------

    always @* begin
        active_lane           = '0;
        beat_word_count       = '0;

        memory_write_enable_o = '0;
        memory_write_addr_o   = '0;
        memory_write_data_o   = '0;
        memory_write_strb_o   = '0;

        expected_last  = 1'b0;
        last_ok        = 1'b1;
        strobe_ok      = 1'b1;
        malformed_beat = 1'b0;

        if (busy_q) begin
            if (
                words_remaining_q >=
                WORD_COUNT_WIDTH'(PORT_COUNT)
            ) begin
                beat_word_count =
                    WORD_COUNT_WIDTH'(PORT_COUNT);
            end
            else begin
                beat_word_count =
                    words_remaining_q;
            end

            expected_last =
                (
                    words_remaining_q <=
                    WORD_COUNT_WIDTH'(PORT_COUNT)
                );

            last_ok =
                (stream_last_i == expected_last);

            if (stream_valid_i) begin
                for (
                    request_lane_index = 0;
                    request_lane_index < PORT_COUNT;
                    request_lane_index = request_lane_index + 1
                ) begin
                    if (
                        words_remaining_q >
                        WORD_COUNT_WIDTH'(request_lane_index)
                    ) begin
                        active_lane[request_lane_index] = 1'b1;

                        memory_write_addr_o[
                            (
                                request_lane_index *
                                FLAT_ADDR_WIDTH
                            ) +:
                            FLAT_ADDR_WIDTH
                        ] =
                            next_addr_q +
                            FLAT_ADDR_WIDTH'(request_lane_index);

                        memory_write_data_o[
                            (request_lane_index * DATA_WIDTH) +:
                            DATA_WIDTH
                        ] = stream_data_i[
                            (request_lane_index * DATA_WIDTH) +:
                            DATA_WIDTH
                        ];

                        memory_write_strb_o[
                            (request_lane_index * BYTE_COUNT) +:
                            BYTE_COUNT
                        ] = stream_strb_i[
                            (request_lane_index * BYTE_COUNT) +:
                            BYTE_COUNT
                        ];

                        if (
                            !(
                                |stream_strb_i[
                                    (
                                        request_lane_index *
                                        BYTE_COUNT
                                    ) +:
                                    BYTE_COUNT
                                ]
                            )
                        ) begin
                            strobe_ok = 1'b0;
                        end
                    end
                end

                malformed_beat =
                    !last_ok ||
                    !strobe_ok;

                // Valid write requests are presented independently of ready.
                // Malformed beats are consumed without touching memory.
                if (!malformed_beat) begin
                    memory_write_enable_o =
                        active_lane;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Downstream-ready aggregation
    //
    // This block reads memory ready but does not generate memory write-enable,
    // preventing a combinational valid/ready feedback loop.
    // -------------------------------------------------------------------------

    always @* begin
        memory_ready_all = 1'b1;
        stream_ready_o   = 1'b0;

        if (
            busy_q &&
            stream_valid_i
        ) begin
            if (malformed_beat) begin
                // Consume the malformed beat so that the sequential control
                // logic can terminate the transfer and report its error.
                stream_ready_o = 1'b1;
            end
            else begin
                for (
                    ready_lane_index = 0;
                    ready_lane_index < PORT_COUNT;
                    ready_lane_index = ready_lane_index + 1
                ) begin
                    if (
                        active_lane[ready_lane_index] &&
                        !memory_write_ready_i[ready_lane_index]
                    ) begin
                        memory_ready_all = 1'b0;
                    end
                end

                stream_ready_o =
                    memory_ready_all;
            end
        end
    end

    assign beat_accept =
        stream_valid_i &&
        stream_ready_o;

    // -------------------------------------------------------------------------
    // Transfer control and accounting
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            busy_q            <= 1'b0;
            done_o            <= 1'b0;
            error_o           <= 1'b0;
            error_code_o      <= ERROR_NONE;
            next_addr_q       <= '0;
            words_remaining_q <= '0;
            words_written_o   <= '0;
        end
        else if (clear_i) begin
            busy_q            <= 1'b0;
            done_o            <= 1'b0;
            error_o           <= 1'b0;
            error_code_o      <= ERROR_NONE;
            next_addr_q       <= '0;
            words_remaining_q <= '0;
            words_written_o   <= '0;
        end
        else begin
            done_o       <= 1'b0;
            error_o      <= 1'b0;
            error_code_o <= ERROR_NONE;

            if (!busy_q) begin
                if (start_i) begin
                    words_written_o <= '0;

                    if (word_count_i == '0) begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_ZERO_LENGTH;
                    end
                    else if (
                        transfer_end_ext >
                        TOTAL_WORDS_EXT
                    ) begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_RANGE;
                    end
                    else begin
                        busy_q            <= 1'b1;
                        next_addr_q       <= base_addr_i;
                        words_remaining_q <= word_count_i;
                    end
                end
            end
            else if (beat_accept) begin
                if (!last_ok) begin
                    busy_q <= 1'b0;
                    error_o <= 1'b1;

                    if (stream_last_i) begin
                        error_code_o <= ERROR_EARLY_LAST;
                    end
                    else begin
                        error_code_o <= ERROR_MISSING_LAST;
                    end
                end
                else if (!strobe_ok) begin
                    busy_q       <= 1'b0;
                    error_o      <= 1'b1;
                    error_code_o <= ERROR_ZERO_STROBE;
                end
                else begin
                    words_written_o <=
                        words_written_o +
                        beat_word_count;

                    if (
                        words_remaining_q <=
                        WORD_COUNT_WIDTH'(PORT_COUNT)
                    ) begin
                        busy_q            <= 1'b0;
                        done_o            <= 1'b1;
                        words_remaining_q <= '0;
                    end
                    else begin
                        next_addr_q <=
                            next_addr_q +
                            FLAT_ADDR_WIDTH'(PORT_COUNT);

                        words_remaining_q <=
                            words_remaining_q -
                            WORD_COUNT_WIDTH'(PORT_COUNT);
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
