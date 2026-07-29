`timescale 1ns/1ps
`default_nettype none

module tb_nce_bf24_mul_to_fp32;

    logic [23:0] a_i;
    logic [23:0] b_i;

    logic [31:0] product_o;

    logic invalid_o;
    logic overflow_o;
    logic underflow_o;
    logic inexact_o;

    logic [31:0] expected_product;
    logic [3:0]  expected_flags;

    integer vector_file;
    integer scan_count;
    integer vector_count;
    integer error_count;

    nce_bf24_mul_to_fp32 dut (
        .a_i        (a_i),
        .b_i        (b_i),

        .product_o  (product_o),

        .invalid_o  (invalid_o),
        .overflow_o (overflow_o),
        .underflow_o(underflow_o),
        .inexact_o  (inexact_o)
    );

    initial begin
        a_i = 24'd0;
        b_i = 24'd0;

        expected_product = 32'd0;
        expected_flags   = 4'd0;

        vector_count = 0;
        error_count  = 0;

        vector_file = $fopen(
            "build/bf24_mul_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Unable to open build/bf24_mul_vectors.txt"
            );
        end

        while (!$feof(vector_file)) begin
            scan_count = $fscanf(
                vector_file,
                "%h %h %h %h\n",
                a_i,
                b_i,
                expected_product,
                expected_flags
            );

            if (scan_count == 4) begin
                #1;

                vector_count = vector_count + 1;

                if (
                    product_o !== expected_product ||
                    invalid_o !== expected_flags[3] ||
                    overflow_o !== expected_flags[2] ||
                    underflow_o !== expected_flags[1] ||
                    inexact_o !== expected_flags[0]
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR vector=%0d a=%06h b=%06h",
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
                            "  flags  =%b%b%b%b expected=%b",
                            invalid_o,
                            overflow_o,
                            underflow_o,
                            inexact_o,
                            expected_flags
                        );
                    end
                end
            end
            else if (scan_count != -1) begin
                $fatal(
                    1,
                    "Malformed BF24 vector file near vector %0d",
                    vector_count
                );
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_bf24_mul_to_fp32 passed all %0d vectors.",
                vector_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d BF24 multiplication errors in %0d vectors.",
                error_count,
                vector_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
