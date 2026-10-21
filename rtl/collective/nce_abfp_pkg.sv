// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- Adaptive Block Floating Point (ABFP)
//
// Front-end for the Layer 12 in-network reduction ALU.
//
// Why this exists. Layer 12 reduces in flight across a ring, and Layer 13
// requires bit-exact results regardless of ring position. IEEE-754 addition is
// not associative, so reducing FP32 directly would make the answer depend on
// arrival order. ABFP removes the dependency: every value in a block is
// rescaled to one shared exponent, after which the mantissas are plain
// integers and integer addition is associative and commutative. The ring can
// then combine them in any order and get the same answer every time.
//
// Format produced:
//
//   block_exp          one 8-bit biased exponent shared by the whole block
//   mantissa[k]        ABFP_MANT_WIDTH-bit signed integer, scaled by 2^-GUARD
//
//   value_k  ~=  mantissa[k] * 2^(block_exp - 127 - 23 - GUARD)
//
// Width choice. The IEEE significand is 24 bits (hidden bit + 23 fraction), so
// a signed significand needs 25. Three guard bits below it give 28, and eight
// 28-bit values sum to at most 31 bits -- which fits the INT32 collective ALU
// without overflow. That is why ABFP_MANT_WIDTH is 28 and BLOCK is 8.
//
// Rounding. Alignment truncates toward zero rather than rounding to nearest.
// Truncation is deterministic and order-independent, which is the property
// Layer 13 needs; round-to-nearest-even would also be deterministic but costs
// a sticky/guard network per lane for an error already bounded by 2^-GUARD of
// the block maximum. The three guard bits bound that error.
//
// Not handled, deliberately, and flagged rather than silently mangled:
//   - subnormals are flushed to zero (flag per lane)
//   - Inf and NaN set a lane flag; the lane contributes zero
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

package nce_abfp_pkg;

    parameter int unsigned ABFP_BLOCK       = 8;
    parameter int unsigned ABFP_GUARD       = 3;
    parameter int unsigned ABFP_SIG_WIDTH   = 24;   // hidden bit + 23 fraction
    parameter int unsigned ABFP_MANT_WIDTH  = 28;   // sign + 24 + 3 guard

    // FP32 field positions.
    parameter int unsigned FP32_FRAC_BITS = 23;
    parameter int unsigned FP32_EXP_BITS  = 8;
    parameter int unsigned FP32_BIAS      = 127;

    // Per-lane condition flags.
    parameter int unsigned ABFP_FLAG_SUBNORMAL = 0;
    parameter int unsigned ABFP_FLAG_INF_NAN   = 1;

    function automatic logic                      fp32_sign (input logic [31:0] f);
        begin fp32_sign = f[31]; end
    endfunction

    function automatic logic [FP32_EXP_BITS-1:0]  fp32_exp  (input logic [31:0] f);
        begin fp32_exp = f[30:23]; end
    endfunction

    function automatic logic [FP32_FRAC_BITS-1:0] fp32_frac (input logic [31:0] f);
        begin fp32_frac = f[22:0]; end
    endfunction

    function automatic logic fp32_is_zero (input logic [31:0] f);
        begin fp32_is_zero = (f[30:23] == 8'h00) && (f[22:0] == 23'd0); end
    endfunction

    function automatic logic fp32_is_subnormal (input logic [31:0] f);
        begin fp32_is_subnormal = (f[30:23] == 8'h00) && (f[22:0] != 23'd0); end
    endfunction

    function automatic logic fp32_is_inf_nan (input logic [31:0] f);
        begin fp32_is_inf_nan = (f[30:23] == 8'hFF); end
    endfunction


    // -------------------------------------------------------------------------
    // Align one value to a block exponent.
    //
    // delta = block_exp - exp. A delta at or beyond the mantissa width shifts
    // every significant bit out, so the lane contributes exactly zero; the
    // shift is clamped rather than left to implementation-defined behaviour.
    // -------------------------------------------------------------------------
    function automatic logic signed [ABFP_MANT_WIDTH-1:0] abfp_align (
        input logic [31:0]                f,
        input logic [FP32_EXP_BITS-1:0]   block_exp
    );
        logic [ABFP_MANT_WIDTH-1:0] mag_u;
        int unsigned                delta;
        begin
            if (fp32_is_zero(f) || fp32_is_subnormal(f) || fp32_is_inf_nan(f)) begin
                abfp_align = '0;
            end
            else begin
                delta = (block_exp >= fp32_exp(f))
                        ? int'(block_exp) - int'(fp32_exp(f))
                        : 0;                       // block_exp is the maximum

                // Everything below is UNSIGNED arithmetic on a magnitude, and
                // the sign is applied last as an explicit two's complement.
                //
                // This deliberately avoids `signed` semantics inside the
                // function. Simulators do not agree on them here: Icarus
                // performs a logical shift on a variable declared `logic
                // signed` inside a function, which silently turns every
                // negative lane positive. Unsigned shifts plus ~x+1 behave
                // identically in every tool and synthesise the same.
                if (delta >= ABFP_MANT_WIDTH) begin
                    abfp_align = '0;
                end
                else begin
                    mag_u      = ({1'b1, f[22:0]} << ABFP_GUARD) >> delta;
                    abfp_align = f[31] ? (~mag_u + 1'b1) : mag_u;
                end
            end
        end
    endfunction

endpackage

`default_nettype wire
