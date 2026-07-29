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
// IEEE-754 binary32 finite-operand alignment stage.
//
// Inputs must already be decoded. This block performs:
//
//   1. Effective-exponent calculation
//   2. Magnitude comparison
//   3. Large/small operand ordering
//   4. Exponent-difference calculation
//   5. Smaller-significand right shift
//   6. Sticky-bit generation
//
// The 24-bit significands are extended to 27 bits:
//
//   [26:3] = significand
//   [2]    = guard position
//   [1]    = round position
//   [0]    = sticky position
//
// For subnormal numbers, the effective exponent is 1 while the hidden
// significand bit remains zero.
// -----------------------------------------------------------------------------

module nce_fp32_align (
    input  logic        a_sign_i,
    input  logic [7:0]  a_exponent_i,
    input  logic [23:0] a_significand_i,

    input  logic        b_sign_i,
    input  logic [7:0]  b_exponent_i,
    input  logic [23:0] b_significand_i,

    output logic        large_is_a_o,
    output logic        large_sign_o,
    output logic        small_sign_o,
    output logic        subtract_o,

    output logic [7:0]  common_exponent_o,
    output logic [7:0]  exponent_difference_o,

    output logic [26:0] large_significand_o,
    output logic [26:0] small_significand_o
);

    logic [7:0]  a_effective_exponent;
    logic [7:0]  b_effective_exponent;

    logic [23:0] large_significand_raw;
    logic [23:0] small_significand_raw;

    // Right shift with sticky-bit accumulation.
    function automatic logic [26:0] shift_right_jam (
        input logic [26:0] value,
        input logic [7:0]  shift_amount
    );

        logic [26:0] shifted_value;
        logic [26:0] discarded_mask;
        logic        discarded_nonzero;
        logic [4:0]  limited_shift;

        begin
            shifted_value     = 27'd0;
            discarded_mask    = 27'd0;
            discarded_nonzero = 1'b0;
            limited_shift     = 5'd0;

            if (shift_amount == 8'd0) begin
                shift_right_jam = value;
            end
            else if (shift_amount >= 8'd27) begin
                shift_right_jam = {
                    26'd0,
                    |value
                };
            end
            else begin
                limited_shift = shift_amount[4:0];

                shifted_value =
                    value >> limited_shift;

                discarded_mask =
                    (27'd1 << limited_shift) - 27'd1;

                discarded_nonzero =
                    |(value & discarded_mask);

                shift_right_jam = shifted_value;

                shift_right_jam[0] =
                    shifted_value[0] |
                    discarded_nonzero;
            end
        end
    endfunction

    // IEEE-754 treats subnormal exponent field 0 as effective exponent 1.
    assign a_effective_exponent =
        (a_exponent_i == 8'd0)
        ? 8'd1
        : a_exponent_i;

    assign b_effective_exponent =
        (b_exponent_i == 8'd0)
        ? 8'd1
        : b_exponent_i;

    always @* begin
        large_is_a_o           = 1'b0;
        large_sign_o           = 1'b0;
        small_sign_o           = 1'b0;
        subtract_o             = 1'b0;
        common_exponent_o      = 8'd0;
        exponent_difference_o  = 8'd0;
        large_significand_raw  = 24'd0;
        small_significand_raw  = 24'd0;
        large_significand_o    = 27'd0;
        small_significand_o    = 27'd0;

        // Compare exponent first, followed by significand.
        // Equal magnitudes choose operand A as the large operand.
        if (
            (a_effective_exponent > b_effective_exponent) ||
            (
                (a_effective_exponent == b_effective_exponent) &&
                (a_significand_i >= b_significand_i)
            )
        ) begin
            large_is_a_o          = 1'b1;
            large_sign_o          = a_sign_i;
            small_sign_o          = b_sign_i;
            common_exponent_o     = a_effective_exponent;
            exponent_difference_o =
                a_effective_exponent -
                b_effective_exponent;

            large_significand_raw = a_significand_i;
            small_significand_raw = b_significand_i;
        end
        else begin
            large_is_a_o          = 1'b0;
            large_sign_o          = b_sign_i;
            small_sign_o          = a_sign_i;
            common_exponent_o     = b_effective_exponent;
            exponent_difference_o =
                b_effective_exponent -
                a_effective_exponent;

            large_significand_raw = b_significand_i;
            small_significand_raw = a_significand_i;
        end

        subtract_o =
            large_sign_o ^
            small_sign_o;

        large_significand_o = {
            large_significand_raw,
            3'b000
        };

        small_significand_o = shift_right_jam(
            {
                small_significand_raw,
                3'b000
            },
            exponent_difference_o
        );
    end

endmodule

`default_nettype wire
