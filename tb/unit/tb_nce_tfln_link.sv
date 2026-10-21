// -----------------------------------------------------------------------------
// Testbench: TFLN optical die-to-die link, serializer + deserializer.
//
// This link is the one thing standing between the repository and the
// photonic bridge, and until now nothing simulated it. The claims tested
// here are the ones nce_tfln_pkg.sv makes in its own header, in its words:
//
//   1. "transmitted most-significant bit first" -- so the first eight bits
//      on the wire must be the SYNC marker, not the CRC.
//   2. A frame survives the round trip with every field intact.
//   3. "A receiver hunts for SYNC, collects the remaining 88 bits, then
//      validates the CRC."
//   4. "The line idles at zero" -- idle must not manufacture frames.
//   5. "A false SYNC match inside payload data fails the CRC check and the
//      receiver returns to hunting, so framing re-acquires without external
//      intervention."  This is the interesting one. It is a claim about
//      RECOVERY, not about detection, so it is tested by putting 8'hA5
//      inside the payload and requiring that subsequent frames still
//      arrive correctly.
//   6. A corrupted frame raises crc_error_o and does NOT raise frame_valid_o
//      -- a link that reports a bad frame as good is worse than one that
//      drops it.
//
// Note on claim 5: a false SYNC can only be *recovered from*, not avoided.
// The test therefore does not assert that the bad frame is rejected
// silently; it asserts that the link is still carrying correct frames
// afterwards, which is what "re-acquires without external intervention"
// actually means operationally.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_tfln_link;

    import nce_tfln_pkg::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUTs, wired as a loopback ----------------------------------------
    logic                       frame_valid_i;
    logic                       frame_ready_o;
    logic [TFLN_FRAME_BITS-1:0] frame_i;
    logic                       serial;
    logic                       busy;

    logic                       rx_valid;
    logic [TFLN_FRAME_BITS-1:0] rx_frame;
    logic                       rx_crc_error;

    // Injected line errors ride on top of the serializer output, so the
    // transmitter never has to know the channel is lossy.
    logic                       line_corrupt;
    wire                        line = serial ^ line_corrupt;

    nce_tfln_serializer u_ser (
        .clk_i         (clk),
        .rst_ni        (rst_n),
        .frame_valid_i (frame_valid_i),
        .frame_ready_o (frame_ready_o),
        .frame_i       (frame_i),
        .serial_o      (serial),
        .busy_o        (busy)
    );

    nce_tfln_deserializer u_des (
        .clk_i         (clk),
        .rst_ni        (rst_n),
        .serial_i      (line),
        .frame_valid_o (rx_valid),
        .frame_o       (rx_frame),
        .crc_error_o   (rx_crc_error)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    // ---- observation -------------------------------------------------------
    // Captured independently of the deserializer so that an ordering bug
    // cannot be hidden by a matching bug on the receive side.
    logic [7:0]  first_octet;
    int unsigned bits_seen;
    logic        capturing;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_octet <= 8'h00;
            bits_seen   <= 0;
            capturing   <= 1'b0;
        end
        // Gated on busy, not merely on the test's arm flag. serial_o is
        // driven to 0 whenever the serializer is idle, so capturing from the
        // moment the test arms itself shifts in leading idle zeros: the
        // first attempt here read 8'h29, which is 0010_1001 -- two idle bits
        // followed by the first six bits of 8'hA5. The wire was right and
        // the observer was early.
        else if (capturing && busy && bits_seen < 8) begin
            first_octet <= {first_octet[6:0], serial};
            bits_seen   <= bits_seen + 1;
        end
    end

    // ---- receive bookkeeping ----------------------------------------------
    int unsigned rx_count = 0;
    int unsigned crc_error_count = 0;
    logic [TFLN_FRAME_BITS-1:0] last_rx;

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (rx_valid) begin
                rx_count <= rx_count + 1;
                last_rx  <= rx_frame;
            end
            if (rx_crc_error) crc_error_count <= crc_error_count + 1;
        end
    end

    // ---- stimulus ----------------------------------------------------------
    task automatic send(input logic [TFLN_FRAME_BITS-1:0] f);
        begin
            @(negedge clk);
            frame_i       = f;
            frame_valid_i = 1'b1;
            // Wait for the serializer to accept it.
            do @(negedge clk); while (!frame_ready_o);
            frame_valid_i = 1'b0;
            // Then let the whole frame clock out, plus slack for the
            // receiver to validate the CRC.
            repeat (TFLN_FRAME_BITS + 8) @(negedge clk);
        end
    endtask

    task automatic expect_eq(input logic [TFLN_FRAME_BITS-1:0] got,
                             input logic [TFLN_FRAME_BITS-1:0] exp,
                             input string tag);
        begin
            checks++;
            if (got !== exp) begin
                errors++;
                $display("FAIL [%s]: got %024h expected %024h", tag, got, exp);
            end
        end
    endtask

    logic [TFLN_FRAME_BITS-1:0] f_a, f_b, f_sync_trap;
    int unsigned rx_before;

    initial begin
        frame_valid_i = 1'b0;
        frame_i       = '0;
        line_corrupt  = 1'b0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // --- 4. the line idles at zero and invents nothing -----------------
        repeat (TFLN_FRAME_BITS * 2) @(negedge clk);
        checks++;
        if (rx_count != 0) begin
            errors++;
            $display("FAIL [idle]: %0d frames appeared with no transmission",
                     rx_count);
        end
        checks++;
        if (serial !== 1'b0) begin
            errors++;
            $display("FAIL [idle-level]: serial_o = %b while idle", serial);
        end

        // --- 1. most-significant bit first ---------------------------------
        f_a = tfln_pack(1'b0, 1'b1, 1'b0, 4'hF, 32'hDEAD_BEEF, 32'hCAFE_F00D);
        capturing = 1'b1;
        send(f_a);
        capturing = 1'b0;
        checks++;
        if (first_octet !== TFLN_SYNC) begin
            errors++;
            $display("FAIL [msb-first]: first octet on the wire was %02h,",
                     first_octet);
            $display("                  expected the SYNC marker %02h.",
                     TFLN_SYNC);
            $display("                  %02h would mean the frame is going out",
                     f_a[7:0]);
            $display("                  least-significant bit first; anything");
            $display("                  else means the capture is misaligned.");
        end

        // --- 2/3. round trip with fields intact -----------------------------
        checks++;
        if (rx_count != 1) begin
            errors++;
            $display("FAIL [rx-count]: %0d frames received, expected 1",
                     rx_count);
        end
        expect_eq(last_rx, f_a, "round-trip");

        checks++;
        if (last_rx[TFLN_ADDR_LSB +: 32] !== 32'hDEAD_BEEF) begin
            errors++;
            $display("FAIL [addr]: %08h", last_rx[TFLN_ADDR_LSB +: 32]);
        end
        checks++;
        if (last_rx[TFLN_DATA_LSB +: 32] !== 32'hCAFE_F00D) begin
            errors++;
            $display("FAIL [data]: %08h", last_rx[TFLN_DATA_LSB +: 32]);
        end
        checks++;
        if (last_rx[TFLN_CTRL_LSB + TFLN_CTRL_WRITE] !== 1'b1) begin
            errors++;
            $display("FAIL [ctrl-write]: write bit did not survive");
        end
        checks++;
        if (last_rx[TFLN_STRB_LSB +: 4] !== 4'hF) begin
            errors++;
            $display("FAIL [strb]: %h", last_rx[TFLN_STRB_LSB +: 4]);
        end

        // --- back-to-back frames -------------------------------------------
        f_b = tfln_pack(1'b1, 1'b0, 1'b0, 4'h0, 32'h0000_1000, 32'h1234_5678);
        send(f_b);
        checks++;
        if (rx_count != 2) begin
            errors++;
            $display("FAIL [back-to-back]: rx_count=%0d expected 2", rx_count);
        end
        expect_eq(last_rx, f_b, "second-frame");

        // --- 6. a corrupted frame must not be reported as good --------------
        rx_before = rx_count;
        fork
            begin
                send(f_a);
            end
            begin
                // Flip one bit in the middle of the payload.
                repeat (40) @(negedge clk);
                line_corrupt = 1'b1;
                @(negedge clk);
                line_corrupt = 1'b0;
            end
        join
        checks++;
        if (rx_count != rx_before) begin
            errors++;
            $display("FAIL [crc-accept]: a corrupted frame was reported valid");
        end
        checks++;
        if (crc_error_count == 0) begin
            errors++;
            $display("FAIL [crc-detect]: corruption raised no crc_error_o");
        end

        // --- 5. a false SYNC inside the payload must not wedge the link -----
        // 8'hA5 is placed in the data field on purpose. Whether the receiver
        // trips on it is not the question -- the header concedes it may.
        // The question is whether the link still works afterwards.
        f_sync_trap = tfln_pack(1'b0, 1'b1, 1'b0, 4'h5,
                                32'hA5A5_A5A5, 32'hA5A5_A5A5);
        send(f_sync_trap);
        rx_before = rx_count;
        send(f_b);
        checks++;
        if (rx_count != rx_before + 1) begin
            errors++;
            $display("FAIL [re-acquire]: after a payload containing the SYNC");
            $display("                   marker the link stopped delivering ");
            $display("                   frames. rx_count %0d -> %0d",
                     rx_before, rx_count);
        end
        expect_eq(last_rx, f_b, "re-acquire-content");

        // --- recovery after reset ------------------------------------------
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);
        rx_before = rx_count;
        send(f_a);
        checks++;
        if (rx_count != rx_before + 1) begin
            errors++;
            $display("FAIL [post-reset]: link did not resume after reset");
        end

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: TFLN link passed all %0d checks.", checks);
        else
            $display("FAIL: TFLN link had %0d errors in %0d checks.",
                     errors, checks);
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1, "tfln link mismatch");
        $finish;
    end

    // A hung handshake should fail loudly rather than run forever.
    initial begin
        #200000;
        $display("FAIL: TFLN link testbench timed out.");
        $fatal(1, "timeout");
    end

endmodule

`default_nettype wire
