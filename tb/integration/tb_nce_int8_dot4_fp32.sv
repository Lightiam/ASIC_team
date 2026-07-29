`timescale 1ns/1ps
`default_nettype none

module tb_nce_int8_dot4_fp32;

    logic [31:0] lhs_i;
    logic [31:0] rhs_i;

    logic signed [17:0] dot_int_o;
    logic        [31:0] dot_fp32_o;

    logic [31:0] vector_lhs;
    logic [31:0] vector_rhs;
    logic [17:0] expected_dot;
    logic [31:0] expected_fp32;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_int8_dot4_fp32 dut (
        .lhs_i      (lhs_i),
        .rhs_i      (rhs_i),
        .dot_int_o  (dot_int_o),
        .dot_fp32_o (dot_fp32_o)
    );

    initial begin
        lhs_i         = '0;
        rhs_i         = '0;
        vector_lhs    = '0;
        vector_rhs    = '0;
        expected_dot  = '0;
        expected_fp32 = '0;
        test_count    = 0;
        error_count   = 0;

        vector_file =
            $fopen("build/int8_dot4_fp32_vectors.txt", "r");

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open build/int8_dot4_fp32_vectors.txt"
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h\n",
                vector_lhs,
                vector_rhs,
                expected_dot,
                expected_fp32
            );

            if (scan_result == 4) begin
                lhs_i = vector_lhs;
                rhs_i = vector_rhs;

                #1;

                test_count = test_count + 1;

                if (
                    dot_int_o !== expected_dot ||
                    dot_fp32_o !== expected_fp32
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR test=%0d lhs=%08h rhs=%08h dot_expected=%05h dot_actual=%05h fp_expected=%08h fp_actual=%08h",
                            test_count,
                            vector_lhs,
                            vector_rhs,
                            expected_dot,
                            dot_int_o,
                            expected_fp32,
                            dot_fp32_o
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_int8_dot4_fp32 passed all %0d vectors.",
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
