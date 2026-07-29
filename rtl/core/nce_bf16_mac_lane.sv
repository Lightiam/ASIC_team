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
// BF16 multiply-accumulate lane.
//
// Pipeline:
//   BF16 × BF16
//       ↓
//   FP32 product register
//       ↓
//   IEEE-754 FP32 accumulator
//
// The multiplier exception flags are associated with the completed
// accumulation operation. The output flags describe the most recently
// completed operation.
// -----------------------------------------------------------------------------

module nce_bf16_mac_lane (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        clear_i,

    input  logic        in_valid_i,
    output logic        in_ready_o,

    input  logic [15:0] lhs_i,
    input  logic [15:0] rhs_i,

    output logic [31:0] accumulator_o,
    output logic        accumulator_valid_o,
    output logic        accumulator_update_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    // -------------------------------------------------------------------------
    // Combinational BF16 multiplier
    // -------------------------------------------------------------------------

    logic [31:0] multiplier_product;

    logic multiplier_invalid;
    logic multiplier_overflow;
    logic multiplier_underflow;
    logic multiplier_inexact;

    nce_bf16_mul_to_fp32 u_multiplier (
        .a_i          (lhs_i),
        .b_i          (rhs_i),

        .product_o    (multiplier_product),

        .invalid_o    (multiplier_invalid),
        .overflow_o   (multiplier_overflow),
        .underflow_o  (multiplier_underflow),
        .inexact_o    (multiplier_inexact)
    );

    // -------------------------------------------------------------------------
    // One-entry product pipeline
    // -------------------------------------------------------------------------

    logic        product_valid_q;
    logic [31:0] product_q;

    logic product_invalid_q;
    logic product_overflow_q;
    logic product_underflow_q;
    logic product_inexact_q;

    logic accumulator_in_ready;
    logic accumulator_fire;

    assign in_ready_o =
        rst_ni &&
        !clear_i &&
        (
            !product_valid_q ||
            accumulator_in_ready
        );

    assign accumulator_fire =
        product_valid_q &&
        accumulator_in_ready &&
        !clear_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            product_valid_q     <= 1'b0;
            product_q           <= 32'd0;

            product_invalid_q   <= 1'b0;
            product_overflow_q  <= 1'b0;
            product_underflow_q <= 1'b0;
            product_inexact_q   <= 1'b0;
        end
        else if (clear_i) begin
            product_valid_q     <= 1'b0;
            product_q           <= 32'd0;

            product_invalid_q   <= 1'b0;
            product_overflow_q  <= 1'b0;
            product_underflow_q <= 1'b0;
            product_inexact_q   <= 1'b0;
        end
        else if (in_ready_o) begin
            product_valid_q <= in_valid_i;

            if (in_valid_i) begin
                product_q <= multiplier_product;

                product_invalid_q   <= multiplier_invalid;
                product_overflow_q  <= multiplier_overflow;
                product_underflow_q <= multiplier_underflow;
                product_inexact_q   <= multiplier_inexact;
            end
            else begin
                product_q <= 32'd0;

                product_invalid_q   <= 1'b0;
                product_overflow_q  <= 1'b0;
                product_underflow_q <= 1'b0;
                product_inexact_q   <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FP32 accumulator
    // -------------------------------------------------------------------------

    logic accumulator_invalid;
    logic accumulator_overflow;
    logic accumulator_underflow;
    logic accumulator_inexact;

    nce_fp32_accumulator u_accumulator (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),

        .clear_i               (clear_i),

        .in_valid_i            (product_valid_q),
        .in_ready_o            (accumulator_in_ready),
        .addend_i              (product_q),

        .accumulator_o         (accumulator_o),
        .accumulator_valid_o   (accumulator_valid_o),

        .invalid_o             (accumulator_invalid),
        .overflow_o            (accumulator_overflow),
        .underflow_o           (accumulator_underflow),
        .inexact_o             (accumulator_inexact)
    );

    // -------------------------------------------------------------------------
    // Completion status
    // -------------------------------------------------------------------------

    logic completed_multiplier_invalid_q;
    logic completed_multiplier_overflow_q;
    logic completed_multiplier_underflow_q;
    logic completed_multiplier_inexact_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            accumulator_update_o <= 1'b0;

            completed_multiplier_invalid_q   <= 1'b0;
            completed_multiplier_overflow_q  <= 1'b0;
            completed_multiplier_underflow_q <= 1'b0;
            completed_multiplier_inexact_q   <= 1'b0;
        end
        else if (clear_i) begin
            accumulator_update_o <= 1'b0;

            completed_multiplier_invalid_q   <= 1'b0;
            completed_multiplier_overflow_q  <= 1'b0;
            completed_multiplier_underflow_q <= 1'b0;
            completed_multiplier_inexact_q   <= 1'b0;
        end
        else begin
            accumulator_update_o <= accumulator_fire;

            if (accumulator_fire) begin
                completed_multiplier_invalid_q <=
                    product_invalid_q;

                completed_multiplier_overflow_q <=
                    product_overflow_q;

                completed_multiplier_underflow_q <=
                    product_underflow_q;

                completed_multiplier_inexact_q <=
                    product_inexact_q;
            end
        end
    end

    assign invalid_o =
        completed_multiplier_invalid_q |
        accumulator_invalid;

    assign overflow_o =
        completed_multiplier_overflow_q |
        accumulator_overflow;

    assign underflow_o =
        completed_multiplier_underflow_q |
        accumulator_underflow;

    assign inexact_o =
        completed_multiplier_inexact_q |
        accumulator_inexact;

endmodule

`default_nettype wire
