`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_tiled_gemm_8x8_top;

    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;

    localparam logic [31:0] ADDR_DEVICE_ID       = 32'h0000_0000;
    localparam logic [31:0] ADDR_VERSION         = 32'h0000_0004;

    // Direct native-4x4 GEMM CSRs.
    localparam logic [31:0] ADDR_DIRECT_CONFIG   = 32'h0000_0140;
    localparam logic [31:0] ADDR_DIRECT_CONTROL  = 32'h0000_0144;
    localparam logic [31:0] ADDR_DIRECT_STATUS   = 32'h0000_0148;
    localparam logic [31:0] ADDR_DIRECT_A_ADDR   = 32'h0000_014C;
    localparam logic [31:0] ADDR_DIRECT_A_DATA   = 32'h0000_0150;
    localparam logic [31:0] ADDR_DIRECT_B_ADDR   = 32'h0000_0154;
    localparam logic [31:0] ADDR_DIRECT_B_DATA   = 32'h0000_0158;

    // Autonomous tiled-8x8 GEMM CSRs.
    localparam logic [31:0] ADDR_CONFIG           = 32'h0000_0200;
    localparam logic [31:0] ADDR_CONTROL          = 32'h0000_0204;
    localparam logic [31:0] ADDR_STATUS           = 32'h0000_0208;

    localparam logic [31:0] ADDR_A_ADDR           = 32'h0000_020C;
    localparam logic [31:0] ADDR_A_DATA           = 32'h0000_0210;
    localparam logic [31:0] ADDR_B_ADDR           = 32'h0000_0214;
    localparam logic [31:0] ADDR_B_DATA           = 32'h0000_0218;

    localparam logic [31:0] ADDR_A_VALID_LO       = 32'h0000_0220;
    localparam logic [31:0] ADDR_A_VALID_HI       = 32'h0000_0224;
    localparam logic [31:0] ADDR_B_VALID_LO       = 32'h0000_0228;
    localparam logic [31:0] ADDR_B_VALID_HI       = 32'h0000_022C;

    localparam logic [31:0] ADDR_RESULT_VALID_LO  = 32'h0000_0230;
    localparam logic [31:0] ADDR_RESULT_VALID_HI  = 32'h0000_0234;

    localparam logic [31:0] ADDR_INVALID_LO       = 32'h0000_0238;
    localparam logic [31:0] ADDR_INVALID_HI       = 32'h0000_023C;
    localparam logic [31:0] ADDR_OVERFLOW_LO      = 32'h0000_0240;
    localparam logic [31:0] ADDR_OVERFLOW_HI      = 32'h0000_0244;
    localparam logic [31:0] ADDR_UNDERFLOW_LO     = 32'h0000_0248;
    localparam logic [31:0] ADDR_UNDERFLOW_HI     = 32'h0000_024C;
    localparam logic [31:0] ADDR_INEXACT_LO       = 32'h0000_0250;
    localparam logic [31:0] ADDR_INEXACT_HI       = 32'h0000_0254;

    localparam logic [31:0] ADDR_RESULT0          = 32'h0000_0300;

    // Fixed 4x4-input, 3x3 valid INT8 convolution CSRs.
    localparam logic [31:0] ADDR_CONV_CONTROL      = 32'h0000_0400;
    localparam logic [31:0] ADDR_CONV_STATUS       = 32'h0000_0404;
    localparam logic [31:0] ADDR_CONV_PIXEL_ADDR   = 32'h0000_0408;
    localparam logic [31:0] ADDR_CONV_PIXEL_DATA   = 32'h0000_040C;
    localparam logic [31:0] ADDR_CONV_KERNEL_ADDR  = 32'h0000_0410;
    localparam logic [31:0] ADDR_CONV_KERNEL_DATA  = 32'h0000_0414;

    localparam logic [31:0] ADDR_CONV_PIXEL_VALID  = 32'h0000_0418;
    localparam logic [31:0] ADDR_CONV_KERNEL_VALID = 32'h0000_041C;
    localparam logic [31:0] ADDR_CONV_RESULT_VALID = 32'h0000_0420;
    localparam logic [31:0] ADDR_CONV_FLAGS        = 32'h0000_0424;

    localparam logic [31:0] ADDR_CONV_RESULT0      = 32'h0000_0440;
    localparam logic [31:0] ADDR_CONV_RESULT1      = 32'h0000_0444;
    localparam logic [31:0] ADDR_CONV_RESULT2      = 32'h0000_0448;
    localparam logic [31:0] ADDR_CONV_RESULT3      = 32'h0000_044C;

    logic clk_i;
    logic rst_ni;

    logic [31:0] s_axi_awaddr_i;
    logic [2:0]  s_axi_awprot_i;
    logic        s_axi_awvalid_i;
    logic        s_axi_awready_o;

    logic [31:0] s_axi_wdata_i;
    logic [3:0]  s_axi_wstrb_i;
    logic        s_axi_wvalid_i;
    logic        s_axi_wready_o;

    logic [1:0] s_axi_bresp_o;
    logic       s_axi_bvalid_o;
    logic       s_axi_bready_i;

    logic [31:0] s_axi_araddr_i;
    logic [2:0]  s_axi_arprot_i;
    logic        s_axi_arvalid_i;
    logic        s_axi_arready_o;

    logic [31:0] s_axi_rdata_o;
    logic [1:0]  s_axi_rresp_o;
    logic        s_axi_rvalid_o;
    logic        s_axi_rready_i;

    integer check_count;
    integer error_count;

    integer row_index;
    integer column_index;
    integer matrix_index;
    integer timeout_count;

    logic [31:0] captured_data;
    logic operation_complete;

    nce_axi_mixed_precision_top dut (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .s_axi_awaddr_i     (s_axi_awaddr_i),
        .s_axi_awprot_i     (s_axi_awprot_i),
        .s_axi_awvalid_i    (s_axi_awvalid_i),
        .s_axi_awready_o    (s_axi_awready_o),

        .s_axi_wdata_i      (s_axi_wdata_i),
        .s_axi_wstrb_i      (s_axi_wstrb_i),
        .s_axi_wvalid_i     (s_axi_wvalid_i),
        .s_axi_wready_o     (s_axi_wready_o),

        .s_axi_bresp_o      (s_axi_bresp_o),
        .s_axi_bvalid_o     (s_axi_bvalid_o),
        .s_axi_bready_i     (s_axi_bready_i),

        .s_axi_araddr_i     (s_axi_araddr_i),
        .s_axi_arprot_i     (s_axi_arprot_i),
        .s_axi_arvalid_i    (s_axi_arvalid_i),
        .s_axi_arready_o    (s_axi_arready_o),

        .s_axi_rdata_o      (s_axi_rdata_o),
        .s_axi_rresp_o      (s_axi_rresp_o),
        .s_axi_rvalid_o     (s_axi_rvalid_o),
        .s_axi_rready_i     (s_axi_rready_i)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    task automatic check_condition (
        input logic  condition,
        input string message
    );
        begin
            check_count = check_count + 1;

            if (!condition) begin
                error_count = error_count + 1;

                $display(
                    "ERROR check=%0d: %s",
                    check_count,
                    message
                );
            end
        end
    endtask

    task automatic axi_write (
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [1:0]  expected_response
    );
        begin
            @(negedge clk_i);

            s_axi_awaddr_i  = address;
            s_axi_awprot_i  = 3'b000;
            s_axi_awvalid_i = 1'b1;

            s_axi_wdata_i   = data;
            s_axi_wstrb_i   = 4'b1111;
            s_axi_wvalid_i  = 1'b1;

            fork
                begin
                    wait (s_axi_awready_o === 1'b1);
                    @(posedge clk_i);
                    #1;
                    s_axi_awvalid_i = 1'b0;
                end

                begin
                    wait (s_axi_wready_o === 1'b1);
                    @(posedge clk_i);
                    #1;
                    s_axi_wvalid_i = 1'b0;
                end
            join

            wait (s_axi_bvalid_o === 1'b1);
            #1;

            check_condition(
                s_axi_bresp_o === expected_response,
                "AXI write response mismatch"
            );

            if (s_axi_bresp_o !== expected_response) begin
                $display(
                    "  address=%08h response=%h expected=%h",
                    address,
                    s_axi_bresp_o,
                    expected_response
                );
            end

            @(negedge clk_i);
            s_axi_bready_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            s_axi_bready_i = 1'b0;
        end
    endtask

    task automatic axi_read_capture (
        input  logic [31:0] address,
        output logic [31:0] data,
        input  logic [1:0]  expected_response
    );
        begin
            @(negedge clk_i);

            s_axi_araddr_i  = address;
            s_axi_arprot_i  = 3'b000;
            s_axi_arvalid_i = 1'b1;

            wait (s_axi_arready_o === 1'b1);

            @(posedge clk_i);
            #1;

            s_axi_arvalid_i = 1'b0;

            wait (s_axi_rvalid_o === 1'b1);
            #1;

            data = s_axi_rdata_o;

            check_condition(
                s_axi_rresp_o === expected_response,
                "AXI read response mismatch"
            );

            @(negedge clk_i);
            s_axi_rready_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            s_axi_rready_i = 1'b0;
        end
    endtask

    task automatic axi_read_expect (
        input logic [31:0] address,
        input logic [31:0] expected_data
    );
        logic [31:0] data;

        begin
            axi_read_capture(
                address,
                data,
                AXI_OKAY
            );

            check_condition(
                data === expected_data,
                "AXI read data mismatch"
            );

            if (data !== expected_data) begin
                $display(
                    "  address=%08h data=%08h expected=%08h",
                    address,
                    data,
                    expected_data
                );
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Packed-token regression helpers
    // -------------------------------------------------------------------------

    task automatic clear_tiled_operation;
        begin
            axi_write(
                ADDR_CONTROL,
                32'h0000_0002,
                AXI_OKAY
            );

            repeat (3) begin
                @(posedge clk_i);
            end
        end
    endtask

    // Load one packed K token for every A row and every B column.
    //
    // For K-token count=1, required locations are:
    //
    //   A[row][0]       -> addresses 0, 8, 16, ..., 56
    //   B[0][column]    -> addresses 0, 1, 2, ..., 7
    //
    task automatic load_single_packed_k_token (
        input logic [31:0] a_token,
        input logic [31:0] b_token
    );
        integer token_index;

        begin
            for (
                token_index = 0;
                token_index < 8;
                token_index = token_index + 1
            ) begin
                axi_write(
                    ADDR_A_ADDR,
                    token_index * 8,
                    AXI_OKAY
                );

                axi_write(
                    ADDR_A_DATA,
                    a_token,
                    AXI_OKAY
                );

                axi_write(
                    ADDR_B_ADDR,
                    token_index,
                    AXI_OKAY
                );

                axi_write(
                    ADDR_B_DATA,
                    b_token,
                    AXI_OKAY
                );
            end

            axi_read_expect(
                ADDR_A_VALID_LO,
                32'h0101_0101
            );

            axi_read_expect(
                ADDR_A_VALID_HI,
                32'h0101_0101
            );

            axi_read_expect(
                ADDR_B_VALID_LO,
                32'h0000_00FF
            );

            axi_read_expect(
                ADDR_B_VALID_HI,
                32'h0000_0000
            );
        end
    endtask

    task automatic execute_tiled_operation (
        input logic [1:0] precision,
        input logic [3:0] k_token_count
    );
        logic [31:0] configuration;

        begin
            configuration = {
                24'd0,
                k_token_count,
                2'b00,
                precision
            };

            axi_write(
                ADDR_CONFIG,
                configuration,
                AXI_OKAY
            );

            axi_read_expect(
                ADDR_CONFIG,
                configuration
            );

            axi_write(
                ADDR_CONTROL,
                32'h0000_0001,
                AXI_OKAY
            );

            operation_complete = 1'b0;

            for (
                timeout_count = 0;
                timeout_count < 500 &&
                !operation_complete;
                timeout_count = timeout_count + 1
            ) begin
                axi_read_capture(
                    ADDR_STATUS,
                    captured_data,
                    AXI_OKAY
                );

                if (
                    captured_data[3] ||
                    captured_data[2]
                ) begin
                    operation_complete = 1'b1;
                end
            end

            check_condition(
                operation_complete,
                "Packed tiled-GEMM operation timed out"
            );

            check_condition(
                captured_data[3] === 1'b0,
                "Packed tiled-GEMM operation reported an error"
            );

            check_condition(
                captured_data[2]  === 1'b1 &&
                captured_data[1]  === 1'b0 &&
                captured_data[0]  === 1'b1 &&
                captured_data[11] === 1'b1,
                "Packed tiled-GEMM completion status mismatch"
            );

            axi_read_expect(
                ADDR_RESULT_VALID_LO,
                32'hFFFF_FFFF
            );

            axi_read_expect(
                ADDR_RESULT_VALID_HI,
                32'hFFFF_FFFF
            );
        end
    endtask

    task automatic check_uniform_tiled_results (
        input logic [31:0] expected_result
    );
        integer result_index;

        begin
            for (
                result_index = 0;
                result_index < 64;
                result_index = result_index + 1
            ) begin
                axi_read_expect(
                    ADDR_RESULT0 +
                        (result_index * 4),
                    expected_result
                );
            end
        end
    endtask

    task automatic check_tiled_arithmetic_flags_clear;
        begin
            axi_read_expect(
                ADDR_INVALID_LO,
                32'd0
            );

            axi_read_expect(
                ADDR_INVALID_HI,
                32'd0
            );

            axi_read_expect(
                ADDR_OVERFLOW_LO,
                32'd0
            );

            axi_read_expect(
                ADDR_OVERFLOW_HI,
                32'd0
            );

            axi_read_expect(
                ADDR_UNDERFLOW_LO,
                32'd0
            );

            axi_read_expect(
                ADDR_UNDERFLOW_HI,
                32'd0
            );

            axi_read_expect(
                ADDR_INEXACT_LO,
                32'd0
            );

            axi_read_expect(
                ADDR_INEXACT_HI,
                32'd0
            );
        end
    endtask

    function automatic logic [31:0] positive_integer_fp32 (
        input integer value
    );
        begin
            case (value)
                 1: positive_integer_fp32 = 32'h3F80_0000;
                 2: positive_integer_fp32 = 32'h4000_0000;
                 3: positive_integer_fp32 = 32'h4040_0000;
                 4: positive_integer_fp32 = 32'h4080_0000;
                 5: positive_integer_fp32 = 32'h40A0_0000;
                 6: positive_integer_fp32 = 32'h40C0_0000;
                 7: positive_integer_fp32 = 32'h40E0_0000;
                 8: positive_integer_fp32 = 32'h4100_0000;
                 9: positive_integer_fp32 = 32'h4110_0000;
                10: positive_integer_fp32 = 32'h4120_0000;
                11: positive_integer_fp32 = 32'h4130_0000;
                12: positive_integer_fp32 = 32'h4140_0000;
                13: positive_integer_fp32 = 32'h4150_0000;
                14: positive_integer_fp32 = 32'h4160_0000;
                15: positive_integer_fp32 = 32'h4170_0000;

                default:
                    positive_integer_fp32 = 32'd0;
            endcase
        end
    endfunction

    initial begin
        rst_ni = 1'b0;

        s_axi_awaddr_i  = 32'd0;
        s_axi_awprot_i  = 3'd0;
        s_axi_awvalid_i = 1'b0;

        s_axi_wdata_i   = 32'd0;
        s_axi_wstrb_i   = 4'd0;
        s_axi_wvalid_i  = 1'b0;

        s_axi_bready_i = 1'b0;

        s_axi_araddr_i  = 32'd0;
        s_axi_arprot_i  = 3'd0;
        s_axi_arvalid_i = 1'b0;

        s_axi_rready_i = 1'b0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        // Legacy routing remains visible.
        axi_read_expect(
            ADDR_DEVICE_ID,
            32'h4E43_4530
        );

        axi_read_expect(
            ADDR_VERSION,
            32'h0001_0000
        );

        // ---------------------------------------------------------------------
        // Shared physical-engine ownership and handoff test
        //
        // 1. Execute a direct native-4x4 operation.
        // 2. Verify the direct client retains ownership after completion.
        // 3. Verify tiled start is rejected while direct ownership remains.
        // 4. Release ownership through direct clear.
        // 5. Verify the tiled controller becomes available.
        // ---------------------------------------------------------------------

        // Load all direct A/B tile entries. Zero-valued operands are legal;
        // writing them marks every tile-buffer location valid.
        for (
            matrix_index = 0;
            matrix_index < 16;
            matrix_index = matrix_index + 1
        ) begin
            axi_write(
                ADDR_DIRECT_A_ADDR,
                matrix_index,
                AXI_OKAY
            );

            axi_write(
                ADDR_DIRECT_A_DATA,
                32'h0000_0000,
                AXI_OKAY
            );

            axi_write(
                ADDR_DIRECT_B_ADDR,
                matrix_index,
                AXI_OKAY
            );

            axi_write(
                ADDR_DIRECT_B_DATA,
                32'h0000_0000,
                AXI_OKAY
            );
        end

        // INT8X4, one packed K token, new accumulator tile.
        axi_write(
            ADDR_DIRECT_CONFIG,
            32'h0000_0010,
            AXI_OKAY
        );

        axi_write(
            ADDR_DIRECT_CONTROL,
            32'h0000_0001,
            AXI_OKAY
        );

        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 100 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_DIRECT_STATUS,
                captured_data,
                AXI_OKAY
            );

            if (
                captured_data[3] ||
                captured_data[2]
            ) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "Direct shared-engine operation timed out"
        );

        check_condition(
            captured_data[3] === 1'b0 &&
            captured_data[2] === 1'b1 &&
            captured_data[1] === 1'b0,
            "Direct shared-engine completion status mismatch"
        );

        // Direct ownership remains active after completion so another direct
        // operation can use accumulate=1. Therefore, tiled start must be
        // rejected synchronously by the tiled CSR backend.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0001,
            AXI_SLVERR
        );

        axi_read_capture(
            ADDR_STATUS,
            captured_data,
            AXI_OKAY
        );

        check_condition(
            captured_data[0] === 1'b0 &&
            captured_data[1] === 1'b0,
            "Tiled controller became ready while direct client owned engine"
        );

        // Clear the direct engine and release direct ownership.
        axi_write(
            ADDR_DIRECT_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        repeat (3) begin
            @(posedge clk_i);
        end

        axi_read_capture(
            ADDR_STATUS,
            captured_data,
            AXI_OKAY
        );

        check_condition(
            captured_data[0] === 1'b1 &&
            captured_data[1] === 1'b0,
            "Tiled controller did not acquire engine availability after release"
        );

        // Clear the tiled engine.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        // Result CSRs are read-only.
        axi_write(
            ADDR_RESULT0,
            32'hDEAD_BEEF,
            AXI_SLVERR
        );

        // A = 8x8 identity.
        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                axi_write(
                    ADDR_A_ADDR,
                    matrix_index,
                    AXI_OKAY
                );

                axi_write(
                    ADDR_A_DATA,
                    (row_index == column_index)
                    ? 32'h0000_0001
                    : 32'h0000_0000,
                    AXI_OKAY
                );
            end
        end

        // B[k][column] = k + column + 1.
        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                axi_write(
                    ADDR_B_ADDR,
                    matrix_index,
                    AXI_OKAY
                );

                axi_write(
                    ADDR_B_DATA,
                    row_index +
                    column_index +
                    1,
                    AXI_OKAY
                );
            end
        end

        axi_read_expect(
            ADDR_A_VALID_LO,
            32'hFFFF_FFFF
        );

        axi_read_expect(
            ADDR_A_VALID_HI,
            32'hFFFF_FFFF
        );

        axi_read_expect(
            ADDR_B_VALID_LO,
            32'hFFFF_FFFF
        );

        axi_read_expect(
            ADDR_B_VALID_HI,
            32'hFFFF_FFFF
        );

        // Unsupported FP32 precision, K=8.
        axi_write(
            ADDR_CONFIG,
            32'h0000_0083,
            AXI_OKAY
        );

        axi_write(
            ADDR_CONTROL,
            32'h0000_0001,
            AXI_OKAY
        );

        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 50 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_STATUS,
                captured_data,
                AXI_OKAY
            );

            if (
                captured_data[3] ||
                captured_data[2]
            ) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "Invalid-precision operation did not terminate"
        );

        check_condition(
            captured_data[3] === 1'b1 &&
            captured_data[6:4] === 3'd1,
            "Invalid precision error status mismatch"
        );

        // Clear only sticky status; retain A/B buffers.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0004,
            AXI_OKAY
        );

        // INT8X4 precision, K-token count=8.
        axi_write(
            ADDR_CONFIG,
            32'h0000_0080,
            AXI_OKAY
        );

        axi_read_expect(
            ADDR_CONFIG,
            32'h0000_0080
        );

        axi_write(
            ADDR_CONTROL,
            32'h0000_0001,
            AXI_OKAY
        );

        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 500 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_STATUS,
                captured_data,
                AXI_OKAY
            );

            if (
                captured_data[3] ||
                captured_data[2]
            ) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "AXI 8x8 tiled GEMM timed out"
        );

        check_condition(
            captured_data[3] === 1'b0,
            "AXI 8x8 tiled GEMM reported an error"
        );

        check_condition(
            captured_data[2] === 1'b1 &&
            captured_data[1] === 1'b0 &&
            captured_data[0] === 1'b1 &&
            captured_data[11] === 1'b1,
            "AXI 8x8 completion status mismatch"
        );

        axi_read_expect(
            ADDR_RESULT_VALID_LO,
            32'hFFFF_FFFF
        );

        axi_read_expect(
            ADDR_RESULT_VALID_HI,
            32'hFFFF_FFFF
        );

        // Since A is identity:
        //
        // C[row][column] = B[row][column] = row + column + 1.
        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                axi_read_expect(
                    ADDR_RESULT0 +
                        (matrix_index * 4),
                    positive_integer_fp32(
                        row_index +
                        column_index +
                        1
                    )
                );
            end
        end

        axi_read_expect(ADDR_INVALID_LO,   32'd0);
        axi_read_expect(ADDR_INVALID_HI,   32'd0);
        axi_read_expect(ADDR_OVERFLOW_LO,  32'd0);
        axi_read_expect(ADDR_OVERFLOW_HI,  32'd0);
        axi_read_expect(ADDR_UNDERFLOW_LO, 32'd0);
        axi_read_expect(ADDR_UNDERFLOW_HI, 32'd0);
        axi_read_expect(ADDR_INEXACT_LO,   32'd0);
        axi_read_expect(ADDR_INEXACT_HI,   32'd0);

        // Clear all tiled state.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        repeat (3) begin
            @(posedge clk_i);
        end

        axi_read_expect(
            ADDR_A_VALID_LO,
            32'd0
        );

        axi_read_expect(
            ADDR_A_VALID_HI,
            32'd0
        );

        axi_read_expect(
            ADDR_B_VALID_LO,
            32'd0
        );

        axi_read_expect(
            ADDR_B_VALID_HI,
            32'd0
        );

        axi_read_expect(
            ADDR_RESULT_VALID_LO,
            32'd0
        );

        axi_read_expect(
            ADDR_RESULT_VALID_HI,
            32'd0
        );

        // ---------------------------------------------------------------------
        // Fully packed INT8X4 end-to-end regression
        //
        // A token sublanes:
        //
        //   [ 1, -2,  3, -4 ]
        //
        // B token sublanes:
        //
        //   [ 5,  6, -7, -8 ]
        //
        // Dot product:
        //
        //   1*5 + (-2)*6 + 3*(-7) + (-4)*(-8)
        // = 5 - 12 - 21 + 32
        // = 4
        //
        // Expected FP32 result: 4.0 = 0x40800000
        // ---------------------------------------------------------------------

        $display(
            "INFO: Starting fully packed signed INT8X4 AXI regression."
        );

        clear_tiled_operation();

        load_single_packed_k_token(
            32'hFC03_FE01,
            32'hF8F9_0605
        );

        execute_tiled_operation(
            2'b00,
            4'd1
        );

        check_uniform_tiled_results(
            32'h4080_0000
        );

        check_tiled_arithmetic_flags_clear();

        // ---------------------------------------------------------------------
        // Fully packed BF16X2 end-to-end regression
        //
        // A token:
        //
        //   lower BF16 =  1.5 = 0x3FC0
        //   upper BF16 = -2.0 = 0xC000
        //
        // B token:
        //
        //   lower BF16 =  4.0 = 0x4080
        //   upper BF16 = -3.0 = 0xC040
        //
        // Dot product:
        //
        //   1.5*4.0 + (-2.0)*(-3.0)
        // = 6.0 + 6.0
        // = 12.0
        //
        // Expected FP32 result: 12.0 = 0x41400000
        // ---------------------------------------------------------------------

        $display(
            "INFO: Starting fully packed signed BF16X2 AXI regression."
        );

        clear_tiled_operation();

        load_single_packed_k_token(
            32'hC000_3FC0,
            32'hC040_4080
        );

        execute_tiled_operation(
            2'b01,
            4'd1
        );

        check_uniform_tiled_results(
            32'h4140_0000
        );

        check_tiled_arithmetic_flags_clear();

        // ---------------------------------------------------------------------
        // Full-field BF24 end-to-end regression
        //
        // BF24 format:
        //
        //   sign:       1 bit
        //   exponent:   8 bits
        //   fraction:  15 bits
        //
        // A[23:0] = 0xBFA5A5
        //
        //   negative value with a nontrivial 15-bit fraction pattern.
        //
        // B[23:0] = 0x3F8000 = +1.0
        //
        // Upper bytes A[31:24]=0xA5 and B[31:24]=0x5A are deliberately
        // nonzero. They are reserved and must not affect arithmetic.
        //
        // Multiplication by +1.0 preserves the BF24 value exactly.
        // Converting the 15-bit BF24 fraction to FP32 appends eight zeros:
        //
        //   expected FP32 = 0xBFA5A500
        // ---------------------------------------------------------------------

        $display(
            "INFO: Starting full-field BF24 AXI regression."
        );

        clear_tiled_operation();

        load_single_packed_k_token(
            32'hA5BF_A5A5,
            32'h5A3F_8000
        );

        execute_tiled_operation(
            2'b10,
            4'd1
        );

        check_uniform_tiled_results(
            32'hBFA5_A500
        );

        check_tiled_arithmetic_flags_clear();

        // Leave the tiled and shared physical-engine state clean.
        clear_tiled_operation();

        axi_read_expect(
            ADDR_RESULT_VALID_LO,
            32'd0
        );

        axi_read_expect(
            ADDR_RESULT_VALID_HI,
            32'd0
        );

        // ---------------------------------------------------------------------
        // End-to-end AXI convolution regression
        //
        // This exercises:
        //
        //   AXI convolution CSR
        //       -> convolution im2col controller
        //       -> tiled-client ownership mux
        //       -> existing 8x8 tiled GEMM controller
        //       -> one shared physical 4x4 systolic array
        // ---------------------------------------------------------------------

        $display(
            "INFO: Starting AXI 3x3 valid signed INT8 convolution regression."
        );

        // ---------------------------------------------------------------------
        // Software-tiled ownership must block convolution start.
        // ---------------------------------------------------------------------

        axi_write(
            ADDR_A_ADDR,
            32'd0,
            AXI_OKAY
        );

        axi_write(
            ADDR_A_DATA,
            32'h0000_0000,
            AXI_OKAY
        );

        axi_write(
            ADDR_CONV_CONTROL,
            32'h0000_0001,
            AXI_SLVERR
        );

        axi_read_capture(
            ADDR_CONV_STATUS,
            captured_data,
            AXI_OKAY
        );

        check_condition(
            captured_data[0] === 1'b0,
            "Convolution became ready while software owned tiled backend"
        );

        // Release software ownership and clear its partially loaded context.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        repeat (3) begin
            @(posedge clk_i);
        end

        axi_read_capture(
            ADDR_CONV_STATUS,
            captured_data,
            AXI_OKAY
        );

        check_condition(
            captured_data[0] === 1'b1 &&
            captured_data[1] === 1'b0,
            "Convolution did not become available after software release"
        );

        // Clear convolution source/result state before loading the test.
        axi_write(
            ADDR_CONV_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        // Result registers are read-only.
        axi_write(
            ADDR_CONV_RESULT0,
            32'hDEAD_BEEF,
            AXI_SLVERR
        );

        // ---------------------------------------------------------------------
        // Input feature map:
        //
        //    1   2   3   4
        //    5   6   7   8
        //    9  10  11  12
        //   13  14  15  16
        // ---------------------------------------------------------------------

        for (
            matrix_index = 0;
            matrix_index < 16;
            matrix_index = matrix_index + 1
        ) begin
            axi_write(
                ADDR_CONV_PIXEL_ADDR,
                matrix_index,
                AXI_OKAY
            );

            axi_write(
                ADDR_CONV_PIXEL_DATA,
                matrix_index + 1,
                AXI_OKAY
            );
        end

        // ---------------------------------------------------------------------
        // Signed kernel:
        //
        //    1  -1   2
        //    0   3  -2
        //   -1   2   1
        // ---------------------------------------------------------------------

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd0, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_0001, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd1, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_00FF, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd2, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_0002, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd3, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_0000, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd4, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_0003, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd5, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_00FE, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd6, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_00FF, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd7, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_0002, AXI_OKAY);

        axi_write(ADDR_CONV_KERNEL_ADDR, 32'd8, AXI_OKAY);
        axi_write(ADDR_CONV_KERNEL_DATA, 32'h0000_0001, AXI_OKAY);

        axi_read_expect(
            ADDR_CONV_PIXEL_VALID,
            32'h0000_FFFF
        );

        axi_read_expect(
            ADDR_CONV_KERNEL_VALID,
            32'h0000_01FF
        );

        // Ready + all pixels valid + all kernel values valid.
        axi_read_expect(
            ADDR_CONV_STATUS,
            32'h0000_0301
        );

        axi_write(
            ADDR_CONV_CONTROL,
            32'h0000_0001,
            AXI_OKAY
        );

        // Wait until convolution ownership and busy state are visible.
        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 50 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_CONV_STATUS,
                captured_data,
                AXI_OKAY
            );

            if (captured_data[1]) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "Convolution busy state was not observed"
        );

        // Software accesses to the tiled source context are rejected while
        // convolution owns the tiled backend.
        axi_write(
            ADDR_A_ADDR,
            32'd0,
            AXI_SLVERR
        );

        // Wait for completed or failed convolution.
        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 1000 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_CONV_STATUS,
                captured_data,
                AXI_OKAY
            );

            if (
                captured_data[3] ||
                captured_data[2]
            ) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "AXI convolution operation timed out"
        );

        check_condition(
            captured_data[3] === 1'b0,
            "AXI convolution operation reported an error"
        );

        check_condition(
            captured_data[2] === 1'b1 &&
            captured_data[1] === 1'b0 &&
            captured_data[10] === 1'b1,
            "AXI convolution completion status mismatch"
        );

        // Allow the convolution client and physical tiled owner to complete
        // their release handshakes.
        repeat (4) begin
            @(posedge clk_i);
        end

        axi_read_expect(
            ADDR_CONV_STATUS,
            32'h0000_0705
        );

        axi_read_expect(
            ADDR_CONV_RESULT_VALID,
            32'h0000_000F
        );

        // Expected output:
        //
        //   31.0   36.0
        //   51.0   56.0

        axi_read_expect(
            ADDR_CONV_RESULT0,
            32'h41F8_0000
        );

        axi_read_expect(
            ADDR_CONV_RESULT1,
            32'h4210_0000
        );

        axi_read_expect(
            ADDR_CONV_RESULT2,
            32'h424C_0000
        );

        axi_read_expect(
            ADDR_CONV_RESULT3,
            32'h4260_0000
        );

        axi_read_expect(
            ADDR_CONV_FLAGS,
            32'd0
        );

        // ---------------------------------------------------------------------
        // Backend-context cleanup verification
        //
        // Configure software tiled GEMM for INT8X4, K=3, but do not load any
        // software A/B matrix. The operation must fail with A-matrix-invalid.
        //
        // If convolution im2col data leaked into the software context, this
        // operation could incorrectly execute.
        // ---------------------------------------------------------------------

        axi_write(
            ADDR_CONFIG,
            32'h0000_0030,
            AXI_OKAY
        );

        axi_write(
            ADDR_CONTROL,
            32'h0000_0001,
            AXI_OKAY
        );

        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 100 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_STATUS,
                captured_data,
                AXI_OKAY
            );

            if (
                captured_data[3] ||
                captured_data[2]
            ) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "Post-convolution empty tiled operation did not terminate"
        );

        check_condition(
            captured_data[3] === 1'b1 &&
            captured_data[6:4] === 3'd3,
            "Convolution tiled-context cleanup was not preserved"
        );

        // Release software ownership after the deliberate invalid operation.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        repeat (3) begin
            @(posedge clk_i);
        end

        // Clear convolution input, kernel, results and sticky status.
        axi_write(
            ADDR_CONV_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        repeat (3) begin
            @(posedge clk_i);
        end

        axi_read_expect(
            ADDR_CONV_PIXEL_VALID,
            32'd0
        );

        axi_read_expect(
            ADDR_CONV_KERNEL_VALID,
            32'd0
        );

        axi_read_expect(
            ADDR_CONV_RESULT_VALID,
            32'd0
        );

        axi_read_expect(
            ADDR_CONV_STATUS,
            32'h0000_0001
        );

        if (error_count == 0) begin
            $display(
                "PASS: AXI 8x8 tiled GEMM passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d AXI tiled-GEMM errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
