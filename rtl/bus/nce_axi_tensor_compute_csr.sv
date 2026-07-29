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
// AXI-backend-style CSR extension for tensor-memory loading, autonomous tensor
// GEMM, and output-scratchpad readback.
//
// Address map:
//
//   0x500 LOADER_CONTROL
//         bit 0 start loader
//         bit 1 clear complete tensor subsystem and all sticky status
//         bit 2 clear loader sticky status
//
//   0x504 LOADER_STATUS
//         bit 0     loader start ready
//         bit 1     loader busy
//         bit 2     loader done sticky
//         bit 3     loader error sticky
//         bits 6:4  loader error code
//         bit 8     stream ready
//         bits 10:9 active loader target
//
//   0x508 LOADER_CONFIG
//         bits 1:0 target: 0 activation, 1 weight, 2 output, 3 invalid
//
//   0x50C LOADER_BASE
//   0x510 LOADER_WORD_COUNT
//   0x514 LOADER_WORDS_WRITTEN
//
//   0x520 STREAM_DATA_0
//   0x524 STREAM_DATA_1
//   0x528 STREAM_DATA_2
//   0x52C STREAM_DATA_3
//   0x530 STREAM_STROBE
//         bits 15:0 byte strobes for the four staged words
//
//   0x534 STREAM_CONTROL
//         bit 0 push staged 128-bit beat
//         bit 1 assert stream_last with this push
//
//   0x540 GEMM_ACTIVATION_BASE
//   0x544 GEMM_WEIGHT_BASE
//   0x548 GEMM_OUTPUT_BASE
//
//   0x54C GEMM_CONFIG
//         bits 1:0 precision
//         bits 7:4 packed K-token count
//
//   0x550 GEMM_CONTROL
//         bit 0 start tensor GEMM
//         bit 1 clear complete tensor subsystem and all sticky status
//         bit 2 clear GEMM sticky status
//
//   0x554 GEMM_STATUS
//         bit 0     GEMM start ready
//         bit 1     GEMM busy
//         bit 2     compute done sticky
//         bit 3     complete writeback done sticky
//         bit 4     error sticky
//         bit 8     all 64 result values valid
//         bits 15:12 any invalid/overflow/underflow/inexact
//
//   0x558 GEMM_ERROR
//         bits 1:0   error source
//         bits 6:4   error code
//         bits 10:8  error detail
//
//   0x55C GEMM_WORDS_LOADED
//   0x560 GEMM_WORDS_WRITTEN
//   0x564 RESULT_VALID_LOW
//   0x568 RESULT_VALID_HIGH
//   0x56C ARITHMETIC_SUMMARY
//         bit 0 any invalid
//         bit 1 any overflow
//         bit 2 any underflow
//         bit 3 any inexact
//
//   0x570 OUTPUT_READ_ADDRESS
//
//   0x574 OUTPUT_READ_CONTROL_STATUS
//         write bit 0: issue one output-memory read
//         write bit 1: clear output-read status/data
//
//         read bit 0: issue ready
//         read bit 1: read pending
//         read bit 2: captured data valid
//         read bit 3: conflict sticky
//         read bit 4: memory lane-0 ready
//
//   0x578 OUTPUT_READ_DATA
// -----------------------------------------------------------------------------

