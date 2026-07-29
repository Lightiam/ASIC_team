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
// Eight-lane BF16X2 SIMD DOT2 MAC engine.
//
// Each 32-bit lane contains two BF16 operands:
//
//   bits [15:0]  : BF16 element 0
//   bits [31:16] : BF16 element 1
//
// Each command performs sixteen BF16 multiplications:
//
//   8 lanes × 2 BF16 products per lane
// -----------------------------------------------------------------------------

module nce_bf16_simd8_mac (
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

    logic [7:0] lane_ready;
    logic [7:0] lane_accumulator_valid;
    logic [7:0] lane_accumulator_update;

    genvar lane_index;

    generate
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin : generate_bf16x2_lane

            nce_bf16_dot2_mac_lane u_lane (
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

                .lhs_i (
                    lhs_i[
                        (lane_index * 32) +: 32
                    ]
                ),

                .rhs_i (
                    rhs_i[
                        (lane_index * 32) +: 32
                    ]
                ),

                .accumulator_o (
                    accumulator_o[
                        (lane_index * 32) +: 32
                    ]
                ),

                .accumulator_valid_o (
                    lane_accumulator_valid[
                        lane_index
                    ]
                ),

                .accumulator_update_o (
                    lane_accumulator_update[
                        lane_index
                    ]
                ),

                .invalid_o (
                    lane_invalid_o[
                        lane_index
                    ]
                ),

                .overflow_o (
                    lane_overflow_o[
                        lane_index
                    ]
                ),

                .underflow_o (
                    lane_underflow_o[
                        lane_index
                    ]
                ),

                .inexact_o (
                    lane_inexact_o[
                        lane_index
                    ]
                )
            );

        end
    endgenerate

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
