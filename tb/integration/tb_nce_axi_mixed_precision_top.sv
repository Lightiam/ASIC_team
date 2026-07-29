`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_mixed_precision_top;

    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;

    localparam logic [31:0] ADDR_DEVICE_ID           = 32'h0000_0000;
    localparam logic [31:0] ADDR_VERSION             = 32'h0000_0004;
    localparam logic [31:0] ADDR_CONTROL             = 32'h0000_0008;
    localparam logic [31:0] ADDR_COMMAND             = 32'h0000_0010;
    localparam logic [31:0] ADDR_COMMAND_COUNT       = 32'h0000_0014;
    localparam logic [31:0] ADDR_COMMAND_ERROR_COUNT = 32'h0000_0018;
    localparam logic [31:0] ADDR_EXECUTE_COUNT       = 32'h0000_001C;

    localparam logic [31:0] ADDR_VECTOR_CONFIG       = 32'h0000_0040;
    localparam logic [31:0] ADDR_VECTOR_DATA0        = 32'h0000_0060;
    localparam logic [31:0] ADDR_VECTOR_COMMIT       = 32'h0000_0080;

    localparam logic [31:0] ADDR_MATRIX_CONFIG       = 32'h0000_00A0;
    localparam logic [31:0] ADDR_MATRIX_DATA0        = 32'h0000_00C0;
    localparam logic [31:0] ADDR_MATRIX_COMMIT       = 32'h0000_00E0;

    localparam logic [31:0] ADDR_ACCUMULATOR0        = 32'h0000_0100;
    localparam logic [31:0] ADDR_VECTOR_VALID_MASK   = 32'h0000_0120;
    localparam logic [31:0] ADDR_MATRIX_VALID_MASK   = 32'h0000_0124;

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

    integer test_count;
    integer error_count;
    integer lane_index;

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

    task automatic report_error (
        input string message
    );
        begin
            error_count = error_count + 1;

            if (error_count <= 20) begin
                $display(
                    "ERROR test=%0d: %s",
                    test_count,
                    message
                );
            end
        end
    endtask

    task automatic axi_write (
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [3:0]  strobes,
        input logic [1:0]  expected_response
    );
        begin
            test_count = test_count + 1;

            @(negedge clk_i);

            s_axi_awaddr_i  = address;
            s_axi_awprot_i  = 3'b000;
            s_axi_awvalid_i = 1'b1;

            s_axi_wdata_i   = data;
            s_axi_wstrb_i   = strobes;
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

            if (s_axi_bresp_o !== expected_response) begin
                report_error("AXI write response mismatch");

                if (error_count <= 20) begin
                    $display(
                        "  address=%08h response=%h expected=%h",
                        address,
                        s_axi_bresp_o,
                        expected_response
                    );
                end
            end

            @(negedge clk_i);
            s_axi_bready_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            s_axi_bready_i = 1'b0;
        end
    endtask

    task automatic axi_read (
        input logic [31:0] address,
        input logic [31:0] expected_data,
        input logic [1:0]  expected_response
    );
        begin
            test_count = test_count + 1;

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

            if (s_axi_rresp_o !== expected_response) begin
                report_error("AXI read response mismatch");
            end

            if (
                expected_response == AXI_OKAY &&
                s_axi_rdata_o !== expected_data
            ) begin
                report_error("AXI read data mismatch");

                if (error_count <= 20) begin
                    $display(
                        "  address=%08h data=%08h expected=%08h",
                        address,
                        s_axi_rdata_o,
                        expected_data
                    );
                end
            end

            @(negedge clk_i);
            s_axi_rready_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            s_axi_rready_i = 1'b0;
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        s_axi_awaddr_i  = 32'd0;
        s_axi_awprot_i  = 3'd0;
        s_axi_awvalid_i = 1'b0;

        s_axi_wdata_i   = 32'd0;
        s_axi_wstrb_i   = 4'd0;
        s_axi_wvalid_i  = 1'b0;

        s_axi_bready_i  = 1'b0;

        s_axi_araddr_i  = 32'd0;
        s_axi_arprot_i  = 3'd0;
        s_axi_arvalid_i = 1'b0;

        s_axi_rready_i  = 1'b0;

        test_count  = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        axi_read(
            ADDR_DEVICE_ID,
            32'h4E43_4530,
            AXI_OKAY
        );

        axi_read(
            ADDR_VERSION,
            32'h0001_0000,
            AXI_OKAY
        );

        // Load vector register 1.
        axi_write(
            ADDR_VECTOR_CONFIG,
            32'h0000_FF01,
            4'b1111,
            AXI_OKAY
        );

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_write(
                ADDR_VECTOR_DATA0 +
                    (lane_index * 4),
                32'h0101_0101,
                4'b1111,
                AXI_OKAY
            );
        end

        axi_write(
            ADDR_VECTOR_COMMIT,
            32'h0000_0001,
            4'b1111,
            AXI_OKAY
        );

        // Load matrix register 2.
        axi_write(
            ADDR_MATRIX_CONFIG,
            32'h0000_FF02,
            4'b1111,
            AXI_OKAY
        );

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_write(
                ADDR_MATRIX_DATA0 +
                    (lane_index * 4),
                32'h0101_0101,
                4'b1111,
                AXI_OKAY
            );
        end

        axi_write(
            ADDR_MATRIX_COMMIT,
            32'h0000_0001,
            4'b1111,
            AXI_OKAY
        );

        axi_read(
            ADDR_VECTOR_VALID_MASK,
            32'h0000_0002,
            AXI_OKAY
        );

        axi_read(
            ADDR_MATRIX_VALID_MASK,
            32'h0000_0004,
            AXI_OKAY
        );

        // DOT4_MAC INT8X4: vector register 1, matrix register 2.
        axi_write(
            ADDR_COMMAND,
            32'h0000_2104,
            4'b1111,
            AXI_OKAY
        );

        repeat (5) begin
            @(posedge clk_i);
        end

        // Every lane computes:
        //   1*1 + 1*1 + 1*1 + 1*1 = 4.0
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_read(
                ADDR_ACCUMULATOR0 +
                    (lane_index * 4),
                32'h4080_0000,
                AXI_OKAY
            );
        end

        // Execute the same command again.
        axi_write(
            ADDR_COMMAND,
            32'h0000_2104,
            4'b1111,
            AXI_OKAY
        );

        repeat (5) begin
            @(posedge clk_i);
        end

        // Every accumulator is now 8.0.
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_read(
                ADDR_ACCUMULATOR0 +
                    (lane_index * 4),
                32'h4100_0000,
                AXI_OKAY
            );
        end

        // ---------------------------------------------------------------------
        // AXI-level BF16X2 execution through the same architectural
        // accumulators previously updated by INT8X4.
        //
        // Packed BF16X2 per lane:
        //
        //   vector = {3.0, 1.0}
        //   matrix = {4.0, 2.0}
        //
        // BF16X2 DOT2:
        //
        //   1.0 * 2.0 + 3.0 * 4.0 = 14.0
        //
        // Existing INT8 accumulator:
        //
        //   8.0 + 14.0 = 22.0
        // ---------------------------------------------------------------------

        // Load BF16X2 vector register 4.
        axi_write(
            ADDR_VECTOR_CONFIG,
            32'h0000_FF04,
            4'b1111,
            AXI_OKAY
        );

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_write(
                ADDR_VECTOR_DATA0 +
                    (lane_index * 4),
                32'h4040_3F80,
                4'b1111,
                AXI_OKAY
            );
        end

        axi_write(
            ADDR_VECTOR_COMMIT,
            32'h0000_0001,
            4'b1111,
            AXI_OKAY
        );

        // Load BF16X2 matrix register 5.
        axi_write(
            ADDR_MATRIX_CONFIG,
            32'h0000_FF05,
            4'b1111,
            AXI_OKAY
        );

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_write(
                ADDR_MATRIX_DATA0 +
                    (lane_index * 4),
                32'h4080_4000,
                4'b1111,
                AXI_OKAY
            );
        end

        axi_write(
            ADDR_MATRIX_COMMIT,
            32'h0000_0001,
            4'b1111,
            AXI_OKAY
        );

        // Register-valid masks now include:
        //
        //   vector registers 1 and 4
        //   matrix registers 2 and 5
        axi_read(
            ADDR_VECTOR_VALID_MASK,
            32'h0000_0012,
            AXI_OKAY
        );

        axi_read(
            ADDR_MATRIX_VALID_MASK,
            32'h0000_0024,
            AXI_OKAY
        );

        // COMMAND:
        //
        //   matrix source = 5
        //   vector source = 4
        //   precision     = BF16X2, 2'b01
        //   opcode        = MAC, 4'h3
        //
        // Encoded command = 0x0000_5413.
        axi_write(
            ADDR_COMMAND,
            32'h0000_5413,
            4'b1111,
            AXI_OKAY
        );

        repeat (5) begin
            @(posedge clk_i);
        end

        // Every shared FP32 accumulator must now contain 22.0.
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_read(
                ADDR_ACCUMULATOR0 +
                    (lane_index * 4),
                32'h41B0_0000,
                AXI_OKAY
            );
        end

        // ---------------------------------------------------------------------
        // AXI-level BF24 execution through the same architectural accumulators.
        //
        // One BF24 value occupies bits [23:0] of each 32-bit lane.
        // Bits [31:24] remain reserved and zero.
        //
        // Per lane:
        //
        //   vector BF24 = 2.0 = 0x400000
        //   matrix BF24 = 5.0 = 0x40A000
        //
        //   2.0 * 5.0 = 10.0
        //
        // Existing shared accumulator:
        //
        //   22.0 + 10.0 = 32.0
        // ---------------------------------------------------------------------

        // Load BF24 vector register 6.
        axi_write(
            ADDR_VECTOR_CONFIG,
            32'h0000_FF06,
            4'b1111,
            AXI_OKAY
        );

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_write(
                ADDR_VECTOR_DATA0 +
                    (lane_index * 4),
                32'h0040_0000,
                4'b1111,
                AXI_OKAY
            );
        end

        axi_write(
            ADDR_VECTOR_COMMIT,
            32'h0000_0001,
            4'b1111,
            AXI_OKAY
        );

        // Load BF24 matrix register 7.
        axi_write(
            ADDR_MATRIX_CONFIG,
            32'h0000_FF07,
            4'b1111,
            AXI_OKAY
        );

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_write(
                ADDR_MATRIX_DATA0 +
                    (lane_index * 4),
                32'h0040_A000,
                4'b1111,
                AXI_OKAY
            );
        end

        axi_write(
            ADDR_MATRIX_COMMIT,
            32'h0000_0001,
            4'b1111,
            AXI_OKAY
        );

        // Valid-register masks now include:
        //
        //   vectors: 1, 4 and 6 -> 0x0052
        //   matrices: 2, 5 and 7 -> 0x00A4
        axi_read(
            ADDR_VECTOR_VALID_MASK,
            32'h0000_0052,
            AXI_OKAY
        );

        axi_read(
            ADDR_MATRIX_VALID_MASK,
            32'h0000_00A4,
            AXI_OKAY
        );

        // COMMAND:
        //
        //   matrix source = 7
        //   vector source = 6
        //   precision     = BF24, 2'b10
        //   opcode        = MAC, 4'h3
        //
        // Encoded command = 0x0000_7623.
        axi_write(
            ADDR_COMMAND,
            32'h0000_7623,
            4'b1111,
            AXI_OKAY
        );

        repeat (5) begin
            @(posedge clk_i);
        end

        // Every shared FP32 accumulator must now contain 32.0.
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_read(
                ADDR_ACCUMULATOR0 +
                    (lane_index * 4),
                32'h4200_0000,
                AXI_OKAY
            );
        end

        axi_read(
            ADDR_COMMAND_COUNT,
            32'd4,
            AXI_OKAY
        );

        axi_read(
            ADDR_COMMAND_ERROR_COUNT,
            32'd0,
            AXI_OKAY
        );

        axi_read(
            ADDR_EXECUTE_COUNT,
            32'd4,
            AXI_OKAY
        );

        // Native FP32 precision is not implemented and must return SLVERR.
        //
        // matrix 7, vector 6, FP32 precision 2'b11, MAC opcode 4'h3:
        //
        //   command = 0x0000_7633
        axi_write(
            ADDR_COMMAND,
            32'h0000_7633,
            4'b1111,
            AXI_SLVERR
        );

        axi_read(
            ADDR_COMMAND_COUNT,
            32'd5,
            AXI_OKAY
        );

        axi_read(
            ADDR_COMMAND_ERROR_COUNT,
            32'd1,
            AXI_OKAY
        );

        axi_read(
            ADDR_EXECUTE_COUNT,
            32'd4,
            AXI_OKAY
        );

        // Unsupported opcode must return SLVERR.
        axi_write(
            ADDR_COMMAND,
            32'h0000_2101,
            4'b1111,
            AXI_SLVERR
        );

        axi_read(
            ADDR_COMMAND_COUNT,
            32'd6,
            AXI_OKAY
        );

        axi_read(
            ADDR_COMMAND_ERROR_COUNT,
            32'd2,
            AXI_OKAY
        );

        axi_read(
            ADDR_EXECUTE_COUNT,
            32'd4,
            AXI_OKAY
        );

        // Clear the FP32 accumulators.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0002,
            4'b0001,
            AXI_OKAY
        );

        repeat (2) begin
            @(posedge clk_i);
        end

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            axi_read(
                ADDR_ACCUMULATOR0 +
                    (lane_index * 4),
                32'h0000_0000,
                AXI_OKAY
            );
        end

        // Clear architectural registers.
        axi_write(
            ADDR_CONTROL,
            32'h0000_0001,
            4'b0001,
            AXI_OKAY
        );

        axi_read(
            ADDR_VECTOR_VALID_MASK,
            32'h0000_0000,
            AXI_OKAY
        );

        axi_read(
            ADDR_MATRIX_VALID_MASK,
            32'h0000_0000,
            AXI_OKAY
        );

        // Valid command encoding but invalid register operands.
        axi_write(
            ADDR_COMMAND,
            32'h0000_2104,
            4'b1111,
            AXI_SLVERR
        );

        axi_read(
            ADDR_COMMAND_COUNT,
            32'd7,
            AXI_OKAY
        );

        axi_read(
            ADDR_COMMAND_ERROR_COUNT,
            32'd3,
            AXI_OKAY
        );

        axi_read(
            ADDR_EXECUTE_COUNT,
            32'd4,
            AXI_OKAY
        );

        // Unmapped address.
        axi_read(
            32'h0000_F000,
            32'd0,
            AXI_SLVERR
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_axi_mixed_precision_top passed all %0d full-system AXI checks.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d full-system checks.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
