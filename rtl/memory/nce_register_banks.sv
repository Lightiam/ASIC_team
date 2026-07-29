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
// NCE architectural register banks.
//
// Contains:
//   - 16 x 256-bit vector register file
//   - 16 x 256-bit matrix register file
//
// Both banks support:
//   - Two asynchronous read ports
//   - One synchronous write port
//   - Eight independent 32-bit lane write enables
//   - Independent valid tracking
// -----------------------------------------------------------------------------

module nce_register_banks (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    // Vector register-file read ports
    input  logic [3:0]   vector_read_addr_a_i,
    output logic [255:0] vector_read_data_a_o,
    output logic         vector_read_valid_a_o,

    input  logic [3:0]   vector_read_addr_b_i,
    output logic [255:0] vector_read_data_b_o,
    output logic         vector_read_valid_b_o,

    // Vector register-file write port
    input  logic         vector_write_enable_i,
    input  logic [3:0]   vector_write_addr_i,
    input  logic [7:0]   vector_write_lane_enable_i,
    input  logic [255:0] vector_write_data_i,

    // Matrix register-file read ports
    input  logic [3:0]   matrix_read_addr_a_i,
    output logic [255:0] matrix_read_data_a_o,
    output logic         matrix_read_valid_a_o,

    input  logic [3:0]   matrix_read_addr_b_i,
    output logic [255:0] matrix_read_data_b_o,
    output logic         matrix_read_valid_b_o,

    // Matrix register-file write port
    input  logic         matrix_write_enable_i,
    input  logic [3:0]   matrix_write_addr_i,
    input  logic [7:0]   matrix_write_lane_enable_i,
    input  logic [255:0] matrix_write_data_i,

    output logic [15:0]  vector_valid_mask_o,
    output logic [15:0]  matrix_valid_mask_o
);

    nce_regfile_16x256 u_vector_registers (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .clear_i              (clear_i),

        .read_addr_a_i        (vector_read_addr_a_i),
        .read_data_a_o        (vector_read_data_a_o),
        .read_valid_a_o       (vector_read_valid_a_o),

        .read_addr_b_i        (vector_read_addr_b_i),
        .read_data_b_o        (vector_read_data_b_o),
        .read_valid_b_o       (vector_read_valid_b_o),

        .write_enable_i       (vector_write_enable_i),
        .write_addr_i         (vector_write_addr_i),
        .write_lane_enable_i  (vector_write_lane_enable_i),
        .write_data_i         (vector_write_data_i),

        .valid_mask_o         (vector_valid_mask_o)
    );

    nce_regfile_16x256 u_matrix_registers (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .clear_i              (clear_i),

        .read_addr_a_i        (matrix_read_addr_a_i),
        .read_data_a_o        (matrix_read_data_a_o),
        .read_valid_a_o       (matrix_read_valid_a_o),

        .read_addr_b_i        (matrix_read_addr_b_i),
        .read_data_b_o        (matrix_read_data_b_o),
        .read_valid_b_o       (matrix_read_valid_b_o),

        .write_enable_i       (matrix_write_enable_i),
        .write_addr_i         (matrix_write_addr_i),
        .write_lane_enable_i  (matrix_write_lane_enable_i),
        .write_data_i         (matrix_write_data_i),

        .valid_mask_o         (matrix_valid_mask_o)
    );

endmodule

`default_nettype wire
