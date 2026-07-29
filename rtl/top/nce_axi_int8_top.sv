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
// AXI4-Lite controlled NCE INT8 MVP top level.
//
// Integrates:
//
//   AXI4-Lite frontend
//          ↓
//   CSR and staging backend
//          ↓
//   Command decoder
//          ↓
//   16 x 256-bit vector registers
//   16 x 256-bit matrix registers
//          ↓
//   Eight-lane packed INT8 DOT4
//          ↓
//   Eight FP32 accumulators
//
// This is the first complete digital NCE logical top level. A future chip/pad
// top will wrap this block with pads, clock generation, reset conditioning and
// the selected external transport interface.
// -----------------------------------------------------------------------------

module nce_axi_int8_top (
    input  logic         clk_i,
    input  logic         rst_ni,

    // AXI4-Lite write-address channel
    input  logic [31:0]  s_axi_awaddr_i,
    input  logic [2:0]   s_axi_awprot_i,
    input  logic         s_axi_awvalid_i,
    output logic         s_axi_awready_o,

    // AXI4-Lite write-data channel
    input  logic [31:0]  s_axi_wdata_i,
    input  logic [3:0]   s_axi_wstrb_i,
    input  logic         s_axi_wvalid_i,
    output logic         s_axi_wready_o,

    // AXI4-Lite write-response channel
    output logic [1:0]   s_axi_bresp_o,
    output logic         s_axi_bvalid_o,
    input  logic         s_axi_bready_i,

    // AXI4-Lite read-address channel
    input  logic [31:0]  s_axi_araddr_i,
    input  logic [2:0]   s_axi_arprot_i,
    input  logic         s_axi_arvalid_i,
    output logic         s_axi_arready_o,

    // AXI4-Lite read-data channel
    output logic [31:0]  s_axi_rdata_o,
    output logic [1:0]   s_axi_rresp_o,
    output logic         s_axi_rvalid_o,
    input  logic         s_axi_rready_i
);

    // -------------------------------------------------------------------------
    // AXI frontend to CSR backend
    // -------------------------------------------------------------------------

    logic        backend_write_valid;
    logic        backend_write_ready;
    logic [31:0] backend_write_addr;
    logic [31:0] backend_write_data;
    logic [3:0]  backend_write_strb;
    logic        backend_write_error;

    logic        backend_read_valid;
    logic        backend_read_ready;
    logic [31:0] backend_read_addr;
    logic [31:0] backend_read_data;
    logic        backend_read_error;

    // -------------------------------------------------------------------------
    // CSR backend to command core
    // -------------------------------------------------------------------------

    logic register_clear;
    logic accumulator_clear;

    logic         vector_write_enable;
    logic [3:0]   vector_write_addr;
    logic [7:0]   vector_write_lane_enable;
    logic [255:0] vector_write_data;

    logic         matrix_write_enable;
    logic [3:0]   matrix_write_addr;
    logic [7:0]   matrix_write_lane_enable;
    logic [255:0] matrix_write_data;

    logic       cmd_valid;
    logic       cmd_ready;
    logic [3:0] cmd_opcode;
    logic [1:0] cmd_precision;
    logic [3:0] cmd_vector_source_addr;
    logic [3:0] cmd_matrix_source_addr;

    logic       cmd_accept;
    logic       cmd_error;
    logic [1:0] cmd_error_code;
    logic       execute_issue;
    logic       operand_valid;

    // -------------------------------------------------------------------------
    // Execution results
    // -------------------------------------------------------------------------

    logic [255:0] accumulator;
    logic         accumulator_valid;
    logic         accumulator_update;

    logic [7:0] lane_invalid;
    logic [7:0] lane_overflow;
    logic [7:0] lane_underflow;
    logic [7:0] lane_inexact;

    logic global_invalid;
    logic global_overflow;
    logic global_underflow;
    logic global_inexact;

    logic [15:0] vector_valid_mask;
    logic [15:0] matrix_valid_mask;

    // -------------------------------------------------------------------------
    // AXI4-Lite protocol frontend
    // -------------------------------------------------------------------------

    nce_axi4lite_frontend u_axi_frontend (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),

        .s_axi_awaddr_i      (s_axi_awaddr_i),
        .s_axi_awprot_i      (s_axi_awprot_i),
        .s_axi_awvalid_i     (s_axi_awvalid_i),
        .s_axi_awready_o     (s_axi_awready_o),

        .s_axi_wdata_i       (s_axi_wdata_i),
        .s_axi_wstrb_i       (s_axi_wstrb_i),
        .s_axi_wvalid_i      (s_axi_wvalid_i),
        .s_axi_wready_o      (s_axi_wready_o),

        .s_axi_bresp_o       (s_axi_bresp_o),
        .s_axi_bvalid_o      (s_axi_bvalid_o),
        .s_axi_bready_i      (s_axi_bready_i),

        .s_axi_araddr_i      (s_axi_araddr_i),
        .s_axi_arprot_i      (s_axi_arprot_i),
        .s_axi_arvalid_i     (s_axi_arvalid_i),
        .s_axi_arready_o     (s_axi_arready_o),

        .s_axi_rdata_o       (s_axi_rdata_o),
        .s_axi_rresp_o       (s_axi_rresp_o),
        .s_axi_rvalid_o      (s_axi_rvalid_o),
        .s_axi_rready_i      (s_axi_rready_i),

        .write_valid_o       (backend_write_valid),
        .write_ready_i       (backend_write_ready),
        .write_addr_o        (backend_write_addr),
        .write_prot_o        (),
        .write_data_o        (backend_write_data),
        .write_strb_o        (backend_write_strb),
        .write_error_i       (backend_write_error),

        .read_valid_o        (backend_read_valid),
        .read_ready_i        (backend_read_ready),
        .read_addr_o         (backend_read_addr),
        .read_prot_o         (),
        .read_data_i         (backend_read_data),
        .read_error_i        (backend_read_error)
    );

    // -------------------------------------------------------------------------
    // CSR, register staging and status backend
    // -------------------------------------------------------------------------

    nce_axi_csr_backend u_csr_backend (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .write_valid_i               (backend_write_valid),
        .write_ready_o               (backend_write_ready),
        .write_addr_i                (backend_write_addr),
        .write_data_i                (backend_write_data),
        .write_strb_i                (backend_write_strb),
        .write_error_o               (backend_write_error),

        .read_valid_i                (backend_read_valid),
        .read_ready_o                (backend_read_ready),
        .read_addr_i                 (backend_read_addr),
        .read_data_o                 (backend_read_data),
        .read_error_o                (backend_read_error),

        .register_clear_o            (register_clear),
        .accumulator_clear_o         (accumulator_clear),

        .vector_write_enable_o       (vector_write_enable),
        .vector_write_addr_o         (vector_write_addr),
        .vector_write_lane_enable_o  (vector_write_lane_enable),
        .vector_write_data_o         (vector_write_data),

        .matrix_write_enable_o       (matrix_write_enable),
        .matrix_write_addr_o         (matrix_write_addr),
        .matrix_write_lane_enable_o  (matrix_write_lane_enable),
        .matrix_write_data_o         (matrix_write_data),

        .cmd_valid_o                 (cmd_valid),
        .cmd_ready_i                 (cmd_ready),

        .cmd_opcode_o                (cmd_opcode),
        .cmd_precision_o             (cmd_precision),
        .cmd_vector_source_addr_o    (cmd_vector_source_addr),
        .cmd_matrix_source_addr_o    (cmd_matrix_source_addr),

        .cmd_accept_i                (cmd_accept),
        .cmd_error_i                 (cmd_error),
        .cmd_error_code_i            (cmd_error_code),
        .execute_issue_i             (execute_issue),
        .operand_valid_i             (operand_valid),

        .accumulator_i               (accumulator),
        .accumulator_valid_i         (accumulator_valid),
        .accumulator_update_i        (accumulator_update),

        .lane_invalid_i              (lane_invalid),
        .lane_overflow_i             (lane_overflow),
        .lane_underflow_i            (lane_underflow),
        .lane_inexact_i              (lane_inexact),

        .invalid_i                   (global_invalid),
        .overflow_i                  (global_overflow),
        .underflow_i                 (global_underflow),
        .inexact_i                   (global_inexact),

        .vector_valid_mask_i         (vector_valid_mask),
        .matrix_valid_mask_i         (matrix_valid_mask)
    );

    // -------------------------------------------------------------------------
    // Command-controlled compute core
    // -------------------------------------------------------------------------

    nce_int8_command_core u_command_core (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .register_clear_i            (register_clear),
        .accumulator_clear_i         (accumulator_clear),

        .vector_write_enable_i       (vector_write_enable),
        .vector_write_addr_i         (vector_write_addr),
        .vector_write_lane_enable_i  (vector_write_lane_enable),
        .vector_write_data_i         (vector_write_data),

        .matrix_write_enable_i       (matrix_write_enable),
        .matrix_write_addr_i         (matrix_write_addr),
        .matrix_write_lane_enable_i  (matrix_write_lane_enable),
        .matrix_write_data_i         (matrix_write_data),

        .cmd_valid_i                 (cmd_valid),
        .cmd_ready_o                 (cmd_ready),

        .cmd_opcode_i                (cmd_opcode),
        .cmd_precision_i             (cmd_precision),

        .vector_source_addr_i        (cmd_vector_source_addr),
        .matrix_source_addr_i        (cmd_matrix_source_addr),

        .cmd_accept_o                (cmd_accept),
        .cmd_error_o                 (cmd_error),
        .cmd_error_code_o            (cmd_error_code),
        .execute_issue_o             (execute_issue),
        .operand_valid_o             (operand_valid),

        .accumulator_o               (accumulator),
        .accumulator_valid_o         (accumulator_valid),
        .accumulator_update_o        (accumulator_update),

        .lane_invalid_o              (lane_invalid),
        .lane_overflow_o             (lane_overflow),
        .lane_underflow_o            (lane_underflow),
        .lane_inexact_o              (lane_inexact),

        .invalid_o                   (global_invalid),
        .overflow_o                  (global_overflow),
        .underflow_o                 (global_underflow),
        .inexact_o                   (global_inexact),

        .vector_valid_mask_o         (vector_valid_mask),
        .matrix_valid_mask_o         (matrix_valid_mask)
    );

endmodule

`default_nettype wire
