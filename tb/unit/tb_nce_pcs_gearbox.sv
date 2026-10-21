// -----------------------------------------------------------------------------
// Testbench: PCS gearbox.
//
// A gearbox has exactly one job and exactly one way to fail: the bit stream
// out must equal the bit stream in, in order, with nothing dropped,
// duplicated or reordered. Everything here is in service of that.
//
// Tested:
//   1. Bit-exact stream equality through a 64->32 narrowing.
//   2. Bit-exact through a 32->64 widening, which is the harder direction
//      because output cannot be produced until enough input has arrived.
//   3. A non-integer ratio (48->32), where the buffer never returns to the
//      same alignment and an off-by-one shows up as corruption rather than
//      as a clean failure.
//   4. Backpressure: a stalled sink must not cause loss, and the source
//      must be told to stop.
//   5. The gearbox never claims output it does not hold.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_pcs_gearbox;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    int unsigned checks = 0;
    int unsigned errors = 0;

    // ---- 64 -> 32 -----------------------------------------------------------
    localparam int unsigned A_IN = 64, A_OUT = 32;
    logic             a_iv, a_ir, a_ov, a_or_;
    logic [A_IN-1:0]  a_id;
    logic [A_OUT-1:0] a_od;
    logic [15:0]      a_lvl;

    nce_pcs_gearbox #(.IN_W(A_IN), .OUT_W(A_OUT)) dut_a (
        .clk_i(clk), .rst_ni(rst_n),
        .in_valid_i(a_iv), .in_data_i(a_id), .in_ready_o(a_ir),
        .out_valid_o(a_ov), .out_data_o(a_od), .out_ready_i(a_or_),
        .level_o(a_lvl));

    // ---- 32 -> 64 -----------------------------------------------------------
    localparam int unsigned B_IN = 32, B_OUT = 64;
    logic             b_iv, b_ir, b_ov, b_or_;
    logic [B_IN-1:0]  b_id;
    logic [B_OUT-1:0] b_od;
    logic [15:0]      b_lvl;

    nce_pcs_gearbox #(.IN_W(B_IN), .OUT_W(B_OUT)) dut_b (
        .clk_i(clk), .rst_ni(rst_n),
        .in_valid_i(b_iv), .in_data_i(b_id), .in_ready_o(b_ir),
        .out_valid_o(b_ov), .out_data_o(b_od), .out_ready_i(b_or_),
        .level_o(b_lvl));

    // ---- 48 -> 32, a non-integer ratio --------------------------------------
    localparam int unsigned C_IN = 48, C_OUT = 32;
    logic             c_iv, c_ir, c_ov, c_or_;
    logic [C_IN-1:0]  c_id;
    logic [C_OUT-1:0] c_od;
    logic [15:0]      c_lvl;

    nce_pcs_gearbox #(.IN_W(C_IN), .OUT_W(C_OUT)) dut_c (
        .clk_i(clk), .rst_ni(rst_n),
        .in_valid_i(c_iv), .in_data_i(c_id), .in_ready_o(c_ir),
        .out_valid_o(c_ov), .out_data_o(c_od), .out_ready_i(c_or_),
        .level_o(c_lvl));

    // Reference bit streams, MSB-first.
    localparam int unsigned NBITS = 64 * 24;
    logic ref_bits [NBITS];
    logic got_bits [NBITS];
    int unsigned n_in, n_out;

    task automatic gen_stream;
        begin
            for (int unsigned i = 0; i < NBITS; i++)
                // A deterministic but non-trivial pattern: a constant or a
                // simple counter can hide a reordering bug.
                ref_bits[i] = ((i * 7 + (i / 5) * 13 + (i % 11)) & 1) == 1;
        end
    endtask

    // ---- generic exerciser --------------------------------------------------
    // Drives one gearbox with the reference stream and collects the output,
    // with a stall pattern on both sides so backpressure is exercised.
    task automatic run_case(input int unsigned iw, input int unsigned ow,
                            input string label, input int unsigned stall_mod);
        int unsigned i, o, guard;
        begin
            n_in = 0; n_out = 0;
            i = 0; o = 0; guard = 0;
            for (int unsigned k = 0; k < NBITS; k++) got_bits[k] = 1'bx;

            while (o < NBITS && guard < NBITS * 40) begin
                guard++;
                @(negedge clk);

                // --- drive input ---
                if (iw == A_IN && ow == A_OUT) begin
                    a_or_ = (stall_mod == 0) || ((guard % stall_mod) != 0);
                    if (i + iw <= NBITS && a_ir) begin
                        for (int unsigned b = 0; b < A_IN; b++)
                            a_id[A_IN-1-b] = ref_bits[i+b];
                        a_iv = 1'b1;
                    end
                    else a_iv = 1'b0;
                end
                else if (iw == B_IN && ow == B_OUT) begin
                    b_or_ = (stall_mod == 0) || ((guard % stall_mod) != 0);
                    if (i + iw <= NBITS && b_ir) begin
                        for (int unsigned b = 0; b < B_IN; b++)
                            b_id[B_IN-1-b] = ref_bits[i+b];
                        b_iv = 1'b1;
                    end
                    else b_iv = 1'b0;
                end
                else begin
                    c_or_ = (stall_mod == 0) || ((guard % stall_mod) != 0);
                    if (i + iw <= NBITS && c_ir) begin
                        for (int unsigned b = 0; b < C_IN; b++)
                            c_id[C_IN-1-b] = ref_bits[i+b];
                        c_iv = 1'b1;
                    end
                    else c_iv = 1'b0;
                end

                @(posedge clk);

                // --- record what moved ---
                if (iw == A_IN && ow == A_OUT) begin
                    if (a_iv && a_ir) i += iw;
                    if (a_ov && a_or_) begin
                        for (int unsigned b = 0; b < A_OUT; b++)
                            if (o + b < NBITS) got_bits[o+b] = a_od[A_OUT-1-b];
                        o += ow;
                    end
                end
                else if (iw == B_IN && ow == B_OUT) begin
                    if (b_iv && b_ir) i += iw;
                    if (b_ov && b_or_) begin
                        for (int unsigned b = 0; b < B_OUT; b++)
                            if (o + b < NBITS) got_bits[o+b] = b_od[B_OUT-1-b];
                        o += ow;
                    end
                end
                else begin
                    if (c_iv && c_ir) i += iw;
                    if (c_ov && c_or_) begin
                        for (int unsigned b = 0; b < C_OUT; b++)
                            if (o + b < NBITS) got_bits[o+b] = c_od[C_OUT-1-b];
                        o += ow;
                    end
                end
            end

            n_in = i; n_out = o;

            checks++;
            if (o < NBITS) begin
                errors++;
                $display("FAIL [%s/drain]: only %0d of %0d bits came out",
                         label, o, NBITS);
            end

            checks++;
            begin
                int unsigned bad = 0;
                int unsigned first_bad = 0;
                for (int unsigned k = 0; k < NBITS; k++) begin
                    if (got_bits[k] !== ref_bits[k]) begin
                        if (bad == 0) first_bad = k;
                        bad++;
                    end
                end
                if (bad != 0) begin
                    errors++;
                    $display("FAIL [%s/stream]: %0d of %0d bits wrong, first at %0d",
                             label, bad, NBITS, first_bad);
                end
                else begin
                    $display("  %-10s %0d bits in, %0d out, bit-exact", label, i, o);
                end
            end
        end
    endtask

    initial begin
        a_iv = 0; a_or_ = 0; a_id = '0;
        b_iv = 0; b_or_ = 0; b_id = '0;
        c_iv = 0; c_or_ = 0; c_id = '0;
        gen_stream();

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // Level must be zero out of reset, and nothing may be offered.
        checks++;
        if (a_lvl !== 16'd0 || a_ov !== 1'b0) begin
            errors++;
            $display("FAIL [reset]: level=%0d out_valid=%b after reset",
                     a_lvl, a_ov);
        end

        run_case(A_IN, A_OUT, "64->32", 0);
        run_case(B_IN, B_OUT, "32->64", 0);
        run_case(C_IN, C_OUT, "48->32", 0);

        // Same again with the sink stalling, which is where a gearbox
        // usually loses or repeats a word.
        rst_n = 1'b0; repeat (3) @(negedge clk); rst_n = 1'b1;
        repeat (2) @(negedge clk);
        run_case(A_IN, A_OUT, "64->32 bp", 3);

        rst_n = 1'b0; repeat (3) @(negedge clk); rst_n = 1'b1;
        repeat (2) @(negedge clk);
        run_case(C_IN, C_OUT, "48->32 bp", 4);

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: PCS gearbox passed all %0d checks.", checks);
        else
            $display("FAIL: PCS gearbox had %0d errors in %0d checks.",
                     errors, checks);
        $display("NOTE A gearbox converts widths. It carries no bandwidth of");
        $display("     its own, and it is not a PCS: KP4 FEC, alignment");
        $display("     markers and deskew are separate and not built.");
        $display("----------------------------------------------------------");
        if (errors != 0) $fatal(1, "gearbox mismatch");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: PCS gearbox testbench timed out.");
        $fatal(1, "timeout");
    end

endmodule

`default_nettype wire