module nce_axi_tensor_compute_csr #(
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

    // -------------------------------------------------------------------------
    // AXI-backend request interface
    // -------------------------------------------------------------------------

    input  logic        write_valid_i,
    output logic        write_ready_o,
    input  logic [31:0] write_addr_i,
    input  logic [31:0] write_data_i,
    input  logic [3:0]  write_strb_i,
    output logic        write_error_o,

    input  logic        read_valid_i,
    output logic        read_ready_o,
    input  logic [31:0] read_addr_i,
    output logic [31:0] read_data_o,
    output logic        read_error_o,

    // Clears tensor memories, loader, GEMM client, and local status.
    output logic tensor_clear_o,

    // -------------------------------------------------------------------------
    // Tensor-memory loader command
    // -------------------------------------------------------------------------

    output logic loader_start_o,
    input  logic loader_start_ready_i,

    output logic [1:0] loader_target_o,

    output logic [FLAT_ADDR_WIDTH-1:0] loader_base_addr_o,

    output logic [
        WORD_COUNT_WIDTH-1:0
    ] loader_word_count_o,

    output logic stream_valid_o,
    input  logic stream_ready_i,
    output logic stream_last_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] stream_data_o,

    output logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] stream_strb_o,

    input logic loader_busy_i,
    input logic loader_done_i,
    input logic loader_error_i,
    input logic [2:0] loader_error_code_i,

    input logic [
        WORD_COUNT_WIDTH-1:0
    ] loader_words_written_i,

    input logic [1:0] loader_active_target_i,

    // -------------------------------------------------------------------------
    // Autonomous tensor GEMM command and status
    // -------------------------------------------------------------------------

    output logic gemm_start_o,
    input  logic gemm_start_ready_i,

    output logic [FLAT_ADDR_WIDTH-1:0] gemm_activation_base_addr_o,
    output logic [FLAT_ADDR_WIDTH-1:0] gemm_weight_base_addr_o,
    output logic [FLAT_ADDR_WIDTH-1:0] gemm_output_base_addr_o,

    output logic [1:0] gemm_precision_o,
    output logic [3:0] gemm_k_token_count_o,

    input logic gemm_busy_i,
    input logic gemm_compute_done_i,
    input logic gemm_done_i,
    input logic gemm_error_i,

    input logic [1:0] gemm_error_source_i,
    input logic [2:0] gemm_error_code_i,
    input logic [2:0] gemm_error_detail_i,

    input logic [
        WORD_COUNT_WIDTH-1:0
    ] gemm_words_loaded_i,

    input logic [6:0] gemm_words_written_i,

    input logic [63:0] gemm_result_valid_i,
    input logic [63:0] gemm_invalid_i,
    input logic [63:0] gemm_overflow_i,
    input logic [63:0] gemm_underflow_i,
    input logic [63:0] gemm_inexact_i,

    // -------------------------------------------------------------------------
    // Output-memory single-word read adapter
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] output_read_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_read_addr_o,

    // Only lane 0 is used by the CSR single-word read adapter. The remaining
    // memory lanes stay available to wider internal compute-side clients.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [PORT_COUNT-1:0] output_read_ready_i,
    input logic [PORT_COUNT-1:0] output_read_conflict_i,

    input logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_read_data_i,

    input logic [PORT_COUNT-1:0] output_read_valid_i
    /* verilator lint_on UNUSEDSIGNAL */
);

    localparam logic [31:0] ADDR_LOADER_CONTROL =
        32'h0000_0500;

    localparam logic [31:0] ADDR_LOADER_STATUS =
        32'h0000_0504;

    localparam logic [31:0] ADDR_LOADER_CONFIG =
        32'h0000_0508;

    localparam logic [31:0] ADDR_LOADER_BASE =
        32'h0000_050C;

    localparam logic [31:0] ADDR_LOADER_WORD_COUNT =
        32'h0000_0510;

    localparam logic [31:0] ADDR_LOADER_WORDS_WRITTEN =
        32'h0000_0514;

    localparam logic [31:0] ADDR_STREAM_DATA_0 =
        32'h0000_0520;

    localparam logic [31:0] ADDR_STREAM_DATA_1 =
        32'h0000_0524;

    localparam logic [31:0] ADDR_STREAM_DATA_2 =
        32'h0000_0528;

    localparam logic [31:0] ADDR_STREAM_DATA_3 =
        32'h0000_052C;

    localparam logic [31:0] ADDR_STREAM_STROBE =
        32'h0000_0530;

    localparam logic [31:0] ADDR_STREAM_CONTROL =
        32'h0000_0534;

    localparam logic [31:0] ADDR_GEMM_ACTIVATION_BASE =
        32'h0000_0540;

    localparam logic [31:0] ADDR_GEMM_WEIGHT_BASE =
        32'h0000_0544;

    localparam logic [31:0] ADDR_GEMM_OUTPUT_BASE =
        32'h0000_0548;

    localparam logic [31:0] ADDR_GEMM_CONFIG =
        32'h0000_054C;

    localparam logic [31:0] ADDR_GEMM_CONTROL =
        32'h0000_0550;

    localparam logic [31:0] ADDR_GEMM_STATUS =
        32'h0000_0554;

    localparam logic [31:0] ADDR_GEMM_ERROR =
        32'h0000_0558;

    localparam logic [31:0] ADDR_GEMM_WORDS_LOADED =
        32'h0000_055C;

    localparam logic [31:0] ADDR_GEMM_WORDS_WRITTEN =
        32'h0000_0560;

    localparam logic [31:0] ADDR_RESULT_VALID_LOW =
        32'h0000_0564;

    localparam logic [31:0] ADDR_RESULT_VALID_HIGH =
        32'h0000_0568;

    localparam logic [31:0] ADDR_ARITHMETIC_SUMMARY =
        32'h0000_056C;

    localparam logic [31:0] ADDR_OUTPUT_READ_ADDRESS =
        32'h0000_0570;

    localparam logic [31:0] ADDR_OUTPUT_READ_CONTROL =
        32'h0000_0574;

    localparam logic [31:0] ADDR_OUTPUT_READ_DATA =
        32'h0000_0578;

    logic [1:0] loader_target_q;

    logic [FLAT_ADDR_WIDTH-1:0] loader_base_addr_q;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] loader_word_count_q;

    logic [31:0] stream_data_0_q;
    logic [31:0] stream_data_1_q;
    logic [31:0] stream_data_2_q;
    logic [31:0] stream_data_3_q;

    logic [(PORT_COUNT * BYTE_COUNT)-1:0] stream_strb_q;

    logic [FLAT_ADDR_WIDTH-1:0] gemm_activation_base_addr_q;
    logic [FLAT_ADDR_WIDTH-1:0] gemm_weight_base_addr_q;
    logic [FLAT_ADDR_WIDTH-1:0] gemm_output_base_addr_q;

    logic [1:0] gemm_precision_q;
    logic [3:0] gemm_k_token_count_q;

    logic loader_done_sticky_q;
    logic loader_error_sticky_q;
    logic [2:0] loader_error_code_q;

    logic gemm_compute_done_sticky_q;
    logic gemm_done_sticky_q;
    logic gemm_error_sticky_q;

    logic [1:0] gemm_error_source_q;
    logic [2:0] gemm_error_code_q;
    logic [2:0] gemm_error_detail_q;

    logic [FLAT_ADDR_WIDTH-1:0] output_read_addr_q;

    logic output_read_pending_q;
    logic output_read_valid_sticky_q;
    logic output_read_conflict_sticky_q;

    logic [31:0] output_read_data_q;

    // Preserve a successful backend response during the cycle immediately
    // following acceptance of a state-changing request.
    logic stream_accept_q;
    logic output_read_accept_q;

    logic stream_issue_ready;

    logic write_fire;
    logic full_write_strobe;

    logic valid_loader_control_action;
    logic valid_gemm_control_action;
    logic valid_stream_control_action;
    logic valid_output_read_action;

    logic output_read_blocked;
    logic output_read_issue_ready;

    assign write_ready_o =
        rst_ni;

    assign read_ready_o =
        rst_ni;

    assign write_fire =
        write_valid_i &&
        write_ready_o;

    assign full_write_strobe =
        (write_strb_i == 4'b1111);

    assign valid_loader_control_action =
        (write_data_i[31:3] == 29'd0) &&
        (
            (write_data_i[2:0] == 3'b001) ||
            (write_data_i[2:0] == 3'b010) ||
            (write_data_i[2:0] == 3'b100)
        );

    assign valid_gemm_control_action =
        (write_data_i[31:3] == 29'd0) &&
        (
            (write_data_i[2:0] == 3'b001) ||
            (write_data_i[2:0] == 3'b010) ||
            (write_data_i[2:0] == 3'b100)
        );

    assign valid_stream_control_action =
        (write_data_i[31:2] == 30'd0) &&
        write_data_i[0];

    assign valid_output_read_action =
        (write_data_i[31:2] == 30'd0) &&
        (
            (write_data_i[1:0] == 2'b01) ||
            (write_data_i[1:0] == 2'b10)
        );

    assign loader_target_o =
        loader_target_q;

    assign loader_base_addr_o =
        loader_base_addr_q;

    assign loader_word_count_o =
        loader_word_count_q;

    assign stream_data_o = {
        stream_data_3_q,
        stream_data_2_q,
        stream_data_1_q,
        stream_data_0_q
    };

    assign stream_strb_o =
        stream_strb_q;

    assign gemm_activation_base_addr_o =
        gemm_activation_base_addr_q;

    assign gemm_weight_base_addr_o =
        gemm_weight_base_addr_q;

    assign gemm_output_base_addr_o =
        gemm_output_base_addr_q;

    assign gemm_precision_o =
        gemm_precision_q;

    assign gemm_k_token_count_o =
        gemm_k_token_count_q;

    assign stream_issue_ready =
        rst_ni &&
        loader_busy_i &&
        !stream_valid_o;

    assign output_read_blocked =
        gemm_busy_i ||
        (
            loader_busy_i &&
            (loader_active_target_i == 2'd2)
        );

    assign output_read_issue_ready =
        rst_ni &&
        !output_read_blocked &&
        !output_read_pending_q &&
        !output_read_enable_o[0];

    always @* begin
        output_read_addr_o =
            '0;

        output_read_addr_o[
            FLAT_ADDR_WIDTH-1:0
        ] =
            output_read_addr_q;
    end

    // -------------------------------------------------------------------------
    // Write validation
    // -------------------------------------------------------------------------

    always @* begin
        write_error_o =
            1'b0;

        if (write_addr_i[1:0] != 2'b00) begin
            write_error_o =
                1'b1;
        end
        else if (!full_write_strobe) begin
            write_error_o =
                1'b1;
        end
        else begin
            case (write_addr_i)
                ADDR_LOADER_CONTROL: begin
                    if (!valid_loader_control_action) begin
                        write_error_o =
                            1'b1;
                    end
                    else if (
                        write_data_i[0] &&
                        !loader_start_ready_i
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_LOADER_CONFIG: begin
                    if (
                        loader_busy_i ||
                        (write_data_i[31:2] != 30'd0)
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_LOADER_BASE: begin
                    if (
                        loader_busy_i ||
                        (
                            write_data_i[
                                31:FLAT_ADDR_WIDTH
                            ] != '0
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_LOADER_WORD_COUNT: begin
                    if (
                        loader_busy_i ||
                        (
                            write_data_i[
                                31:WORD_COUNT_WIDTH
                            ] != '0
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_STREAM_DATA_0,
                ADDR_STREAM_DATA_1,
                ADDR_STREAM_DATA_2,
                ADDR_STREAM_DATA_3: begin
                    // Keep the staged beat stable while it is pending.
                    write_error_o =
                        stream_valid_o;
                end

                ADDR_STREAM_STROBE: begin
                    if (
                        stream_valid_o ||
                        (
                            write_data_i[
                                31:(PORT_COUNT * BYTE_COUNT)
                            ] != '0
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_STREAM_CONTROL: begin
                    if (
                        !valid_stream_control_action ||
                        !(
                            stream_issue_ready ||
                            stream_accept_q
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_GEMM_ACTIVATION_BASE,
                ADDR_GEMM_WEIGHT_BASE,
                ADDR_GEMM_OUTPUT_BASE: begin
                    if (
                        gemm_busy_i ||
                        (
                            write_data_i[
                                31:FLAT_ADDR_WIDTH
                            ] != '0
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_GEMM_CONFIG: begin
                    if (
                        gemm_busy_i ||
                        (write_data_i[31:8] != 24'd0) ||
                        (write_data_i[3:2] != 2'd0)
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_GEMM_CONTROL: begin
                    if (!valid_gemm_control_action) begin
                        write_error_o =
                            1'b1;
                    end
                    else if (
                        write_data_i[0] &&
                        !gemm_start_ready_i
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_OUTPUT_READ_ADDRESS: begin
                    if (
                        output_read_pending_q ||
                        (
                            write_data_i[
                                31:FLAT_ADDR_WIDTH
                            ] != '0
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                ADDR_OUTPUT_READ_CONTROL: begin
                    if (!valid_output_read_action) begin
                        write_error_o =
                            1'b1;
                    end
                    else if (
                        write_data_i[0] &&
                        !(
                            output_read_issue_ready ||
                            output_read_accept_q
                        )
                    ) begin
                        write_error_o =
                            1'b1;
                    end
                end

                default: begin
                    write_error_o =
                        1'b1;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Configuration, command pulses, sticky status, and read capture
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            loader_target_q <=
                2'd0;

            loader_base_addr_q <=
                '0;

            loader_word_count_q <=
                '0;

            stream_data_0_q <=
                32'd0;

            stream_data_1_q <=
                32'd0;

            stream_data_2_q <=
                32'd0;

            stream_data_3_q <=
                32'd0;

            stream_strb_q <=
                '1;

            gemm_activation_base_addr_q <=
                '0;

            gemm_weight_base_addr_q <=
                '0;

            gemm_output_base_addr_q <=
                '0;

            gemm_precision_q <=
                2'b00;

            gemm_k_token_count_q <=
                4'd8;

            loader_done_sticky_q <=
                1'b0;

            loader_error_sticky_q <=
                1'b0;

            loader_error_code_q <=
                3'd0;

            gemm_compute_done_sticky_q <=
                1'b0;

            gemm_done_sticky_q <=
                1'b0;

            gemm_error_sticky_q <=
                1'b0;

            gemm_error_source_q <=
                2'd0;

            gemm_error_code_q <=
                3'd0;

            gemm_error_detail_q <=
                3'd0;

            output_read_addr_q <=
                '0;

            output_read_pending_q <=
                1'b0;

            output_read_valid_sticky_q <=
                1'b0;

            output_read_conflict_sticky_q <=
                1'b0;

            output_read_data_q <=
                32'd0;

            tensor_clear_o <=
                1'b0;

            loader_start_o <=
                1'b0;

            stream_valid_o <=
                1'b0;

            stream_last_o <=
                1'b0;

            stream_accept_q <=
                1'b0;

            gemm_start_o <=
                1'b0;

            output_read_enable_o <=
                '0;

            output_read_accept_q <=
                1'b0;
        end
        else begin
            tensor_clear_o <=
                1'b0;

            loader_start_o <=
                1'b0;

            stream_accept_q <=
                1'b0;

            output_read_accept_q <=
                1'b0;

            gemm_start_o <=
                1'b0;

            // Hold the staged stream request until the loader accepts it.
            if (
                stream_valid_o &&
                stream_ready_i
            ) begin
                stream_valid_o <=
                    1'b0;

                stream_last_o <=
                    1'b0;
            end

            // Hold output-read enable until the scratchpad accepts the request.
            // Pending remains asserted until data-valid or conflict is returned.
            if (
                output_read_enable_o[0] &&
                output_read_ready_i[0]
            ) begin
                output_read_enable_o[0] <=
                    1'b0;
            end

            if (loader_done_i) begin
                loader_done_sticky_q <=
                    1'b1;
            end

            if (loader_error_i) begin
                loader_error_sticky_q <=
                    1'b1;

                loader_error_code_q <=
                    loader_error_code_i;
            end

            if (gemm_compute_done_i) begin
                gemm_compute_done_sticky_q <=
                    1'b1;
            end

            if (gemm_done_i) begin
                gemm_done_sticky_q <=
                    1'b1;
            end

            if (gemm_error_i) begin
                gemm_error_sticky_q <=
                    1'b1;

                gemm_error_source_q <=
                    gemm_error_source_i;

                gemm_error_code_q <=
                    gemm_error_code_i;

                gemm_error_detail_q <=
                    gemm_error_detail_i;
            end

            if (
                (
                    output_read_enable_o[0] ||
                    output_read_pending_q
                ) &&
                output_read_conflict_i[0]
            ) begin
                output_read_enable_o <=
                    '0;

                output_read_pending_q <=
                    1'b0;

                output_read_valid_sticky_q <=
                    1'b0;

                output_read_conflict_sticky_q <=
                    1'b1;
            end

            if (output_read_valid_i[0]) begin
                output_read_enable_o <=
                    '0;

                output_read_pending_q <=
                    1'b0;

                output_read_valid_sticky_q <=
                    1'b1;

                output_read_conflict_sticky_q <=
                    1'b0;

                output_read_data_q <=
                    output_read_data_i[31:0];
            end

            if (
                write_fire &&
                !write_error_o
            ) begin
                case (write_addr_i)
                    ADDR_LOADER_CONTROL: begin
                        case (write_data_i[2:0])
                            3'b001: begin
                                loader_start_o <=
                                    1'b1;

                                loader_done_sticky_q <=
                                    1'b0;

                                loader_error_sticky_q <=
                                    1'b0;

                                loader_error_code_q <=
                                    3'd0;
                            end

                            3'b010: begin
                                tensor_clear_o <=
                                    1'b1;

                                stream_valid_o <=
                                    1'b0;

                                stream_last_o <=
                                    1'b0;

                                stream_accept_q <=
                                    1'b0;

                                output_read_enable_o <=
                                    '0;

                                output_read_accept_q <=
                                    1'b0;

                                loader_done_sticky_q <=
                                    1'b0;

                                loader_error_sticky_q <=
                                    1'b0;

                                loader_error_code_q <=
                                    3'd0;

                                gemm_compute_done_sticky_q <=
                                    1'b0;

                                gemm_done_sticky_q <=
                                    1'b0;

                                gemm_error_sticky_q <=
                                    1'b0;

                                gemm_error_source_q <=
                                    2'd0;

                                gemm_error_code_q <=
                                    3'd0;

                                gemm_error_detail_q <=
                                    3'd0;

                                output_read_pending_q <=
                                    1'b0;

                                output_read_valid_sticky_q <=
                                    1'b0;

                                output_read_conflict_sticky_q <=
                                    1'b0;

                                output_read_data_q <=
                                    32'd0;
                            end

                            3'b100: begin
                                loader_done_sticky_q <=
                                    1'b0;

                                loader_error_sticky_q <=
                                    1'b0;

                                loader_error_code_q <=
                                    3'd0;
                            end

                            default: begin
                            end
                        endcase
                    end

                    ADDR_LOADER_CONFIG: begin
                        loader_target_q <=
                            write_data_i[1:0];
                    end

                    ADDR_LOADER_BASE: begin
                        loader_base_addr_q <=
                            write_data_i[
                                FLAT_ADDR_WIDTH-1:0
                            ];
                    end

                    ADDR_LOADER_WORD_COUNT: begin
                        loader_word_count_q <=
                            write_data_i[
                                WORD_COUNT_WIDTH-1:0
                            ];
                    end

                    ADDR_STREAM_DATA_0: begin
                        stream_data_0_q <=
                            write_data_i;
                    end

                    ADDR_STREAM_DATA_1: begin
                        stream_data_1_q <=
                            write_data_i;
                    end

                    ADDR_STREAM_DATA_2: begin
                        stream_data_2_q <=
                            write_data_i;
                    end

                    ADDR_STREAM_DATA_3: begin
                        stream_data_3_q <=
                            write_data_i;
                    end

                    ADDR_STREAM_STROBE: begin
                        stream_strb_q <=
                            write_data_i[
                                (PORT_COUNT * BYTE_COUNT)-1:0
                            ];
                    end

                    ADDR_STREAM_CONTROL: begin
                        stream_valid_o <=
                            1'b1;

                        stream_last_o <=
                            write_data_i[1];

                        stream_accept_q <=
                            1'b1;
                    end

                    ADDR_GEMM_ACTIVATION_BASE: begin
                        gemm_activation_base_addr_q <=
                            write_data_i[
                                FLAT_ADDR_WIDTH-1:0
                            ];
                    end

                    ADDR_GEMM_WEIGHT_BASE: begin
                        gemm_weight_base_addr_q <=
                            write_data_i[
                                FLAT_ADDR_WIDTH-1:0
                            ];
                    end

                    ADDR_GEMM_OUTPUT_BASE: begin
                        gemm_output_base_addr_q <=
                            write_data_i[
                                FLAT_ADDR_WIDTH-1:0
                            ];
                    end

                    ADDR_GEMM_CONFIG: begin
                        gemm_precision_q <=
                            write_data_i[1:0];

                        gemm_k_token_count_q <=
                            write_data_i[7:4];
                    end

                    ADDR_GEMM_CONTROL: begin
                        case (write_data_i[2:0])
                            3'b001: begin
                                gemm_start_o <=
                                    1'b1;

                                gemm_compute_done_sticky_q <=
                                    1'b0;

                                gemm_done_sticky_q <=
                                    1'b0;

                                gemm_error_sticky_q <=
                                    1'b0;

                                gemm_error_source_q <=
                                    2'd0;

                                gemm_error_code_q <=
                                    3'd0;

                                gemm_error_detail_q <=
                                    3'd0;
                            end

                            3'b010: begin
                                tensor_clear_o <=
                                    1'b1;

                                stream_valid_o <=
                                    1'b0;

                                stream_last_o <=
                                    1'b0;

                                stream_accept_q <=
                                    1'b0;

                                output_read_enable_o <=
                                    '0;

                                output_read_accept_q <=
                                    1'b0;

                                loader_done_sticky_q <=
                                    1'b0;

                                loader_error_sticky_q <=
                                    1'b0;

                                loader_error_code_q <=
                                    3'd0;

                                gemm_compute_done_sticky_q <=
                                    1'b0;

                                gemm_done_sticky_q <=
                                    1'b0;

                                gemm_error_sticky_q <=
                                    1'b0;

                                gemm_error_source_q <=
                                    2'd0;

                                gemm_error_code_q <=
                                    3'd0;

                                gemm_error_detail_q <=
                                    3'd0;

                                output_read_pending_q <=
                                    1'b0;

                                output_read_valid_sticky_q <=
                                    1'b0;

                                output_read_conflict_sticky_q <=
                                    1'b0;

                                output_read_data_q <=
                                    32'd0;
                            end

                            3'b100: begin
                                gemm_compute_done_sticky_q <=
                                    1'b0;

                                gemm_done_sticky_q <=
                                    1'b0;

                                gemm_error_sticky_q <=
                                    1'b0;

                                gemm_error_source_q <=
                                    2'd0;

                                gemm_error_code_q <=
                                    3'd0;

                                gemm_error_detail_q <=
                                    3'd0;
                            end

                            default: begin
                            end
                        endcase
                    end

                    ADDR_OUTPUT_READ_ADDRESS: begin
                        output_read_addr_q <=
                            write_data_i[
                                FLAT_ADDR_WIDTH-1:0
                            ];
                    end

                    ADDR_OUTPUT_READ_CONTROL: begin
                        case (write_data_i[1:0])
                            2'b01: begin
                                output_read_enable_o[0] <=
                                    1'b1;

                                output_read_pending_q <=
                                    1'b1;

                                output_read_accept_q <=
                                    1'b1;

                                output_read_valid_sticky_q <=
                                    1'b0;

                                output_read_conflict_sticky_q <=
                                    1'b0;
                            end

                            2'b10: begin
                                output_read_enable_o <=
                                    '0;

                                output_read_accept_q <=
                                    1'b0;

                                output_read_pending_q <=
                                    1'b0;

                                output_read_valid_sticky_q <=
                                    1'b0;

                                output_read_conflict_sticky_q <=
                                    1'b0;

                                output_read_data_q <=
                                    32'd0;
                            end

                            default: begin
                            end
                        endcase
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read decode
    // -------------------------------------------------------------------------

    always @* begin
        read_data_o =
            32'd0;

        read_error_o =
            1'b0;

        if (
            read_valid_i &&
            (read_addr_i[1:0] != 2'b00)
        ) begin
            read_error_o =
                1'b1;
        end
        else if (read_valid_i) begin
            case (read_addr_i)
                ADDR_LOADER_CONTROL: begin
                    read_data_o =
                        32'd0;
                end

                ADDR_LOADER_STATUS: begin
                    read_data_o[0] =
                        loader_start_ready_i;

                    read_data_o[1] =
                        loader_busy_i;

                    read_data_o[2] =
                        loader_done_sticky_q;

                    read_data_o[3] =
                        loader_error_sticky_q;

                    read_data_o[6:4] =
                        loader_error_code_q;

                    read_data_o[8] =
                        stream_issue_ready;

                    read_data_o[10:9] =
                        loader_active_target_i;
                end

                ADDR_LOADER_CONFIG: begin
                    read_data_o[1:0] =
                        loader_target_q;
                end

                ADDR_LOADER_BASE: begin
                    read_data_o[
                        FLAT_ADDR_WIDTH-1:0
                    ] =
                        loader_base_addr_q;
                end

                ADDR_LOADER_WORD_COUNT: begin
                    read_data_o[
                        WORD_COUNT_WIDTH-1:0
                    ] =
                        loader_word_count_q;
                end

                ADDR_LOADER_WORDS_WRITTEN: begin
                    read_data_o[
                        WORD_COUNT_WIDTH-1:0
                    ] =
                        loader_words_written_i;
                end

                ADDR_STREAM_DATA_0: begin
                    read_data_o =
                        stream_data_0_q;
                end

                ADDR_STREAM_DATA_1: begin
                    read_data_o =
                        stream_data_1_q;
                end

                ADDR_STREAM_DATA_2: begin
                    read_data_o =
                        stream_data_2_q;
                end

                ADDR_STREAM_DATA_3: begin
                    read_data_o =
                        stream_data_3_q;
                end

                ADDR_STREAM_STROBE: begin
                    read_data_o[
                        (PORT_COUNT * BYTE_COUNT)-1:0
                    ] =
                        stream_strb_q;
                end

                ADDR_STREAM_CONTROL: begin
                    read_data_o =
                        32'd0;
                end

                ADDR_GEMM_ACTIVATION_BASE: begin
                    read_data_o[
                        FLAT_ADDR_WIDTH-1:0
                    ] =
                        gemm_activation_base_addr_q;
                end

                ADDR_GEMM_WEIGHT_BASE: begin
                    read_data_o[
                        FLAT_ADDR_WIDTH-1:0
                    ] =
                        gemm_weight_base_addr_q;
                end

                ADDR_GEMM_OUTPUT_BASE: begin
                    read_data_o[
                        FLAT_ADDR_WIDTH-1:0
                    ] =
                        gemm_output_base_addr_q;
                end

                ADDR_GEMM_CONFIG: begin
                    read_data_o[1:0] =
                        gemm_precision_q;

                    read_data_o[7:4] =
                        gemm_k_token_count_q;
                end

                ADDR_GEMM_CONTROL: begin
                    read_data_o =
                        32'd0;
                end

                ADDR_GEMM_STATUS: begin
                    read_data_o[0] =
                        gemm_start_ready_i;

                    read_data_o[1] =
                        gemm_busy_i;

                    read_data_o[2] =
                        gemm_compute_done_sticky_q;

                    read_data_o[3] =
                        gemm_done_sticky_q;

                    read_data_o[4] =
                        gemm_error_sticky_q;

                    read_data_o[8] =
                        &gemm_result_valid_i;

                    read_data_o[12] =
                        |gemm_invalid_i;

                    read_data_o[13] =
                        |gemm_overflow_i;

                    read_data_o[14] =
                        |gemm_underflow_i;

                    read_data_o[15] =
                        |gemm_inexact_i;
                end

                ADDR_GEMM_ERROR: begin
                    read_data_o[1:0] =
                        gemm_error_source_q;

                    read_data_o[6:4] =
                        gemm_error_code_q;

                    read_data_o[10:8] =
                        gemm_error_detail_q;
                end

                ADDR_GEMM_WORDS_LOADED: begin
                    read_data_o[
                        WORD_COUNT_WIDTH-1:0
                    ] =
                        gemm_words_loaded_i;
                end

                ADDR_GEMM_WORDS_WRITTEN: begin
                    read_data_o[6:0] =
                        gemm_words_written_i;
                end

                ADDR_RESULT_VALID_LOW: begin
                    read_data_o =
                        gemm_result_valid_i[31:0];
                end

                ADDR_RESULT_VALID_HIGH: begin
                    read_data_o =
                        gemm_result_valid_i[63:32];
                end

                ADDR_ARITHMETIC_SUMMARY: begin
                    read_data_o[0] =
                        |gemm_invalid_i;

                    read_data_o[1] =
                        |gemm_overflow_i;

                    read_data_o[2] =
                        |gemm_underflow_i;

                    read_data_o[3] =
                        |gemm_inexact_i;
                end

                ADDR_OUTPUT_READ_ADDRESS: begin
                    read_data_o[
                        FLAT_ADDR_WIDTH-1:0
                    ] =
                        output_read_addr_q;
                end

                ADDR_OUTPUT_READ_CONTROL: begin
                    read_data_o[0] =
                        output_read_issue_ready;

                    read_data_o[1] =
                        output_read_pending_q;

                    read_data_o[2] =
                        output_read_valid_sticky_q;

                    read_data_o[3] =
                        output_read_conflict_sticky_q;

                    read_data_o[4] =
                        output_read_ready_i[0];
                end

                ADDR_OUTPUT_READ_DATA: begin
                    read_data_o =
                        output_read_data_q;
                end

                default: begin
                    read_data_o =
                        32'd0;

                    read_error_o =
                        1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
