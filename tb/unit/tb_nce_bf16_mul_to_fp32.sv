`timescale 1ns/1ps
`default_nettype none

module tb_nce_bf16_mul_to_fp32;

    logic [15:0] a_i;
    logic [15:0] b_i;

    logic [31:0] product_o;

    logic invalid_o;
    logic overflow_o;
    logic underflow_o;
    logic inexact_o;

    logic [31:0] expected_product;

    integer expected_invalid;
    integer expected_overflow;
    integer expected_underflow;
    integer expected_inexact;

    integer vector_file;
    integer scan_count;

    integer vector_count;
    integer error_count;

    nce_bf16_mul_to_fp32 dut (
        .a_i          (a_i),
        .b_i          (b_i),

        .product_o    (product_o),

        .invalid_o    (invalid_o),
        .overflow_o   (overflow_o),
        .underflow_o  (underflow_o),
        .inexact_o    (inexact_o)
    );

    initial begin
        a_i = 16'd0;
        b_i = 16'd0;

        expected_product   = 32'd0;
        expected_invalid   = 0;
        expected_overflow  = 0;
        expected_underflow = 0;
        expected_inexact   = 0;

        vector_count = 0;
        error_count  = 0;

        vector_file = $fopen(
            "build/bf16_mul_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Unable to open BF16 vector file."
            );
        end

        while (!$feof(vector_file)) begin
            scan_count = $fscanf(
                vector_file,
                "%h %h %h %d %d %d %d\n",
                a_i,
                b_i,
                expected_product,
                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact
            );

            if (scan_count == 7) begin
                #1;

                vector_count = vector_count + 1;

                if (
                    product_o !== expected_product ||
                    invalid_o !== expected_invalid[0] ||
                    overflow_o !== expected_overflow[0] ||
                    underflow_o !== expected_underflow[0] ||
                    inexact_o !== expected_inexact[0]
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR vector=%0d a=%04h b=%04h",
                            vector_count,
                            a_i,
                            b_i
                        );

                        $display(
                            "  product=%08h expected=%08h",
                            product_o,
                            expected_product
                        );

                        $display(
                            "  flags=%b%b%b%b expected=%0d%0d%0d%0d",
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

        if (error_count == 0) begin
            $display(
                "PASS: nce_bf16_mul_to_fp32 passed all %0d vectors.",
                vector_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d BF16 vectors.",
                error_count,
                vector_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
