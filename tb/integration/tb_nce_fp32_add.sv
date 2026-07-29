`timescale 1ns/1ps
`default_nettype none

module tb_nce_fp32_add;

    logic [31:0] a_i;
    logic [31:0] b_i;

    logic [31:0] result_o;
    logic        invalid_o;
    logic        overflow_o;
    logic        underflow_o;
    logic        inexact_o;

    logic [31:0] vector_a;
    logic [31:0] vector_b;
    logic [31:0] expected_result;
    logic        expected_invalid;
    logic        expected_overflow;
    logic        expected_underflow;
    logic        expected_inexact;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_fp32_add dut (
        .a_i         (a_i),
        .b_i         (b_i),
        .result_o    (result_o),
        .invalid_o   (invalid_o),
        .overflow_o  (overflow_o),
        .underflow_o (underflow_o),
        .inexact_o   (inexact_o)
    );

    initial begin
        a_i                = '0;
        b_i                = '0;
        vector_a           = '0;
        vector_b           = '0;
        expected_result    = '0;
        expected_invalid   = '0;
        expected_overflow  = '0;
        expected_underflow = '0;
        expected_inexact   = '0;
        test_count         = 0;
        error_count        = 0;

        vector_file =
            $fopen("build/fp32_add_vectors.txt", "r");

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open build/fp32_add_vectors.txt"
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h\n",
                vector_a,
                vector_b,
                expected_result,
                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact
            );

            if (scan_result == 7) begin
                a_i = vector_a;
                b_i = vector_b;

                #1;

                test_count = test_count + 1;

                if (
                    result_o !== expected_result ||
                    invalid_o !== expected_invalid ||
                    overflow_o !== expected_overflow ||
                    underflow_o !== expected_underflow ||
                    inexact_o !== expected_inexact
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR a=%08h b=%08h result=%08h/%08h invalid=%h/%h overflow=%h/%h underflow=%h/%h inexact=%h/%h",
                            vector_a,
                            vector_b,
                            result_o,
                            expected_result,
                            invalid_o,
                            expected_invalid,
                            overflow_o,
                            expected_overflow,
                            underflow_o,
                            expected_underflow,
                            inexact_o,
                            expected_inexact
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_fp32_add passed all %0d vectors.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d tests.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
