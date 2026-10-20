// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- ABFP block alignment stage
//
// Takes a block of ABFP_BLOCK FP32 values, finds the largest exponent present,
// and rescales every lane to that shared exponent. Downstream of this stage
// the data is integer, so the Layer 12 ring reduction is associative and the
// result does not depend on ring position.
//
// Pipeline: one cycle. The exponent scan and the per-lane barrel shift are
// both combinational; the register sits on the outputs.
//
//   exponent scan (max)  ->  per-lane align (>> delta)  ->  register
//
// Lanes that are zero, subnormal, Inf or NaN contribute a zero mantissa and
// raise their flag, so the reduction stays well defined and the condition is
// still visible to software.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_abfp_align (
    input  wire                                       clk_i,
    input  wire                                       rst_ni,

    input  wire                                       valid_i,
    // ABFP_BLOCK FP32 values, lane k at [32*k +: 32].
    input  wire  [8*32-1:0]                           block_i,

    output logic                                      valid_o,
    // Shared block exponent, biased, as in IEEE-754.
    output logic [7:0]                                block_exp_o,
    // Aligned signed mantissas, lane k at [28*k +: 28].
    output logic [8*28-1:0]                           mantissa_o,
    // Per-lane: subnormal flushed to zero.
    output logic [7:0]                                subnormal_o,
    // Per-lane: Inf or NaN seen.
    output logic [7:0]                                inf_nan_o
);

    localparam int unsigned BLOCK = nce_abfp_pkg::ABFP_BLOCK;
    localparam int unsigned MW    = nce_abfp_pkg::ABFP_MANT_WIDTH;

    // ---- exponent scan -------------------------------------------------------
    // The block exponent is the largest exponent among lanes that carry a
    // normal, finite value. Inf/NaN are excluded so one bad lane cannot drag
    // the whole block's scale to 255 and flush every other lane to zero.
    logic [7:0] exp_max;
    logic [7:0] lane_exp  [BLOCK];
    logic       lane_norm [BLOCK];

    // Note: no variable is declared inside these loop bodies. A `logic`
    // declared in a for-loop body inside an always_comb is not handled
    // reliably by every simulator (Icarus warns about the sensitivity and can
    // evaluate the function with a stale copy), so each lane's word is indexed
    // directly out of block_i at every use.
    always_comb begin
        for (int unsigned k = 0; k < BLOCK; k++) begin
            lane_exp[k]  = nce_abfp_pkg::fp32_exp(block_i[32*k +: 32]);
            lane_norm[k] = !nce_abfp_pkg::fp32_is_zero(block_i[32*k +: 32])
                        && !nce_abfp_pkg::fp32_is_subnormal(block_i[32*k +: 32])
                        && !nce_abfp_pkg::fp32_is_inf_nan(block_i[32*k +: 32]);
        end

        exp_max = 8'h00;
        for (int unsigned k = 0; k < BLOCK; k++)
            if (lane_norm[k] && (lane_exp[k] > exp_max)) exp_max = lane_exp[k];
    end

    // ---- per-lane alignment --------------------------------------------------
    logic signed [MW-1:0] aligned [BLOCK];
    logic [BLOCK-1:0]     subnorm_bits;
    logic [BLOCK-1:0]     infnan_bits;

    always_comb begin
        for (int unsigned k = 0; k < BLOCK; k++) begin
            subnorm_bits[k] = nce_abfp_pkg::fp32_is_subnormal(block_i[32*k +: 32]);
            infnan_bits[k]  = nce_abfp_pkg::fp32_is_inf_nan(block_i[32*k +: 32]);
            aligned[k]      = nce_abfp_pkg::abfp_align(block_i[32*k +: 32], exp_max);
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_o     <= 1'b0;
            block_exp_o <= 8'h00;
            mantissa_o  <= '0;
            subnormal_o <= '0;
            inf_nan_o   <= '0;
        end
        else begin
            valid_o <= valid_i;
            if (valid_i) begin
                block_exp_o <= exp_max;
                subnormal_o <= subnorm_bits;
                inf_nan_o   <= infnan_bits;
                for (int unsigned k = 0; k < BLOCK; k++)
                    mantissa_o[MW*k +: MW] <= aligned[k];
            end
        end
    end

endmodule

`default_nettype wire
