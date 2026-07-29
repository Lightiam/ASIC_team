`timescale 1ns/1ps
`default_nettype none

module tb_nce_fp32_accumulator;

    logic clk_i;
    logic rst_ni;

    logic clear_i;

    logic        in_valid_i;
    logic        in_ready_o;
    logic [31:0] addend_i;

    logic [31:0] accumulator_o;
    logic        accumulator_valid_o;

    logic invalid_o;
    logic overflow_o;
    logic underflow_o;
    logic inexact_o;

    logic        vector_clear;
    logic        vector_valid;
    logic [31:0] vector_addend;

    logic        expected_ready;
    logic [31:0] expected_accumulator;
    logic        expected_accumulator_valid;
    logic        expected_invalid;
    logic        expected_overflow;
    logic        expected_underflow;
    logic        expected_inexact;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_fp32_accumulator dut (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .clear_i             (clear_i),
        .in_valid_i          (in_valid_i),
        .in_ready_o          (in_ready_o),
        .addend_i            (addend_i),
        .accumulator_o       (accumulator_o),
        .accumulator_valid_o (accumulator_valid_o),
        .invalid_o           (invalid_o),
        .overflow_o          (overflow_o),
        .underflow_o         (underflow_o),
        .inexact_o           (inexact_o)
    );

    initial begin
        clk_i = 1'b0;

        forever begin
            #5 clk_i = ~clk_i;
        end
    end

    initial begin
        rst_ni                     = 1'b0;
        clear_i                    = 1'b0;
        in_valid_i                 = 1'b0;
        addend_i                   = 32'd0;

        vector_clear               = 1'b0;
        vector_valid               = 1'b0;
        vector_addend              = 32'd0;

        expected_ready             = 1'b0;
        expected_accumulator       = 32'd0;
        expected_accumulator_valid = 1'b0;
        expected_invalid           = 1'b0;
        expected_overflow          = 1'b0;
        expected_underflow         = 1'b0;
        expected_inexact           = 1'b0;

        test_count                 = 0;
        error_count                = 0;

        repeat (3) begin
            @(posedge clk_i);
        end

        #1;

        if (
            accumulator_o !== 32'h0000_0000 ||
            accumulator_valid_o !== 1'b0 ||
            invalid_o !== 1'b0 ||
            overflow_o !== 1'b0 ||
            underflow_o !== 1'b0 ||
            inexact_o !== 1'b0
        ) begin
            $fatal(1, "Accumulator reset state is incorrect.");
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file =
            $fopen("build/fp32_accumulator_vectors.txt", "r");

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open FP32 accumulator vectors."
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h\n",
                vector_clear,
                vector_valid,
                vector_addend,
                expected_ready,
                expected_accumulator,
                expected_accumulator_valid,
                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact
            );

            if (scan_result == 10) begin
                @(negedge clk_i);

                clear_i    = vector_clear;
                in_valid_i = vector_valid;
                addend_i   = vector_addend;

                #1;

                if (in_ready_o !== expected_ready) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "READY ERROR test=%0d clear=%h valid=%h ready=%h/%h",
                            test_count + 1,
                            vector_clear,
                            vector_valid,
                            in_ready_o,
                            expected_ready
                        );
                    end
                end

                @(posedge clk_i);
                #1;

                test_count = test_count + 1;

                if (
                    accumulator_o !== expected_accumulator ||
                    accumulator_valid_o !== expected_accumulator_valid ||
                    invalid_o !== expected_invalid ||
                    overflow_o !== expected_overflow ||
                    underflow_o !== expected_underflow ||
                    inexact_o !== expected_inexact
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "STATE ERROR test=%0d clear=%h valid=%h addend=%08h acc=%08h/%08h acc_valid=%h/%h flags=%h%h%h%h/%h%h%h%h",
                            test_count,
                            vector_clear,
                            vector_valid,
                            vector_addend,
                            accumulator_o,
                            expected_accumulator,
                            accumulator_valid_o,
                            expected_accumulator_valid,
                            invalid_o,
                            overflow_o,
                            underflow_o,
                            inexact_o,
                            expected_invalid,
                            expected_overflow,
                            expected_underflow,
                            expected_inexact
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        clear_i    = 1'b0;
        in_valid_i = 1'b0;
        addend_i   = 32'd0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_fp32_accumulator passed all %0d cycles.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d cycles.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
