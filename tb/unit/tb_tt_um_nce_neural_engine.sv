// -----------------------------------------------------------------------------
// Testbench for tt_um_nce_neural_engine (Tiny Tapeout wrapper)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_tt_um_nce_neural_engine;

    logic [7:0] ui_in;
    wire  [7:0] uo_out;
    logic [7:0] uio_in;
    wire  [7:0] uio_out;
    wire  [7:0] uio_oe;
    logic       ena;
    logic       clk;
    logic       rst_n;

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    tt_um_nce_neural_engine dut (
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

    // Byte write task
    task automatic tt_write_word(input [31:0] addr, input [31:0] data);
        integer i;
        begin
            // 4 bytes of address
            for (i = 0; i < 4; i = i + 1) begin
                @(posedge clk);
                ui_in <= addr[i*8 +: 8];
                uio_in[0] <= 1'b1; // cmd_valid
                uio_in[1] <= 1'b1; // is_write
                uio_in[2] <= 1'b0;
                @(posedge clk);
                uio_in[0] <= 1'b0;
            end

            // 4 bytes of data
            for (i = 0; i < 4; i = i + 1) begin
                @(posedge clk);
                ui_in <= data[i*8 +: 8];
                uio_in[0] <= 1'b1;
                uio_in[1] <= 1'b1;
                @(posedge clk);
                uio_in[0] <= 1'b0;
            end

            // Wait for response
            while (!uio_out[1]) @(posedge clk); // wait resp_valid
            $display("[%0t] TT_WRITE OK: addr=0x%08h, data=0x%08h, resp=0x%02h", $time, addr, data, uo_out);

            @(posedge clk);
            uio_in[2] <= 1'b1; // resp_ack
            @(posedge clk);
            uio_in[2] <= 1'b0;
        end
    endtask

    // Byte read task
    task automatic tt_read_word(input [31:0] addr, output [31:0] data, output [1:0] resp);
        integer i;
        logic [7:0] rbytes [0:3];
        begin
            // 4 bytes of address
            for (i = 0; i < 4; i = i + 1) begin
                @(posedge clk);
                ui_in <= addr[i*8 +: 8];
                uio_in[0] <= 1'b1; // cmd_valid
                uio_in[1] <= 1'b0; // is_read
                uio_in[2] <= 1'b0;
                @(posedge clk);
                uio_in[0] <= 1'b0;
            end

            // Receive 4 data bytes
            for (i = 0; i < 4; i = i + 1) begin
                while (!uio_out[1]) @(posedge clk);
                rbytes[i] = uo_out;
                @(posedge clk);
                uio_in[2] <= 1'b1; // ack byte
                @(posedge clk);
                uio_in[2] <= 1'b0;
            end

            // Receive status byte
            while (!uio_out[1]) @(posedge clk);
            resp = uo_out[1:0];
            @(posedge clk);
            uio_in[2] <= 1'b1; // ack status
            @(posedge clk);
            uio_in[2] <= 1'b0;

            data = {rbytes[3], rbytes[2], rbytes[1], rbytes[0]};
            $display("[%0t] TT_READ OK: addr=0x%08h, data=0x%08h, resp=0x%01h", $time, addr, data, resp);
        end
    endtask

    logic [31:0] rdata;
    logic [1:0]  rresp;

    initial begin
        clk   = 0;
        rst_n = 0;
        ena   = 0;
        ui_in = 8'h00;
        uio_in = 8'h00;

        #100;
        rst_n = 1;
        ena   = 1;
        #100;

        $display("===== Starting Tiny Tapeout NCE Wrapper Verification =====");

        // 1. Read VERSION ID (0x000)
        tt_read_word(32'h00000000, rdata, rresp);
        if (rdata !== 32'h4E434531) begin
            $display("[FAIL] Expected ID 0x4E434531, got 0x%08h", rdata);
            $finish;
        end

        // 2. Read CAPABILITIES (0x004)
        tt_read_word(32'h00000004, rdata, rresp);
        if (rdata[3:0] !== 4'hF) begin
            $display("[FAIL] Expected capabilities 0x0F, got 0x%08h", rdata);
            $finish;
        end

        // 3. Stage Vector Data (0x060)
        tt_write_word(32'h00000060, 32'h11223344);

        // 4. Readback Vector Data (0x060)
        tt_read_word(32'h00000060, rdata, rresp);
        if (rdata !== 32'h11223344) begin
            $display("[FAIL] Staging readback mismatch: expected 0x11223344, got 0x%08h", rdata);
            $finish;
        end

        $display("===== Tiny Tapeout NCE Wrapper Tests PASSED Successfully! =====");
        #100;
        $finish;
    end

endmodule

`default_nettype wire
