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
// Pipelined packed-INT8 DOT4 MAC lane.
//
// Each accepted transaction computes:
//
//   accumulator = accumulator +
//                 sum(lhs_i[n] * rhs_i[n]), n = 0..3
//
// where every packed element is a signed INT8 value.
//
// Pipeline:
//   Stage 1: INT8 DOT4 and exact INT18-to-FP32 conversion
//   Stage 2: IEEE-754 FP32 accumulation
//
// Throughput:
//   One accepted DOT4 operation per clock after pipeline fill.
//
// Clear behavior:
//   clear_i flushes the pipeline, accumulator, valid state and status flags.
// -----------------------------------------------------------------------------

module nce_int8_mac_lane (
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

    logic signed [17:0] dot_int_comb;
    logic        [31:0] dot_fp32_comb;

    logic               stage_valid_q;
    logic        [31:0] stage_fp32_q;

    logic accumulator_ready;
    logic stage_push;
    logic stage_pop;

    nce_int8_dot4 u_dot4 (
        .lhs_i (lhs_i),
        .rhs_i (rhs_i),
        .dot_o (dot_int_comb)
    );

    nce_int18_to_fp32 u_int_to_fp32 (
        .int_i  (dot_int_comb),
        .fp32_o (dot_fp32_comb)
    );

    nce_fp32_accumulator u_accumulator (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .clear_i             (clear_i),

        .in_valid_i          (stage_valid_q),
        .in_ready_o          (accumulator_ready),
        .addend_i            (stage_fp32_q),

        .accumulator_o       (accumulator_o),
        .accumulator_valid_o (accumulator_valid_o),

        .invalid_o           (invalid_o),
        .overflow_o          (overflow_o),
        .underflow_o         (underflow_o),
        .inexact_o           (inexact_o)
    );

    // Elastic one-entry pipeline stage.
    //
    // A new input may be accepted when the stage is empty or when its current
    // value will be consumed by the accumulator on the same clock edge.
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
        accumulator_ready;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            stage_valid_q       <= 1'b0;
            stage_fp32_q        <= 32'h0000_0000;
            accumulator_update_o <= 1'b0;
        end
        else if (clear_i) begin
            stage_valid_q       <= 1'b0;
            stage_fp32_q        <= 32'h0000_0000;
            accumulator_update_o <= 1'b0;
        end
        else begin
            accumulator_update_o <= stage_pop;

            case ({stage_push, stage_pop})
                2'b10: begin
                    stage_valid_q <= 1'b1;
                    stage_fp32_q  <= dot_fp32_comb;
                end

                2'b01: begin
                    stage_valid_q <= 1'b0;
                    stage_fp32_q  <= 32'h0000_0000;
                end

                2'b11: begin
                    // Consume the old value and replace it with the new one.
                    stage_valid_q <= 1'b1;
                    stage_fp32_q  <= dot_fp32_comb;
                end

                default: begin
                    stage_valid_q <= stage_valid_q;
                    stage_fp32_q  <= stage_fp32_q;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
