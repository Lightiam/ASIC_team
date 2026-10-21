// -----------------------------------------------------------------------------
// Testbench: 200G PAM4 SerDes behavioural stub.
//
// The claims tested are the ones the module header makes, and one it makes
// implicitly by existing:
//
//   1. Gray mapping round-trips: every 2-bit input returns as itself.
//   2. The Gray PROPERTY holds -- adjacent PAM4 levels differ in exactly one
//      bit. This is the whole reason to Gray code a PAM4 link, since the
//      likely symbol error is off-by-one-level, and it should cost one bit
//      rather than two.
//   3. A constant line NEVER locks the CDR. A real CDR needs transitions,
//      and a stub that locks on silence hides a dead link.
//   4. The CDR locks once there are transitions.
//   5. rx_valid is suppressed until lock. Presenting data the receiver
//      cannot trust is the most misleading thing a stub can do.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_serdes_200g_stub;

    localparam int unsigned LOCKC = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic       tx_valid, tx_ready;
    logic [1:0] tx_bits;
    logic [1:0] sym_tx, sym_rx;
    logic       rx_valid;
    logic [1:0] rx_bits;
    logic       cdr_locked, prbs_en, prbs_err;
    logic [31:0] prbs_cnt;

    nce_serdes_200g_stub #(.CDR_LOCK_CYCLES(LOCKC)) dut (
        .clk_i (clk), .rst_ni (rst_n),
        .tx_valid_i (tx_valid), .tx_bits_i (tx_bits), .tx_ready_o (tx_ready),
        .sym_o (sym_tx), .sym_i (sym_rx),
        .rx_valid_o (rx_valid), .rx_bits_o (rx_bits),
        .cdr_locked_o (cdr_locked), .prbs_enable_o (prbs_en),
        .prbs_error_o (prbs_err), .prbs_error_count_o (prbs_cnt)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    // Gray table, mirrored from the DUT so the test is an independent
    // statement of the mapping rather than a copy of the implementation.
    function automatic logic [1:0] expect_level (input logic [1:0] b);
        begin
            case (b)
                2'b00:   expect_level = 2'd0;
                2'b01:   expect_level = 2'd1;
                2'b11:   expect_level = 2'd2;
                default: expect_level = 2'd3;
            endcase
        end
    endfunction

    function automatic int unsigned popcount2 (input logic [1:0] v);
        begin
            popcount2 = (v[0] ? 1 : 0) + (v[1] ? 1 : 0);
        end
    endfunction

    logic [1:0] bits_for_level [4];
    int unsigned diff;

    initial begin
        tx_valid = 1'b0;
        tx_bits  = 2'b00;
        sym_rx   = 2'd0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // --- 3. a constant line must not lock ----------------------------
        sym_rx = 2'd2;
        repeat (LOCKC * 4) @(negedge clk);
        checks++;
        if (cdr_locked !== 1'b0) begin
            errors++;
            $display("FAIL [lock-on-silence]: CDR locked with a constant symbol");
            $display("                        A real CDR needs transitions.");
        end

        // --- 5. nothing valid before lock --------------------------------
        checks++;
        if (rx_valid !== 1'b0) begin
            errors++;
            $display("FAIL [early-valid]: rx_valid asserted before CDR lock");
        end

        // --- 4. transitions lock it --------------------------------------
        for (int unsigned i = 0; i < LOCKC * 3; i++) begin
            sym_rx = 2'(i % 4);
            @(negedge clk);
        end
        checks++;
        if (cdr_locked !== 1'b1) begin
            errors++;
            $display("FAIL [no-lock]: CDR did not lock after %0d transitions",
                     LOCKC * 3);
        end

        checks++;
        if (rx_valid !== 1'b1) begin
            errors++;
            $display("FAIL [valid-after-lock]: rx_valid still low after lock");
        end

        // --- 1. mapping round-trips --------------------------------------
        for (int unsigned b = 0; b < 4; b++) begin
            tx_bits  = 2'(b);
            tx_valid = 1'b1;
            @(negedge clk);
            tx_valid = 1'b0;
            @(negedge clk);

            checks++;
            if (sym_tx !== expect_level(2'(b))) begin
                errors++;
                $display("FAIL [encode %02b]: level %0d expected %0d",
                         b[1:0], sym_tx, expect_level(2'(b)));
            end

            // Feed the symbol back and confirm the bits return.
            sym_rx = sym_tx;
            @(negedge clk);
            @(negedge clk);
            checks++;
            if (rx_bits !== 2'(b)) begin
                errors++;
                $display("FAIL [round-trip %02b]: got %02b", b[1:0], rx_bits);
            end
            bits_for_level[expect_level(2'(b))] = 2'(b);
        end

        // --- 2. the Gray property ----------------------------------------
        // Adjacent levels must differ in exactly one bit. If this fails the
        // Gray coding is decorative and a one-level slip costs two bits.
        for (int unsigned L = 0; L < 3; L++) begin
            diff = popcount2(bits_for_level[L] ^ bits_for_level[L+1]);
            checks++;
            if (diff != 1) begin
                errors++;
                $display("FAIL [gray %0d->%0d]: %02b vs %02b differ in %0d bits",
                         L, L + 1, bits_for_level[L], bits_for_level[L+1], diff);
            end
        end
        $display("  PAM4 levels 0..3 carry %02b %02b %02b %02b -- Gray adjacent",
                 bits_for_level[0], bits_for_level[1],
                 bits_for_level[2], bits_for_level[3]);

        // --- PRBS plumbing is alive --------------------------------------
        checks++;
        if (prbs_en !== 1'b1) begin
            errors++;
            $display("FAIL [prbs-enable]: PRBS not enabled after CDR lock");
        end

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: 200G SerDes stub passed all %0d checks.", checks);
        else
            $display("FAIL: 200G SerDes stub had %0d errors in %0d checks.",
                     errors, checks);
        $display("NOTE This stub carries no bandwidth. See BANDWIDTH-STATEMENT.md");
        $display("----------------------------------------------------------");
        if (errors != 0) $fatal(1, "serdes stub mismatch");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: SerDes stub testbench timed out.");
        $fatal(1, "timeout");
    end

endmodule

`default_nettype wire
