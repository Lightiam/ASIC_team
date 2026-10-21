// -----------------------------------------------------------------------------
// Testbench: on-chip autoregressive token selection.
//
// Checks greedy decode against a software argmax over the same vector, across
// random vocabularies, and prints the real tokens/sec implied by the design
// for several vocabulary sizes -- which is the number the "single-cycle token
// loop" claim has to be measured against.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_neural_gen_loop;

    localparam int unsigned WINDOW  = 8;
    localparam int unsigned LOGIT_W = 16;
    localparam int unsigned TOKEN_W = 16;
    localparam int unsigned VOCAB   = 256;            // 32 windows
    localparam int unsigned WINDOWS = VOCAB / WINDOW;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic                       start_i;
    logic                       valid_i;
    logic [WINDOW*LOGIT_W-1:0]  logits_i;
    logic [TOKEN_W-1:0]         base_token_i;
    logic                       last_i;
    logic                       noise_enable_i;
    logic [LOGIT_W-1:0]         temperature_i;
    logic [31:0]                seed_i;
    logic                       seed_load_i;
    logic                       done_o;
    logic [TOKEN_W-1:0]         token_o;
    logic signed [LOGIT_W-1:0]  logit_o;
    logic                       busy_o;

    nce_neural_gen_loop #(
        .WINDOW (WINDOW), .LOGIT_W (LOGIT_W), .TOKEN_W (TOKEN_W)
    ) dut (
        .clk_i (clk), .rst_ni (rst_n),
        .start_i (start_i),
        .valid_i (valid_i), .logits_i (logits_i),
        .base_token_i (base_token_i), .last_i (last_i),
        .noise_enable_i (noise_enable_i), .temperature_i (temperature_i),
        .seed_i (seed_i), .seed_load_i (seed_load_i),
        .done_o (done_o), .token_o (token_o), .logit_o (logit_o), .busy_o (busy_o)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    // Software reference vocabulary.
    logic signed [LOGIT_W-1:0] vocab [VOCAB];

    task automatic run_vocab (output int unsigned exp_tok,
                              output int signed   exp_val);
        int unsigned best_i;
        int signed   best_v;
        begin
            best_i = 0;
            best_v = vocab[0];
            for (int unsigned i = 1; i < VOCAB; i++)
                if (vocab[i] > best_v) begin best_v = vocab[i]; best_i = i; end
            exp_tok = best_i;
            exp_val = best_v;

            @(negedge clk);
            start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start_i = 1'b0;

            for (int unsigned w = 0; w < WINDOWS; w++) begin
                for (int unsigned k = 0; k < WINDOW; k++)
                    logits_i[LOGIT_W*k +: LOGIT_W] = vocab[w*WINDOW + k];
                base_token_i = TOKEN_W'(w * WINDOW);
                last_i       = (w == WINDOWS - 1);
                valid_i      = 1'b1;
                @(posedge clk);
                @(negedge clk);
                valid_i      = 1'b0;
            end
            last_i = 1'b0;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        int unsigned exp_tok;
        int signed   exp_val;
        int unsigned hits [8];

        start_i = 0; valid_i = 0; logits_i = '0; base_token_i = '0; last_i = 0;
        noise_enable_i = 0; temperature_i = '0; seed_i = 32'd1; seed_load_i = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- greedy decode vs software argmax, many random vocabularies ----
        for (int unsigned t = 0; t < 200; t++) begin
            for (int unsigned i = 0; i < VOCAB; i++)
                vocab[i] = LOGIT_W'($urandom_range(0, 65535) - 32768);
            run_vocab(exp_tok, exp_val);

            checks++;
            if (token_o !== TOKEN_W'(exp_tok)) begin
                errors++;
                $display("FAIL [greedy %0d]: token=%0d expected=%0d", t, token_o, exp_tok);
            end
            if (logit_o !== LOGIT_W'(exp_val)) begin
                errors++;
                $display("FAIL [greedy %0d]: logit=%0d expected=%0d", t, logit_o, exp_val);
            end
        end
        $display("  greedy decode matched software argmax on 200 random vocabularies");

        // ---- winner at the very first and very last position ---------------
        for (int unsigned i = 0; i < VOCAB; i++) vocab[i] = -1000;
        vocab[0] = 32000;
        run_vocab(exp_tok, exp_val);
        checks++;
        if (token_o !== 0) begin
            errors++; $display("FAIL [first]: token=%0d expected 0", token_o);
        end

        for (int unsigned i = 0; i < VOCAB; i++) vocab[i] = -1000;
        vocab[VOCAB-1] = 32000;
        run_vocab(exp_tok, exp_val);
        checks++;
        if (token_o !== TOKEN_W'(VOCAB-1)) begin
            errors++;
            $display("FAIL [last]: token=%0d expected %0d", token_o, VOCAB-1);
        end
        $display("  winner found correctly at both ends of the vocabulary");

        // ---- ties resolve to the lowest index, deterministically -----------
        for (int unsigned i = 0; i < VOCAB; i++) vocab[i] = 500;
        run_vocab(exp_tok, exp_val);
        checks++;
        if (token_o !== 0) begin
            errors++;
            $display("FAIL [tie]: token=%0d expected 0 (lowest index)", token_o);
        end
        else $display("  all-equal logits resolve to token 0 (deterministic tie-break)");

        // ---- stochastic sampling actually varies ---------------------------
        for (int unsigned i = 0; i < 8; i++) hits[i] = 0;
        for (int unsigned i = 0; i < VOCAB; i++) vocab[i] = -30000;
        for (int unsigned i = 0; i < 8; i++)     vocab[i] = 1000;   // 8 plausible

        noise_enable_i = 1'b1;
        temperature_i  = 16'd7;
        seed_i = 32'hDEAD_BEEF; seed_load_i = 1'b1;
        @(negedge clk); @(posedge clk); @(negedge clk); seed_load_i = 1'b0;

        for (int unsigned t = 0; t < 120; t++) begin
            run_vocab(exp_tok, exp_val);
            if (token_o < 8) hits[token_o]++;
        end
        begin
            int unsigned distinct;
            distinct = 0;
            for (int unsigned i = 0; i < 8; i++) if (hits[i] > 0) distinct++;
            checks++;
            if (distinct < 2) begin
                errors++;
                $display("FAIL [sampling]: only %0d distinct tokens in 120 draws", distinct);
            end
            else $display("  stochastic sampling produced %0d distinct winners / 120 draws",
                          distinct);
        end
        noise_enable_i = 1'b0;
        temperature_i  = '0;

        // ---- the throughput the design actually delivers --------------------
        $display("");
        $display("  --- tokens/sec implied by this design ---");
        $display("  WINDOW=%0d logits per clock, so cycles/token = ceil(VOCAB/WINDOW)",
                 WINDOW);
        $display("  %-10s %-12s %-14s %-14s", "vocab", "cycles/tok", "@30.3 MHz", "@250 MHz");
        begin
            int unsigned vsize [4];
            vsize = '{256, 4096, 32768, 128256};
            for (int unsigned i = 0; i < 4; i++) begin
                int unsigned cyc;
                cyc = (vsize[i] + WINDOW - 1) / WINDOW;
                $display("  %-10d %-12d %-14.1f %-14.1f",
                         vsize[i], cyc,
                         30.3e6 / real'(cyc), 250.0e6 / real'(cyc));
            end
        end

        $display("");
        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: neural gen loop passed all %0d checks.", checks);
        else
            $display("FAIL: neural gen loop had %0d errors in %0d checks.", errors, checks);
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1, "gen loop mismatch");
        $finish;
    end

endmodule

`default_nettype wire
