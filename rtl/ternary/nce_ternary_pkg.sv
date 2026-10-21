// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- Layer 8: Ternary Logic & Precision Compression
//
// Balanced ternary (trit) encoding for 1.58-bit BitNet-style weight
// quantisation. Weights take values in {-1, 0, +1} and are packed two bits per
// trit, so a 32-bit word carries 16 trits.
//
// Encoding, per the Layer 8 specification:
//
//   2'b00 ->  0
//   2'b01 -> +1
//   2'b11 -> -1
//   2'b10 -> Reserved / Trap
//
// The reserved code is not silently treated as a value. Decode reports it on a
// per-trit trap mask so the surrounding logic can raise an error rather than
// quietly computing with an undefined weight.
//
// Portability: every subroutine here takes and returns packed types only.
// Function output arguments and unpacked array ports are avoided because
// Icarus Verilog does not support them, and this package must elaborate under
// Icarus, Verilator and Yosys alike.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

package nce_ternary_pkg;

    // Two bits per trit.
    parameter int unsigned TRIT_BITS = 2;

    // Lanes per packed weight word, and the reference model's lane width.
    parameter int unsigned TRITS_PER_WORD = 16;
    parameter int unsigned REF_ACT_WIDTH  = 16;

    // Code points.
    parameter logic [1:0] TRIT_ZERO     = 2'b00;
    parameter logic [1:0] TRIT_POS      = 2'b01;
    parameter logic [1:0] TRIT_RESERVED = 2'b10;
    parameter logic [1:0] TRIT_NEG      = 2'b11;

    // Bit positions within the flag vector returned by trit_flags.
    parameter int unsigned TRIT_FLAG_POS  = 0;
    parameter int unsigned TRIT_FLAG_NEG  = 1;
    parameter int unsigned TRIT_FLAG_TRAP = 2;

    // -------------------------------------------------------------------------
    // Decode one trit into {trap, is_neg, is_pos}.
    //
    // is_pos and is_neg are mutually exclusive. Both low means the trit is zero
    // (or reserved, which is additionally flagged by trap).
    // -------------------------------------------------------------------------
    function automatic logic [2:0] trit_flags (input logic [1:0] code);
        begin
            trit_flags[TRIT_FLAG_POS]  = (code == TRIT_POS);
            trit_flags[TRIT_FLAG_NEG]  = (code == TRIT_NEG);
            trit_flags[TRIT_FLAG_TRAP] = (code == TRIT_RESERVED);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Encode a signed value into a trit. Values outside {-1,0,+1} saturate
    // towards the nearest representable trit, which keeps the encoder total.
    // -------------------------------------------------------------------------
    function automatic logic [1:0] trit_encode (input logic signed [7:0] value);
        begin
            if (value > 0)      trit_encode = TRIT_POS;
            else if (value < 0) trit_encode = TRIT_NEG;
            else                trit_encode = TRIT_ZERO;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Per-trap mask over a packed weight word.
    // -------------------------------------------------------------------------
    function automatic logic [TRITS_PER_WORD-1:0] trit_trap_mask (
        input logic [2*TRITS_PER_WORD-1:0] packed_weights
    );
        begin
            for (int unsigned i = 0; i < TRITS_PER_WORD; i++)
                trit_trap_mask[i] =
                    (packed_weights[2*i +: 2] == TRIT_RESERVED);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Reference model: ternary dot product of 16 trits against 16 signed
    // activations, each sign-extended into REF_ACT_WIDTH bits and packed.
    //
    // This is the definition the RTL must match. Multiplication is never
    // required -- a trit selects add, subtract or skip.
    // -------------------------------------------------------------------------
    function automatic logic signed [31:0] trit_dot_ref (
        input logic [2*TRITS_PER_WORD-1:0]              packed_weights,
        input logic [REF_ACT_WIDTH*TRITS_PER_WORD-1:0]  packed_acts
    );
        logic signed [31:0]              acc;
        logic signed [REF_ACT_WIDTH-1:0] act;
        logic [1:0]                      code;
        begin
            acc = 32'sd0;
            for (int unsigned i = 0; i < TRITS_PER_WORD; i++) begin
                code = packed_weights[2*i +: 2];
                act  = packed_acts[REF_ACT_WIDTH*i +: REF_ACT_WIDTH];

                if (code == TRIT_POS)      acc = acc + 32'(act);
                else if (code == TRIT_NEG) acc = acc - 32'(act);
                // TRIT_ZERO and TRIT_RESERVED contribute nothing.
            end
            trit_dot_ref = acc;
        end
    endfunction

endpackage

`default_nettype wire
