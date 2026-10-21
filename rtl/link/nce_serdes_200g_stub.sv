// -----------------------------------------------------------------------------
// 200G PAM4 SerDes -- BEHAVIOURAL STUB
//
// WHAT THIS IS NOT
// ----------------
// This is not a PHY and it does not close the bandwidth gap. A real 200G
// PAM4 lane runs at 100 Gbaud, a 50 GHz Nyquist, and is analog mixed-signal
// IP bought from a vendor. Nothing synthesised from this file will carry
// 200 Gbps, and the repository's own figure stands: the implemented link
// frames at 33.3 Mbps per lane, 6000x below target. See
// docs/BANDWIDTH-STATEMENT.md.
//
// WHAT IT IS FOR
// --------------
// It lets the DIGITAL side of the optical path be exercised: symbol
// mapping, CDR lock behaviour, and a PRBS31 bit-error check end to end. The
// protocol is the part that can be got right before the PHY exists, and the
// part that is expensive to get wrong afterwards.
//
// It lives in rtl/link/ and is deliberately NOT in src/. The Tiny Tapeout
// build compiles exactly three files listed in info.yaml, so a stub cannot
// wander into the GDS path and cost the green build.
//
// PAM4 MAPPING
// ------------
// Gray-coded, which is the mapping a real PAM4 link uses: adjacent levels
// differ in one bit, so the most likely symbol error (off by one level)
// costs one bit, not two.
//
//   bits  level
//   00  ->  0   (-3)
//   01  ->  1   (-1)
//   11  ->  2   (+1)
//   10  ->  3   (+3)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_serdes_200g_stub #(
    parameter int unsigned CDR_LOCK_CYCLES = 16
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    // Transmit: two bits per symbol.
    input  wire        tx_valid_i,
    input  wire [1:0]  tx_bits_i,
    output logic       tx_ready_o,

    // The "wire": one PAM4 symbol, four levels.
    output logic [1:0] sym_o,
    input  wire  [1:0] sym_i,

    // Receive.
    output logic       rx_valid_o,
    output logic [1:0] rx_bits_o,

    // Status.
    output logic       cdr_locked_o,
    output logic       prbs_enable_o,
    output logic       prbs_error_o,
    output logic [31:0] prbs_error_count_o
);

    // ---- PAM4 symbol mapping ------------------------------------------------
    function automatic logic [1:0] gray_encode (input logic [1:0] b);
        begin
            case (b)
                2'b00:   gray_encode = 2'd0;
                2'b01:   gray_encode = 2'd1;
                2'b11:   gray_encode = 2'd2;
                default: gray_encode = 2'd3;   // 2'b10
            endcase
        end
    endfunction

    function automatic logic [1:0] gray_decode (input logic [1:0] s);
        begin
            case (s)
                2'd0:    gray_decode = 2'b00;
                2'd1:    gray_decode = 2'b01;
                2'd2:    gray_decode = 2'b11;
                default: gray_decode = 2'b10;
            endcase
        end
    endfunction

    // ---- CDR lock -----------------------------------------------------------
    // A real CDR needs transitions to lock. This counts cycles in which the
    // incoming symbol CHANGES, so a constant line never locks -- which is
    // the behaviour that catches a dead or stuck link in simulation.
    logic [$clog2(CDR_LOCK_CYCLES+1)-1:0] lock_cnt;
    logic [1:0]                           sym_prev;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            lock_cnt     <= '0;
            sym_prev     <= 2'd0;
            cdr_locked_o <= 1'b0;
        end
        else begin
            sym_prev <= sym_i;
            if (sym_i != sym_prev) begin
                if (lock_cnt == CDR_LOCK_CYCLES[$bits(lock_cnt)-1:0]) begin
                    cdr_locked_o <= 1'b1;
                end
                else begin
                    lock_cnt <= lock_cnt + 1'b1;
                end
            end
        end
    end

    assign tx_ready_o = 1'b1;          // the stub never backpressures

    // ---- transmit -----------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) sym_o <= 2'd0;
        else if (tx_valid_i) sym_o <= gray_encode(tx_bits_i);
    end

    // ---- receive ------------------------------------------------------------
    // Data is only presented once the CDR has locked. Before lock a real
    // receiver emits noise, and handing the layer above "valid" data it
    // cannot trust is the single most misleading thing a stub can do.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_valid_o <= 1'b0;
            rx_bits_o  <= 2'b00;
        end
        else begin
            rx_valid_o <= cdr_locked_o;
            rx_bits_o  <= gray_decode(sym_i);
        end
    end

    // ---- PRBS31 -------------------------------------------------------------
    // x^31 + x^28 + 1, the standard pattern for this class of link.
    logic [30:0] prbs_tx;
    logic [30:0] prbs_rx;
    logic        prbs_rx_primed;

    assign prbs_enable_o = cdr_locked_o;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            prbs_tx            <= 31'h7FFF_FFFF;
            prbs_rx            <= 31'h7FFF_FFFF;
            prbs_rx_primed     <= 1'b0;
            prbs_error_o       <= 1'b0;
            prbs_error_count_o <= 32'd0;
        end
        else begin
            prbs_error_o <= 1'b0;
            if (cdr_locked_o) begin
                // Two bits per symbol, so the LFSR advances twice.
                prbs_tx <= {prbs_tx[28:0],
                            prbs_tx[30] ^ prbs_tx[27],
                            prbs_tx[29] ^ prbs_tx[26]};
                if (!prbs_rx_primed) begin
                    prbs_rx        <= 31'h7FFF_FFFF;
                    prbs_rx_primed <= 1'b1;
                end
                else begin
                    prbs_rx <= {prbs_rx[28:0],
                                prbs_rx[30] ^ prbs_rx[27],
                                prbs_rx[29] ^ prbs_rx[26]};
                    if (rx_valid_o &&
                        (rx_bits_o != {prbs_rx[30], prbs_rx[29]})) begin
                        prbs_error_o       <= 1'b1;
                        prbs_error_count_o <= prbs_error_count_o + 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
