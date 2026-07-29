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
// NCE INT8 register-to-MAC execution core.
//
// Integrates:
//   - 16 x 256-bit vector register bank
//   - 16 x 256-bit matrix register bank
//   - Eight-lane packed-INT8 SIMD MAC engine
//
// An execution transaction reads one vector register and one matrix register.
// Each 32-bit lane contains four packed signed INT8 elements.
//
// A transaction is accepted when:
//
//   exec_valid_i && exec_ready_o
//
// Same-cycle register write and execution are supported through register-file
// write-through forwarding.
//
// Register clearing and accumulator clearing are independent.
// -----------------------------------------------------------------------------

module nce_int8_register_mac_core (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         register_clear_i,
    input  logic         accumulator_clear_i,

    // -------------------------------------------------------------------------
    // Vector register write interface
    // -------------------------------------------------------------------------
    input  logic         vector_write_enable_i,
    input  logic [3:0]   vector_write_addr_i,
    input  logic [7:0]   vector_write_lane_enable_i,
    input  logic [255:0] vector_write_data_i,

    // -------------------------------------------------------------------------
    // Matrix register write interface
    // -------------------------------------------------------------------------
    input  logic         matrix_write_enable_i,
    input  logic [3:0]   matrix_write_addr_i,
    input  logic [7:0]   matrix_write_lane_enable_i,
    input  logic [255:0] matrix_write_data_i,

    // -------------------------------------------------------------------------
    // Execution interface
    // -------------------------------------------------------------------------
    input  logic         exec_valid_i,
    output logic         exec_ready_o,

    input  logic [3:0]   vector_source_addr_i,
    input  logic [3:0]   matrix_source_addr_i,

    output logic         operand_valid_o,
    output logic         operand_error_o,

    // -------------------------------------------------------------------------
    // Auxiliary register read ports for debugging/control
    // -------------------------------------------------------------------------
    input  logic [3:0]   vector_debug_addr_i,
    output logic [255:0] vector_debug_data_o,
    output logic         vector_debug_valid_o,

    input  logic [3:0]   matrix_debug_addr_i,
    output logic [255:0] matrix_debug_data_o,
    output logic         matrix_debug_valid_o,

    // -------------------------------------------------------------------------
    // SIMD accumulator results
    // -------------------------------------------------------------------------
    output logic [255:0] accumulator_o,
    output logic         accumulator_valid_o,
    output logic         accumulator_update_o,

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

    logic [255:0] vector_operand;
    logic         vector_operand_valid;

    logic [255:0] matrix_operand;
    logic         matrix_operand_valid;

    logic simd_ready;
    logic simd_valid;

    nce_register_banks u_register_banks (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (register_clear_i),

        .vector_read_addr_a_i        (vector_source_addr_i),
        .vector_read_data_a_o        (vector_operand),
        .vector_read_valid_a_o       (vector_operand_valid),

        .vector_read_addr_b_i        (vector_debug_addr_i),
        .vector_read_data_b_o        (vector_debug_data_o),
        .vector_read_valid_b_o       (vector_debug_valid_o),

        .vector_write_enable_i       (vector_write_enable_i),
        .vector_write_addr_i         (vector_write_addr_i),
        .vector_write_lane_enable_i  (vector_write_lane_enable_i),
        .vector_write_data_i         (vector_write_data_i),

        .matrix_read_addr_a_i        (matrix_source_addr_i),
        .matrix_read_data_a_o        (matrix_operand),
        .matrix_read_valid_a_o       (matrix_operand_valid),

        .matrix_read_addr_b_i        (matrix_debug_addr_i),
        .matrix_read_data_b_o        (matrix_debug_data_o),
        .matrix_read_valid_b_o       (matrix_debug_valid_o),

        .matrix_write_enable_i       (matrix_write_enable_i),
        .matrix_write_addr_i         (matrix_write_addr_i),
        .matrix_write_lane_enable_i  (matrix_write_lane_enable_i),
        .matrix_write_data_i         (matrix_write_data_i),

        .vector_valid_mask_o         (vector_valid_mask_o),
        .matrix_valid_mask_o         (matrix_valid_mask_o)
    );

    assign operand_valid_o =
        vector_operand_valid &&
        matrix_operand_valid;

    assign exec_ready_o =
        simd_ready &&
        operand_valid_o &&
        !register_clear_i &&
        !accumulator_clear_i;

    assign simd_valid =
        exec_valid_i &&
        exec_ready_o;

    // Invalid-source execution requests are reported but not accepted.
    assign operand_error_o =
        exec_valid_i &&
        !operand_valid_o &&
        !register_clear_i;

    nce_int8_simd8_mac u_simd_mac (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .clear_i              (accumulator_clear_i),

        .in_valid_i           (simd_valid),
        .in_ready_o           (simd_ready),

        .lhs_i                (vector_operand),
        .rhs_i                (matrix_operand),

        .accumulator_o        (accumulator_o),
        .accumulator_valid_o  (accumulator_valid_o),
        .accumulator_update_o (accumulator_update_o),

        .lane_invalid_o       (lane_invalid_o),
        .lane_overflow_o      (lane_overflow_o),
        .lane_underflow_o     (lane_underflow_o),
        .lane_inexact_o       (lane_inexact_o),

        .invalid_o            (invalid_o),
        .overflow_o           (overflow_o),
        .underflow_o          (underflow_o),
        .inexact_o            (inexact_o)
    );

endmodule

`default_nettype wire
