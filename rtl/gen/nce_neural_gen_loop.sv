// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- on-chip autoregressive token selection
//
// Hardware argmax / top-1 sampler over a logit vector. Given a stream of
// logits it returns the winning token id, so the sampling step of
// autoregressive decode happens on-die instead of round-tripping to a host.
//
// -----------------------------------------------------------------------------
// WHAT "ONE CYCLE" ACTUALLY MEANS
// -----------------------------------------------------------------------------
// This block compares WINDOW logits per clock. That window comparison is
// genuinely single-cycle: an explicit comparator tree of depth ceil(log2(WINDOW)).
//
// It does NOT select over an entire vocabulary in one cycle, and no design
// can. A 32768-entry vocabulary needs 32768 comparators and a depth-15 tree
// to do that, which is neither routable nor timeable in any sensible process.
// Real vocabularies are streamed:
//
//     cycles_per_token = ceil(VOCAB / WINDOW)
//     tokens_per_second = f_clk / cycles_per_token
//
// So a "single-cycle token loop" is a single cycle per WINDOW, not per token.
// The distinction is the difference between a claimed 4 ns per token and the
// real figure, which the testbench prints for several configurations.
//
// -----------------------------------------------------------------------------
// SAMPLING MODE
// -----------------------------------------------------------------------------
// Greedy (temperature 0) is exact: argmax over the logits.
//
// Stochastic sampling uses the Gumbel-max trick -- argmax(logit + g) with
// g ~ Gumbel(0,1) draws exactly from softmax(logit). True Gumbel needs
// -log(-log(u)), which is a transcendental and not synthesisable directly;
// a production design uses a small ROM of precomputed Gumbel quantiles
// addressed by the PRNG. What this block implements is additive uniform
// noise from an LFSR, scaled by temperature. That is a cheap approximation,
// NOT a correct softmax sample, and it is flagged here rather than left for
// someone to discover from skewed output distributions.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_neural_gen_loop #(
    // Logits compared per clock. Sets the comparator tree depth.
    parameter int unsigned WINDOW    = 8,
    // Signed logit width.
    parameter int unsigned LOGIT_W   = 16,
    // Token id width; must cover the vocabulary.
    parameter int unsigned TOKEN_W   = 16
) (
    input  wire                        clk_i,
    input  wire                        rst_ni,

    // Begin a new token: clears the running maximum.
    input  wire                        start_i,

    // One window of logits, with the token id of its first element.
    input  wire                        valid_i,
    input  wire [WINDOW*LOGIT_W-1:0]   logits_i,
    input  wire [TOKEN_W-1:0]          base_token_i,
    // Asserted with the final window of the vocabulary.
    input  wire                        last_i,

    // Stochastic sampling controls.
    input  wire                        noise_enable_i,
    input  wire [LOGIT_W-1:0]          temperature_i,   // noise amplitude
    input  wire [31:0]                 seed_i,
    input  wire                        seed_load_i,

    // Result, valid the cycle after the window marked last_i.
    output logic                       done_o,
    output logic [TOKEN_W-1:0]         token_o,
    output logic signed [LOGIT_W-1:0]  logit_o,
    // High while a token selection is in progress.
    output logic                       busy_o
);

    localparam int unsigned IDX_W = (WINDOW > 1) ? $clog2(WINDOW) : 1;

    // ---- PRNG ---------------------------------------------------------------
    // 32-bit maximal-length Galois LFSR, taps 32,22,2,1.
    logic [31:0] lfsr_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)            lfsr_q <= 32'hACE1_2345;
        else if (seed_load_i)   lfsr_q <= (seed_i == 32'd0) ? 32'hACE1_2345 : seed_i;
        else if (valid_i)       lfsr_q <= {lfsr_q[30:0], 1'b0}
                                        ^ (32'h8020_0003 & {32{lfsr_q[31]}});
    end

    // ---- per-lane noise and effective logit ---------------------------------
    logic signed [LOGIT_W-1:0] eff [WINDOW];

    // Rotated copy of the PRNG word. Kept as its own signal because a
    // concatenation cannot be part-selected directly in every tool.
    logic [31:0] lfsr_rot;
    assign lfsr_rot = {lfsr_q[7:0], lfsr_q[31:8]};

    always_comb begin
        for (int unsigned k = 0; k < WINDOW; k++) begin
            logic signed [LOGIT_W-1:0] raw;
            logic signed [LOGIT_W-1:0] noise;
            logic        [LOGIT_W-1:0] rnd;

            raw = logits_i[LOGIT_W*k +: LOGIT_W];

            // Decorrelate lanes by rotating the LFSR word per lane.
            rnd = lfsr_q[LOGIT_W-1:0]
                ^ lfsr_rot[LOGIT_W-1:0]
                ^ LOGIT_W'(k * 32'h9E37);

            // Centre the noise, then scale by temperature (shift, not multiply).
            noise = $signed(rnd) >>> 2;
            noise = (temperature_i == '0) ? '0
                                          : (noise >>> (8 - temperature_i[2:0]));

            eff[k] = noise_enable_i ? (raw + noise) : raw;
        end
    end

    // ---- single-cycle argmax over the window --------------------------------
    // Explicit balanced comparator tree of depth ceil(log2(WINDOW)).
    //
    // This used to be a serial "if (eff[k] > win_val)" loop with a comment
    // claiming synthesis would turn it into a tree. It does not: the loop is a
    // chain of WINDOW-1 compare-and-mux stages, each waiting on the previous
    // one, and the resulting cone from logits_i was the worst setup path in the
    // nce_core_cluster flow (every violated path launched from gen_logits_i).
    // Synthesis preserves the order of a priority chain because reordering it
    // could change the result; a tree has to be written as a tree.
    //
    // Tie-break is unchanged: the lowest index wins. A right child takes over
    // only when STRICTLY greater than the left, so equal values keep the left
    // (lower-index) side at every level, which is the same rule the serial
    // chain implemented. tb_nce_neural_gen_loop checks the all-equal case.
    //
    // Heap-indexed: node n has children 2n (left) and 2n+1 (right); leaves sit
    // at WP2 .. 2*WP2-1. WINDOW is padded up to a power of two with VAL_MIN
    // leaves. A padded leaf is to the right of every real leaf and never
    // strictly beats one, so it cannot win even when every real logit equals
    // VAL_MIN (the left side takes the tie).
    localparam int unsigned WP2 = 1 << $clog2(WINDOW);

    // Most negative representable value, so the first window always wins.
    localparam logic signed [LOGIT_W-1:0] VAL_MIN = {1'b1, {(LOGIT_W-1){1'b0}}};

    logic signed [LOGIT_W-1:0] win_val;
    logic        [IDX_W-1:0]   win_idx;

    logic signed [LOGIT_W-1:0] tv [2*WP2];
    logic        [IDX_W-1:0]   ti [2*WP2];

    always_comb begin
        tv[0] = '0;
        ti[0] = '0;
        for (int unsigned k = 0; k < WP2; k++) begin
            tv[WP2 + k] = (k < WINDOW) ? eff[(k < WINDOW) ? k : 0] : VAL_MIN;
            ti[WP2 + k] = IDX_W'(k);
        end
        // Signed loop variable: with WP2 == 1 there are no internal nodes and
        // an unsigned "n >= 1" countdown would wrap.
        for (int n = int'(WP2) - 1; n >= 1; n--) begin
            if (tv[2*n + 1] > tv[2*n]) begin
                tv[n] = tv[2*n + 1];
                ti[n] = ti[2*n + 1];
            end
            else begin
                tv[n] = tv[2*n];
                ti[n] = ti[2*n];
            end
        end
        win_val = tv[1];
        win_idx = ti[1];
    end

    // ---- running maximum across windows -------------------------------------
    logic signed [LOGIT_W-1:0] best_val_q;
    logic        [TOKEN_W-1:0] best_tok_q;
    logic                      armed_q;

    // VAL_MIN is declared above, with the comparator tree that also uses it.

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            best_val_q <= VAL_MIN;
            best_tok_q <= '0;
            armed_q    <= 1'b0;
            done_o     <= 1'b0;
            token_o    <= '0;
            logit_o    <= '0;
        end
        else begin
            done_o <= 1'b0;

            if (start_i) begin
                best_val_q <= VAL_MIN;
                best_tok_q <= '0;
                armed_q    <= 1'b1;
            end
            else if (valid_i && armed_q) begin
                if (win_val > best_val_q) begin
                    best_val_q <= win_val;
                    best_tok_q <= base_token_i + TOKEN_W'(win_idx);
                end

                if (last_i) begin
                    armed_q <= 1'b0;
                    done_o  <= 1'b1;
                    // Publish the better of the running best and this window.
                    if (win_val > best_val_q) begin
                        token_o <= base_token_i + TOKEN_W'(win_idx);
                        logit_o <= win_val;
                    end
                    else begin
                        token_o <= best_tok_q;
                        logit_o <= best_val_q;
                    end
                end
            end
        end
    end

    assign busy_o = armed_q;

endmodule

`default_nettype wire
