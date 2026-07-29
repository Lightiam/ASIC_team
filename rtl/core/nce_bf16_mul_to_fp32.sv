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
// IEEE BF16 × BF16 multiplier with FP32 output.
//
// BF16:
//   sign     : bit 15
//   exponent : bits 14:7
//   fraction : bits 6:0
//
// The finite BF16 significands contain at most eight bits. Their product
// therefore contains at most sixteen significant bits and fits exactly within
// the 24-bit FP32 significand except when the result enters the FP32 subnormal
// range.
//
// Rounding mode:
//   Round to nearest, ties to even.
//
// Exception outputs:
//   invalid   : signalling NaN or infinity multiplied by zero
//   overflow  : finite result exceeds FP32 range
//   underflow : tiny and inexact FP32 result
//   inexact   : result required rounding or overflowed
// -----------------------------------------------------------------------------

module nce_bf16_mul_to_fp32 (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,

    output logic [31:0] product_o,

    output logic invalid_o,
    output logic overflow_o,
    output logic underflow_o,
    output logic inexact_o
);

    logic sign_a;
    logic sign_b;
    logic sign_product;

    logic [7:0] exponent_a;
    logic [7:0] exponent_b;

    logic [6:0] fraction_a;
    logic [6:0] fraction_b;

    logic a_is_zero;
    logic b_is_zero;

    logic a_is_infinity;
    logic b_is_infinity;

    logic a_is_nan;
    logic b_is_nan;

    logic a_is_signalling_nan;
    logic b_is_signalling_nan;

    logic [7:0]  significand_a;
    logic [7:0]  significand_b;
    logic [15:0] significand_product;

    logic [63:0] wide_value;
    logic [63:0] quotient;
    logic [63:0] remainder;
    logic [63:0] half_value;

    logic round_up;

    integer exponent2_a;
    integer exponent2_b;
    integer product_exponent2;

    integer msb_position;
    integer unbiased_exponent;

    integer shift_amount;
    integer right_shift;
    integer bit_index;

    assign sign_a       = a_i[15];
    assign exponent_a   = a_i[14:7];
    assign fraction_a   = a_i[6:0];

    assign sign_b       = b_i[15];
    assign exponent_b   = b_i[14:7];
    assign fraction_b   = b_i[6:0];

    assign sign_product = sign_a ^ sign_b;

    assign a_is_zero =
        (exponent_a == 8'h00) &&
        (fraction_a == 7'h00);

    assign b_is_zero =
        (exponent_b == 8'h00) &&
        (fraction_b == 7'h00);

    assign a_is_infinity =
        (exponent_a == 8'hFF) &&
        (fraction_a == 7'h00);

    assign b_is_infinity =
        (exponent_b == 8'hFF) &&
        (fraction_b == 7'h00);

    assign a_is_nan =
        (exponent_a == 8'hFF) &&
        (fraction_a != 7'h00);

    assign b_is_nan =
        (exponent_b == 8'hFF) &&
        (fraction_b != 7'h00);

    // BF16 fraction bit 6 is the quiet-NaN bit.
    assign a_is_signalling_nan =
        a_is_nan &&
        !fraction_a[6];

    assign b_is_signalling_nan =
        b_is_nan &&
        !fraction_b[6];

    always @* begin
        product_o   = 32'h0000_0000;

        invalid_o   = 1'b0;
        overflow_o  = 1'b0;
        underflow_o = 1'b0;
        inexact_o   = 1'b0;

        significand_a       = 8'd0;
        significand_b       = 8'd0;
        significand_product = 16'd0;

        exponent2_a       = 0;
        exponent2_b       = 0;
        product_exponent2 = 0;

        msb_position      = 0;
        unbiased_exponent = 0;

        shift_amount = 0;
        right_shift  = 0;

        wide_value = 64'd0;
        quotient    = 64'd0;
        remainder   = 64'd0;
        half_value  = 64'd0;

        round_up = 1'b0;

        // ---------------------------------------------------------------------
        // NaN handling
        // ---------------------------------------------------------------------

        if (a_is_nan || b_is_nan) begin
            product_o = 32'h7FC0_0000;

            invalid_o =
                a_is_signalling_nan ||
                b_is_signalling_nan;
        end

        // ---------------------------------------------------------------------
        // Infinity multiplied by zero is invalid.
        // ---------------------------------------------------------------------

        else if (
            (a_is_infinity && b_is_zero) ||
            (b_is_infinity && a_is_zero)
        ) begin
            product_o = 32'h7FC0_0000;
            invalid_o = 1'b1;
        end

        // ---------------------------------------------------------------------
        // Infinity multiplied by a finite nonzero number.
        // ---------------------------------------------------------------------

        else if (a_is_infinity || b_is_infinity) begin
            product_o = {
                sign_product,
                8'hFF,
                23'd0
            };
        end

        // ---------------------------------------------------------------------
        // Signed zero.
        // ---------------------------------------------------------------------

        else if (a_is_zero || b_is_zero) begin
            product_o = {
                sign_product,
                31'd0
            };
        end

        // ---------------------------------------------------------------------
        // Finite, nonzero multiplication.
        //
        // The value is represented internally as:
        //
        //   significand × 2^exponent2
        // ---------------------------------------------------------------------

        else begin
            if (exponent_a == 8'h00) begin
                significand_a = {
                    1'b0,
                    fraction_a
                };

                exponent2_a = -133;
            end
            else begin
                significand_a = {
                    1'b1,
                    fraction_a
                };

                exponent2_a =
                    $signed({24'd0, exponent_a}) -
                    32'sd134;
            end

            if (exponent_b == 8'h00) begin
                significand_b = {
                    1'b0,
                    fraction_b
                };

                exponent2_b = -133;
            end
            else begin
                significand_b = {
                    1'b1,
                    fraction_b
                };

                exponent2_b =
                    $signed({24'd0, exponent_b}) -
                    32'sd134;
            end

            significand_product =
                significand_a *
                significand_b;

            product_exponent2 =
                exponent2_a +
                exponent2_b;

            // Locate the most-significant one in the exact 16-bit product.
            msb_position = 0;

            for (
                bit_index = 0;
                bit_index < 16;
                bit_index = bit_index + 1
            ) begin
                if (significand_product[bit_index]) begin
                    msb_position = bit_index;
                end
            end

            unbiased_exponent =
                product_exponent2 +
                msb_position;

            // -----------------------------------------------------------------
            // FP32 overflow
            // -----------------------------------------------------------------

            if (unbiased_exponent > 127) begin
                product_o = {
                    sign_product,
                    8'hFF,
                    23'd0
                };

                overflow_o = 1'b1;
                inexact_o  = 1'b1;
            end

            // -----------------------------------------------------------------
            // Normal FP32 result
            //
            // BF16 multiplication has at most sixteen significant bits, so the
            // result fits exactly in the 24-bit FP32 significand.
            // -----------------------------------------------------------------

            else if (unbiased_exponent >= -126) begin
                wide_value =
                    {48'd0, significand_product}
                    <<
                    (23 - msb_position);

                product_o[31]    = sign_product;
                // In this branch unbiased_exponent is restricted to
                // -126 through +127. The eight-bit modular addition produces
                // the required biased FP32 exponent from 1 through 254.
                product_o[30:23] =
                    unbiased_exponent[7:0] +
                    8'd127;
                product_o[22:0]  =
                    wide_value[22:0];
            end

            // -----------------------------------------------------------------
            // FP32 subnormal or zero result
            //
            // FP32 subnormal values are represented as:
            //
            //   fraction × 2^-149
            // -----------------------------------------------------------------

            else begin
                wide_value = {
                    48'd0,
                    significand_product
                };

                shift_amount =
                    product_exponent2 + 149;

                if (shift_amount >= 0) begin
                    quotient =
                        wide_value <<
                        shift_amount;

                    remainder = 64'd0;
                    round_up  = 1'b0;
                end
                else begin
                    right_shift = -shift_amount;

                    if (right_shift >= 64) begin
                        quotient  = 64'd0;
                        remainder = wide_value;
                        round_up  = 1'b0;
                    end
                    else begin
                        quotient =
                            wide_value >>
                            right_shift;

                        remainder =
                            wide_value &
                            (
                                (64'h1 << right_shift) -
                                64'h1
                            );

                        half_value =
                            64'h1 <<
                            (right_shift - 1);

                        round_up =
                            (remainder > half_value) ||
                            (
                                (remainder == half_value) &&
                                quotient[0]
                            );
                    end
                end

                inexact_o =
                    (remainder != 64'd0);

                if (round_up) begin
                    quotient =
                        quotient + 64'd1;
                end

                // Rounding may promote a subnormal result to the smallest
                // normal FP32 value.
                if (quotient >= 64'd8388608) begin
                    product_o = {
                        sign_product,
                        8'h01,
                        23'd0
                    };

                    underflow_o = 1'b0;
                end
                else begin
                    product_o = {
                        sign_product,
                        8'h00,
                        quotient[22:0]
                    };

                    underflow_o =
                        inexact_o;
                end
            end
        end
    end

endmodule

`default_nettype wire
