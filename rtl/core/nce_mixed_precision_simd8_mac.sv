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
// Eight-lane mixed-precision SIMD MAC engine.
//
// Supported precision modes:
//
//   2'b00: INT8X4 DOT4
//   2'b01: BF16X2 DOT2
//   2'b10: BF24 multiply
//
// All eight lanes use the same precision for a transaction. Each lane owns one
// shared FP32 accumulator that can be updated by any supported precision.
// -----------------------------------------------------------------------------

module nce_mixed_precision_simd8_mac #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    input  logic         in_valid_i,
    output logic         in_ready_o,

    input  logic [1:0]   precision_i,
    output logic         precision_supported_o,

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

    logic [7:0] lane_ready;
    logic [7:0] lane_precision_supported;
    logic [7:0] lane_accumulator_valid;
    logic [7:0] lane_accumulator_update;

    genvar lane_index;

    generate
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin : generate_mixed_precision_lane

            nce_mixed_precision_mac_lane #(
                .INT8X4_PRECISION (INT8X4_PRECISION),
                .BF16X2_PRECISION (BF16X2_PRECISION),
                .BF24_PRECISION   (BF24_PRECISION)
            ) u_lane (
                .clk_i (
                    clk_i
                ),

                .rst_ni (
                    rst_ni
                ),

                .clear_i (
                    clear_i
                ),

                .in_valid_i (
                    in_valid_i
                ),

                .in_ready_o (
                    lane_ready[lane_index]
                ),

                .precision_i (
                    precision_i
                ),

                .lhs_i (
                    lhs_i[(lane_index * 32) +: 32]
                ),

                .rhs_i (
                    rhs_i[(lane_index * 32) +: 32]
                ),

                .precision_supported_o (
                    lane_precision_supported[lane_index]
                ),

                .accumulator_o (
                    accumulator_o[
                        (lane_index * 32) +: 32
                    ]
                ),

                .accumulator_valid_o (
                    lane_accumulator_valid[lane_index]
                ),

                .accumulator_update_o (
                    lane_accumulator_update[lane_index]
                ),

                .invalid_o (
                    lane_invalid_o[lane_index]
                ),

                .overflow_o (
                    lane_overflow_o[lane_index]
                ),

                .underflow_o (
                    lane_underflow_o[lane_index]
                ),

                .inexact_o (
                    lane_inexact_o[lane_index]
                )
            );

        end
    endgenerate

    assign precision_supported_o =
        &lane_precision_supported;

    assign in_ready_o =
        &lane_ready;

    assign accumulator_valid_o =
        &lane_accumulator_valid;

    assign accumulator_update_o =
        &lane_accumulator_update;

    assign invalid_o =
        |lane_invalid_o;

    assign overflow_o =
        |lane_overflow_o;

    assign underflow_o =
        |lane_underflow_o;

    assign inexact_o =
        |lane_inexact_o;

endmodule

`default_nettype wire
