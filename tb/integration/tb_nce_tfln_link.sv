`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// TFLN die-to-die link integration test.
//
// Wires an initiator to a target across an ideal optical loopback, terminates
// the far side with a small AXI4-Lite memory, and checks that backend requests
// survive the round trip: framing, CRC, serialisation and AXI replay.
//
// Also checks that a broken optical path retires transactions with an error
// rather than hanging the bus.
// -----------------------------------------------------------------------------

module tb_nce_tfln_link;

    localparam int unsigned TIMEOUT = 512;

    logic clk_i;
    logic rst_ni;

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    // Backend request interface driven by the test
    logic        write_valid;
    logic        write_ready;
    logic [31:0] write_addr;
    logic [31:0] write_data;
    logic [3:0]  write_strb;
    logic        write_error;

    logic        read_valid;
    logic        read_ready;
    logic [31:0] read_addr;
    logic [31:0] read_data;
    logic        read_error;

    logic        link_busy;
    logic        link_timeout;
    logic        link_crc_error;
    logic        link_dropped;
    logic        target_busy;
    logic        target_crc;

    // Optical lanes
    logic a_tx;
    logic b_tx;
    logic sever_link;

    // A severed fibre delivers no light: the lane reads as constant zero.
    wire a_rx = sever_link ? 1'b0 : b_tx;
    wire b_rx = sever_link ? 1'b0 : a_tx;

    // Far-side AXI
    logic [31:0] b_awaddr;
    logic [2:0]  b_awprot;
    logic        b_awvalid;
    logic        b_awready;
    logic [31:0] b_wdata;
    logic [3:0]  b_wstrb;
    logic        b_wvalid;
    logic        b_wready;
    logic [1:0]  b_bresp;
    logic        b_bvalid;
    logic        b_bready;
    logic [31:0] b_araddr;
    logic [2:0]  b_arprot;
    logic        b_arvalid;
    logic        b_arready;
    logic [31:0] b_rdata;
    logic [1:0]  b_rresp;
    logic        b_rvalid;
    logic        b_rready;

    integer check_count;
    integer error_count;

    nce_tfln_link_initiator #(
        .RESPONSE_TIMEOUT (TIMEOUT)
    ) u_initiator (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .write_valid_i    (write_valid),
        .write_ready_o    (write_ready),
        .write_addr_i     (write_addr),
        .write_data_i     (write_data),
        .write_strb_i     (write_strb),
        .write_error_o    (write_error),
        .read_valid_i     (read_valid),
        .read_ready_o     (read_ready),
        .read_addr_i      (read_addr),
        .read_data_o      (read_data),
        .read_error_o     (read_error),
        .tfln_tx_o        (a_tx),
        .tfln_rx_i        (a_rx),
        .link_busy_o      (link_busy),
        .link_timeout_o   (link_timeout),
        .link_crc_error_o (link_crc_error)
    );

    nce_tfln_link_target u_target (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .tfln_rx_i        (b_rx),
        .tfln_tx_o        (b_tx),
        .m_axi_awaddr_o   (b_awaddr),
        .m_axi_awprot_o   (b_awprot),
        .m_axi_awvalid_o  (b_awvalid),
        .m_axi_awready_i  (b_awready),
        .m_axi_wdata_o    (b_wdata),
        .m_axi_wstrb_o    (b_wstrb),
        .m_axi_wvalid_o   (b_wvalid),
        .m_axi_wready_i   (b_wready),
        .m_axi_bresp_i    (b_bresp),
        .m_axi_bvalid_i   (b_bvalid),
        .m_axi_bready_o   (b_bready),
        .m_axi_araddr_o   (b_araddr),
        .m_axi_arprot_o   (b_arprot),
        .m_axi_arvalid_o  (b_arvalid),
        .m_axi_arready_i  (b_arready),
        .m_axi_rdata_i    (b_rdata),
        .m_axi_rresp_i    (b_rresp),
        .m_axi_rvalid_i   (b_rvalid),
        .m_axi_rready_o   (b_rready),
        .link_busy_o      (target_busy),
        .link_crc_error_o (target_crc),
        .link_dropped_o   (link_dropped)
    );

    // -------------------------------------------------------------------------
    // Far-side AXI4-Lite memory, 16 words. Address 0x40 always returns SLVERR
    // so the error path can be exercised.
    // -------------------------------------------------------------------------

    logic [31:0] memory [0:15];

    logic aw_seen;
    logic w_seen;

    assign b_awready = 1'b1;
    assign b_wready  = 1'b1;
    assign b_arready = 1'b1;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_seen  <= 1'b0;
            w_seen   <= 1'b0;
            b_bvalid <= 1'b0;
            b_bresp  <= 2'b00;
            b_rvalid <= 1'b0;
            b_rdata  <= 32'd0;
            b_rresp  <= 2'b00;
            for (int i = 0; i < 16; i = i + 1) begin
                memory[i] <= 32'd0;
            end
        end
        else begin
            if (b_bvalid && b_bready) begin
                b_bvalid <= 1'b0;
            end

            if (b_rvalid && b_rready) begin
                b_rvalid <= 1'b0;
            end

            if (b_awvalid && b_awready) begin
                aw_seen <= 1'b1;
            end

            if (b_wvalid && b_wready) begin
                w_seen <= 1'b1;

                if (b_awaddr[7:0] != 8'h40) begin
                    memory[b_awaddr[5:2]] <= b_wdata;
                end
            end

            if (
                (aw_seen || (b_awvalid && b_awready)) &&
                (w_seen  || (b_wvalid  && b_wready)) &&
                !b_bvalid
            ) begin
                aw_seen  <= 1'b0;
                w_seen   <= 1'b0;
                b_bvalid <= 1'b1;
                b_bresp  <= (b_awaddr[7:0] == 8'h40) ? 2'b10 : 2'b00;
            end

            if (b_arvalid && b_arready) begin
                b_rvalid <= 1'b1;
                b_rdata  <= (b_araddr[7:0] == 8'h40)
                            ? 32'd0
                            : memory[b_araddr[5:2]];
                b_rresp  <= (b_araddr[7:0] == 8'h40) ? 2'b10 : 2'b00;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    task automatic check_condition (
        input logic  condition,
        input string message
    );
        begin
            check_count = check_count + 1;
            if (!condition) begin
                error_count = error_count + 1;
                $display("ERROR check=%0d: %s", check_count, message);
            end
        end
    endtask

    task automatic do_write (
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [3:0]  strb
    );
        begin
            @(negedge clk_i);
            write_addr  = addr;
            write_data  = data;
            write_strb  = strb;
            write_valid = 1'b1;

            // The backend acknowledgement is a single cycle.
            @(posedge clk_i);
            while (!write_ready) begin
                @(posedge clk_i);
            end

            @(negedge clk_i);
            write_valid = 1'b0;
        end
    endtask

    task automatic do_read (
        input logic [31:0] addr
    );
        begin
            @(negedge clk_i);
            read_addr  = addr;
            read_valid = 1'b1;

            @(posedge clk_i);
            while (!read_ready) begin
                @(posedge clk_i);
            end

            @(negedge clk_i);
            read_valid = 1'b0;
        end
    endtask

    logic [31:0] captured_data;
    logic        captured_error;

    // Capture the response in the cycle the backend acknowledges it.
    always_ff @(posedge clk_i) begin
        if (read_ready) begin
            captured_data  <= read_data;
            captured_error <= read_error;
        end
    end

    initial begin
        rst_ni      = 1'b0;
        write_valid = 1'b0;
        read_valid  = 1'b0;
        write_addr  = 32'd0;
        write_data  = 32'd0;
        write_strb  = 4'hF;
        read_addr   = 32'd0;
        sever_link  = 1'b0;
        check_count = 0;
        error_count = 0;

        repeat (4) @(posedge clk_i);
        @(negedge clk_i);
        rst_ni = 1'b1;
        repeat (2) @(posedge clk_i);

        // ---------------------------------------------------------------------
        // A write then a read of the same address must round-trip the value.
        // ---------------------------------------------------------------------

        do_write(32'h0000_0004, 32'hDEAD_BEEF, 4'hF);
        check_condition(!write_error, "write over link reported an error");

        do_read(32'h0000_0004);
        @(posedge clk_i);
        check_condition(
            captured_data === 32'hDEAD_BEEF,
            $sformatf("read got %08h expected DEADBEEF", captured_data)
        );
        check_condition(!captured_error, "read over link reported an error");

        // ---------------------------------------------------------------------
        // A second, different value proves the link is not returning a stale
        // frame.
        // ---------------------------------------------------------------------

        do_write(32'h0000_0008, 32'h1234_5678, 4'hF);
        do_read(32'h0000_0008);
        @(posedge clk_i);
        check_condition(
            captured_data === 32'h1234_5678,
            $sformatf("second read got %08h expected 12345678", captured_data)
        );

        do_read(32'h0000_0004);
        @(posedge clk_i);
        check_condition(
            captured_data === 32'hDEAD_BEEF,
            $sformatf("re-read got %08h expected DEADBEEF", captured_data)
        );

        // ---------------------------------------------------------------------
        // A far-side SLVERR must propagate back across the link.
        // ---------------------------------------------------------------------

        do_read(32'h0000_0040);
        @(posedge clk_i);
        check_condition(
            captured_error === 1'b1,
            "far-side SLVERR did not propagate across the link"
        );

        // ---------------------------------------------------------------------
        // A severed optical path must retire the transaction with an error
        // instead of hanging the bus.
        // ---------------------------------------------------------------------

        sever_link = 1'b1;

        fork
            begin
                do_read(32'h0000_0004);
                @(posedge clk_i);
                check_condition(
                    captured_error === 1'b1,
                    "severed link did not report an error"
                );
            end
            begin
                // Generous bound: the timeout plus frame and AXI overhead.
                repeat (TIMEOUT + 600) @(posedge clk_i);
                check_condition(1'b0, "severed link hung the bus");
            end
        join_any
        disable fork;

        sever_link = 1'b0;

        // ---------------------------------------------------------------------
        // The link must recover once light returns.
        // ---------------------------------------------------------------------

        repeat (200) @(posedge clk_i);

        do_read(32'h0000_0008);
        @(posedge clk_i);
        check_condition(
            captured_data === 32'h1234_5678,
            $sformatf("post-recovery read got %08h expected 12345678",
                      captured_data)
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_tfln_link passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
