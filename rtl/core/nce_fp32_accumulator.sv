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
// Clocked IEEE-754 binary32 accumulator.
//
// Handshake:
//   An input is accepted when in_valid_i && in_ready_o.
//
// Control:
//   - rst_ni: asynchronous active-low reset
//   - clear_i: synchronous clear with priority over input acceptance
//
// Status flags are sticky until reset or clear.
// -----------------------------------------------------------------------------

module nce_fp32_accumulator (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        clear_i,

    input  logic        in_valid_i,
    output logic        in_ready_o,
    input  logic [31:0] addend_i,

    output logic [31:0] accumulator_o,
    output logic        accumulator_valid_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    logic [31:0] accumulator_q;

    logic [31:0] add_result;
    logic        add_invalid;
    logic        add_overflow;
    logic        add_underflow;
    logic        add_inexact;

    logic        input_accepted;

    // Clear occupies the current update cycle, so an addend is not accepted
    // while clear_i is asserted.
    assign in_ready_o =
        rst_ni &&
        !clear_i;

    assign input_accepted =
        in_valid_i &&
        in_ready_o;

    assign accumulator_o =
        accumulator_q;

    nce_fp32_add u_fp32_add (
        .a_i         (accumulator_q),
        .b_i         (addend_i),
        .result_o    (add_result),
        .invalid_o   (add_invalid),
        .overflow_o  (add_overflow),
        .underflow_o (add_underflow),
        .inexact_o   (add_inexact)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            accumulator_q       <= 32'h0000_0000;
            accumulator_valid_o <= 1'b0;

            invalid_o           <= 1'b0;
            overflow_o          <= 1'b0;
            underflow_o         <= 1'b0;
            inexact_o           <= 1'b0;
        end
        else if (clear_i) begin
            accumulator_q       <= 32'h0000_0000;
            accumulator_valid_o <= 1'b0;

            invalid_o           <= 1'b0;
            overflow_o          <= 1'b0;
            underflow_o         <= 1'b0;
            inexact_o           <= 1'b0;
        end
        else if (input_accepted) begin
            accumulator_q       <= add_result;
            accumulator_valid_o <= 1'b1;

            invalid_o           <= invalid_o   | add_invalid;
            overflow_o          <= overflow_o  | add_overflow;
            underflow_o         <= underflow_o | add_underflow;
            inexact_o           <= inexact_o   | add_inexact;
        end
    end

endmodule

`default_nettype wire
