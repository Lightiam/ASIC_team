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
// IEEE-754 binary32 addition special-case resolver.
//
// This stage resolves:
//   - Quiet and signaling NaNs
//   - Positive and negative infinity
//   - Infinity plus opposite infinity
//   - Positive and negative zero
//   - Zero plus a finite nonzero operand
//
// When handled_o is low, both operands are finite and nonzero and must proceed
// to the normal FP32 significand alignment and addition datapath.
//
// NaN policy:
//   1. Prefer signaling NaN A
//   2. Prefer signaling NaN B
//   3. Prefer quiet NaN A
//   4. Prefer quiet NaN B
//
// Any returned NaN is quieted.
// -----------------------------------------------------------------------------

module nce_fp32_add_special (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,

    output logic        handled_o,
    output logic [31:0] result_o,
    output logic        invalid_o
);

    logic a_exp_all_ones;
    logic b_exp_all_ones;
    logic a_exp_zero;
    logic b_exp_zero;
    logic a_frac_zero;
    logic b_frac_zero;

    logic a_zero;
    logic b_zero;
    logic a_infinity;
    logic b_infinity;
    logic a_nan;
    logic b_nan;
    logic a_signaling_nan;
    logic b_signaling_nan;

    function automatic logic [31:0] quiet_nan (
        input logic        sign,
        input logic [21:0] payload
    );
        begin
            quiet_nan = {
                sign,
                8'hff,
                1'b1,
                payload
            };
        end
    endfunction

    assign a_exp_all_ones = (a_i[30:23] == 8'hff);
    assign b_exp_all_ones = (b_i[30:23] == 8'hff);

    assign a_exp_zero = (a_i[30:23] == 8'h00);
    assign b_exp_zero = (b_i[30:23] == 8'h00);

    assign a_frac_zero = (a_i[22:0] == 23'd0);
    assign b_frac_zero = (b_i[22:0] == 23'd0);

    assign a_zero = a_exp_zero && a_frac_zero;
    assign b_zero = b_exp_zero && b_frac_zero;

    assign a_infinity = a_exp_all_ones && a_frac_zero;
    assign b_infinity = b_exp_all_ones && b_frac_zero;

    assign a_nan = a_exp_all_ones && !a_frac_zero;
    assign b_nan = b_exp_all_ones && !b_frac_zero;

    assign a_signaling_nan = a_nan && !a_i[22];
    assign b_signaling_nan = b_nan && !b_i[22];

    always @* begin
        handled_o = 1'b1;
        result_o  = 32'h0000_0000;
        invalid_o = 1'b0;

        if (a_signaling_nan) begin
            result_o  = quiet_nan(a_i[31], a_i[21:0]);
            invalid_o = 1'b1;
        end
        else if (b_signaling_nan) begin
            result_o  = quiet_nan(b_i[31], b_i[21:0]);
            invalid_o = 1'b1;
        end
        else if (a_nan) begin
            result_o = quiet_nan(a_i[31], a_i[21:0]);
        end
        else if (b_nan) begin
            result_o = quiet_nan(b_i[31], b_i[21:0]);
        end
        else if (
            a_infinity &&
            b_infinity &&
            (a_i[31] != b_i[31])
        ) begin
            // +infinity + -infinity is invalid.
            result_o  = 32'h7fc0_0000;
            invalid_o = 1'b1;
        end
        else if (a_infinity) begin
            result_o = a_i;
        end
        else if (b_infinity) begin
            result_o = b_i;
        end
        else if (a_zero && b_zero) begin
            // Under round-to-nearest-even:
            // -0 + -0 = -0
            // all other zero combinations produce +0.
            result_o = {
                a_i[31] && b_i[31],
                31'd0
            };
        end
        else if (a_zero) begin
            result_o = b_i;
        end
        else if (b_zero) begin
            result_o = a_i;
        end
        else begin
            handled_o = 1'b0;
            result_o  = 32'h0000_0000;
            invalid_o = 1'b0;
        end
    end

endmodule

`default_nettype wire
