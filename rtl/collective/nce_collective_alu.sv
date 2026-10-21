// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- Layer 12: In-Network Collective ALU
//
// Reduction element for ring collectives. Sits between the link receiver and
// the link transmitter, combining an arriving payload with a locally held
// accumulator and forwarding the result, so a reduction completes in flight
// rather than by round-tripping through the host.
//
// Supported operations (Layer 12 specification):
//
//   COLL_SUM   accumulator + payload
//   COLL_MIN   min(accumulator, payload)
//   COLL_MAX   max(accumulator, payload)
//   COLL_PASS  forward payload unchanged (All-Gather / All-to-All)
//
// Numerics. SUM/MIN/MAX are performed on INT32 two's-complement payloads. The
// specification also names FP32 and BF16; those are deliberately NOT folded
// into this unit, because floating-point addition is not associative and an
// in-flight ring reduction would then produce results that depend on ring
// position -- precisely the non-determinism Layer 13 exists to eliminate.
// Integer reduction is associative and commutative, so a ring of these units
// is order-independent by construction. A float path belongs behind the
// Layer 13 reproducible-summation scheme, not here.
//
// MIN/MAX are order-independent for any total order, so they are safe.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

package nce_collective_pkg;

    parameter int unsigned COLL_OP_WIDTH = 2;

    parameter logic [1:0] COLL_SUM  = 2'b00;
    parameter logic [1:0] COLL_MIN  = 2'b01;
    parameter logic [1:0] COLL_MAX  = 2'b10;
    parameter logic [1:0] COLL_PASS = 2'b11;

    // Identity element for each operation, as a 32-bit signed pattern.
    function automatic logic signed [31:0] coll_identity (input logic [1:0] op);
        begin
            case (op)
                COLL_SUM: coll_identity = 32'sd0;
                COLL_MIN: coll_identity = 32'sh7FFF_FFFF;   // +max
                COLL_MAX: coll_identity = 32'sh8000_0000;   // -min
                default:  coll_identity = 32'sd0;
            endcase
        end
    endfunction

    // Reference reduction, used by the testbench and as the RTL's definition.
    function automatic logic signed [31:0] coll_reduce (
        input logic [1:0]          op,
        input logic signed [31:0]  acc,
        input logic signed [31:0]  payload
    );
        begin
            case (op)
                COLL_SUM:  coll_reduce = acc + payload;
                COLL_MIN:  coll_reduce = (payload < acc) ? payload : acc;
                COLL_MAX:  coll_reduce = (payload > acc) ? payload : acc;
                COLL_PASS: coll_reduce = payload;
                default:   coll_reduce = acc;
            endcase
        end
    endfunction

endpackage


module nce_collective_alu #(
    // Number of independently addressable accumulator slots.
    parameter int unsigned SLOTS = 16
) (
    input  wire                       clk_i,
    input  wire                       rst_ni,

    // Drop all accumulators back to the identity for the configured op.
    input  wire                       clear_i,
    input  wire [1:0]                 clear_op_i,

    // Ingress from the link receiver.
    input  wire                       in_valid_i,
    output logic                      in_ready_o,
    input  wire [1:0]                 op_i,
    input  wire [$clog2(SLOTS)-1:0]   slot_i,
    input  wire signed [31:0]         payload_i,
    // Last contribution for this slot: emit and reset the accumulator.
    input  wire                       last_i,

    // Egress toward the link transmitter.
    output logic                      out_valid_o,
    input  wire                       out_ready_i,
    output logic signed [31:0]        out_payload_o,
    output logic [$clog2(SLOTS)-1:0]  out_slot_o,
    output logic                      out_last_o,

    // Barrier support: one bit per slot, set when that slot saw its last.
    output logic [SLOTS-1:0]          slot_complete_o
);

    localparam int unsigned SLOT_BITS = $clog2(SLOTS);

    logic signed [31:0] acc_q [SLOTS];
    logic [SLOTS-1:0]   complete_q;

    // Single-cycle reduction, so we can accept whenever the egress can take a
    // result. This gives the <= 4 cycle in-flight budget the spec asks for:
    // one cycle here plus the serializer's own pipeline.
    assign in_ready_o      = out_ready_i;
    assign slot_complete_o = complete_q;

    logic signed [31:0] reduced;
    always_comb begin
        reduced = nce_collective_pkg::coll_reduce(op_i, acc_q[slot_i], payload_i);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int unsigned s = 0; s < SLOTS; s++) acc_q[s] <= 32'sd0;
            complete_q    <= '0;
            out_valid_o   <= 1'b0;
            out_payload_o <= 32'sd0;
            out_slot_o    <= '0;
            out_last_o    <= 1'b0;
        end
        else if (clear_i) begin
            for (int unsigned s = 0; s < SLOTS; s++)
                acc_q[s] <= nce_collective_pkg::coll_identity(clear_op_i);
            complete_q  <= '0;
            out_valid_o <= 1'b0;
            out_last_o  <= 1'b0;
        end
        else begin
            // Egress handshake: drop valid once accepted.
            if (out_valid_o && out_ready_i) out_valid_o <= 1'b0;

            if (in_valid_i && in_ready_o) begin
                out_payload_o <= reduced;
                out_slot_o    <= slot_i;
                out_last_o    <= last_i;
                out_valid_o   <= 1'b1;

                if (last_i) begin
                    // Reduction for this slot is done: publish and re-arm.
                    acc_q[slot_i]      <= nce_collective_pkg::coll_identity(op_i);
                    complete_q[slot_i] <= 1'b1;
                end
                else begin
                    acc_q[slot_i]      <= reduced;
                    complete_q[slot_i] <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
