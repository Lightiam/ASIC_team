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
// Command-controlled NCE INT8 execution core.
//
// Supported command:
//   opcode    = DOT4_MAC (4'h4)
//   precision = INT8X4   (2'b00)
//
// Unsupported commands and invalid operands are accepted as rejected commands.
// Supported commands execute through:
//
//   Vector registers + Matrix registers
//                  ↓
//          8-lane INT8 DOT4
//                  ↓
//          FP32 accumulators
// -----------------------------------------------------------------------------

module nce_int8_command_core (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         register_clear_i,
    input  logic         accumulator_clear_i,

    // Vector register write interface
    input  logic         vector_write_enable_i,
    input  logic [3:0]   vector_write_addr_i,
    input  logic [7:0]   vector_write_lane_enable_i,
    input  logic [255:0] vector_write_data_i,

    // Matrix register write interface
    input  logic         matrix_write_enable_i,
    input  logic [3:0]   matrix_write_addr_i,
    input  logic [7:0]   matrix_write_lane_enable_i,
    input  logic [255:0] matrix_write_data_i,

    // Command interface
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,

    input  logic [3:0]   cmd_opcode_i,
    input  logic [1:0]   cmd_precision_i,

    input  logic [3:0]   vector_source_addr_i,
    input  logic [3:0]   matrix_source_addr_i,

    output logic         cmd_accept_o,
    output logic         cmd_error_o,
    output logic [1:0]   cmd_error_code_o,
    output logic         execute_issue_o,
    output logic         operand_valid_o,

    // Accumulator results
    output logic [255:0] accumulator_o,
    output logic         accumulator_valid_o,
    output logic         accumulator_update_o,

    // Status
    output logic [7:0]   lane_invalid_o,
    output logic [7:0]   lane_overflow_o,
    output logic [7:0]   lane_underflow_o,
    output logic [7:0]   lane_inexact_o,

    output logic         invalid_o,
    output logic         overflow_o,
    output logic         underflow_o,
    output logic         inexact_o,

    output logic [15:0]  vector_valid_mask_o,
    output logic [15:0]  matrix_valid_mask_o
);

    logic flush_command;

    logic decoder_execute_valid;
    logic decoder_command_error;
    logic [1:0] decoder_error_code;

    logic execution_ready;

    assign flush_command =
        register_clear_i |
        accumulator_clear_i;

    nce_int8_command_decoder u_command_decoder (
        .flush_i          (flush_command),

        .cmd_valid_i      (cmd_valid_i),
        .cmd_ready_o      (cmd_ready_o),

        .cmd_opcode_i     (cmd_opcode_i),
        .cmd_precision_i  (cmd_precision_i),

        .operand_valid_i  (operand_valid_o),
        .execute_ready_i  (execution_ready),

        .execute_valid_o  (decoder_execute_valid),
        .cmd_accept_o     (cmd_accept_o),
        .cmd_error_o      (decoder_command_error),
        .cmd_error_code_o (decoder_error_code)
    );

    assign execute_issue_o =
        decoder_execute_valid;

    // The decoder handles unsupported commands and invalid operands before
    // execution is issued. No execution-stage error feedback is required.
    assign cmd_error_o =
        decoder_command_error;

    assign cmd_error_code_o =
        decoder_error_code;

    nce_int8_register_mac_core u_execution_core (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .register_clear_i            (register_clear_i),
        .accumulator_clear_i         (accumulator_clear_i),

        .vector_write_enable_i       (vector_write_enable_i),
        .vector_write_addr_i         (vector_write_addr_i),
        .vector_write_lane_enable_i  (vector_write_lane_enable_i),
        .vector_write_data_i         (vector_write_data_i),

        .matrix_write_enable_i       (matrix_write_enable_i),
        .matrix_write_addr_i         (matrix_write_addr_i),
        .matrix_write_lane_enable_i  (matrix_write_lane_enable_i),
        .matrix_write_data_i         (matrix_write_data_i),

        .exec_valid_i                (decoder_execute_valid),
        .exec_ready_o                (execution_ready),

        .vector_source_addr_i        (vector_source_addr_i),
        .matrix_source_addr_i        (matrix_source_addr_i),

        .operand_valid_o             (operand_valid_o),
        .operand_error_o             (),

        .vector_debug_addr_i         (vector_source_addr_i),
        .vector_debug_data_o         (),
        .vector_debug_valid_o        (),

        .matrix_debug_addr_i         (matrix_source_addr_i),
        .matrix_debug_data_o         (),
        .matrix_debug_valid_o        (),

        .accumulator_o               (accumulator_o),
        .accumulator_valid_o         (accumulator_valid_o),
        .accumulator_update_o        (accumulator_update_o),

        .lane_invalid_o              (lane_invalid_o),
        .lane_overflow_o             (lane_overflow_o),
        .lane_underflow_o            (lane_underflow_o),
        .lane_inexact_o              (lane_inexact_o),

        .invalid_o                   (invalid_o),
        .overflow_o                  (overflow_o),
        .underflow_o                 (underflow_o),
        .inexact_o                   (inexact_o),

        .vector_valid_mask_o         (vector_valid_mask_o),
        .matrix_valid_mask_o         (matrix_valid_mask_o)
    );

endmodule

`default_nettype wire
