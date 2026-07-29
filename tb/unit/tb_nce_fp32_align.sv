`timescale 1ns/1ps
`default_nettype none

module tb_nce_fp32_align;

    logic [31:0] a_i;
    logic [31:0] b_i;

    logic        a_sign;
    logic [7:0]  a_exponent;
    logic [22:0] a_fraction;
    logic [23:0] a_significand;

    logic        b_sign;
    logic [7:0]  b_exponent;
    logic [22:0] b_fraction;
    logic [23:0] b_significand;

    logic large_is_a;
    logic large_sign;
    logic small_sign;
    logic subtract;

    logic [7:0] common_exponent;
    logic [7:0] exponent_difference;

    logic [26:0] large_significand;
    logic [26:0] small_significand;

    logic [31:0] vector_a;
    logic [31:0] vector_b;

    logic        expected_large_is_a;
    logic        expected_large_sign;
    logic        expected_small_sign;
    logic        expected_subtract;

    logic [7:0]  expected_common_exponent;
    logic [7:0]  expected_exponent_difference;

    logic [26:0] expected_large_significand;
    logic [26:0] expected_small_significand;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_fp32_decode u_decode_a (
        .fp_i               (a_i),
        .sign_o             (a_sign),
        .exponent_o         (a_exponent),
        .fraction_o         (a_fraction),
        .significand_o      (a_significand),
        .is_zero_o          (),
        .is_subnormal_o     (),
        .is_normal_o        (),
        .is_infinity_o      (),
        .is_nan_o           (),
        .is_quiet_nan_o     (),
        .is_signaling_nan_o ()
    );

    nce_fp32_decode u_decode_b (
        .fp_i               (b_i),
        .sign_o             (b_sign),
        .exponent_o         (b_exponent),
        .fraction_o         (b_fraction),
        .significand_o      (b_significand),
        .is_zero_o          (),
        .is_subnormal_o     (),
        .is_normal_o        (),
        .is_infinity_o      (),
        .is_nan_o           (),
        .is_quiet_nan_o     (),
        .is_signaling_nan_o ()
    );

    nce_fp32_align dut (
        .a_sign_i               (a_sign),
        .a_exponent_i           (a_exponent),
        .a_significand_i        (a_significand),

        .b_sign_i               (b_sign),
        .b_exponent_i           (b_exponent),
        .b_significand_i        (b_significand),

        .large_is_a_o           (large_is_a),
        .large_sign_o           (large_sign),
        .small_sign_o           (small_sign),
        .subtract_o             (subtract),

        .common_exponent_o      (common_exponent),
        .exponent_difference_o  (exponent_difference),

        .large_significand_o    (large_significand),
        .small_significand_o    (small_significand)
    );

    initial begin
        a_i                          = '0;
        b_i                          = '0;
        vector_a                     = '0;
        vector_b                     = '0;
        expected_large_is_a          = '0;
        expected_large_sign          = '0;
        expected_small_sign          = '0;
        expected_subtract            = '0;
        expected_common_exponent     = '0;
        expected_exponent_difference = '0;
        expected_large_significand   = '0;
        expected_small_significand   = '0;
        test_count                    = 0;
        error_count                   = 0;

        vector_file =
            $fopen("build/fp32_align_vectors.txt", "r");

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open build/fp32_align_vectors.txt"
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h\n",
                vector_a,
                vector_b,
                expected_large_is_a,
                expected_large_sign,
                expected_small_sign,
                expected_subtract,
                expected_common_exponent,
                expected_exponent_difference,
                expected_large_significand,
                expected_small_significand
            );

            if (scan_result == 10) begin
                a_i = vector_a;
                b_i = vector_b;

                #1;

                test_count = test_count + 1;

                if (
                    large_is_a !== expected_large_is_a ||
                    large_sign !== expected_large_sign ||
                    small_sign !== expected_small_sign ||
                    subtract !== expected_subtract ||
                    common_exponent !== expected_common_exponent ||
                    exponent_difference !== expected_exponent_difference ||
                    large_significand !== expected_large_significand ||
                    small_significand !== expected_small_significand
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR a=%08h b=%08h large_a=%h/%h signs=%h,%h/%h,%h sub=%h/%h exp=%02h/%02h diff=%02h/%02h large_sig=%07h/%07h small_sig=%07h/%07h",
                            vector_a,
                            vector_b,
                            large_is_a,
                            expected_large_is_a,
                            large_sign,
                            small_sign,
                            expected_large_sign,
                            expected_small_sign,
                            subtract,
                            expected_subtract,
                            common_exponent,
                            expected_common_exponent,
                            exponent_difference,
                            expected_exponent_difference,
                            large_significand,
                            expected_large_significand,
                            small_significand,
                            expected_small_significand
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_fp32_align passed all %0d vectors.",
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
