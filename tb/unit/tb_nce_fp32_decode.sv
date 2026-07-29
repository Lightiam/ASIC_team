`timescale 1ns/1ps
`default_nettype none

module tb_nce_fp32_decode;

    logic [31:0] fp_i;

    logic        sign_o;
    logic [7:0]  exponent_o;
    logic [22:0] fraction_o;
    logic [23:0] significand_o;

    logic is_zero_o;
    logic is_subnormal_o;
    logic is_normal_o;
    logic is_infinity_o;
    logic is_nan_o;
    logic is_quiet_nan_o;
    logic is_signaling_nan_o;

    logic [31:0] vector_fp;
    logic        expected_sign;
    logic [7:0]  expected_exponent;
    logic [22:0] expected_fraction;
    logic [23:0] expected_significand;
    logic [6:0]  expected_flags;
    logic [6:0]  actual_flags;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_fp32_decode dut (
        .fp_i               (fp_i),
        .sign_o             (sign_o),
        .exponent_o         (exponent_o),
        .fraction_o         (fraction_o),
        .significand_o      (significand_o),
        .is_zero_o          (is_zero_o),
        .is_subnormal_o     (is_subnormal_o),
        .is_normal_o        (is_normal_o),
        .is_infinity_o      (is_infinity_o),
        .is_nan_o           (is_nan_o),
        .is_quiet_nan_o     (is_quiet_nan_o),
        .is_signaling_nan_o (is_signaling_nan_o)
    );

    assign actual_flags = {
        is_signaling_nan_o,
        is_quiet_nan_o,
        is_nan_o,
        is_infinity_o,
        is_normal_o,
        is_subnormal_o,
        is_zero_o
    };

    initial begin
        fp_i                 = '0;
        vector_fp            = '0;
        expected_sign        = '0;
        expected_exponent    = '0;
        expected_fraction    = '0;
        expected_significand = '0;
        expected_flags       = '0;
        test_count           = 0;
        error_count          = 0;

        vector_file =
            $fopen("build/fp32_decode_vectors.txt", "r");

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open build/fp32_decode_vectors.txt"
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h\n",
                vector_fp,
                expected_sign,
                expected_exponent,
                expected_fraction,
                expected_significand,
                expected_flags
            );

            if (scan_result == 6) begin
                fp_i = vector_fp;
                #1;

                test_count = test_count + 1;

                if (
                    sign_o !== expected_sign ||
                    exponent_o !== expected_exponent ||
                    fraction_o !== expected_fraction ||
                    significand_o !== expected_significand ||
                    actual_flags !== expected_flags
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR fp=%08h sign=%h/%h exp=%02h/%02h frac=%06h/%06h sig=%06h/%06h flags=%02h/%02h",
                            vector_fp,
                            sign_o,
                            expected_sign,
                            exponent_o,
                            expected_exponent,
                            fraction_o,
                            expected_fraction,
                            significand_o,
                            expected_significand,
                            actual_flags,
                            expected_flags
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_fp32_decode passed all %0d vectors.",
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
