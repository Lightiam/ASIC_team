// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
//
// RECONSTRUCTED LEAF MODULE
// -------------------------
// This module is instantiated by rtl/core/nce_mixed_precision_command_core.sv
// but was not present in any published branch of the repository. It has been
// reconstructed to satisfy every directed case asserted by the unit testbench
// tb/unit/tb_nce_mixed_precision_command_decoder.sv.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Mixed-precision command decoder.
//
// Purely combinational admission control for the mixed-precision command core.
//
// Unlike the INT8 decoder, opcode and precision are not independently legal:
// each opcode admits only the precisions its datapath implements.
//
//   DOT4_MAC + INT8X4  -> executable (INT8 dot-product path)
//   MAC      + BF16X2  -> executable (BF16 lane path)
//   MAC      + BF24    -> executable (BF24 lane path)
//
// Every other pairing of a *recognised* opcode is reported as an unsupported
// precision, including native FP32, which has no lane implementation.
//
// Handshake rules:
//   - flush_i blocks all acceptance.
//   - An executable command waits for execute_ready_i (backpressure applies).
//   - A rejected command is consumed immediately and retired as an error, even
//     while execution is stalled, so it cannot wedge the command stream.
//
// Error codes:
//   2'b00 = no error
//   2'b01 = unsupported opcode
//   2'b10 = unsupported precision (includes opcode/precision mismatch)
//   2'b11 = invalid operand
// -----------------------------------------------------------------------------

module nce_mixed_precision_command_decoder #(
    parameter logic [3:0] MAC_OPCODE       = 4'h3,
    parameter logic [3:0] DOT4_MAC_OPCODE  = 4'h4,
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
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

    logic opcode_is_mac;
    logic opcode_is_dot4_mac;
    logic opcode_supported;

    logic int8_command;
    logic bf16_command;
    logic bf24_command;

    logic command_supported;
    logic command_executable;

    assign opcode_is_mac =
        (cmd_opcode_i == MAC_OPCODE);

    assign opcode_is_dot4_mac =
        (cmd_opcode_i == DOT4_MAC_OPCODE);

    assign opcode_supported =
        opcode_is_mac ||
        opcode_is_dot4_mac;

    // Legal opcode/precision pairings.
    assign int8_command =
        opcode_is_dot4_mac &&
        (cmd_precision_i == INT8X4_PRECISION);

    assign bf16_command =
        opcode_is_mac &&
        (cmd_precision_i == BF16X2_PRECISION);

    assign bf24_command =
        opcode_is_mac &&
        (cmd_precision_i == BF24_PRECISION);

    assign command_supported =
        int8_command ||
        bf16_command ||
        bf24_command;

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

    // An unrecognised opcode is reported before any precision judgement; a
    // recognised opcode carrying a precision it cannot execute is reported as
    // an unsupported precision; operands are judged last.
    assign cmd_error_code_o =
        !cmd_error_o
        ? ERROR_NONE
        : !opcode_supported
          ? ERROR_UNSUPPORTED_OPCODE
          : !command_supported
            ? ERROR_UNSUPPORTED_PRECISION
            : ERROR_INVALID_OPERAND;

endmodule

`default_nettype wire
