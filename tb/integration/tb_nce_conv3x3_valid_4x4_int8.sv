`timescale 1ns/1ps
`default_nettype none

module tb_nce_conv3x3_valid_4x4_int8;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic       pixel_write_enable_i;
    logic [3:0] pixel_write_addr_i;
    logic [7:0] pixel_write_data_i;

    logic       kernel_write_enable_i;
    logic [3:0] kernel_write_addr_i;
    logic [7:0] kernel_write_data_i;

    logic [15:0] pixel_valid_mask_o;
    logic [8:0]  kernel_valid_mask_o;

    logic start_i;
    logic start_ready_o;

    logic       busy_o;
    logic       done_o;
    logic       error_o;
    logic [2:0] error_code_o;

    logic [127:0] result_o;
    logic [3:0]   result_valid_o;

    logic [3:0] invalid_o;
    logic [3:0] overflow_o;
    logic [3:0] underflow_o;
    logic [3:0] inexact_o;

    integer check_count;
    integer error_count;
    integer write_index;
    integer timeout_count;

    nce_conv3x3_valid_4x4_int8 dut (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .pixel_write_enable_i   (pixel_write_enable_i),
        .pixel_write_addr_i     (pixel_write_addr_i),
        .pixel_write_data_i     (pixel_write_data_i),

        .kernel_write_enable_i  (kernel_write_enable_i),
        .kernel_write_addr_i    (kernel_write_addr_i),
        .kernel_write_data_i    (kernel_write_data_i),

        .pixel_valid_mask_o     (pixel_valid_mask_o),
        .kernel_valid_mask_o    (kernel_valid_mask_o),

        .start_i                (start_i),
        .start_ready_o          (start_ready_o),

        .busy_o                 (busy_o),
        .done_o                 (done_o),
        .error_o                (error_o),
        .error_code_o           (error_code_o),

        .result_o               (result_o),
        .result_valid_o         (result_valid_o),

        .invalid_o              (invalid_o),
        .overflow_o             (overflow_o),
        .underflow_o            (underflow_o),
        .inexact_o              (inexact_o)
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

    task automatic write_pixel (
        input logic [3:0] address,
        input logic [7:0] data
    );
        begin
            @(negedge clk_i);

            pixel_write_enable_i = 1'b1;
            pixel_write_addr_i   = address;
            pixel_write_data_i   = data;

            @(negedge clk_i);

            pixel_write_enable_i = 1'b0;
        end
    endtask

    task automatic write_kernel (
        input logic [3:0] address,
        input logic [7:0] data
    );
        begin
            @(negedge clk_i);

            kernel_write_enable_i = 1'b1;
            kernel_write_addr_i   = address;
            kernel_write_data_i   = data;

            @(negedge clk_i);

            kernel_write_enable_i = 1'b0;
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk_i);
            start_i = 1'b1;

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        pixel_write_enable_i = 1'b0;
        pixel_write_addr_i   = 4'd0;
        pixel_write_data_i   = 8'd0;

        kernel_write_enable_i = 1'b0;
        kernel_write_addr_i   = 4'd0;
        kernel_write_data_i   = 8'd0;

        start_i = 1'b0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        // Allow reset release and combinational readiness to propagate.
        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "Convolution frontend was not ready after reset"
        );

        check_condition(
            pixel_valid_mask_o === 16'd0 &&
            kernel_valid_mask_o === 9'd0,
            "Source-valid masks were not clear after reset"
        );

        // Starting without input data must fail.
        pulse_start();

        check_condition(
            error_o === 1'b1 &&
            error_code_o === 3'd1,
            "Missing-input error was not reported"
        );

        // Input feature map:
        //
        //    1   2   3   4
        //    5   6   7   8
        //    9  10  11  12
        //   13  14  15  16

        for (
            write_index = 0;
            write_index < 16;
            write_index = write_index + 1
        ) begin
            write_pixel(
                write_index[3:0],
                write_index + 1
            );
        end

        check_condition(
            pixel_valid_mask_o === 16'hFFFF,
            "Input feature map was not completely valid"
        );

        // Starting without the kernel must fail.
        pulse_start();

        check_condition(
            error_o === 1'b1 &&
            error_code_o === 3'd2,
            "Missing-kernel error was not reported"
        );

        // Signed 3x3 kernel:
        //
        //    1  -1   2
        //    0   3  -2
        //   -1   2   1
        //
        // Expected valid convolution:
        //
        //   31  36
        //   51  56

        write_kernel(4'd0, 8'h01);
        write_kernel(4'd1, 8'hFF);
        write_kernel(4'd2, 8'h02);

        write_kernel(4'd3, 8'h00);
        write_kernel(4'd4, 8'h03);
        write_kernel(4'd5, 8'hFE);

        write_kernel(4'd6, 8'hFF);
        write_kernel(4'd7, 8'h02);
        write_kernel(4'd8, 8'h01);

        check_condition(
            kernel_valid_mask_o === 9'h1FF,
            "Kernel was not completely valid"
        );

        pulse_start();

        timeout_count = 0;

        while (
            !done_o &&
            !error_o &&
            timeout_count < 1000
        ) begin
            @(posedge clk_i);
            #1;
            timeout_count = timeout_count + 1;
        end

        check_condition(
            timeout_count < 1000,
            "Convolution operation timed out"
        );

        check_condition(
            error_o === 1'b0,
            "Convolution operation reported an error"
        );

        check_condition(
            done_o === 1'b1,
            "Convolution operation did not produce done"
        );

        check_condition(
            result_valid_o === 4'hF,
            "Convolution results were not all valid"
        );

        check_condition(
            result_o[31:0] === 32'h41F8_0000,
            "Output[0][0] mismatch: expected 31.0"
        );

        check_condition(
            result_o[63:32] === 32'h4210_0000,
            "Output[0][1] mismatch: expected 36.0"
        );

        check_condition(
            result_o[95:64] === 32'h424C_0000,
            "Output[1][0] mismatch: expected 51.0"
        );

        check_condition(
            result_o[127:96] === 32'h4260_0000,
            "Output[1][1] mismatch: expected 56.0"
        );

        check_condition(
            invalid_o   === 4'd0 &&
            overflow_o  === 4'd0 &&
            underflow_o === 4'd0 &&
            inexact_o   === 4'd0,
            "Unexpected convolution arithmetic flags"
        );

        // Clear must remove source and result validity.
        @(negedge clk_i);
        clear_i = 1'b1;

        @(negedge clk_i);
        clear_i = 1'b0;

        check_condition(
            pixel_valid_mask_o === 16'd0 &&
            kernel_valid_mask_o === 9'd0,
            "Clear did not remove source validity"
        );

        check_condition(
            result_valid_o === 4'd0,
            "Clear did not remove result validity"
        );

        if (error_count == 0) begin
            $display(
                "PASS: 3x3 valid INT8 convolution passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d convolution errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
