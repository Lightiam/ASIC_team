`timescale 1ns/1ps
`default_nettype none

module tb_nce_fp32_round_pack;

    logic [31:0] a_i;
    logic [31:0] b_i;

    logic        a_sign;
    logic [7:0]  a_exponent;
    logic [23:0] a_significand;

    logic        b_sign;
    logic [7:0]  b_exponent;
    logic [23:0] b_significand;

    logic        large_sign;
    logic        subtract;
    logic [7:0]  common_exponent;
    logic [26:0] large_significand;
    logic [26:0] small_significand;

    logic        raw_sign;
    logic [7:0]  raw_exponent;
    logic [27:0] raw_significand;
    logic        raw_exact_zero;

    logic        normalized_sign;
    logic [7:0]  normalized_exponent;
    logic [26:0] normalized_significand;
    logic        normalized_subnormal;
    logic        normalized_exact_zero;

    logic [31:0] result_fp32;
    logic        result_inexact;
    logic        result_overflow;
    logic        result_underflow;

    logic [31:0] vector_a;
    logic [31:0] vector_b;
    logic [31:0] expected_result;
    logic        expected_inexact;
    logic        expected_overflow;
    logic        expected_underflow;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_fp32_decode u_decode_a (
        .fp_i               (a_i),
        .sign_o             (a_sign),
        .exponent_o         (a_exponent),
        .fraction_o         (),
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
        .fraction_o         (),
        .significand_o      (b_significand),
        .is_zero_o          (),
        .is_subnormal_o     (),
        .is_normal_o        (),
        .is_infinity_o      (),
        .is_nan_o           (),
        .is_quiet_nan_o     (),
        .is_signaling_nan_o ()
    );

    nce_fp32_align u_align (
        .a_sign_i              (a_sign),
        .a_exponent_i          (a_exponent),
        .a_significand_i       (a_significand),
        .b_sign_i              (b_sign),
        .b_exponent_i          (b_exponent),
        .b_significand_i       (b_significand),
        .large_is_a_o          (),
        .large_sign_o          (large_sign),
        .small_sign_o          (),
        .subtract_o            (subtract),
        .common_exponent_o     (common_exponent),
        .exponent_difference_o (),
        .large_significand_o   (large_significand),
        .small_significand_o   (small_significand)
    );

    nce_fp32_addsub_raw u_addsub (
        .large_sign_i        (large_sign),
        .subtract_i          (subtract),
        .common_exponent_i   (common_exponent),
        .large_significand_i (large_significand),
        .small_significand_i (small_significand),
        .result_sign_o       (raw_sign),
        .exponent_o          (raw_exponent),
        .significand_o       (raw_significand),
        .exact_zero_o        (raw_exact_zero)
    );

    nce_fp32_normalize u_normalize (
        .result_sign_i  (raw_sign),
        .exponent_i     (raw_exponent),
        .significand_i  (raw_significand),
        .exact_zero_i   (raw_exact_zero),
        .result_sign_o  (normalized_sign),
        .exponent_o     (normalized_exponent),
        .significand_o  (normalized_significand),
        .is_subnormal_o (normalized_subnormal),
        .exact_zero_o   (normalized_exact_zero)
    );

    nce_fp32_round_pack dut (
        .result_sign_i   (normalized_sign),
        .exponent_i      (normalized_exponent),
        .significand_i   (normalized_significand),
        .is_subnormal_i  (normalized_subnormal),
        .exact_zero_i    (normalized_exact_zero),
        .fp32_o          (result_fp32),
        .inexact_o       (result_inexact),
        .overflow_o      (result_overflow),
        .underflow_o     (result_underflow)
    );

    initial begin
        a_i                = '0;
        b_i                = '0;
        vector_a           = '0;
        vector_b           = '0;
        expected_result    = '0;
        expected_inexact   = '0;
        expected_overflow  = '0;
        expected_underflow = '0;
        test_count         = 0;
        error_count        = 0;

        vector_file =
            $fopen(
                "build/fp32_round_pack_vectors.txt",
                "r"
            );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open FP32 round-pack vectors"
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h\n",
                vector_a,
                vector_b,
                expected_result,
                expected_inexact,
                expected_overflow,
                expected_underflow
            );

            if (scan_result == 6) begin
                a_i = vector_a;
                b_i = vector_b;

                #1;

                test_count = test_count + 1;

                if (
                    result_fp32 !== expected_result ||
                    result_inexact !== expected_inexact ||
                    result_overflow !== expected_overflow ||
                    result_underflow !== expected_underflow
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR a=%08h b=%08h result=%08h/%08h inexact=%h/%h overflow=%h/%h underflow=%h/%h",
                            vector_a,
                            vector_b,
                            result_fp32,
                            expected_result,
                            result_inexact,
                            expected_inexact,
                            result_overflow,
                            expected_overflow,
                            result_underflow,
                            expected_underflow
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_fp32_round_pack passed all %0d vectors.",
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
