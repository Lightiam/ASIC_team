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
// Four-element signed INT8 dot-product.
//
// Packing:
//   Element 0: bits [7:0]
//   Element 1: bits [15:8]
//   Element 2: bits [23:16]
//   Element 3: bits [31:24]
//
// Output range:
//   Minimum: -65024
//   Maximum:  65536
//
// A signed 18-bit result represents the complete range exactly.
// -----------------------------------------------------------------------------

module nce_int8_dot4 (
    input  logic        [31:0] lhs_i,
    input  logic        [31:0] rhs_i,
    output logic signed [17:0] dot_o
);

    logic signed [7:0] lhs_0;
    logic signed [7:0] lhs_1;
    logic signed [7:0] lhs_2;
    logic signed [7:0] lhs_3;

    logic signed [7:0] rhs_0;
    logic signed [7:0] rhs_1;
    logic signed [7:0] rhs_2;
    logic signed [7:0] rhs_3;

    logic signed [15:0] product_0;
    logic signed [15:0] product_1;
    logic signed [15:0] product_2;
    logic signed [15:0] product_3;

    logic signed [17:0] product_ext_0;
    logic signed [17:0] product_ext_1;
    logic signed [17:0] product_ext_2;
    logic signed [17:0] product_ext_3;

    assign lhs_0 = $signed(lhs_i[7:0]);
    assign lhs_1 = $signed(lhs_i[15:8]);
    assign lhs_2 = $signed(lhs_i[23:16]);
    assign lhs_3 = $signed(lhs_i[31:24]);

    assign rhs_0 = $signed(rhs_i[7:0]);
    assign rhs_1 = $signed(rhs_i[15:8]);
    assign rhs_2 = $signed(rhs_i[23:16]);
    assign rhs_3 = $signed(rhs_i[31:24]);

    assign product_0 = lhs_0 * rhs_0;
    assign product_1 = lhs_1 * rhs_1;
    assign product_2 = lhs_2 * rhs_2;
    assign product_3 = lhs_3 * rhs_3;

    assign product_ext_0 = {{2{product_0[15]}}, product_0};
    assign product_ext_1 = {{2{product_1[15]}}, product_1};
    assign product_ext_2 = {{2{product_2[15]}}, product_2};
    assign product_ext_3 = {{2{product_3[15]}}, product_3};

    assign dot_o =
        product_ext_0 +
        product_ext_1 +
        product_ext_2 +
        product_ext_3;

endmodule

`default_nettype wire
