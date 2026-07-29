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
// BF24 multiply-accumulate lane.
//
// Lane packing:
//
//   lhs_i[23:0]  = BF24 operand
//   rhs_i[23:0]  = BF24 operand
//   bits [31:24] = reserved
//
// Operation:
//
//   FP32 accumulator += FP32(BF24(lhs) * BF24(rhs))
//
// The BF24 multiplier is combinational. A one-entry elastic stage separates
// product generation from the shared FP32 accumulator.
// -----------------------------------------------------------------------------

module nce_bf24_mac_lane (
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
    // BF24 multiplication
    // -------------------------------------------------------------------------

    logic [31:0] product;

    logic product_invalid;
    logic product_overflow;
    logic product_underflow;
    logic product_inexact;

    nce_bf24_mul_to_fp32 u_bf24_multiplier (
        .a_i         (lhs_i[23:0]),
        .b_i         (rhs_i[23:0]),

        .product_o   (product),

        .invalid_o   (product_invalid),
        .overflow_o  (product_overflow),
        .underflow_o (product_underflow),
        .inexact_o   (product_inexact)
    );

    // -------------------------------------------------------------------------
    // One-entry elastic product stage
    // -------------------------------------------------------------------------

    logic        stage_valid_q;
    logic [31:0] stage_product_q;

    logic stage_invalid_q;
    logic stage_overflow_q;
    logic stage_underflow_q;
    logic stage_inexact_q;

    logic accumulator_ready;

    logic stage_push;
    logic stage_pop;

    assign in_ready_o =
        rst_ni &&
        !clear_i &&
        (
            !stage_valid_q ||
            accumulator_ready
        );

    assign stage_push =
        in_valid_i &&
        in_ready_o;

    assign stage_pop =
        stage_valid_q &&
        accumulator_ready &&
        !clear_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            stage_valid_q   <= 1'b0;
            stage_product_q <= 32'h0000_0000;

            stage_invalid_q   <= 1'b0;
            stage_overflow_q  <= 1'b0;
            stage_underflow_q <= 1'b0;
            stage_inexact_q   <= 1'b0;
        end
        else if (clear_i) begin
            stage_valid_q   <= 1'b0;
            stage_product_q <= 32'h0000_0000;

            stage_invalid_q   <= 1'b0;
            stage_overflow_q  <= 1'b0;
            stage_underflow_q <= 1'b0;
            stage_inexact_q   <= 1'b0;
        end
        else begin
            case ({stage_push, stage_pop})
                2'b10,
                2'b11: begin
                    stage_valid_q   <= 1'b1;
                    stage_product_q <= product;

                    stage_invalid_q   <= product_invalid;
                    stage_overflow_q  <= product_overflow;
                    stage_underflow_q <= product_underflow;
                    stage_inexact_q   <= product_inexact;
                end

                2'b01: begin
                    stage_valid_q   <= 1'b0;
                    stage_product_q <= 32'h0000_0000;

                    stage_invalid_q   <= 1'b0;
                    stage_overflow_q  <= 1'b0;
                    stage_underflow_q <= 1'b0;
                    stage_inexact_q   <= 1'b0;
                end

                default: begin
                    stage_valid_q   <= stage_valid_q;
                    stage_product_q <= stage_product_q;

                    stage_invalid_q   <= stage_invalid_q;
                    stage_overflow_q  <= stage_overflow_q;
                    stage_underflow_q <= stage_underflow_q;
                    stage_inexact_q   <= stage_inexact_q;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Shared-format FP32 accumulator
    // -------------------------------------------------------------------------

    logic accumulator_invalid;
    logic accumulator_overflow;
    logic accumulator_underflow;
    logic accumulator_inexact;

    nce_fp32_accumulator u_accumulator (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .clear_i             (clear_i),

        .in_valid_i          (stage_valid_q),
        .in_ready_o          (accumulator_ready),
        .addend_i            (stage_product_q),

        .accumulator_o       (accumulator_o),
        .accumulator_valid_o (accumulator_valid_o),

        .invalid_o           (accumulator_invalid),
        .overflow_o          (accumulator_overflow),
        .underflow_o         (accumulator_underflow),
        .inexact_o           (accumulator_inexact)
    );

    // -------------------------------------------------------------------------
    // Completed-operation status
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
            accumulator_update_o <= stage_pop;

            if (stage_pop) begin
                completed_preacc_invalid_q <=
                    stage_invalid_q;

                completed_preacc_overflow_q <=
                    stage_overflow_q;

                completed_preacc_underflow_q <=
                    stage_underflow_q;

                completed_preacc_inexact_q <=
                    stage_inexact_q;
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
