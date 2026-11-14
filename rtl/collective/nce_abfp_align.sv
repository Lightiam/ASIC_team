// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- ABFP block alignment stage
//
// Takes a block of ABFP_BLOCK FP32 values, finds the largest exponent present,
// and rescales every lane to that shared exponent. Downstream of this stage
// the data is integer, so the Layer 12 ring reduction is associative and the
// result does not depend on ring position.
//
// Pipeline: TWO cycles.
//
//   stage 1:  exponent scan (max over 8 lanes)  ->  register
//   stage 2:  per-lane align (>> delta)         ->  register
//
// It was one cycle, with the scan and the shift sharing a single
// combinational path into one register. Hardening measured that path at
// -2.286 ns at max_ss_100C_1v60 and it was the only violating path in the
// cluster once the I/O constraints were made realistic, so the reduction and
// the shift were separated. Stage 1 carries the 256-bit block forward
// because abfp_align() consumes each lane's whole FP32 word.
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
    //
    // This used to be a serial loop, "if (lane_norm[k] && lane_exp[k] > exp_max)
    // exp_max = lane_exp[k]", which synthesises to a chain of BLOCK compare-and-
    // select stages: lane k's value waits behind every stage after it, so lane 0
    // passes through all BLOCK of them. In one hardening run of nce_core_cluster
    // the worst setup slack from each lane's exponent MSB to this register rose
    // by about 3.6 ns per lane, from -2.20 ns at lane 0 to +23.23 ns at lane 7,
    // and lane 0 was the worst path left. Synthesis keeps the order of a
    // priority chain because reordering it could change the result; a tree has
    // to be written as a tree.
    //
    // Only the VALUE is wanted, not which lane supplied it, so there is no
    // tie-break to preserve. A lane that is not normal (zero, subnormal, Inf or
    // NaN) contributes 0, which is what the old loop's initial value did, and
    // every normal exponent is 1..254, so the result is unchanged:
    //     exp_max = max over lanes of (lane_norm ? lane_exp : 0)
    // The tree is heap-indexed: node n has children 2n and 2n+1, and the leaves
    // sit at BP2 .. 2*BP2-1, padded with 0 up to a power of two.
    localparam int unsigned BP2 = 1 << $clog2(BLOCK);

    logic [7:0] exp_max;
    logic [7:0] lane_exp  [BLOCK];
    logic       lane_norm [BLOCK];
    logic [7:0] tmax      [2*BP2];

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

        // Masked leaves, padded with 0 up to a power of two.
        tmax[0] = 8'h00;
        for (int unsigned k = 0; k < BP2; k++)
            tmax[BP2 + k] = (k < BLOCK && lane_norm[(k < BLOCK) ? k : 0])
                          ? lane_exp[(k < BLOCK) ? k : 0] : 8'h00;
        // Signed loop variable: with BP2 == 1 there are no internal nodes and
        // an unsigned "n >= 1" countdown would wrap.
        for (int n = int'(BP2) - 1; n >= 1; n--)
            tmax[n] = (tmax[2*n + 1] > tmax[2*n]) ? tmax[2*n + 1] : tmax[2*n];
        exp_max = tmax[1];
    end

    // ---- per-lane classification ---------------------------------------------
    // These depend only on each lane's own word, not on exp_max, so they
    // belong in stage 1 beside the scan rather than behind it.
    logic [BLOCK-1:0] subnorm_bits;
    logic [BLOCK-1:0] infnan_bits;

    always_comb begin
        for (int unsigned k = 0; k < BLOCK; k++) begin
            subnorm_bits[k] = nce_abfp_pkg::fp32_is_subnormal(block_i[32*k +: 32]);
            infnan_bits[k]  = nce_abfp_pkg::fp32_is_inf_nan(block_i[32*k +: 32]);
        end
    end

    // ---- STAGE 1 / STAGE 2 BOUNDARY ------------------------------------------
    // Originally the exponent scan and the mantissa alignment were one
    // combinational block feeding one register, so the path from block_i ran
    // through an 8-lane maximum reduction AND a variable shift before meeting
    // a flop. Hardening measured that path at -2.286 ns at max_ss_100C_1v60
    // once the I/O constraints were made realistic, and it was the only
    // violating path left.
    //
    // The reduction is now registered and the shift happens in stage 2.
    //
    // COST. Stage 2 still needs each lane's full FP32 word, because
    // abfp_align() works on the word and not on anything stage 1 derives, so
    // the 256-bit block is carried across the boundary. That is 256 flops
    // bought to shorten a path. The alternative -- recomputing sign and
    // mantissa in stage 1 and carrying those instead -- saves nothing, since
    // sign plus 23-bit mantissa plus the exponent is the whole word again.
    //
    // LATENCY. valid_i to valid_o is now TWO cycles, not one. The ALU behind
    // this block is latency-insensitive and keyed off valid, so nothing
    // downstream needed changing, but the testbench did.
    logic                s1_valid;
    logic [8*32-1:0]     s1_block;
    logic [7:0]          s1_exp_max;
    logic [BLOCK-1:0]    s1_subnorm;
    logic [BLOCK-1:0]    s1_infnan;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s1_valid   <= 1'b0;
            s1_block   <= '0;
            s1_exp_max <= 8'h00;
            s1_subnorm <= '0;
            s1_infnan  <= '0;
        end
        else begin
            s1_valid <= valid_i;
            if (valid_i) begin
                s1_block   <= block_i;
                s1_exp_max <= exp_max;
                s1_subnorm <= subnorm_bits;
                s1_infnan  <= infnan_bits;
            end
        end
    end

    // ---- stage 2: per-lane alignment -----------------------------------------
    logic signed [MW-1:0] aligned [BLOCK];

    always_comb begin
        for (int unsigned k = 0; k < BLOCK; k++)
            aligned[k] = nce_abfp_pkg::abfp_align(s1_block[32*k +: 32], s1_exp_max);
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
            valid_o <= s1_valid;
            if (s1_valid) begin
                block_exp_o <= s1_exp_max;
                subnormal_o <= s1_subnorm;
                inf_nan_o   <= s1_infnan;
                for (int unsigned k = 0; k < BLOCK; k++)
                    mantissa_o[MW*k +: MW] <= aligned[k];
            end
        end
    end

endmodule

`default_nettype wire
