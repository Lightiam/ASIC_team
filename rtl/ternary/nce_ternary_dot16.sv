// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- Layer 8: ternary dot-product unit
//
// Computes  y = sum_{w_i=+1} x_i  -  sum_{w_j=-1} x_j   over 16 lanes.
//
// No multiplier is instantiated. Each trit steers its activation through a
// conditional two's-complement negation, and a balanced adder tree sums the
// 16 terms. This is the area saving Layer 8 exists for: an INT8 multiplier
// array is replaced by negate-and-add.
//
// Width growth: a trit may negate its activation, so each term spans
// [-2^(ACT_WIDTH-1), +2^(ACT_WIDTH-1)] and needs ACT_WIDTH+1 bits -- negating
// the most negative input is the case that forces the extra bit. Summing 16
// such terms adds log2(16) = 4 more, giving ACT_WIDTH+5.
// For ACT_WIDTH=8 the worst case is 16 x -(-128) = +2048, which a 12-bit
// accumulator would wrap; 13 bits holds it.
//
// Latency: combinational core, one optional output register (REGISTERED).
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_ternary_dot16 #(
    // Width of each signed activation.
    parameter int unsigned ACT_WIDTH = 8,

    // Register the result when set. Zero gives a purely combinational unit.
    parameter bit REGISTERED = 1'b1
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire                      valid_i,
    // 16 trits, two bits each, lane i at [2*i +: 2].
    input  wire  [31:0]              weights_i,
    // 16 signed activations, lane i at [ACT_WIDTH*i +: ACT_WIDTH].
    input  wire  [16*ACT_WIDTH-1:0]  activations_i,

    output logic                     valid_o,
    output logic signed [ACT_WIDTH+5-1:0] result_o,
    // One bit per lane: that lane's trit used the reserved code point.
    output logic [15:0]              trap_o
);

    localparam int unsigned ACC_WIDTH = ACT_WIDTH + 5;

    // Sign-extended, conditionally negated per-lane terms.
    logic signed [ACC_WIDTH-1:0] term [16];
    logic [15:0] trap_bits;

    always_comb begin
        for (int unsigned i = 0; i < 16; i++) begin
            logic [1:0]                  code;
            logic                        is_pos;
            logic                        is_neg;
            logic signed [ACT_WIDTH-1:0] act;
            logic signed [ACC_WIDTH-1:0] act_ext;

            code   = weights_i[2*i +: 2];
            is_pos = (code == nce_ternary_pkg::TRIT_POS);
            is_neg = (code == nce_ternary_pkg::TRIT_NEG);

            act     = activations_i[ACT_WIDTH*i +: ACT_WIDTH];
            act_ext = act;   // widen by assignment: sign-extends reliably

            trap_bits[i] = (code == nce_ternary_pkg::TRIT_RESERVED);

            // A trit never multiplies. It selects +x, -x, or drops the term.
            if (is_pos)      term[i] =  act_ext;
            else if (is_neg) term[i] = -act_ext;
            else             term[i] = '0;      // zero and reserved contribute 0
        end
    end

    // Balanced adder tree, 16 -> 8 -> 4 -> 2 -> 1.
    logic signed [ACC_WIDTH-1:0] lvl3 [8];
    logic signed [ACC_WIDTH-1:0] lvl2 [4];
    logic signed [ACC_WIDTH-1:0] lvl1 [2];
    logic signed [ACC_WIDTH-1:0] sum;

    always_comb begin
        for (int unsigned i = 0; i < 8; i++) lvl3[i] = term[2*i] + term[2*i + 1];
        for (int unsigned i = 0; i < 4; i++) lvl2[i] = lvl3[2*i] + lvl3[2*i + 1];
        for (int unsigned i = 0; i < 2; i++) lvl1[i] = lvl2[2*i] + lvl2[2*i + 1];
        sum = lvl1[0] + lvl1[1];
    end

    generate
        if (REGISTERED) begin : g_registered
            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    result_o <= '0;
                    trap_o   <= '0;
                    valid_o  <= 1'b0;
                end
                else begin
                    valid_o <= valid_i;
                    if (valid_i) begin
                        result_o <= sum;
                        trap_o   <= trap_bits;
                    end
                end
            end
        end
        else begin : g_combinational
            always_comb begin
                result_o = sum;
                trap_o   = trap_bits;
                valid_o  = valid_i;
            end
        end
    endgenerate

endmodule

`default_nettype wire
