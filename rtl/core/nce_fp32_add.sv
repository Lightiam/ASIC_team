// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// IEEE-754 binary32 combinational adder.
//
// Supported behavior:
//   - Round to nearest, ties to even
//   - Normal and subnormal operands
//   - Signed zeros
//   - Positive and negative infinity
//   - Quiet and signaling NaNs
//   - Invalid, overflow, underflow and inexact flags
//
// Underflow uses tininess detection after rounding.
// -----------------------------------------------------------------------------

module nce_fp32_add (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,

    output logic [31:0] result_o,

    output logic invalid_o,
    output logic overflow_o,
    output logic underflow_o,
    output logic inexact_o
);

    logic        special_handled;
    logic [31:0] special_result;
    logic        special_invalid;

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

    logic [31:0] finite_result;
    logic        finite_inexact;
    logic        finite_overflow;
    logic        finite_underflow;

    nce_fp32_add_special u_special (
        .a_i       (a_i),
        .b_i       (b_i),
        .handled_o (special_handled),
        .result_o  (special_result),
        .invalid_o (special_invalid)
    );

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

    nce_fp32_round_pack u_round_pack (
        .result_sign_i  (normalized_sign),
        .exponent_i     (normalized_exponent),
        .significand_i  (normalized_significand),
        .is_subnormal_i (normalized_subnormal),
        .exact_zero_i   (normalized_exact_zero),

        .fp32_o         (finite_result),
        .inexact_o      (finite_inexact),
        .overflow_o     (finite_overflow),
        .underflow_o    (finite_underflow)
    );

    assign result_o =
        special_handled
        ? special_result
        : finite_result;

    assign invalid_o =
        special_handled
        ? special_invalid
        : 1'b0;

    assign overflow_o =
        special_handled
        ? 1'b0
        : finite_overflow;

    assign underflow_o =
        special_handled
        ? 1'b0
        : finite_underflow;

    assign inexact_o =
        special_handled
        ? 1'b0
        : finite_inexact;

endmodule

`default_nettype wire
