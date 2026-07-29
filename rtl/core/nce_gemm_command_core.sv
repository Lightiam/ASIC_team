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
// Register-resident GEMM execution core.
//
// Integrates:
//
//   GEMM K-loop controller
//             ↓
//   Mixed-precision command core
//             ↓
//   Vector/matrix registers
//             ↓
//   Eight-lane SIMD MAC
//             ↓
//   Eight FP32 accumulators
//
// One GEMM operation accumulates K register pairs into the existing eight
// architectural FP32 accumulators.
// -----------------------------------------------------------------------------

module nce_gemm_command_core #(
    parameter logic [3:0] MAC_OPCODE        = 4'h3,
    parameter logic [3:0] DOT4_MAC_OPCODE   = 4'h4,

    parameter logic [1:0] INT8X4_PRECISION  = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION  = 2'b01,
    parameter logic [1:0] BF24_PRECISION    = 2'b10
) (
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

    // GEMM start and configuration interface
    input  logic         gemm_start_i,
    output logic         gemm_start_ready_o,

    input  logic [1:0]   gemm_precision_i,
    input  logic [3:0]   gemm_vector_base_addr_i,
    input  logic [3:0]   gemm_matrix_base_addr_i,
    input  logic [4:0]   gemm_k_count_i,

    // GEMM status
    output logic         gemm_busy_o,
    output logic         gemm_done_o,
    output logic         gemm_error_o,
    output logic [2:0]   gemm_error_code_o,
    output logic [1:0]   gemm_command_error_code_o,

    output logic [4:0]   gemm_completed_iterations_o,
    output logic [4:0]   gemm_total_iterations_o,

    // Internal command activity for verification/status
    output logic         command_accept_o,
    output logic         command_error_o,
    output logic [1:0]   command_error_code_o,
    output logic         execute_issue_o,
    output logic         operand_valid_o,

    // FP32 accumulator results
    output logic [255:0] accumulator_o,
    output logic         accumulator_valid_o,
    output logic         accumulator_update_o,

    // Arithmetic status
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

    logic flush_controller;

    logic controller_start;
    logic controller_start_ready;

    logic       controller_cmd_valid;
    logic       controller_cmd_ready;
    logic [3:0] controller_cmd_opcode;
    logic [1:0] controller_cmd_precision;
    logic [3:0] controller_vector_source_addr;
    logic [3:0] controller_matrix_source_addr;

    assign flush_controller =
        register_clear_i |
        accumulator_clear_i;

    assign gemm_start_ready_o =
        rst_ni &&
        controller_start_ready &&
        !register_clear_i &&
        !accumulator_clear_i;

    assign controller_start =
        gemm_start_i &&
        gemm_start_ready_o;

    // -------------------------------------------------------------------------
    // GEMM K-loop sequencer
    // -------------------------------------------------------------------------

    nce_gemm_controller #(
        .MAC_OPCODE        (MAC_OPCODE),
        .DOT4_MAC_OPCODE   (DOT4_MAC_OPCODE),

        .INT8X4_PRECISION  (INT8X4_PRECISION),
        .BF16X2_PRECISION  (BF16X2_PRECISION),
        .BF24_PRECISION    (BF24_PRECISION)
    ) u_gemm_controller (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .flush_i                     (flush_controller),

        .start_i                     (controller_start),
        .start_ready_o               (controller_start_ready),

        .precision_i                 (gemm_precision_i),
        .vector_base_addr_i          (gemm_vector_base_addr_i),
        .matrix_base_addr_i          (gemm_matrix_base_addr_i),
        .k_count_i                   (gemm_k_count_i),

        .cmd_valid_o                 (controller_cmd_valid),
        .cmd_ready_i                 (controller_cmd_ready),

        .cmd_opcode_o                (controller_cmd_opcode),
        .cmd_precision_o             (controller_cmd_precision),

        .cmd_vector_source_addr_o    (
            controller_vector_source_addr
        ),

        .cmd_matrix_source_addr_o    (
            controller_matrix_source_addr
        ),

        .cmd_error_i                 (command_error_o),
        .cmd_error_code_i            (command_error_code_o),
        .execute_issue_i             (execute_issue_o),
        .accumulator_update_i        (accumulator_update_o),

        .busy_o                      (gemm_busy_o),
        .done_o                      (gemm_done_o),
        .error_o                     (gemm_error_o),
        .error_code_o                (gemm_error_code_o),
        .command_error_code_o        (
            gemm_command_error_code_o
        ),

        .completed_iterations_o      (
            gemm_completed_iterations_o
        ),

        .total_iterations_o          (
            gemm_total_iterations_o
        )
    );

    // -------------------------------------------------------------------------
    // Existing command-controlled execution hierarchy
    // -------------------------------------------------------------------------

    nce_mixed_precision_command_core #(
        .MAC_OPCODE        (MAC_OPCODE),
        .DOT4_MAC_OPCODE   (DOT4_MAC_OPCODE),

        .INT8X4_PRECISION  (INT8X4_PRECISION),
        .BF16X2_PRECISION  (BF16X2_PRECISION),
        .BF24_PRECISION    (BF24_PRECISION)
    ) u_command_core (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .register_clear_i            (register_clear_i),
        .accumulator_clear_i         (accumulator_clear_i),

        .vector_write_enable_i       (vector_write_enable_i),
        .vector_write_addr_i         (vector_write_addr_i),
        .vector_write_lane_enable_i  (
            vector_write_lane_enable_i
        ),
        .vector_write_data_i         (vector_write_data_i),

        .matrix_write_enable_i       (matrix_write_enable_i),
        .matrix_write_addr_i         (matrix_write_addr_i),
        .matrix_write_lane_enable_i  (
            matrix_write_lane_enable_i
        ),
        .matrix_write_data_i         (matrix_write_data_i),

        .cmd_valid_i                 (controller_cmd_valid),
        .cmd_ready_o                 (controller_cmd_ready),

        .cmd_opcode_i                (controller_cmd_opcode),
        .cmd_precision_i             (controller_cmd_precision),

        .vector_source_addr_i        (
            controller_vector_source_addr
        ),

        .matrix_source_addr_i        (
            controller_matrix_source_addr
        ),

        .cmd_accept_o                (command_accept_o),
        .cmd_error_o                 (command_error_o),
        .cmd_error_code_o            (command_error_code_o),
        .execute_issue_o             (execute_issue_o),
        .operand_valid_o             (operand_valid_o),

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
