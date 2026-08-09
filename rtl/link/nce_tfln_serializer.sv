// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN optical die-to-die link
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Frame serializer.
//
// Accepts a complete frame and shifts it onto the modulator lane most
// significant bit first, one bit per clock. The lane idles at zero between
// frames, which the receiver relies on to avoid mistaking idle for payload.
//
// A frame is accepted only while the serializer is idle, so the transmit path
// is naturally single-outstanding.
// -----------------------------------------------------------------------------

module nce_tfln_serializer
    import nce_tfln_pkg::*;
(
    input  logic                       clk_i,
    input  logic                       rst_ni,

    input  logic                       frame_valid_i,
    output logic                       frame_ready_o,
    input  logic [TFLN_FRAME_BITS-1:0] frame_i,

    output logic                       serial_o,
    output logic                       busy_o
);

    localparam int unsigned COUNT_WIDTH = $clog2(TFLN_FRAME_BITS + 1);

    logic [TFLN_FRAME_BITS-1:0] shift_q;
    logic [COUNT_WIDTH-1:0]     remaining_q;
    logic                       busy_q;

    assign busy_o        = busy_q;
    assign frame_ready_o = !busy_q;

    // Idle low so the receiver's sync hunt cannot latch onto dead air.
    assign serial_o =
        busy_q
        ? shift_q[TFLN_FRAME_BITS-1]
        : 1'b0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            shift_q     <= {TFLN_FRAME_BITS{1'b0}};
            remaining_q <= {COUNT_WIDTH{1'b0}};
            busy_q      <= 1'b0;
        end
        else if (!busy_q) begin
            if (frame_valid_i) begin
                shift_q     <= frame_i;
                remaining_q <= COUNT_WIDTH'(TFLN_FRAME_BITS);
                busy_q      <= 1'b1;
            end
        end
        else begin
            shift_q <= {shift_q[TFLN_FRAME_BITS-2:0], 1'b0};

            if (remaining_q == COUNT_WIDTH'(1)) begin
                busy_q      <= 1'b0;
                remaining_q <= {COUNT_WIDTH{1'b0}};
            end
            else begin
                remaining_q <= remaining_q - COUNT_WIDTH'(1);
            end
        end
    end

endmodule

`default_nettype wire
