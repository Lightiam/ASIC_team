// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN optical die-to-die link
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Frame deserializer.
//
// Samples the photodetector lane one bit per clock and recovers whole frames.
//
// Framing is recovered by hunting for the SYNC byte in the most recently
// received eight bits. Once SYNC is seen the remaining bits of the frame are
// collected and the CRC is checked.
//
// Because SYNC is only a byte, a payload can contain a byte equal to SYNC and
// trigger a false lock. That case is caught by the CRC: the frame is discarded,
// crc_error_o pulses, and the receiver returns to hunting, so framing recovers
// on a later genuine SYNC without external intervention.
// -----------------------------------------------------------------------------

module nce_tfln_deserializer
(
    input  logic                       clk_i,
    input  logic                       rst_ni,

    input  logic                       serial_i,

    output logic                       frame_valid_o,
    output logic [nce_tfln_pkg::TFLN_FRAME_BITS-1:0] frame_o,
    output logic                       crc_error_o
);

    localparam int unsigned PAYLOAD_BITS =
        nce_tfln_pkg::TFLN_FRAME_BITS - nce_tfln_pkg::TFLN_SYNC_BITS;

    localparam int unsigned COUNT_WIDTH = $clog2(PAYLOAD_BITS + 1);

    typedef enum logic [0:0] {
        STATE_HUNT = 1'b0,
        STATE_RECV = 1'b1
    } state_e;

    state_e                     state_q;
    logic [nce_tfln_pkg::TFLN_FRAME_BITS-1:0] shift_q;
    logic [COUNT_WIDTH-1:0]     received_q;

    logic [nce_tfln_pkg::TFLN_FRAME_BITS-1:0] shift_next;
    logic [nce_tfln_pkg::TFLN_CRC_COVER_BITS-1:0] covered;
    logic [nce_tfln_pkg::TFLN_CRC_BITS-1:0]       crc_received;
    logic                           crc_ok;

    assign shift_next = {shift_q[nce_tfln_pkg::TFLN_FRAME_BITS-2:0], serial_i};

    // Once the final bit has shifted in, the frame sits left-aligned in the
    // shift register with SYNC back at the top.
    assign covered      = shift_next[nce_tfln_pkg::TFLN_CRC_COVER_BITS+nce_tfln_pkg::TFLN_CRC_BITS-1:nce_tfln_pkg::TFLN_CRC_BITS];
    assign crc_received = shift_next[nce_tfln_pkg::TFLN_CRC_BITS-1:0];
    assign crc_ok       = (nce_tfln_pkg::tfln_crc8(covered) == crc_received);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q       <= STATE_HUNT;
            shift_q       <= {nce_tfln_pkg::TFLN_FRAME_BITS{1'b0}};
            received_q    <= {COUNT_WIDTH{1'b0}};
            frame_valid_o <= 1'b0;
            frame_o       <= {nce_tfln_pkg::TFLN_FRAME_BITS{1'b0}};
            crc_error_o   <= 1'b0;
        end
        else begin
            shift_q       <= shift_next;
            frame_valid_o <= 1'b0;
            crc_error_o   <= 1'b0;

            unique case (state_q)
                STATE_HUNT: begin
                    if (shift_next[nce_tfln_pkg::TFLN_SYNC_BITS-1:0] == nce_tfln_pkg::TFLN_SYNC) begin
                        state_q    <= STATE_RECV;
                        received_q <= {COUNT_WIDTH{1'b0}};
                    end
                end

                STATE_RECV: begin
                    if (received_q == COUNT_WIDTH'(PAYLOAD_BITS - 1)) begin
                        state_q    <= STATE_HUNT;
                        received_q <= {COUNT_WIDTH{1'b0}};

                        if (crc_ok) begin
                            frame_valid_o <= 1'b1;
                            frame_o       <= shift_next;
                        end
                        else begin
                            crc_error_o <= 1'b1;
                        end
                    end
                    else begin
                        received_q <= received_q + COUNT_WIDTH'(1);
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
