`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_systolic_gemm_top;

    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;

    localparam logic [31:0] ADDR_DEVICE_ID         = 32'h0000_0000;
    localparam logic [31:0] ADDR_VERSION           = 32'h0000_0004;

    localparam logic [31:0] ADDR_GEMM_CONFIG       = 32'h0000_0140;
    localparam logic [31:0] ADDR_GEMM_CONTROL      = 32'h0000_0144;
    localparam logic [31:0] ADDR_GEMM_STATUS       = 32'h0000_0148;
    localparam logic [31:0] ADDR_GEMM_A_ADDR       = 32'h0000_014C;
    localparam logic [31:0] ADDR_GEMM_A_DATA       = 32'h0000_0150;
    localparam logic [31:0] ADDR_GEMM_B_ADDR       = 32'h0000_0154;
    localparam logic [31:0] ADDR_GEMM_B_DATA       = 32'h0000_0158;
    localparam logic [31:0] ADDR_GEMM_A_VALID      = 32'h0000_015C;
    localparam logic [31:0] ADDR_GEMM_B_VALID      = 32'h0000_0160;

    localparam logic [31:0] ADDR_GEMM_RESULT0      = 32'h0000_0180;
    localparam logic [31:0] ADDR_GEMM_RESULT_VALID = 32'h0000_01C0;
    localparam logic [31:0] ADDR_GEMM_INVALID      = 32'h0000_01C8;
    localparam logic [31:0] ADDR_GEMM_OVERFLOW     = 32'h0000_01CC;
    localparam logic [31:0] ADDR_GEMM_UNDERFLOW    = 32'h0000_01D0;
    localparam logic [31:0] ADDR_GEMM_INEXACT      = 32'h0000_01D4;

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
    integer index;
    integer timeout_count;

    logic [31:0] captured_read_data;
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
        input logic [31:0] address,
        output logic [31:0] data,
        input logic [1:0] expected_response
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

    function automatic integer matrix_b (
        input integer address
    );
        begin
            case (address)
                 0: matrix_b = 1;
                 1: matrix_b = 0;
                 2: matrix_b = 2;
                 3: matrix_b = 1;

                 4: matrix_b = 0;
                 5: matrix_b = 1;
                 6: matrix_b = 1;
                 7: matrix_b = 2;

                 8: matrix_b = 1;
                 9: matrix_b = 1;
                10: matrix_b = 0;
                11: matrix_b = 1;

                12: matrix_b = 2;
                13: matrix_b = 1;
                14: matrix_b = 1;
                15: matrix_b = 0;

                default: matrix_b = 0;
            endcase
        end
    endfunction

    function automatic logic [31:0] expected_result (
        input integer result_index
    );
        begin
            case (result_index)
                 0: expected_result = 32'h4140_0000;
                 1: expected_result = 32'h4110_0000;
                 2: expected_result = 32'h4100_0000;
                 3: expected_result = 32'h4100_0000;

                 4: expected_result = 32'h41E0_0000;
                 5: expected_result = 32'h41A8_0000;
                 6: expected_result = 32'h41C0_0000;
                 7: expected_result = 32'h41C0_0000;

                 8: expected_result = 32'h4230_0000;
                 9: expected_result = 32'h4204_0000;
                10: expected_result = 32'h4220_0000;
                11: expected_result = 32'h4220_0000;

                12: expected_result = 32'h4270_0000;
                13: expected_result = 32'h4234_0000;
                14: expected_result = 32'h4260_0000;
                15: expected_result = 32'h4260_0000;

                default: expected_result = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] expected_accumulated_result (
        input integer result_index
    );
        begin
            case (result_index)
                 0: expected_accumulated_result = 32'h4150_0000; // 13
                 1: expected_accumulated_result = 32'h4120_0000; // 10
                 2: expected_accumulated_result = 32'h4110_0000; // 9
                 3: expected_accumulated_result = 32'h4110_0000; // 9

                 4: expected_accumulated_result = 32'h41E8_0000; // 29
                 5: expected_accumulated_result = 32'h41B0_0000; // 22
                 6: expected_accumulated_result = 32'h41C8_0000; // 25
                 7: expected_accumulated_result = 32'h41C8_0000; // 25

                 8: expected_accumulated_result = 32'h4234_0000; // 45
                 9: expected_accumulated_result = 32'h4208_0000; // 34
                10: expected_accumulated_result = 32'h4224_0000; // 41
                11: expected_accumulated_result = 32'h4224_0000; // 41

                12: expected_accumulated_result = 32'h4274_0000; // 61
                13: expected_accumulated_result = 32'h4238_0000; // 46
                14: expected_accumulated_result = 32'h4264_0000; // 57
                15: expected_accumulated_result = 32'h4264_0000; // 57

                default:
                    expected_accumulated_result = 32'd0;
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

        // Confirm legacy/base CSR routing remains active.
        axi_read_expect(
            ADDR_DEVICE_ID,
            32'h4E43_4530
        );

        axi_read_expect(
            ADDR_VERSION,
            32'h0001_0000
        );

        // Clear GEMM engine and tile validity.
        axi_write(
            ADDR_GEMM_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        // Load A: values 1 through 16.
        for (
            index = 0;
            index < 16;
            index = index + 1
        ) begin
            axi_write(
                ADDR_GEMM_A_ADDR,
                index,
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_A_DATA,
                index + 1,
                AXI_OKAY
            );
        end

        // Load B.
        for (
            index = 0;
            index < 16;
            index = index + 1
        ) begin
            axi_write(
                ADDR_GEMM_B_ADDR,
                index,
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_B_DATA,
                matrix_b(index),
                AXI_OKAY
            );
        end

        axi_read_expect(
            ADDR_GEMM_A_VALID,
            32'h0000_FFFF
        );

        axi_read_expect(
            ADDR_GEMM_B_VALID,
            32'h0000_FFFF
        );

        // INT8X4 precision=00, K=4.
        axi_write(
            ADDR_GEMM_CONFIG,
            32'h0000_0040,
            AXI_OKAY
        );

        axi_write(
            ADDR_GEMM_CONTROL,
            32'h0000_0001,
            AXI_OKAY
        );

        // Poll sticky completion/error status.
        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 100 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            axi_read_capture(
                ADDR_GEMM_STATUS,
                captured_read_data,
                AXI_OKAY
            );

            if (captured_read_data[3]) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: GEMM reported error code %0d",
                    captured_read_data[6:4]
                );

                operation_complete = 1'b1;
            end
            else if (captured_read_data[2]) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "AXI systolic GEMM timed out"
        );

        check_condition(
            captured_read_data[3] === 1'b0,
            "AXI systolic GEMM reported an error"
        );

        check_condition(
            captured_read_data[2] === 1'b1 &&
            captured_read_data[1] === 1'b0 &&
            captured_read_data[0] === 1'b1,
            "Completed GEMM status mismatch"
        );

        axi_read_expect(
            ADDR_GEMM_RESULT_VALID,
            32'h0000_FFFF
        );

        for (
            index = 0;
            index < 16;
            index = index + 1
        ) begin
            axi_read_expect(
                ADDR_GEMM_RESULT0 +
                    (index * 4),
                expected_result(index)
            );
        end

        axi_read_expect(
            ADDR_GEMM_INVALID,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_OVERFLOW,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_UNDERFLOW,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_INEXACT,
            32'h0000_0000
        );

        // ---------------------------------------------------------------------
        // Second packed-K tile with accumulator preservation.
        //
        // A2 is a 4x4 matrix of ones.
        // B2 is the 4x4 identity matrix.
        //
        // A2 x B2 contributes exactly 1.0 to every existing C element.
        // ---------------------------------------------------------------------

        for (
            index = 0;
            index < 16;
            index = index + 1
        ) begin
            axi_write(
                ADDR_GEMM_A_ADDR,
                index,
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_A_DATA,
                32'h0000_0001,
                AXI_OKAY
            );
        end

        for (
            index = 0;
            index < 16;
            index = index + 1
        ) begin
            axi_write(
                ADDR_GEMM_B_ADDR,
                index,
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_B_DATA,
                ((index / 4) == (index % 4))
                ? 32'h0000_0001
                : 32'h0000_0000,
                AXI_OKAY
            );
        end

        // precision=INT8X4, K-token count=4, accumulate=1.
        axi_write(
            ADDR_GEMM_CONFIG,
            32'h0000_0140,
            AXI_OKAY
        );

        axi_read_expect(
            ADDR_GEMM_CONFIG,
            32'h0000_0140
        );

        axi_write(
            ADDR_GEMM_CONTROL,
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
                ADDR_GEMM_STATUS,
                captured_read_data,
                AXI_OKAY
            );

            if (captured_read_data[3]) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: accumulated GEMM reported error code %0d",
                    captured_read_data[6:4]
                );

                operation_complete = 1'b1;
            end
            else if (captured_read_data[2]) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "Accumulated AXI systolic GEMM timed out"
        );

        check_condition(
            captured_read_data[3] === 1'b0,
            "Accumulated AXI systolic GEMM reported an error"
        );

        check_condition(
            captured_read_data[2] === 1'b1 &&
            captured_read_data[1] === 1'b0 &&
            captured_read_data[0] === 1'b1,
            "Accumulated GEMM completion status mismatch"
        );

        axi_read_expect(
            ADDR_GEMM_RESULT_VALID,
            32'h0000_FFFF
        );

        for (
            index = 0;
            index < 16;
            index = index + 1
        ) begin
            axi_read_expect(
                ADDR_GEMM_RESULT0 +
                    (index * 4),
                expected_accumulated_result(index)
            );
        end

        axi_read_expect(
            ADDR_GEMM_INVALID,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_OVERFLOW,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_UNDERFLOW,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_INEXACT,
            32'h0000_0000
        );

        // A second start while operating would be rejected. At idle, an
        // unsupported control encoding must also return SLVERR.
        axi_write(
            ADDR_GEMM_CONTROL,
            32'h0000_0003,
            AXI_SLVERR
        );

        // Clear the GEMM engine and prove tile/results validity resets.
        axi_write(
            ADDR_GEMM_CONTROL,
            32'h0000_0002,
            AXI_OKAY
        );

        repeat (2) begin
            @(posedge clk_i);
        end

        axi_read_expect(
            ADDR_GEMM_A_VALID,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_B_VALID,
            32'h0000_0000
        );

        axi_read_expect(
            ADDR_GEMM_RESULT_VALID,
            32'h0000_0000
        );

        if (error_count == 0) begin
            $display(
                "PASS: AXI native systolic GEMM passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d AXI systolic-GEMM errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
