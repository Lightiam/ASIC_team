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
// NCE packed INT8 dot-product front end.
//
// Computes four signed INT8 multiplications, sums them exactly, and converts
// the resulting signed 18-bit integer into IEEE-754 binary32.
//
// Both outputs are exposed for verification and later pipeline integration.
// -----------------------------------------------------------------------------

module nce_int8_dot4_fp32 (
    input  logic [31:0]        lhs_i,
    input  logic [31:0]        rhs_i,

    output logic signed [17:0] dot_int_o,
    output logic        [31:0] dot_fp32_o
);

    nce_int8_dot4 u_dot4 (
        .lhs_i (lhs_i),
        .rhs_i (rhs_i),
        .dot_o (dot_int_o)
    );

    nce_int18_to_fp32 u_int_to_fp32 (
        .int_i  (dot_int_o),
        .fp32_o (dot_fp32_o)
    );

endmodule

`default_nettype wire
