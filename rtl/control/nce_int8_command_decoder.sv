// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
//
// RECONSTRUCTED LEAF MODULE
// -------------------------
// This module is instantiated by rtl/core/nce_int8_command_core.sv but was not
// present in any published branch of the repository. It has been reconstructed
// to match, bit-for-bit, the reference model in
// scripts/gen_int8_command_decoder_vectors.py, which the unit testbench
// tb/unit/tb_nce_int8_command_decoder.sv checks exhaustively (all 2*2*16*4*2*2 =
// 1024 input combinations).
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// INT8 command decoder.
//
// Purely combinational admission control for the INT8 command core. The decoder
// decides whether an offered command may be consumed this cycle, and whether
// consuming it launches an execution or retires it as an error.
//
// A command is *supported* only when it is the DOT4_MAC opcode carrying the
// INT8X4 precision. A supported command is *executable* only when its operands
// are also valid.
//
// Handshake rules:
//   - flush_i blocks all acceptance.
//   - An executable command waits for execute_ready_i (backpressure applies).
//   - A non-executable command is consumed immediately and retired as an error,
//     so a malformed command can never wedge the command stream behind a busy
//     execution unit.
//
// Error codes:
//   2'b00 = no error
//   2'b01 = unsupported opcode
//   2'b10 = unsupported precision
//   2'b11 = invalid operand
// -----------------------------------------------------------------------------

module nce_int8_command_decoder #(
    parameter logic [3:0] DOT4_MAC_OPCODE  = 4'h4,
    parameter logic [1:0] INT8X4_PRECISION = 2'b00
) (
    input  logic       flush_i,

    input  logic       cmd_valid_i,
    output logic       cmd_ready_o,

    input  logic [3:0] cmd_opcode_i,
    input  logic [1:0] cmd_precision_i,

    input  logic       operand_valid_i,
    input  logic       execute_ready_i,

    output logic       execute_valid_o,
    output logic       cmd_accept_o,
    output logic       cmd_error_o,
    output logic [1:0] cmd_error_code_o
);

    localparam logic [1:0] ERROR_NONE                  = 2'b00;
    localparam logic [1:0] ERROR_UNSUPPORTED_OPCODE    = 2'b01;
    localparam logic [1:0] ERROR_UNSUPPORTED_PRECISION = 2'b10;
    localparam logic [1:0] ERROR_INVALID_OPERAND       = 2'b11;

    logic opcode_supported;
    logic precision_supported;
    logic command_supported;
    logic command_executable;

    assign opcode_supported =
        (cmd_opcode_i == DOT4_MAC_OPCODE);

    assign precision_supported =
        (cmd_precision_i == INT8X4_PRECISION);

    assign command_supported =
        opcode_supported &&
        precision_supported;

    assign command_executable =
        command_supported &&
        operand_valid_i;

    // An executable command honours execution backpressure. Anything else is
    // consumed immediately so the command stream cannot deadlock on it.
    assign cmd_ready_o =
        !flush_i &&
        (command_executable
         ? execute_ready_i
         : 1'b1);

    assign cmd_accept_o =
        cmd_valid_i &&
        cmd_ready_o;

    assign execute_valid_o =
        cmd_accept_o &&
        command_executable;

    assign cmd_error_o =
        cmd_accept_o &&
        !command_executable;

    // Opcode is reported before precision, and precision before operands.
    assign cmd_error_code_o =
        !cmd_error_o
        ? ERROR_NONE
        : !opcode_supported
          ? ERROR_UNSUPPORTED_OPCODE
          : !precision_supported
            ? ERROR_UNSUPPORTED_PRECISION
            : ERROR_INVALID_OPERAND;

endmodule

`default_nettype wire
