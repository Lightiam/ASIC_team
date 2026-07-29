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
// BF24 × BF24 multiplier with IEEE-754 FP32 output.
//
// BF24 format:
//
//   sign     : bit 23
//   exponent : bits 22:15
//   fraction : bits 14:0
//   bias     : 127
//
// Each finite BF24 operand contains up to sixteen significand bits. The exact
// product therefore contains up to thirty-two significand bits and is rounded
// to the 24-bit FP32 significand.
//
// Rounding:
//
//   Round to nearest, ties to even.
//
// Exception outputs:
//
//   invalid   : signalling NaN or infinity multiplied by zero
//   overflow  : finite rounded result exceeds the FP32 finite range
//   underflow : tiny and inexact result after rounding
//   inexact   : discarded nonzero bits or overflow
// -----------------------------------------------------------------------------

module nce_bf24_mul_to_fp32 (
    input  logic [23:0] a_i,
    input  logic [23:0] b_i,

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

    logic [14:0] fraction_a;
    logic [14:0] fraction_b;

    logic a_is_zero;
    logic b_is_zero;

    logic a_is_infinity;
    logic b_is_infinity;

    logic a_is_nan;
    logic b_is_nan;

    logic a_is_signalling_nan;
    logic b_is_signalling_nan;

    logic [15:0] significand_a;
    logic [15:0] significand_b;
    logic [31:0] significand_product;

    logic [63:0] wide_value;
    logic [63:0] quotient;
    logic [63:0] remainder;
    logic [63:0] half_value;
    logic [63:0] rounded_value;

    logic round_up;

    integer exponent2_a;
    integer exponent2_b;
    integer product_exponent2;

    integer msb_position;
    integer unbiased_exponent;

    integer shift_amount;
    integer right_shift;
    integer bit_index;

    assign sign_a     = a_i[23];
    assign exponent_a = a_i[22:15];
    assign fraction_a = a_i[14:0];

    assign sign_b     = b_i[23];
    assign exponent_b = b_i[22:15];
    assign fraction_b = b_i[14:0];

    assign sign_product = sign_a ^ sign_b;

    assign a_is_zero =
        (exponent_a == 8'h00) &&
        (fraction_a == 15'h0000);

    assign b_is_zero =
        (exponent_b == 8'h00) &&
        (fraction_b == 15'h0000);

    assign a_is_infinity =
        (exponent_a == 8'hFF) &&
        (fraction_a == 15'h0000);

    assign b_is_infinity =
        (exponent_b == 8'hFF) &&
        (fraction_b == 15'h0000);

    assign a_is_nan =
        (exponent_a == 8'hFF) &&
        (fraction_a != 15'h0000);

    assign b_is_nan =
        (exponent_b == 8'hFF) &&
        (fraction_b != 15'h0000);

    // The most-significant fraction bit is the quiet-NaN bit.
    assign a_is_signalling_nan =
        a_is_nan &&
        !fraction_a[14];

    assign b_is_signalling_nan =
        b_is_nan &&
        !fraction_b[14];

    always @* begin
        product_o   = 32'h0000_0000;

        invalid_o   = 1'b0;
        overflow_o  = 1'b0;
        underflow_o = 1'b0;
        inexact_o   = 1'b0;

        significand_a       = 16'd0;
        significand_b       = 16'd0;
        significand_product = 32'd0;

        wide_value   = 64'd0;
        quotient     = 64'd0;
        remainder    = 64'd0;
        half_value   = 64'd0;
        rounded_value = 64'd0;

        round_up = 1'b0;

        exponent2_a       = 0;
        exponent2_b       = 0;
        product_exponent2 = 0;

        msb_position       = 0;
        unbiased_exponent  = 0;

        shift_amount = 0;
        right_shift  = 0;

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
        // Infinity multiplied by a finite nonzero value.
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
        // Internal exact representation:
        //
        //   value = significand × 2^exponent2
        //
        // Normal BF24:
        //
        //   exponent2 = encoded_exponent - 127 - 15
        //             = encoded_exponent - 142
        //
        // Subnormal BF24:
        //
        //   exponent2 = 1 - 127 - 15
        //             = -141
        // ---------------------------------------------------------------------

        else begin
            if (exponent_a == 8'h00) begin
                significand_a = {
                    1'b0,
                    fraction_a
                };

                exponent2_a = -141;
            end
            else begin
                significand_a = {
                    1'b1,
                    fraction_a
                };

                exponent2_a =
                    $signed({24'd0, exponent_a}) -
                    32'sd142;
            end

            if (exponent_b == 8'h00) begin
                significand_b = {
                    1'b0,
                    fraction_b
                };

                exponent2_b = -141;
            end
            else begin
                significand_b = {
                    1'b1,
                    fraction_b
                };

                exponent2_b =
                    $signed({24'd0, exponent_b}) -
                    32'sd142;
            end

            significand_product =
                significand_a *
                significand_b;

            product_exponent2 =
                exponent2_a +
                exponent2_b;

            // Locate the most-significant one in the exact product.
            msb_position = 0;

            for (
                bit_index = 0;
                bit_index < 32;
                bit_index = bit_index + 1
            ) begin
                if (significand_product[bit_index]) begin
                    msb_position = bit_index;
                end
            end

            unbiased_exponent =
                product_exponent2 +
                msb_position;

            wide_value = {
                32'd0,
                significand_product
            };

            // -----------------------------------------------------------------
            // Immediate FP32 overflow.
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
            // Normal FP32 result.
            // -----------------------------------------------------------------

            else if (unbiased_exponent >= -126) begin
                if (msb_position > 23) begin
                    right_shift =
                        msb_position -
                        23;

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
                else begin
                    quotient =
                        wide_value <<
                        (23 - msb_position);

                    remainder  = 64'd0;
                    half_value = 64'd0;
                    round_up   = 1'b0;
                end

                rounded_value =
                    quotient +
                    {
                        63'd0,
                        round_up
                    };

                inexact_o =
                    (remainder != 64'd0);

                // Rounding 1.111... upward can produce 10.000...
                if (rounded_value[24]) begin
                    rounded_value =
                        rounded_value >>
                        1;

                    unbiased_exponent =
                        unbiased_exponent +
                        1;
                end

                // Rounding may push the maximum finite exponent to infinity.
                if (unbiased_exponent > 127) begin
                    product_o = {
                        sign_product,
                        8'hFF,
                        23'd0
                    };

                    overflow_o = 1'b1;
                    inexact_o  = 1'b1;
                end
                else begin
                    product_o[31] =
                        sign_product;

                    product_o[30:23] =
                        unbiased_exponent[7:0] +
                        8'd127;

                    product_o[22:0] =
                        rounded_value[22:0];
                end
            end

            // -----------------------------------------------------------------
            // FP32 subnormal or zero result.
            //
            // A binary32 subnormal represents:
            //
            //   fraction × 2^-149
            //
            // Therefore:
            //
            //   fraction =
            //       significand_product × 2^(product_exponent2 + 149)
            // -----------------------------------------------------------------

            else begin
                shift_amount =
                    product_exponent2 +
                    149;

                if (shift_amount >= 0) begin
                    quotient =
                        wide_value <<
                        shift_amount;

                    remainder  = 64'd0;
                    half_value = 64'd0;
                    round_up   = 1'b0;
                end
                else begin
                    right_shift =
                        -shift_amount;

                    if (right_shift >= 64) begin
                        quotient  = 64'd0;
                        remainder = wide_value;
                        half_value = 64'd0;
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

                rounded_value =
                    quotient +
                    {
                        63'd0,
                        round_up
                    };

                inexact_o =
                    (remainder != 64'd0);

                // A rounded subnormal may become the minimum normal FP32 value.
                if (rounded_value[23]) begin
                    product_o = {
                        sign_product,
                        8'h01,
                        23'd0
                    };

                    // Tininess is detected after rounding.
                    underflow_o = 1'b0;
                end
                else begin
                    product_o = {
                        sign_product,
                        8'h00,
                        rounded_value[22:0]
                    };

                    underflow_o =
                        inexact_o;
                end
            end
        end
    end

endmodule

`default_nettype wire
