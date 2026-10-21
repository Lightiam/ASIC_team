// -----------------------------------------------------------------------------
// PCS gearbox -- width conversion between the core and the PHY.
//
// WHAT THIS IS FOR
// ----------------
// phy/phy_requirements.py puts the bandwidth gap in its most actionable
// form: a 200G PAM4 lane carries 211.67 Gbps of line rate, so the die must
// present width x clock = 211.67e9 bits per second. At 33.33 MHz that is a
// 6350-bit bus, which is why no PHY purchase helps at today's clock. At
// 800 MHz it is 265 bits, which is ordinary for a 100G-class link.
//
// Reconciling the width the core wants with the width the PHY wants is
// what a gearbox does, and unlike the analog front end it is plain
// synthesisable digital. This is the first piece of the PCS.
//
// WHAT IT IS NOT
// --------------
// It is not the whole PCS. A 200G lane also needs KP4 RS(544,514) FEC,
// alignment markers and lane deskew. Those are separate blocks and are NOT
// in this file; claiming a gearbox is a PCS would be the same kind of
// overstatement this repository has been unwinding.
//
// It carries no bandwidth by itself either. It converts widths. What rate
// flows through it is set by the clock it is given and the PHY on the far
// side.
//
// HOW IT WORKS
// ------------
// A left-aligned buffer holds `count` valid bits in its most significant
// positions. Input is inserted below them; output is taken from the top,
// which keeps the output select CONSTANT rather than variable -- a variable
// part-select on the output would be the expensive direction in synthesis
// and is poorly handled by some simulators.
//
// Bit order is most-significant-first throughout, matching
// rtl/link/nce_tfln_serializer.sv so the two can be composed without a
// reversal nobody remembers.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_pcs_gearbox #(
    parameter int unsigned IN_W  = 64,
    parameter int unsigned OUT_W = 32
) (
    input  wire              clk_i,
    input  wire              rst_ni,

    input  wire              in_valid_i,
    input  wire [IN_W-1:0]   in_data_i,
    output logic             in_ready_o,

    output logic             out_valid_o,
    output logic [OUT_W-1:0] out_data_o,
    input  wire              out_ready_i,

    // Bits currently held. Exposed because a gearbox that silently drops or
    // duplicates is almost impossible to debug from its ports alone.
    output logic [15:0]      level_o
);

    // The buffer must hold a full input beside a full output, otherwise a
    // cycle can arrive with room for neither.
    localparam int unsigned BUF_W = IN_W + OUT_W;

    logic [BUF_W-1:0] buf_q;
    logic [15:0]      cnt_q;

    wire accept = in_valid_i  && in_ready_o;
    wire emit   = out_valid_o && out_ready_i;

    assign in_ready_o  = (cnt_q + 16'(IN_W)) <= 16'(BUF_W);
    assign out_valid_o = (cnt_q >= 16'(OUT_W));
    assign out_data_o  = buf_q[BUF_W-1 -: OUT_W];
    assign level_o     = cnt_q;

    // Next-state buffer, written as one expression so the accept-and-emit
    // case cannot disagree with the accept-only and emit-only cases. The
    // shift happens FIRST and the insert uses the post-shift count, which
    // is what makes same-cycle accept+emit correct.
    logic [BUF_W-1:0] shifted;
    logic [15:0]      cnt_after_emit;

    always_comb begin
        shifted        = emit ? (buf_q << OUT_W) : buf_q;
        cnt_after_emit = emit ? (cnt_q - 16'(OUT_W)) : cnt_q;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            buf_q <= '0;
            cnt_q <= 16'd0;
        end
        else begin
            if (accept) begin
                buf_q <= shifted
                       | (BUF_W'(in_data_i)
                          << (BUF_W - IN_W - cnt_after_emit));
                cnt_q <= cnt_after_emit + 16'(IN_W);
            end
            else begin
                buf_q <= shifted;
                cnt_q <= cnt_after_emit;
            end
        end
    end

endmodule

`default_nettype wire
