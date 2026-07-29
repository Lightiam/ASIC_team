// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Eight-lane packed-INT8 SIMD MAC core.
//
// Input packing:
//   Lane 0: bits [31:0]
//   Lane 1: bits [63:32]
//   ...
//   Lane 7: bits [255:224]
//
// Each lane independently computes:
//
//   accumulator[lane] += DOT4_INT8(lhs[lane], rhs[lane])
//
// All eight lanes accept and update transactions atomically.
// -----------------------------------------------------------------------------

module nce_int8_simd8_mac (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    input  logic         in_valid_i,
    output logic         in_ready_o,

    input  logic [255:0] lhs_i,
    input  logic [255:0] rhs_i,

    output logic [255:0] accumulator_o,
    output logic         accumulator_valid_o,
    output logic         accumulator_update_o,

    output logic [7:0]   lane_invalid_o,
    output logic [7:0]   lane_overflow_o,
    output logic [7:0]   lane_underflow_o,
    output logic [7:0]   lane_inexact_o,

    output logic         invalid_o,
    output logic         overflow_o,
    output logic         underflow_o,
    output logic         inexact_o
);

    localparam int unsigned LANE_COUNT = 8;
    localparam int unsigned LANE_WIDTH = 32;

    logic [LANE_COUNT-1:0] lane_ready;
    logic [LANE_COUNT-1:0] lane_accumulator_valid;
    logic [LANE_COUNT-1:0] lane_accumulator_update;

    logic lane_in_valid;

    // A transaction is accepted only when every lane is ready.
    assign in_ready_o =
        &lane_ready;

    // Gate the valid signal to preserve atomic SIMD operation.
    assign lane_in_valid =
        in_valid_i &&
        in_ready_o;

    // All lanes operate in lockstep.
    assign accumulator_valid_o =
        &lane_accumulator_valid;

    assign accumulator_update_o =
        &lane_accumulator_update;

    // Aggregate sticky status across all lanes.
    assign invalid_o   = |lane_invalid_o;
    assign overflow_o  = |lane_overflow_o;
    assign underflow_o = |lane_underflow_o;
    assign inexact_o   = |lane_inexact_o;

    generate
        for (genvar lane = 0; lane < LANE_COUNT; lane++) begin : g_mac_lane
            nce_int8_mac_lane u_lane (
                .clk_i                (clk_i),
                .rst_ni               (rst_ni),
                .clear_i              (clear_i),

                .in_valid_i           (lane_in_valid),
                .in_ready_o           (lane_ready[lane]),

                .lhs_i                (
                    lhs_i[
                        (lane * LANE_WIDTH) +:
                        LANE_WIDTH
                    ]
                ),

                .rhs_i                (
                    rhs_i[
                        (lane * LANE_WIDTH) +:
                        LANE_WIDTH
                    ]
                ),

                .accumulator_o        (
                    accumulator_o[
                        (lane * LANE_WIDTH) +:
                        LANE_WIDTH
                    ]
                ),

                .accumulator_valid_o  (
                    lane_accumulator_valid[lane]
                ),

                .accumulator_update_o (
                    lane_accumulator_update[lane]
                ),

                .invalid_o            (lane_invalid_o[lane]),
                .overflow_o           (lane_overflow_o[lane]),
                .underflow_o          (lane_underflow_o[lane]),
                .inexact_o            (lane_inexact_o[lane])
            );
        end
    endgenerate

endmodule

`default_nettype wire
