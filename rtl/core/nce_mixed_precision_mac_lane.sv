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
// Mixed-precision MAC lane.
//
// Supported operations:
//
//   precision 2'b00:
//       Packed INT8X4 DOT4
//
//       addend = sum(lhs_i[n] * rhs_i[n]), n = 0..3
//
//   precision 2'b01:
//       Packed BF16X2 DOT2
//
//       addend = lhs_i[15:0]  * rhs_i[15:0]
//              + lhs_i[31:16] * rhs_i[31:16]
//
// All supported operations produce one FP32 addend and update one shared FP32
// architectural accumulator.
// -----------------------------------------------------------------------------

module nce_mixed_precision_mac_lane #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        clear_i,

    input  logic        in_valid_i,
    output logic        in_ready_o,

    input  logic [1:0]  precision_i,
    input  logic [31:0] lhs_i,
    input  logic [31:0] rhs_i,

    output logic        precision_supported_o,

    output logic [31:0] accumulator_o,
    output logic        accumulator_valid_o,
    output logic        accumulator_update_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    // -------------------------------------------------------------------------
    // INT8X4 DOT4 datapath
    // -------------------------------------------------------------------------

    logic signed [17:0] int8_dot;
    logic        [31:0] int8_addend;

    nce_int8_dot4 u_int8_dot4 (
        .lhs_i (lhs_i),
        .rhs_i (rhs_i),
        .dot_o (int8_dot)
    );

    nce_int18_to_fp32 u_int8_to_fp32 (
        .int_i  (int8_dot),
        .fp32_o (int8_addend)
    );

    // -------------------------------------------------------------------------
    // BF16X2 DOT2 datapath
    // -------------------------------------------------------------------------

    logic [31:0] bf16_addend;

    logic bf16_invalid;
    logic bf16_overflow;
    logic bf16_underflow;
    logic bf16_inexact;

    nce_bf16_dot2_to_fp32 u_bf16_dot2 (
        .lhs_i       (lhs_i),
        .rhs_i       (rhs_i),

        .result_o    (bf16_addend),

        .invalid_o   (bf16_invalid),
        .overflow_o  (bf16_overflow),
        .underflow_o (bf16_underflow),
        .inexact_o   (bf16_inexact)
    );

    // -------------------------------------------------------------------------
    // BF24 datapath
    //
    // One BF24 operand occupies bits [23:0] of each 32-bit lane.
    // Bits [31:24] are reserved.
    // -------------------------------------------------------------------------

    logic [31:0] bf24_addend;

    logic bf24_invalid;
    logic bf24_overflow;
    logic bf24_underflow;
    logic bf24_inexact;

    nce_bf24_mul_to_fp32 u_bf24_multiplier (
        .a_i         (lhs_i[23:0]),
        .b_i         (rhs_i[23:0]),

        .product_o   (bf24_addend),

        .invalid_o   (bf24_invalid),
        .overflow_o  (bf24_overflow),
        .underflow_o (bf24_underflow),
        .inexact_o   (bf24_inexact)
    );

    // -------------------------------------------------------------------------
    // Precision selection
    // -------------------------------------------------------------------------

    logic [31:0] selected_addend;

    logic selected_invalid;
    logic selected_overflow;
    logic selected_underflow;
    logic selected_inexact;

    always_comb begin
        precision_supported_o = 1'b1;

        selected_addend   = 32'h0000_0000;
        selected_invalid  = 1'b0;
        selected_overflow = 1'b0;
        selected_underflow = 1'b0;
        selected_inexact  = 1'b0;

        case (precision_i)
            INT8X4_PRECISION: begin
                selected_addend = int8_addend;
            end

            BF16X2_PRECISION: begin
                selected_addend    = bf16_addend;
                selected_invalid   = bf16_invalid;
                selected_overflow  = bf16_overflow;
                selected_underflow = bf16_underflow;
                selected_inexact   = bf16_inexact;
            end

            BF24_PRECISION: begin
                selected_addend    = bf24_addend;
                selected_invalid   = bf24_invalid;
                selected_overflow  = bf24_overflow;
                selected_underflow = bf24_underflow;
                selected_inexact   = bf24_inexact;
            end

            default: begin
                precision_supported_o = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Elastic addend pipeline
    // -------------------------------------------------------------------------

    logic        stage_valid_q;
    logic [31:0] stage_addend_q;

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
        precision_supported_o &&
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
            stage_valid_q     <= 1'b0;
            stage_addend_q    <= 32'h0000_0000;

            stage_invalid_q   <= 1'b0;
            stage_overflow_q  <= 1'b0;
            stage_underflow_q <= 1'b0;
            stage_inexact_q   <= 1'b0;
        end
        else if (clear_i) begin
            stage_valid_q     <= 1'b0;
            stage_addend_q    <= 32'h0000_0000;

            stage_invalid_q   <= 1'b0;
            stage_overflow_q  <= 1'b0;
            stage_underflow_q <= 1'b0;
            stage_inexact_q   <= 1'b0;
        end
        else begin
            case ({stage_push, stage_pop})
                2'b10,
                2'b11: begin
                    stage_valid_q  <= 1'b1;
                    stage_addend_q <= selected_addend;

                    stage_invalid_q   <= selected_invalid;
                    stage_overflow_q  <= selected_overflow;
                    stage_underflow_q <= selected_underflow;
                    stage_inexact_q   <= selected_inexact;
                end

                2'b01: begin
                    stage_valid_q  <= 1'b0;
                    stage_addend_q <= 32'h0000_0000;

                    stage_invalid_q   <= 1'b0;
                    stage_overflow_q  <= 1'b0;
                    stage_underflow_q <= 1'b0;
                    stage_inexact_q   <= 1'b0;
                end

                default: begin
                    stage_valid_q  <= stage_valid_q;
                    stage_addend_q <= stage_addend_q;

                    stage_invalid_q   <= stage_invalid_q;
                    stage_overflow_q  <= stage_overflow_q;
                    stage_underflow_q <= stage_underflow_q;
                    stage_inexact_q   <= stage_inexact_q;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Shared FP32 accumulator
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
        .addend_i            (stage_addend_q),

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
