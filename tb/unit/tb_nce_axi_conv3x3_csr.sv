`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_conv3x3_csr;

    localparam logic [31:0] ADDR_CONTROL      = 32'h0000_0400;
    localparam logic [31:0] ADDR_STATUS       = 32'h0000_0404;
    localparam logic [31:0] ADDR_PIXEL_ADDR   = 32'h0000_0408;
    localparam logic [31:0] ADDR_PIXEL_DATA   = 32'h0000_040C;
    localparam logic [31:0] ADDR_KERNEL_ADDR  = 32'h0000_0410;
    localparam logic [31:0] ADDR_KERNEL_DATA  = 32'h0000_0414;
    localparam logic [31:0] ADDR_FLAGS        = 32'h0000_0424;
    localparam logic [31:0] ADDR_RESULT_0     = 32'h0000_0440;
    localparam logic [31:0] ADDR_RESULT_3     = 32'h0000_044C;

    logic clk_i;
    logic rst_ni;

    logic        write_valid_i;
    logic        write_ready_o;
    logic [31:0] write_addr_i;
    logic [31:0] write_data_i;
    logic [3:0]  write_strb_i;
    logic        write_error_o;

    logic        read_valid_i;
    logic        read_ready_o;
    logic [31:0] read_addr_i;
    logic [31:0] read_data_o;
    logic        read_error_o;

    logic conv_clear_o;

    logic       pixel_write_enable_o;
    logic [3:0] pixel_write_addr_o;
    logic [7:0] pixel_write_data_o;

    logic       kernel_write_enable_o;
    logic [3:0] kernel_write_addr_o;
    logic [7:0] kernel_write_data_o;

    logic conv_start_o;
    logic conv_start_ready_i;

    logic       conv_busy_i;
    logic       conv_done_i;
    logic       conv_error_i;
    logic [2:0] conv_error_code_i;

    logic [15:0] pixel_valid_mask_i;
    logic [8:0]  kernel_valid_mask_i;

    logic [127:0] result_i;
    logic [3:0]   result_valid_i;

    logic [3:0] invalid_i;
    logic [3:0] overflow_i;
    logic [3:0] underflow_i;
    logic [3:0] inexact_i;

    integer check_count;
    integer error_count;

    nce_axi_conv3x3_csr dut (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .write_valid_i          (write_valid_i),
        .write_ready_o          (write_ready_o),
        .write_addr_i           (write_addr_i),
        .write_data_i           (write_data_i),
        .write_strb_i           (write_strb_i),
        .write_error_o          (write_error_o),

        .read_valid_i           (read_valid_i),
        .read_ready_o           (read_ready_o),
        .read_addr_i            (read_addr_i),
        .read_data_o            (read_data_o),
        .read_error_o           (read_error_o),

        .conv_clear_o           (conv_clear_o),

        .pixel_write_enable_o   (pixel_write_enable_o),
        .pixel_write_addr_o     (pixel_write_addr_o),
        .pixel_write_data_o     (pixel_write_data_o),

        .kernel_write_enable_o  (kernel_write_enable_o),
        .kernel_write_addr_o    (kernel_write_addr_o),
        .kernel_write_data_o    (kernel_write_data_o),

        .conv_start_o           (conv_start_o),
        .conv_start_ready_i     (conv_start_ready_i),

        .conv_busy_i            (conv_busy_i),
        .conv_done_i            (conv_done_i),
        .conv_error_i           (conv_error_i),
        .conv_error_code_i      (conv_error_code_i),

        .pixel_valid_mask_i     (pixel_valid_mask_i),
        .kernel_valid_mask_i    (kernel_valid_mask_i),

        .result_i               (result_i),
        .result_valid_i         (result_valid_i),

        .invalid_i              (invalid_i),
        .overflow_i             (overflow_i),
        .underflow_i            (underflow_i),
        .inexact_i              (inexact_i)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    task automatic check_condition (
        input logic condition,
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

    task automatic csr_write (
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [3:0]  strobe,
        input logic        expected_error
    );
        begin
            @(negedge clk_i);

            write_valid_i = 1'b1;
            write_addr_i  = address;
            write_data_i  = data;
            write_strb_i  = strobe;

            @(posedge clk_i);
            #1;

            check_condition(
                write_error_o === expected_error,
                "CSR write error response mismatch"
            );

            @(negedge clk_i);
            write_valid_i = 1'b0;
        end
    endtask

    task automatic csr_read (
        input logic [31:0] address,
        input logic [31:0] expected_data,
        input logic        expected_error
    );
        begin
            @(negedge clk_i);

            read_valid_i = 1'b1;
            read_addr_i  = address;

            #1;

            check_condition(
                read_error_o === expected_error,
                "CSR read error response mismatch"
            );

            if (!expected_error) begin
                check_condition(
                    read_data_o === expected_data,
                    "CSR read data mismatch"
                );

                if (read_data_o !== expected_data) begin
                    $display(
                        "  address=%08h data=%08h expected=%08h",
                        address,
                        read_data_o,
                        expected_data
                    );
                end
            end

            @(negedge clk_i);
            read_valid_i = 1'b0;
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        write_valid_i = 1'b0;
        write_addr_i  = 32'd0;
        write_data_i  = 32'd0;
        write_strb_i  = 4'd0;

        read_valid_i = 1'b0;
        read_addr_i  = 32'd0;

        conv_start_ready_i = 1'b1;

        conv_busy_i       = 1'b0;
        conv_done_i       = 1'b0;
        conv_error_i      = 1'b0;
        conv_error_code_i = 3'd0;

        pixel_valid_mask_i  = 16'd0;
        kernel_valid_mask_i = 9'd0;

        result_i       = 128'd0;
        result_valid_i = 4'd0;

        invalid_i   = 4'd0;
        overflow_i  = 4'd0;
        underflow_i = 4'd0;
        inexact_i   = 4'd0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            write_ready_o === 1'b1 &&
            read_ready_o === 1'b1,
            "CSR was not ready after reset"
        );

        // Address and strobe validation.
        csr_write(
            ADDR_PIXEL_ADDR + 32'd1,
            32'd0,
            4'b1111,
            1'b1
        );

        csr_write(
            ADDR_PIXEL_ADDR,
            32'd0,
            4'b0001,
            1'b1
        );

        // Pixel write path.
        csr_write(
            ADDR_PIXEL_ADDR,
            32'd15,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_PIXEL_DATA,
            32'h0000_0080,
            4'b1111,
            1'b0
        );

        check_condition(
            pixel_write_enable_o === 1'b1 &&
            pixel_write_addr_o === 4'd15 &&
            pixel_write_data_o === 8'h80,
            "Pixel write command mismatch"
        );

        // Kernel address validation and write path.
        csr_write(
            ADDR_KERNEL_ADDR,
            32'd9,
            4'b1111,
            1'b1
        );

        csr_write(
            ADDR_KERNEL_ADDR,
            32'd8,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_KERNEL_DATA,
            32'h0000_00FF,
            4'b1111,
            1'b0
        );

        check_condition(
            kernel_write_enable_o === 1'b1 &&
            kernel_write_addr_o === 4'd8 &&
            kernel_write_data_o === 8'hFF,
            "Kernel write command mismatch"
        );

        // Start must be rejected while unavailable.
        conv_start_ready_i = 1'b0;

        csr_write(
            ADDR_CONTROL,
            32'h0000_0001,
            4'b1111,
            1'b1
        );

        check_condition(
            conv_start_o === 1'b0,
            "Unavailable convolution start was emitted"
        );

        conv_start_ready_i = 1'b1;

        csr_write(
            ADDR_CONTROL,
            32'h0000_0001,
            4'b1111,
            1'b0
        );

        check_condition(
            conv_start_o === 1'b1,
            "Valid convolution start was not emitted"
        );

        // Source writes must be rejected while busy.
        conv_busy_i = 1'b1;

        csr_write(
            ADDR_PIXEL_DATA,
            32'h0000_0011,
            4'b1111,
            1'b1
        );

        conv_busy_i = 1'b0;

        // Populate readback values.
        pixel_valid_mask_i  = 16'hFFFF;
        kernel_valid_mask_i = 9'h1FF;
        result_valid_i      = 4'hF;

        result_i = {
            32'h4260_0000,
            32'h424C_0000,
            32'h4210_0000,
            32'h41F8_0000
        };

        invalid_i   = 4'h1;
        overflow_i  = 4'h2;
        underflow_i = 4'h4;
        inexact_i   = 4'h8;

        @(negedge clk_i);
        conv_done_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        conv_done_i = 1'b0;

        csr_read(
            ADDR_STATUS,
            32'h0000_0705,
            1'b0
        );

        @(negedge clk_i);
        conv_error_i      = 1'b1;
        conv_error_code_i = 3'd3;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        conv_error_i = 1'b0;

        csr_read(
            ADDR_STATUS,
            32'h0000_073D,
            1'b0
        );

        csr_read(
            ADDR_RESULT_0,
            32'h41F8_0000,
            1'b0
        );

        csr_read(
            ADDR_RESULT_3,
            32'h4260_0000,
            1'b0
        );

        csr_read(
            ADDR_FLAGS,
            32'h0000_8421,
            1'b0
        );

        // Clear sticky status only.
        csr_write(
            ADDR_CONTROL,
            32'h0000_0004,
            4'b1111,
            1'b0
        );

        csr_read(
            ADDR_STATUS,
            32'h0000_0701,
            1'b0
        );

        // Full clear command.
        csr_write(
            ADDR_CONTROL,
            32'h0000_0002,
            4'b1111,
            1'b0
        );

        check_condition(
            conv_clear_o === 1'b1,
            "Convolution clear command was not emitted"
        );

        // Unsupported read address.
        csr_read(
            32'h0000_0430,
            32'd0,
            1'b1
        );

        if (error_count == 0) begin
            $display(
                "PASS: convolution CSR passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d convolution CSR errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
