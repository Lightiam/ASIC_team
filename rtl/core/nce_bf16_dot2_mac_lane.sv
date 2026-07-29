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
// BF16X2 DOT2 multiply-accumulate lane.
//
// Packing:
//
//   lhs_i[15:0]   = BF16 lhs element 0
//   lhs_i[31:16]  = BF16 lhs element 1
//
//   rhs_i[15:0]   = BF16 rhs element 0
//   rhs_i[31:16]  = BF16 rhs element 1
//
// Operation:
//
//   product_0 = lhs_0 * rhs_0
//   product_1 = lhs_1 * rhs_1
//   dot2      = product_0 + product_1
//
//   FP32 accumulator += dot2
//
// The two BF16 multiplications produce FP32 values. Their sum and the
// architectural accumulation use the existing IEEE-754 FP32 adder.
// -----------------------------------------------------------------------------

module nce_bf16_dot2_mac_lane (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        clear_i,

    input  logic        in_valid_i,
    output logic        in_ready_o,

    input  logic [31:0] lhs_i,
    input  logic [31:0] rhs_i,

    output logic [31:0] accumulator_o,
    output logic        accumulator_valid_o,
    output logic        accumulator_update_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    // -------------------------------------------------------------------------
    // Two BF16 multipliers
    // -------------------------------------------------------------------------

    logic [31:0] product_0;
    logic [31:0] product_1;

    logic product_0_invalid;
    logic product_0_overflow;
    logic product_0_underflow;
    logic product_0_inexact;

    logic product_1_invalid;
    logic product_1_overflow;
    logic product_1_underflow;
    logic product_1_inexact;

    nce_bf16_mul_to_fp32 u_multiplier_0 (
        .a_i         (lhs_i[15:0]),
        .b_i         (rhs_i[15:0]),

        .product_o   (product_0),

        .invalid_o   (product_0_invalid),
        .overflow_o  (product_0_overflow),
        .underflow_o (product_0_underflow),
        .inexact_o   (product_0_inexact)
    );

    nce_bf16_mul_to_fp32 u_multiplier_1 (
        .a_i         (lhs_i[31:16]),
        .b_i         (rhs_i[31:16]),

        .product_o   (product_1),

        .invalid_o   (product_1_invalid),
        .overflow_o  (product_1_overflow),
        .underflow_o (product_1_underflow),
        .inexact_o   (product_1_inexact)
    );

    // -------------------------------------------------------------------------
    // FP32 DOT2 addition
    // -------------------------------------------------------------------------

    logic [31:0] dot2_result;

    logic dot2_invalid;
    logic dot2_overflow;
    logic dot2_underflow;
    logic dot2_inexact;

    nce_fp32_add u_dot2_adder (
        .a_i         (product_0),
        .b_i         (product_1),

        .result_o    (dot2_result),

        .invalid_o   (dot2_invalid),
        .overflow_o  (dot2_overflow),
        .underflow_o (dot2_underflow),
        .inexact_o   (dot2_inexact)
    );

    // -------------------------------------------------------------------------
    // One-entry DOT2 pipeline
    // -------------------------------------------------------------------------

    logic        dot2_valid_q;
    logic [31:0] dot2_result_q;

    logic dot2_preacc_invalid_q;
    logic dot2_preacc_overflow_q;
    logic dot2_preacc_underflow_q;
    logic dot2_preacc_inexact_q;

    logic accumulator_in_ready;
    logic accumulator_fire;

    assign in_ready_o =
        rst_ni &&
        !clear_i &&
        (
            !dot2_valid_q ||
            accumulator_in_ready
        );

    assign accumulator_fire =
        dot2_valid_q &&
        accumulator_in_ready &&
        !clear_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dot2_valid_q <= 1'b0;
            dot2_result_q <= 32'd0;

            dot2_preacc_invalid_q   <= 1'b0;
            dot2_preacc_overflow_q  <= 1'b0;
            dot2_preacc_underflow_q <= 1'b0;
            dot2_preacc_inexact_q   <= 1'b0;
        end
        else if (clear_i) begin
            dot2_valid_q <= 1'b0;
            dot2_result_q <= 32'd0;

            dot2_preacc_invalid_q   <= 1'b0;
            dot2_preacc_overflow_q  <= 1'b0;
            dot2_preacc_underflow_q <= 1'b0;
            dot2_preacc_inexact_q   <= 1'b0;
        end
        else if (in_ready_o) begin
            dot2_valid_q <= in_valid_i;

            if (in_valid_i) begin
                dot2_result_q <= dot2_result;

                dot2_preacc_invalid_q <=
                    product_0_invalid |
                    product_1_invalid |
                    dot2_invalid;

                dot2_preacc_overflow_q <=
                    product_0_overflow |
                    product_1_overflow |
                    dot2_overflow;

                dot2_preacc_underflow_q <=
                    product_0_underflow |
                    product_1_underflow |
                    dot2_underflow;

                dot2_preacc_inexact_q <=
                    product_0_inexact |
                    product_1_inexact |
                    dot2_inexact;
            end
            else begin
                dot2_result_q <= 32'd0;

                dot2_preacc_invalid_q   <= 1'b0;
                dot2_preacc_overflow_q  <= 1'b0;
                dot2_preacc_underflow_q <= 1'b0;
                dot2_preacc_inexact_q   <= 1'b0;
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
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),

        .clear_i             (clear_i),

        .in_valid_i          (dot2_valid_q),
        .in_ready_o          (accumulator_in_ready),
        .addend_i            (dot2_result_q),

        .accumulator_o       (accumulator_o),
        .accumulator_valid_o (accumulator_valid_o),

        .invalid_o           (accumulator_invalid),
        .overflow_o          (accumulator_overflow),
        .underflow_o         (accumulator_underflow),
        .inexact_o           (accumulator_inexact)
    );

    // -------------------------------------------------------------------------
    // Completed operation status
    // -------------------------------------------------------------------------

    logic completed_preacc_invalid_q;
    logic completed_preacc_overflow_q;
    logic completed_preacc_underflow_q;
    logic completed_preacc_inexact_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            accumulator_update_o <= 1'b0;

            completed_preacc_invalid_q   <= 1'b0;
            completed_preacc_overflow_q  <= 1'b0;
            completed_preacc_underflow_q <= 1'b0;
            completed_preacc_inexact_q   <= 1'b0;
        end
        else if (clear_i) begin
            accumulator_update_o <= 1'b0;

            completed_preacc_invalid_q   <= 1'b0;
            completed_preacc_overflow_q  <= 1'b0;
            completed_preacc_underflow_q <= 1'b0;
            completed_preacc_inexact_q   <= 1'b0;
        end
        else begin
            accumulator_update_o <= accumulator_fire;

            if (accumulator_fire) begin
                completed_preacc_invalid_q <=
                    dot2_preacc_invalid_q;

                completed_preacc_overflow_q <=
                    dot2_preacc_overflow_q;

                completed_preacc_underflow_q <=
                    dot2_preacc_underflow_q;

                completed_preacc_inexact_q <=
                    dot2_preacc_inexact_q;
            end
        end
    end

    assign invalid_o =
        completed_preacc_invalid_q |
        accumulator_invalid;

    assign overflow_o =
        completed_preacc_overflow_q |
        accumulator_overflow;

    assign underflow_o =
        completed_preacc_underflow_q |
        accumulator_underflow;

    assign inexact_o =
        completed_preacc_inexact_q |
        accumulator_inexact;

endmodule

`default_nettype wire
