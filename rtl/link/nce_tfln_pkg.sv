// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN optical die-to-die link
//
// NCE core RTL: Original RTL Architect and Digital Designer: Talha Alam
// TFLN X2 node link layer: added for the dual-die TFLN_AI_NODE_X2 substrate.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Frame definition for the die-to-die link that crosses the thin-film lithium
// niobate photonic IC sitting between the two NCE dies.
//
// The optical portion is outside this RTL: each endpoint drives one modulator
// lane and samples one photodetector lane, both presented here as single-bit
// serial ports. Everything below is the digital framing that rides on them.
//
// Frame layout, 96 bits, transmitted most-significant bit first:
//
//   [95:88]  SYNC   8   constant 8'hA5, the framing marker
//   [87:80]  CTRL   8   see bit assignments below
//   [79:76]  STRB   4   AXI write strobe (requests only)
//   [75:72]  RSVD   4   reserved, transmitted as zero
//   [71:40]  ADDR  32   request address (zero on responses)
//   [39: 8]  DATA  32   write data on requests, read data on responses
//   [ 7: 0]  CRC    8   CRC-8 over bits [87:8], the 80 bits after SYNC
//
// The line idles at zero. A receiver hunts for SYNC, collects the remaining 88
// bits, then validates the CRC. A false SYNC match inside payload data fails
// the CRC check and the receiver returns to hunting, so framing re-acquires
// without external intervention.
// -----------------------------------------------------------------------------

package nce_tfln_pkg;

    parameter int unsigned TFLN_FRAME_BITS = 96;
    parameter int unsigned TFLN_SYNC_BITS  = 8;
    parameter int unsigned TFLN_CRC_BITS   = 8;

    // Bits covered by the CRC: everything between SYNC and the CRC itself.
    parameter int unsigned TFLN_CRC_COVER_BITS = 80;

    parameter logic [7:0] TFLN_SYNC = 8'hA5;

    // CTRL bit assignments, relative to the base of the CTRL field.
    parameter int unsigned TFLN_CTRL_RESPONSE = 3;
    parameter int unsigned TFLN_CTRL_WRITE    = 2;
    parameter int unsigned TFLN_CTRL_ERROR    = 1;

    // Least-significant bit position of each field within the 96-bit frame.
    parameter int unsigned TFLN_CRC_LSB  = 0;                    // [  7:  0]
    parameter int unsigned TFLN_DATA_LSB = TFLN_CRC_LSB  + 8;    // [ 39:  8]
    parameter int unsigned TFLN_ADDR_LSB = TFLN_DATA_LSB + 32;   // [ 71: 40]
    parameter int unsigned TFLN_RSVD_LSB = TFLN_ADDR_LSB + 32;   // [ 75: 72]
    parameter int unsigned TFLN_STRB_LSB = TFLN_RSVD_LSB + 4;    // [ 79: 76]
    parameter int unsigned TFLN_CTRL_LSB = TFLN_STRB_LSB + 4;    // [ 87: 80]
    parameter int unsigned TFLN_SYNC_LSB = TFLN_CTRL_LSB + 8;    // [ 95: 88]

    // CRC-8, polynomial 0x07 (x^8 + x^2 + x + 1), initial value zero,
    // fed most-significant bit first.
    function automatic logic [7:0] tfln_crc8 (
        input logic [TFLN_CRC_COVER_BITS-1:0] payload
    );
        logic [7:0] crc;
        logic       feedback;
        begin
            crc = 8'h00;

            for (
                int unsigned bit_index = TFLN_CRC_COVER_BITS;
                bit_index > 0;
                bit_index = bit_index - 1
            ) begin
                feedback = crc[7] ^ payload[bit_index-1];
                crc      = {crc[6:0], 1'b0};

                if (feedback) begin
                    crc = crc ^ 8'h07;
                end
            end

            tfln_crc8 = crc;
        end
    endfunction

    // Assemble a frame from its fields. The CRC is computed here so that the
    // transmitter and the checker can never disagree about the covered range.
    function automatic logic [TFLN_FRAME_BITS-1:0] tfln_pack (
        input logic        is_response,
        input logic        is_write,
        input logic        is_error,
        input logic [3:0]  strb,
        input logic [31:0] addr,
        input logic [31:0] data
    );
        logic [7:0]  ctrl;
        logic [TFLN_CRC_COVER_BITS-1:0] covered;
        begin
            ctrl = 8'h00;
            ctrl[TFLN_CTRL_RESPONSE] = is_response;
            ctrl[TFLN_CTRL_WRITE]    = is_write;
            ctrl[TFLN_CTRL_ERROR]    = is_error;

            covered = {ctrl, strb, 4'h0, addr, data};

            tfln_pack = {TFLN_SYNC, covered, tfln_crc8(covered)};
        end
    endfunction

endpackage

`default_nettype wire
