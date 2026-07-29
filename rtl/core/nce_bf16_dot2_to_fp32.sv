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
// Packed BF16X2 DOT2 to FP32.
//
// Packing:
//   lhs_i[15:0]  × rhs_i[15:0]
//   lhs_i[31:16] × rhs_i[31:16]
//
// Result:
//   FP32(lhs0 * rhs0 + lhs1 * rhs1)
// -----------------------------------------------------------------------------

module nce_bf16_dot2_to_fp32 (
    input  logic [31:0] lhs_i,
    input  logic [31:0] rhs_i,

    output logic [31:0] result_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    logic [31:0] product_0;
    logic [31:0] product_1;

    logic product_0_invalid;
    logic product_0_overflow;
    logic product_0_underflow;
    logic product_0_inexact;

    logic product_1_invalid;
    logic product_1_overflow;
    logic product_1_underflow;
    logic product_1_inexact;

    logic add_invalid;
    logic add_overflow;
    logic add_underflow;
    logic add_inexact;

    nce_bf16_mul_to_fp32 u_multiplier_0 (
        .a_i         (lhs_i[15:0]),
        .b_i         (rhs_i[15:0]),

        .product_o   (product_0),

        .invalid_o   (product_0_invalid),
        .overflow_o  (product_0_overflow),
        .underflow_o (product_0_underflow),
        .inexact_o   (product_0_inexact)
    );

    nce_bf16_mul_to_fp32 u_multiplier_1 (
        .a_i         (lhs_i[31:16]),
        .b_i         (rhs_i[31:16]),

        .product_o   (product_1),

        .invalid_o   (product_1_invalid),
        .overflow_o  (product_1_overflow),
        .underflow_o (product_1_underflow),
        .inexact_o   (product_1_inexact)
    );

    nce_fp32_add u_product_adder (
        .a_i         (product_0),
        .b_i         (product_1),

        .result_o    (result_o),

        .invalid_o   (add_invalid),
        .overflow_o  (add_overflow),
        .underflow_o (add_underflow),
        .inexact_o   (add_inexact)
    );

    assign invalid_o =
        product_0_invalid |
        product_1_invalid |
        add_invalid;

    assign overflow_o =
        product_0_overflow |
        product_1_overflow |
        add_overflow;

    assign underflow_o =
        product_0_underflow |
        product_1_underflow |
        add_underflow;

    assign inexact_o =
        product_0_inexact |
        product_1_inexact |
        add_inexact;

endmodule

`default_nettype wire
