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
// Native mixed-precision output-stationary systolic processing element.
//
// Data movement:
//   activation: left -> right
//   weight:     top  -> bottom
//
// The FP32 partial sum remains local to this PE.
//
// One new operand pair can be accepted on every advancing clock cycle.
// When either valid token is absent, the PE forwards the available token or
// bubble but does not modify its accumulator.
// -----------------------------------------------------------------------------

module nce_systolic_pe #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        clear_i,

    // Global array movement control
    input  logic        step_i,
    output logic        ready_o,

    // Constant during one matrix operation
    input  logic [1:0]  precision_i,
    output logic        precision_supported_o,

    // Activation from the left
    input  logic [31:0] activation_i,
    input  logic        activation_valid_i,

    // Activation forwarded to the right
    output logic [31:0] activation_o,
    output logic        activation_valid_o,

    // Weight from above
    input  logic [31:0] weight_i,
    input  logic        weight_valid_i,

    // Weight forwarded downward
    output logic [31:0] weight_o,
    output logic        weight_valid_o,

    // Indicates a real multiply-accumulate token at this PE
    output logic        mac_fire_o,

    // Output-stationary local FP32 result
    output logic [31:0] accumulator_o,
    output logic        accumulator_valid_o,
    output logic        accumulator_update_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    logic operand_pair_valid;
    logic mac_input_ready;
    logic lane_precision_supported;

    assign operand_pair_valid =
        activation_valid_i &&
        weight_valid_i;

    // The existing MAC datapath has initiation interval one. This readiness
    // logic also allows future implementations to stall the whole array safely.
    assign ready_o =
        rst_ni &&
        !clear_i &&
        lane_precision_supported &&
        (
            !operand_pair_valid ||
            mac_input_ready
        );

    assign precision_supported_o =
        lane_precision_supported;

    assign mac_fire_o =
        step_i &&
        ready_o &&
        operand_pair_valid;

    // -------------------------------------------------------------------------
    // Native systolic forwarding registers
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            activation_o       <= 32'd0;
            activation_valid_o <= 1'b0;

            weight_o       <= 32'd0;
            weight_valid_o <= 1'b0;
        end
        else if (clear_i) begin
            activation_o       <= 32'd0;
            activation_valid_o <= 1'b0;

            weight_o       <= 32'd0;
            weight_valid_o <= 1'b0;
        end
        else if (step_i && ready_o) begin
            activation_o       <= activation_i;
            activation_valid_o <= activation_valid_i;

            weight_o       <= weight_i;
            weight_valid_o <= weight_valid_i;
        end
    end

    // -------------------------------------------------------------------------
    // Output-stationary arithmetic
    // -------------------------------------------------------------------------

    nce_mixed_precision_mac_lane #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_mac_lane (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .clear_i                (clear_i),

        .in_valid_i             (mac_fire_o),
        .in_ready_o             (mac_input_ready),

        .precision_i            (precision_i),
        .lhs_i                  (activation_i),
        .rhs_i                  (weight_i),

        .precision_supported_o  (lane_precision_supported),

        .accumulator_o          (accumulator_o),
        .accumulator_valid_o    (accumulator_valid_o),
        .accumulator_update_o   (accumulator_update_o),

        .invalid_o              (invalid_o),
        .overflow_o             (overflow_o),
        .underflow_o            (underflow_o),
        .inexact_o              (inexact_o)
    );

endmodule

`default_nettype wire
