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
// AXI4-Lite controlled mixed-precision NCE top.
//
// Existing path:
//   AXI -> base CSR backend -> SIMD command core
//
// Native GEMM path:
//   AXI -> GEMM CSR extension -> autonomous 4x4 systolic GEMM
//
// Addresses 0x140 through 0x1D4 are routed to the systolic-GEMM extension.
// The established SIMD command/register path remains unchanged.
// -----------------------------------------------------------------------------

module nce_axi_mixed_precision_top (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic [31:0]  s_axi_awaddr_i,
    input  logic [2:0]   s_axi_awprot_i,
    input  logic         s_axi_awvalid_i,
    output logic         s_axi_awready_o,

    input  logic [31:0]  s_axi_wdata_i,
    input  logic [3:0]   s_axi_wstrb_i,
    input  logic         s_axi_wvalid_i,
    output logic         s_axi_wready_o,

    output logic [1:0]   s_axi_bresp_o,
    output logic         s_axi_bvalid_o,
    input  logic         s_axi_bready_i,

    input  logic [31:0]  s_axi_araddr_i,
    input  logic [2:0]   s_axi_arprot_i,
    input  logic         s_axi_arvalid_i,
    output logic         s_axi_arready_o,

    output logic [31:0]  s_axi_rdata_o,
    output logic [1:0]   s_axi_rresp_o,
    output logic         s_axi_rvalid_o,
    input  logic         s_axi_rready_i
);

    localparam logic [31:0] GEMM_CSR_FIRST =
        32'h0000_0140;

    localparam logic [31:0] GEMM_CSR_LAST =
        32'h0000_01D4;

    localparam logic [31:0] TILED_GEMM_CSR_FIRST =
        32'h0000_0200;

    localparam logic [31:0] TILED_GEMM_CSR_LAST =
        32'h0000_03FF;

    localparam logic [31:0] CONV_CSR_FIRST =
        32'h0000_0400;

    localparam logic [31:0] CONV_CSR_LAST =
        32'h0000_04FF;

    localparam logic [31:0] TENSOR_CSR_FIRST =
        32'h0000_0500;

    localparam logic [31:0] TENSOR_CSR_LAST =
        32'h0000_07FF;

    // -------------------------------------------------------------------------
    // AXI frontend backend request
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
    // Address routing
    // -------------------------------------------------------------------------

    logic gemm_write_select;
    logic gemm_read_select;

    logic tiled_gemm_write_select;
    logic tiled_gemm_read_select;

    logic conv_write_select;
    logic conv_read_select;

    logic tensor_write_select;
    logic tensor_read_select;

    logic base_write_ready;
    logic base_write_error;
    logic base_read_ready;
    logic [31:0] base_read_data;
    logic base_read_error;

    logic gemm_write_ready;
    logic gemm_write_error;
    logic gemm_read_ready;
    logic [31:0] gemm_read_data;
    logic gemm_read_error;

    logic tiled_gemm_write_ready;
    logic tiled_gemm_write_error;
    logic tiled_gemm_read_ready;
    logic [31:0] tiled_gemm_read_data;
    logic tiled_gemm_read_error;

    logic conv_write_ready;
    logic conv_write_error;
    logic conv_read_ready;
    logic [31:0] conv_read_data;
    logic conv_read_error;

    logic tensor_write_ready;
    logic tensor_write_error;
    logic tensor_read_ready;
    logic [31:0] tensor_read_data;
    logic tensor_read_error;

    assign gemm_write_select =
        (backend_write_addr >= GEMM_CSR_FIRST) &&
        (backend_write_addr <= GEMM_CSR_LAST);

    assign gemm_read_select =
        (backend_read_addr >= GEMM_CSR_FIRST) &&
        (backend_read_addr <= GEMM_CSR_LAST);

    assign tiled_gemm_write_select =
        (backend_write_addr >= TILED_GEMM_CSR_FIRST) &&
        (backend_write_addr <= TILED_GEMM_CSR_LAST);

    assign tiled_gemm_read_select =
        (backend_read_addr >= TILED_GEMM_CSR_FIRST) &&
        (backend_read_addr <= TILED_GEMM_CSR_LAST);

    assign conv_write_select =
        (backend_write_addr >= CONV_CSR_FIRST) &&
        (backend_write_addr <= CONV_CSR_LAST);

    assign conv_read_select =
        (backend_read_addr >= CONV_CSR_FIRST) &&
        (backend_read_addr <= CONV_CSR_LAST);

    assign tensor_write_select =
        (backend_write_addr >= TENSOR_CSR_FIRST) &&
        (backend_write_addr <= TENSOR_CSR_LAST);

    assign tensor_read_select =
        (backend_read_addr >= TENSOR_CSR_FIRST) &&
        (backend_read_addr <= TENSOR_CSR_LAST);

    assign backend_write_ready =
        tensor_write_select
        ? tensor_write_ready
        : conv_write_select
          ? conv_write_ready
          : tiled_gemm_write_select
            ? tiled_gemm_write_ready
            : gemm_write_select
              ? gemm_write_ready
              : base_write_ready;

    assign backend_write_error =
        tensor_write_select
        ? tensor_write_error
        : conv_write_select
          ? conv_write_error
          : tiled_gemm_write_select
            ? tiled_gemm_write_error
            : gemm_write_select
              ? gemm_write_error
              : base_write_error;

    assign backend_read_ready =
        tensor_read_select
        ? tensor_read_ready
        : conv_read_select
          ? conv_read_ready
          : tiled_gemm_read_select
            ? tiled_gemm_read_ready
            : gemm_read_select
              ? gemm_read_ready
              : base_read_ready;

    assign backend_read_data =
        tensor_read_select
        ? tensor_read_data
        : conv_read_select
          ? conv_read_data
          : tiled_gemm_read_select
            ? tiled_gemm_read_data
            : gemm_read_select
              ? gemm_read_data
              : base_read_data;

    assign backend_read_error =
        tensor_read_select
        ? tensor_read_error
        : conv_read_select
          ? conv_read_error
          : tiled_gemm_read_select
            ? tiled_gemm_read_error
            : gemm_read_select
              ? gemm_read_error
              : base_read_error;

    // -------------------------------------------------------------------------
    // Existing SIMD command path
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
    // Systolic GEMM path
    // -------------------------------------------------------------------------

    logic gemm_clear;

    logic        gemm_a_write_enable;
    logic [3:0]  gemm_a_write_addr;
    logic [31:0] gemm_a_write_data;

    logic        gemm_b_write_enable;
    logic [3:0]  gemm_b_write_addr;
    logic [31:0] gemm_b_write_data;

    logic       gemm_start;
    logic       gemm_start_ready;
    logic [1:0] gemm_precision;
    logic [2:0] gemm_k_count;
    logic       gemm_accumulate;

    logic       gemm_busy;
    logic       gemm_done;
    logic       gemm_error;
    logic [2:0] gemm_error_code;

    logic [3:0] gemm_wavefront_cycle;

    logic [15:0] gemm_a_valid_mask;
    logic [15:0] gemm_b_valid_mask;

    logic [511:0] gemm_accumulator;
    logic [15:0]  gemm_accumulator_valid;
    logic [15:0]  gemm_accumulator_update;

    logic [15:0] gemm_mac_fire_mask;

    logic [15:0] gemm_invalid;
    logic [15:0] gemm_overflow;
    logic [15:0] gemm_underflow;
    logic [15:0] gemm_inexact;

    // -------------------------------------------------------------------------
    // Autonomous 8x8 tiled-GEMM path
    // -------------------------------------------------------------------------

    logic tiled_gemm_clear;

    logic        tiled_gemm_a_write_enable;
    logic [5:0]  tiled_gemm_a_write_addr;
    logic [31:0] tiled_gemm_a_write_data;

    logic        tiled_gemm_b_write_enable;
    logic [5:0]  tiled_gemm_b_write_addr;
    logic [31:0] tiled_gemm_b_write_data;

    logic       tiled_gemm_start;
    logic       tiled_gemm_start_ready;
    logic [1:0] tiled_gemm_precision;
    logic [3:0] tiled_gemm_k_token_count;

    logic       tiled_gemm_busy;
    logic       tiled_gemm_done;
    logic       tiled_gemm_error;
    logic [2:0] tiled_gemm_error_code;

    logic tiled_gemm_m_tile;
    logic tiled_gemm_n_tile;
    logic tiled_gemm_k_tile;

    logic [63:0] tiled_gemm_a_valid_mask;
    logic [63:0] tiled_gemm_b_valid_mask;

    logic [2047:0] tiled_gemm_accumulator;
    logic [63:0]   tiled_gemm_accumulator_valid;

    logic [63:0] tiled_gemm_invalid;
    logic [63:0] tiled_gemm_overflow;
    logic [63:0] tiled_gemm_underflow;
    logic [63:0] tiled_gemm_inexact;

    // -------------------------------------------------------------------------
    // Fixed 4x4-input, 3x3 valid INT8 convolution path
    // -------------------------------------------------------------------------

    logic conv_clear;

    logic       conv_pixel_write_enable;
    logic [3:0] conv_pixel_write_addr;
    logic [7:0] conv_pixel_write_data;

    logic       conv_kernel_write_enable;
    logic [3:0] conv_kernel_write_addr;
    logic [7:0] conv_kernel_write_data;

    logic conv_start;
    logic conv_start_ready;

    logic       conv_busy;
    logic       conv_done;
    logic       conv_error;
    logic [2:0] conv_error_code;

    logic [15:0] conv_pixel_valid_mask;
    logic [8:0]  conv_kernel_valid_mask;

    logic [127:0] conv_result;
    logic [3:0]   conv_result_valid;

    logic [3:0] conv_invalid;
    logic [3:0] conv_overflow;
    logic [3:0] conv_underflow;
    logic [3:0] conv_inexact;

    // Convolution lowering -> tiled-client mux.
    logic conv_gemm_available;
    logic conv_gemm_clear;

    logic        conv_gemm_a_write_enable;
    logic [5:0]  conv_gemm_a_write_addr;
    logic [31:0] conv_gemm_a_write_data;

    logic        conv_gemm_b_write_enable;
    logic [5:0]  conv_gemm_b_write_addr;
    logic [31:0] conv_gemm_b_write_data;

    logic       conv_gemm_start;
    logic       conv_gemm_start_ready;
    logic [1:0] conv_gemm_precision;
    logic [3:0] conv_gemm_k_token_count;

    logic conv_gemm_done;
    logic conv_gemm_error;

    logic [2047:0] conv_gemm_accumulator;
    logic [63:0]   conv_gemm_accumulator_valid;

    logic [63:0] conv_gemm_invalid;
    logic [63:0] conv_gemm_overflow;
    logic [63:0] conv_gemm_underflow;
    logic [63:0] conv_gemm_inexact;

    logic conv_claim;
    logic conv_release;

    // Tiled-client mux -> existing 8x8 tiled controller.
    logic tiled_client_clear;

    logic        tiled_client_a_write_enable;
    logic [5:0]  tiled_client_a_write_addr;
    logic [31:0] tiled_client_a_write_data;

    logic        tiled_client_b_write_enable;
    logic [5:0]  tiled_client_b_write_addr;
    logic [31:0] tiled_client_b_write_data;

    logic       tiled_client_start;
    logic       tiled_client_start_ready;
    logic [1:0] tiled_client_precision;
    logic [3:0] tiled_client_k_token_count;

    logic       tiled_client_busy;
    logic       tiled_client_done;
    logic       tiled_client_error;
    logic [2:0] tiled_client_error_code;

    logic tiled_client_m_tile;
    logic tiled_client_n_tile;
    logic tiled_client_k_tile;

    logic [63:0] tiled_client_a_valid_mask;
    logic [63:0] tiled_client_b_valid_mask;

    logic [2047:0] tiled_client_accumulator;
    logic [63:0]   tiled_client_accumulator_valid;

    logic [63:0] tiled_client_invalid;
    logic [63:0] tiled_client_overflow;
    logic [63:0] tiled_client_underflow;
    logic [63:0] tiled_client_inexact;

    // -------------------------------------------------------------------------
    // Tiled-controller <-> shared physical-engine interface
    // -------------------------------------------------------------------------

    logic tiled_engine_available;

    logic tiled_engine_clear;

    logic        tiled_engine_a_write_enable;
    logic [3:0]  tiled_engine_a_write_addr;
    logic [31:0] tiled_engine_a_write_data;

    logic        tiled_engine_b_write_enable;
    logic [3:0]  tiled_engine_b_write_addr;
    logic [31:0] tiled_engine_b_write_data;

    logic       tiled_engine_start;
    logic       tiled_engine_start_ready;

    logic [1:0] tiled_engine_precision;
    logic [2:0] tiled_engine_k_count;
    logic       tiled_engine_accumulate;

    logic       tiled_engine_busy;
    logic       tiled_engine_done;
    logic       tiled_engine_error;
    logic [2:0] tiled_engine_error_code;

    logic [511:0] tiled_engine_accumulator;
    logic [15:0]  tiled_engine_accumulator_valid;

    logic [15:0] tiled_engine_invalid;
    logic [15:0] tiled_engine_overflow;
    logic [15:0] tiled_engine_underflow;
    logic [15:0] tiled_engine_inexact;

    logic tiled_gemm_claim;
    logic tiled_gemm_release;

    // -------------------------------------------------------------------------
    // AXI tensor-memory and autonomous tensor-GEMM path
    // -------------------------------------------------------------------------

    logic tensor_clear;

    // CSR -> tensor loader.
    logic tensor_loader_start_cmd;
    logic tensor_loader_start_ready;

    logic tensor_memory_start;
    logic tensor_memory_start_ready;

    logic [1:0] tensor_loader_target;
    logic [9:0] tensor_loader_base_addr;
    logic [10:0] tensor_loader_word_count;

    logic tensor_stream_valid;
    logic tensor_stream_ready;
    logic tensor_stream_last;

    logic [127:0] tensor_stream_data;
    logic [15:0] tensor_stream_strb;

    logic tensor_memory_busy;
    logic tensor_memory_done;
    logic tensor_memory_error;
    logic [2:0] tensor_memory_error_code;

    logic [10:0] tensor_memory_words_written;
    logic [1:0] tensor_memory_active_target;

    // CSR -> autonomous tensor GEMM.
    logic tensor_gemm_start_cmd;
    logic tensor_gemm_start_ready;

    logic tensor_execution_start;
    logic tensor_execution_start_ready;

    logic [9:0] tensor_gemm_activation_base_addr;
    logic [9:0] tensor_gemm_weight_base_addr;
    logic [9:0] tensor_gemm_output_base_addr;

    logic [1:0] tensor_gemm_precision;
    logic [3:0] tensor_gemm_k_token_count;

    logic tensor_execution_busy;
    logic tensor_execution_compute_done;
    logic tensor_execution_done;
    logic tensor_execution_error;

    logic [1:0] tensor_execution_error_source;
    logic [2:0] tensor_execution_error_code;
    logic [2:0] tensor_execution_error_detail;

    logic [10:0] tensor_execution_words_loaded;
    logic [6:0] tensor_execution_words_written;

    logic [63:0] tensor_execution_result_valid;
    logic [63:0] tensor_execution_invalid;
    logic [63:0] tensor_execution_overflow;
    logic [63:0] tensor_execution_underflow;
    logic [63:0] tensor_execution_inexact;

    // CSR output-memory single-word read interface.
    logic [3:0] tensor_output_read_enable;
    logic [39:0] tensor_output_read_addr;

    logic [3:0] tensor_output_read_ready;
    logic [3:0] tensor_output_read_conflict;

    logic [127:0] tensor_output_read_data;
    logic [3:0] tensor_output_read_valid;

    // Tensor execution client <-> activation scratchpad.
    logic [3:0] tensor_activation_read_enable;
    logic [39:0] tensor_activation_read_addr;

    logic [3:0] tensor_activation_read_ready;
    logic [3:0] tensor_activation_read_conflict;

    logic [127:0] tensor_activation_read_data;
    logic [3:0] tensor_activation_read_valid;

    // Tensor execution client <-> weight scratchpad.
    logic [3:0] tensor_weight_read_enable;
    logic [39:0] tensor_weight_read_addr;

    logic [3:0] tensor_weight_read_ready;
    logic [3:0] tensor_weight_read_conflict;

    logic [127:0] tensor_weight_read_data;
    logic [3:0] tensor_weight_read_valid;

    // Tensor execution client -> output scratchpad.
    logic [3:0] tensor_output_write_enable;
    logic [39:0] tensor_output_write_addr;
    logic [127:0] tensor_output_write_data;
    logic [15:0] tensor_output_write_strb;

    logic [3:0] tensor_output_write_ready;
    logic [3:0] tensor_output_write_conflict;

    // Tensor execution client <-> three-client tiled mux.
    logic tensor_tiled_available;
    logic tensor_tiled_claim;
    logic tensor_tiled_release;
    logic tensor_tiled_clear;

    logic tensor_tiled_a_write_enable;
    logic [5:0] tensor_tiled_a_write_addr;
    logic [31:0] tensor_tiled_a_write_data;

    logic tensor_tiled_b_write_enable;
    logic [5:0] tensor_tiled_b_write_addr;
    logic [31:0] tensor_tiled_b_write_data;

    logic tensor_tiled_start;
    logic tensor_tiled_start_ready;

    logic [1:0] tensor_tiled_precision;
    logic [3:0] tensor_tiled_k_token_count;

    logic tensor_tiled_busy;
    logic tensor_tiled_done;
    logic tensor_tiled_error;
    logic [2:0] tensor_tiled_error_code;

    logic [2047:0] tensor_tiled_accumulator;
    logic [63:0] tensor_tiled_accumulator_valid;

    logic [63:0] tensor_tiled_invalid;
    logic [63:0] tensor_tiled_overflow;
    logic [63:0] tensor_tiled_underflow;
    logic [63:0] tensor_tiled_inexact;

    // Tensor loading and tensor execution share the tensor-memory subsystem.
    // They therefore cannot begin concurrently. Other compute clients may
    // continue using the shared systolic engine while tensor loading proceeds.
    assign tensor_loader_start_ready =
        tensor_memory_start_ready &&
        !tensor_execution_busy;

    assign tensor_gemm_start_ready =
        tensor_execution_start_ready &&
        !tensor_memory_busy;

    assign tensor_memory_start =
        tensor_loader_start_cmd &&
        tensor_loader_start_ready;

    assign tensor_execution_start =
        tensor_gemm_start_cmd &&
        tensor_gemm_start_ready;

    // -------------------------------------------------------------------------
    // AXI4-Lite frontend
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
    // Existing base CSR backend
    // -------------------------------------------------------------------------

    nce_axi_csr_backend u_csr_backend (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .write_valid_i               (
            backend_write_valid &&
            !gemm_write_select &&
            !tiled_gemm_write_select &&
            !conv_write_select &&
            !tensor_write_select
        ),
        .write_ready_o               (base_write_ready),
        .write_addr_i                (backend_write_addr),
        .write_data_i                (backend_write_data),
        .write_strb_i                (backend_write_strb),
        .write_error_o               (base_write_error),

        .read_valid_i                (
            backend_read_valid &&
            !gemm_read_select &&
            !tiled_gemm_read_select &&
            !conv_read_select &&
            !tensor_read_select
        ),
        .read_ready_o                (base_read_ready),
        .read_addr_i                 (backend_read_addr),
        .read_data_o                 (base_read_data),
        .read_error_o                (base_read_error),

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
    // Systolic-GEMM CSR extension
    // -------------------------------------------------------------------------

    nce_axi_systolic_gemm_csr u_gemm_csr (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .write_valid_i               (
            backend_write_valid &&
            gemm_write_select
        ),
        .write_ready_o               (gemm_write_ready),
        .write_addr_i                (backend_write_addr),
        .write_data_i                (backend_write_data),
        .write_strb_i                (backend_write_strb),
        .write_error_o               (gemm_write_error),

        .read_valid_i                (
            backend_read_valid &&
            gemm_read_select
        ),
        .read_ready_o                (gemm_read_ready),
        .read_addr_i                 (backend_read_addr),
        .read_data_o                 (gemm_read_data),
        .read_error_o                (gemm_read_error),

        .gemm_clear_o                (gemm_clear),

        .gemm_a_write_enable_o       (gemm_a_write_enable),
        .gemm_a_write_addr_o         (gemm_a_write_addr),
        .gemm_a_write_data_o         (gemm_a_write_data),

        .gemm_b_write_enable_o       (gemm_b_write_enable),
        .gemm_b_write_addr_o         (gemm_b_write_addr),
        .gemm_b_write_data_o         (gemm_b_write_data),

        .gemm_start_o                (gemm_start),
        .gemm_start_ready_i          (gemm_start_ready),

        .gemm_precision_o            (gemm_precision),
        .gemm_k_count_o              (gemm_k_count),
        .gemm_accumulate_o           (gemm_accumulate),

        .gemm_busy_i                 (gemm_busy),
        .gemm_done_i                 (gemm_done),
        .gemm_error_i                (gemm_error),
        .gemm_error_code_i           (gemm_error_code),

        .gemm_wavefront_cycle_i      (gemm_wavefront_cycle),

        .gemm_a_valid_mask_i         (gemm_a_valid_mask),
        .gemm_b_valid_mask_i         (gemm_b_valid_mask),

        .gemm_accumulator_i          (gemm_accumulator),
        .gemm_accumulator_valid_i    (gemm_accumulator_valid),
        .gemm_accumulator_update_i   (gemm_accumulator_update),

        .gemm_mac_fire_mask_i        (gemm_mac_fire_mask),

        .gemm_invalid_i              (gemm_invalid),
        .gemm_overflow_i             (gemm_overflow),
        .gemm_underflow_i            (gemm_underflow),
        .gemm_inexact_i              (gemm_inexact)
    );

    // -------------------------------------------------------------------------
    // Autonomous 8x8 tiled-GEMM CSR extension
    // -------------------------------------------------------------------------

    nce_axi_tiled_gemm_csr u_tiled_gemm_csr (
        .clk_i                         (clk_i),
        .rst_ni                        (rst_ni),

        .write_valid_i                 (
            backend_write_valid &&
            tiled_gemm_write_select
        ),
        .write_ready_o                 (tiled_gemm_write_ready),
        .write_addr_i                  (backend_write_addr),
        .write_data_i                  (backend_write_data),
        .write_strb_i                  (backend_write_strb),
        .write_error_o                 (tiled_gemm_write_error),

        .read_valid_i                  (
            backend_read_valid &&
            tiled_gemm_read_select
        ),
        .read_ready_o                  (tiled_gemm_read_ready),
        .read_addr_i                   (backend_read_addr),
        .read_data_o                   (tiled_gemm_read_data),
        .read_error_o                  (tiled_gemm_read_error),

        .tiled_clear_o                 (tiled_gemm_clear),

        .tiled_a_write_enable_o        (tiled_gemm_a_write_enable),
        .tiled_a_write_addr_o          (tiled_gemm_a_write_addr),
        .tiled_a_write_data_o          (tiled_gemm_a_write_data),

        .tiled_b_write_enable_o        (tiled_gemm_b_write_enable),
        .tiled_b_write_addr_o          (tiled_gemm_b_write_addr),
        .tiled_b_write_data_o          (tiled_gemm_b_write_data),

        .tiled_start_o                 (tiled_gemm_start),
        .tiled_start_ready_i           (tiled_gemm_start_ready),

        .tiled_precision_o             (tiled_gemm_precision),
        .tiled_k_token_count_o         (tiled_gemm_k_token_count),

        .tiled_busy_i                  (tiled_gemm_busy),
        .tiled_done_i                  (tiled_gemm_done),
        .tiled_error_i                 (tiled_gemm_error),
        .tiled_error_code_i            (tiled_gemm_error_code),

        .tiled_m_tile_i                (tiled_gemm_m_tile),
        .tiled_n_tile_i                (tiled_gemm_n_tile),
        .tiled_k_tile_i                (tiled_gemm_k_tile),

        .tiled_a_valid_mask_i          (tiled_gemm_a_valid_mask),
        .tiled_b_valid_mask_i          (tiled_gemm_b_valid_mask),

        .tiled_accumulator_i           (tiled_gemm_accumulator),
        .tiled_accumulator_valid_i     (
            tiled_gemm_accumulator_valid
        ),

        .tiled_invalid_i               (tiled_gemm_invalid),
        .tiled_overflow_i              (tiled_gemm_overflow),
        .tiled_underflow_i             (tiled_gemm_underflow),
        .tiled_inexact_i               (tiled_gemm_inexact)
    );

    // -------------------------------------------------------------------------
    // Fixed 3x3 convolution CSR extension
    // -------------------------------------------------------------------------

    nce_axi_conv3x3_csr u_conv_csr (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .write_valid_i          (
            backend_write_valid &&
            conv_write_select
        ),
        .write_ready_o          (conv_write_ready),
        .write_addr_i           (backend_write_addr),
        .write_data_i           (backend_write_data),
        .write_strb_i           (backend_write_strb),
        .write_error_o          (conv_write_error),

        .read_valid_i           (
            backend_read_valid &&
            conv_read_select
        ),
        .read_ready_o           (conv_read_ready),
        .read_addr_i            (backend_read_addr),
        .read_data_o            (conv_read_data),
        .read_error_o           (conv_read_error),

        .conv_clear_o           (conv_clear),

        .pixel_write_enable_o   (conv_pixel_write_enable),
        .pixel_write_addr_o     (conv_pixel_write_addr),
        .pixel_write_data_o     (conv_pixel_write_data),

        .kernel_write_enable_o  (conv_kernel_write_enable),
        .kernel_write_addr_o    (conv_kernel_write_addr),
        .kernel_write_data_o    (conv_kernel_write_data),

        .conv_start_o           (conv_start),
        .conv_start_ready_i     (conv_start_ready),

        .conv_busy_i            (conv_busy),
        .conv_done_i            (conv_done),
        .conv_error_i           (conv_error),
        .conv_error_code_i      (conv_error_code),

        .pixel_valid_mask_i     (conv_pixel_valid_mask),
        .kernel_valid_mask_i    (conv_kernel_valid_mask),

        .result_i               (conv_result),
        .result_valid_i         (conv_result_valid),

        .invalid_i              (conv_invalid),
        .overflow_i             (conv_overflow),
        .underflow_i            (conv_underflow),
        .inexact_i              (conv_inexact)
    );

    // -------------------------------------------------------------------------
    // Tensor-memory and autonomous tensor-GEMM CSR extension
    // -------------------------------------------------------------------------

    nce_axi_tensor_compute_csr u_tensor_compute_csr (
        .clk_i                          (clk_i),
        .rst_ni                         (rst_ni),

        .write_valid_i                  (
            backend_write_valid &&
            tensor_write_select
        ),

        .write_ready_o                  (tensor_write_ready),
        .write_addr_i                   (backend_write_addr),
        .write_data_i                   (backend_write_data),
        .write_strb_i                   (backend_write_strb),
        .write_error_o                  (tensor_write_error),

        .read_valid_i                   (
            backend_read_valid &&
            tensor_read_select
        ),

        .read_ready_o                   (tensor_read_ready),
        .read_addr_i                    (backend_read_addr),
        .read_data_o                    (tensor_read_data),
        .read_error_o                   (tensor_read_error),

        .tensor_clear_o                 (tensor_clear),

        .loader_start_o                 (tensor_loader_start_cmd),
        .loader_start_ready_i           (tensor_loader_start_ready),

        .loader_target_o                (tensor_loader_target),
        .loader_base_addr_o             (tensor_loader_base_addr),
        .loader_word_count_o            (tensor_loader_word_count),

        .stream_valid_o                 (tensor_stream_valid),
        .stream_ready_i                 (tensor_stream_ready),
        .stream_last_o                  (tensor_stream_last),
        .stream_data_o                  (tensor_stream_data),
        .stream_strb_o                  (tensor_stream_strb),

        .loader_busy_i                  (tensor_memory_busy),
        .loader_done_i                  (tensor_memory_done),
        .loader_error_i                 (tensor_memory_error),
        .loader_error_code_i            (tensor_memory_error_code),

        .loader_words_written_i         (
            tensor_memory_words_written
        ),

        .loader_active_target_i         (
            tensor_memory_active_target
        ),

        .gemm_start_o                   (tensor_gemm_start_cmd),
        .gemm_start_ready_i             (tensor_gemm_start_ready),

        .gemm_activation_base_addr_o    (
            tensor_gemm_activation_base_addr
        ),

        .gemm_weight_base_addr_o        (
            tensor_gemm_weight_base_addr
        ),

        .gemm_output_base_addr_o        (
            tensor_gemm_output_base_addr
        ),

        .gemm_precision_o               (tensor_gemm_precision),
        .gemm_k_token_count_o           (tensor_gemm_k_token_count),

        .gemm_busy_i                    (tensor_execution_busy),

        .gemm_compute_done_i            (
            tensor_execution_compute_done
        ),

        .gemm_done_i                    (tensor_execution_done),
        .gemm_error_i                   (tensor_execution_error),

        .gemm_error_source_i            (
            tensor_execution_error_source
        ),

        .gemm_error_code_i              (
            tensor_execution_error_code
        ),

        .gemm_error_detail_i            (
            tensor_execution_error_detail
        ),

        .gemm_words_loaded_i            (
            tensor_execution_words_loaded
        ),

        .gemm_words_written_i           (
            tensor_execution_words_written
        ),

        .gemm_result_valid_i            (
            tensor_execution_result_valid
        ),

        .gemm_invalid_i                 (tensor_execution_invalid),
        .gemm_overflow_i                (tensor_execution_overflow),
        .gemm_underflow_i               (tensor_execution_underflow),
        .gemm_inexact_i                 (tensor_execution_inexact),

        .output_read_enable_o           (tensor_output_read_enable),
        .output_read_addr_o             (tensor_output_read_addr),

        .output_read_ready_i            (tensor_output_read_ready),
        .output_read_conflict_i         (
            tensor_output_read_conflict
        ),

        .output_read_data_i             (tensor_output_read_data),
        .output_read_valid_i            (tensor_output_read_valid)
    );

    // -------------------------------------------------------------------------
    // Existing command-controlled SIMD core
    // -------------------------------------------------------------------------

    nce_mixed_precision_command_core u_command_core (
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

    // -------------------------------------------------------------------------
    // Convolution lowering controller
    // -------------------------------------------------------------------------

    // conv_start is a registered pulse emitted by the convolution CSR only
    // after its start command has passed the conv_start_ready qualification.
    // Using the pulse directly prevents ownership claim from feeding back
    // combinationally through backend availability and start-ready logic.
    assign conv_claim =
        conv_start;

    assign conv_release =
        conv_done ||
        conv_error ||
        conv_clear;

    nce_conv3x3_valid_4x4_int8_controller u_conv_controller (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .clear_i                  (conv_clear),

        .pixel_write_enable_i     (conv_pixel_write_enable),
        .pixel_write_addr_i       (conv_pixel_write_addr),
        .pixel_write_data_i       (conv_pixel_write_data),

        .kernel_write_enable_i    (conv_kernel_write_enable),
        .kernel_write_addr_i      (conv_kernel_write_addr),
        .kernel_write_data_i      (conv_kernel_write_data),

        .pixel_valid_mask_o       (conv_pixel_valid_mask),
        .kernel_valid_mask_o      (conv_kernel_valid_mask),

        .start_i                  (conv_start),
        .start_ready_o            (conv_start_ready),

        .busy_o                   (conv_busy),
        .done_o                   (conv_done),
        .error_o                  (conv_error),
        .error_code_o             (conv_error_code),

        .result_o                 (conv_result),
        .result_valid_o           (conv_result_valid),

        .invalid_o                (conv_invalid),
        .overflow_o               (conv_overflow),
        .underflow_o              (conv_underflow),
        .inexact_o                (conv_inexact),

        .gemm_available           (conv_gemm_available),
        .gemm_clear               (conv_gemm_clear),

        .gemm_a_write_enable      (conv_gemm_a_write_enable),
        .gemm_a_write_addr        (conv_gemm_a_write_addr),
        .gemm_a_write_data        (conv_gemm_a_write_data),

        .gemm_b_write_enable      (conv_gemm_b_write_enable),
        .gemm_b_write_addr        (conv_gemm_b_write_addr),
        .gemm_b_write_data        (conv_gemm_b_write_data),

        .gemm_start               (conv_gemm_start),
        .gemm_start_ready         (conv_gemm_start_ready),

        .gemm_precision           (conv_gemm_precision),
        .gemm_k_token_count       (conv_gemm_k_token_count),

        .gemm_done                (conv_gemm_done),
        .gemm_error               (conv_gemm_error),

        .gemm_accumulator         (conv_gemm_accumulator),
        .gemm_accumulator_valid   (conv_gemm_accumulator_valid),

        .gemm_invalid             (conv_gemm_invalid),
        .gemm_overflow            (conv_gemm_overflow),
        .gemm_underflow           (conv_gemm_underflow),
        .gemm_inexact             (conv_gemm_inexact)
    );

    // -------------------------------------------------------------------------
    // Physical activation, weight, and output tensor memories
    // -------------------------------------------------------------------------

    nce_tensor_memory_subsystem u_tensor_memory (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (tensor_clear),

        .start_i                     (tensor_memory_start),
        .start_ready_o               (tensor_memory_start_ready),

        .load_target_i               (tensor_loader_target),
        .base_addr_i                 (tensor_loader_base_addr),
        .word_count_i                (tensor_loader_word_count),

        .stream_valid_i              (tensor_stream_valid),
        .stream_ready_o              (tensor_stream_ready),
        .stream_last_i               (tensor_stream_last),
        .stream_data_i               (tensor_stream_data),
        .stream_strb_i               (tensor_stream_strb),

        .busy_o                      (tensor_memory_busy),
        .done_o                      (tensor_memory_done),
        .error_o                     (tensor_memory_error),
        .error_code_o                (tensor_memory_error_code),

        .words_written_o             (tensor_memory_words_written),
        .active_target_o             (tensor_memory_active_target),

        .activation_read_enable_i    (
            tensor_activation_read_enable
        ),

        .activation_read_addr_i      (tensor_activation_read_addr),
        .activation_read_ready_o     (tensor_activation_read_ready),

        .activation_read_conflict_o  (
            tensor_activation_read_conflict
        ),

        .activation_read_data_o      (tensor_activation_read_data),
        .activation_read_valid_o     (tensor_activation_read_valid),

        .weight_read_enable_i        (tensor_weight_read_enable),
        .weight_read_addr_i          (tensor_weight_read_addr),
        .weight_read_ready_o         (tensor_weight_read_ready),

        .weight_read_conflict_o      (
            tensor_weight_read_conflict
        ),

        .weight_read_data_o          (tensor_weight_read_data),
        .weight_read_valid_o         (tensor_weight_read_valid),

        .output_read_enable_i        (tensor_output_read_enable),
        .output_read_addr_i          (tensor_output_read_addr),
        .output_read_ready_o         (tensor_output_read_ready),

        .output_read_conflict_o      (
            tensor_output_read_conflict
        ),

        .output_read_data_o          (tensor_output_read_data),
        .output_read_valid_o         (tensor_output_read_valid),

        .output_write_enable_i       (tensor_output_write_enable),
        .output_write_addr_i         (tensor_output_write_addr),
        .output_write_data_i         (tensor_output_write_data),
        .output_write_strb_i         (tensor_output_write_strb),
        .output_write_ready_o        (tensor_output_write_ready),

        .output_write_conflict_o     (
            tensor_output_write_conflict
        )
    );

    // -------------------------------------------------------------------------
    // Tensor memory-to-existing-shared-tiled-controller client
    // -------------------------------------------------------------------------

    nce_tensor_gemm_shared_client u_tensor_gemm_shared_client (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (tensor_clear),

        .start_i                     (tensor_execution_start),
        .start_ready_o               (tensor_execution_start_ready),

        .activation_base_addr_i      (
            tensor_gemm_activation_base_addr
        ),

        .weight_base_addr_i          (tensor_gemm_weight_base_addr),
        .output_base_addr_i          (tensor_gemm_output_base_addr),

        .precision_i                 (tensor_gemm_precision),
        .k_token_count_i             (tensor_gemm_k_token_count),

        .activation_read_enable_o    (
            tensor_activation_read_enable
        ),

        .activation_read_addr_o      (tensor_activation_read_addr),
        .activation_read_ready_i     (tensor_activation_read_ready),

        .activation_read_conflict_i  (
            tensor_activation_read_conflict
        ),

        .activation_read_data_i      (tensor_activation_read_data),
        .activation_read_valid_i     (tensor_activation_read_valid),

        .weight_read_enable_o        (tensor_weight_read_enable),
        .weight_read_addr_o          (tensor_weight_read_addr),
        .weight_read_ready_i         (tensor_weight_read_ready),

        .weight_read_conflict_i      (
            tensor_weight_read_conflict
        ),

        .weight_read_data_i          (tensor_weight_read_data),
        .weight_read_valid_i         (tensor_weight_read_valid),

        .output_write_enable_o       (tensor_output_write_enable),
        .output_write_addr_o         (tensor_output_write_addr),
        .output_write_data_o         (tensor_output_write_data),
        .output_write_strb_o         (tensor_output_write_strb),
        .output_write_ready_i        (tensor_output_write_ready),

        .output_write_conflict_i     (
            tensor_output_write_conflict
        ),

        .tiled_available_i           (tensor_tiled_available),
        .tiled_claim_o               (tensor_tiled_claim),
        .tiled_release_o             (tensor_tiled_release),
        .tiled_clear_o               (tensor_tiled_clear),

        .tiled_a_write_enable_o      (
            tensor_tiled_a_write_enable
        ),

        .tiled_a_write_addr_o        (tensor_tiled_a_write_addr),
        .tiled_a_write_data_o        (tensor_tiled_a_write_data),

        .tiled_b_write_enable_o      (
            tensor_tiled_b_write_enable
        ),

        .tiled_b_write_addr_o        (tensor_tiled_b_write_addr),
        .tiled_b_write_data_o        (tensor_tiled_b_write_data),

        .tiled_start_o               (tensor_tiled_start),
        .tiled_start_ready_i         (tensor_tiled_start_ready),

        .tiled_precision_o           (tensor_tiled_precision),

        .tiled_k_token_count_o       (
            tensor_tiled_k_token_count
        ),

        .tiled_busy_i                (tensor_tiled_busy),
        .tiled_done_i                (tensor_tiled_done),
        .tiled_error_i               (tensor_tiled_error),
        .tiled_error_code_i          (tensor_tiled_error_code),

        // These fields are intentionally unused by the tensor feeder/writer.
        .tiled_m_tile_i              (1'b0),
        .tiled_n_tile_i              (1'b0),
        .tiled_k_tile_i              (1'b0),

        .tiled_a_valid_mask_i        (64'd0),
        .tiled_b_valid_mask_i        (64'd0),

        .tiled_accumulator_i         (tensor_tiled_accumulator),

        .tiled_accumulator_valid_i   (
            tensor_tiled_accumulator_valid
        ),

        .tiled_invalid_i             (tensor_tiled_invalid),
        .tiled_overflow_i            (tensor_tiled_overflow),
        .tiled_underflow_i           (tensor_tiled_underflow),
        .tiled_inexact_i             (tensor_tiled_inexact),

        .busy_o                      (tensor_execution_busy),

        .compute_done_o              (
            tensor_execution_compute_done
        ),

        .done_o                      (tensor_execution_done),
        .error_o                     (tensor_execution_error),

        .error_source_o              (
            tensor_execution_error_source
        ),

        .error_code_o                (tensor_execution_error_code),

        .error_detail_o              (
            tensor_execution_error_detail
        ),

        .words_loaded_o              (
            tensor_execution_words_loaded
        ),

        .words_written_o             (
            tensor_execution_words_written
        ),

        // Full results are persisted in output memory and read through the CSR.
        .result_data_o               (),

        .result_valid_o              (
            tensor_execution_result_valid
        ),

        .invalid_o                   (tensor_execution_invalid),
        .overflow_o                  (tensor_execution_overflow),
        .underflow_o                 (tensor_execution_underflow),
        .inexact_o                   (tensor_execution_inexact)
    );

    // -------------------------------------------------------------------------
    // Software-tiled, convolution, and tensor ownership mux
    // -------------------------------------------------------------------------

    nce_tiled_gemm_client_mux u_tiled_client_mux (
        .clk_i                              (clk_i),
        .rst_ni                             (rst_ni),

        .software_clear_i                   (tiled_gemm_clear),

        .software_a_write_enable_i          (
            tiled_gemm_a_write_enable
        ),
        .software_a_write_addr_i            (tiled_gemm_a_write_addr),
        .software_a_write_data_i            (tiled_gemm_a_write_data),

        .software_b_write_enable_i          (
            tiled_gemm_b_write_enable
        ),
        .software_b_write_addr_i            (tiled_gemm_b_write_addr),
        .software_b_write_data_i            (tiled_gemm_b_write_data),

        .software_start_i                   (tiled_gemm_start),
        .software_start_ready_o             (tiled_gemm_start_ready),

        .software_precision_i               (tiled_gemm_precision),
        .software_k_token_count_i           (
            tiled_gemm_k_token_count
        ),

        .software_busy_o                    (tiled_gemm_busy),
        .software_done_o                    (tiled_gemm_done),
        .software_error_o                   (tiled_gemm_error),
        .software_error_code_o              (tiled_gemm_error_code),

        .software_m_tile_o                  (tiled_gemm_m_tile),
        .software_n_tile_o                  (tiled_gemm_n_tile),
        .software_k_tile_o                  (tiled_gemm_k_tile),

        .software_a_valid_mask_o            (tiled_gemm_a_valid_mask),
        .software_b_valid_mask_o            (tiled_gemm_b_valid_mask),

        .software_accumulator_o             (tiled_gemm_accumulator),
        .software_accumulator_valid_o       (
            tiled_gemm_accumulator_valid
        ),

        .software_invalid_o                 (tiled_gemm_invalid),
        .software_overflow_o                (tiled_gemm_overflow),
        .software_underflow_o               (tiled_gemm_underflow),
        .software_inexact_o                 (tiled_gemm_inexact),

        .convolution_claim_i                (conv_claim),
        .convolution_release_i              (conv_release),
        .convolution_available_o            (conv_gemm_available),

        .convolution_clear_i                (conv_gemm_clear),

        .convolution_a_write_enable_i       (
            conv_gemm_a_write_enable
        ),
        .convolution_a_write_addr_i         (conv_gemm_a_write_addr),
        .convolution_a_write_data_i         (conv_gemm_a_write_data),

        .convolution_b_write_enable_i       (
            conv_gemm_b_write_enable
        ),
        .convolution_b_write_addr_i         (conv_gemm_b_write_addr),
        .convolution_b_write_data_i         (conv_gemm_b_write_data),

        .convolution_start_i                (conv_gemm_start),
        .convolution_start_ready_o          (conv_gemm_start_ready),

        .convolution_precision_i            (conv_gemm_precision),
        .convolution_k_token_count_i        (
            conv_gemm_k_token_count
        ),

        .convolution_busy_o                 (),
        .convolution_done_o                 (conv_gemm_done),
        .convolution_error_o                (conv_gemm_error),
        .convolution_error_code_o           (),

        .convolution_accumulator_o          (conv_gemm_accumulator),
        .convolution_accumulator_valid_o    (
            conv_gemm_accumulator_valid
        ),

        .convolution_invalid_o              (conv_gemm_invalid),
        .convolution_overflow_o             (conv_gemm_overflow),
        .convolution_underflow_o            (conv_gemm_underflow),
        .convolution_inexact_o              (conv_gemm_inexact),

        .tensor_claim_i                     (tensor_tiled_claim),
        .tensor_release_i                   (tensor_tiled_release),
        .tensor_available_o                 (tensor_tiled_available),

        .tensor_clear_i                     (tensor_tiled_clear),

        .tensor_a_write_enable_i            (
            tensor_tiled_a_write_enable
        ),

        .tensor_a_write_addr_i              (tensor_tiled_a_write_addr),
        .tensor_a_write_data_i              (tensor_tiled_a_write_data),

        .tensor_b_write_enable_i            (
            tensor_tiled_b_write_enable
        ),

        .tensor_b_write_addr_i              (tensor_tiled_b_write_addr),
        .tensor_b_write_data_i              (tensor_tiled_b_write_data),

        .tensor_start_i                     (tensor_tiled_start),
        .tensor_start_ready_o               (tensor_tiled_start_ready),

        .tensor_precision_i                 (tensor_tiled_precision),

        .tensor_k_token_count_i             (
            tensor_tiled_k_token_count
        ),

        .tensor_busy_o                      (tensor_tiled_busy),
        .tensor_done_o                      (tensor_tiled_done),
        .tensor_error_o                     (tensor_tiled_error),
        .tensor_error_code_o                (tensor_tiled_error_code),

        .tensor_accumulator_o               (tensor_tiled_accumulator),

        .tensor_accumulator_valid_o         (
            tensor_tiled_accumulator_valid
        ),

        .tensor_invalid_o                   (tensor_tiled_invalid),
        .tensor_overflow_o                  (tensor_tiled_overflow),
        .tensor_underflow_o                 (tensor_tiled_underflow),
        .tensor_inexact_o                   (tensor_tiled_inexact),

        .shared_clear_o                     (tiled_client_clear),

        .shared_a_write_enable_o            (
            tiled_client_a_write_enable
        ),
        .shared_a_write_addr_o              (tiled_client_a_write_addr),
        .shared_a_write_data_o              (tiled_client_a_write_data),

        .shared_b_write_enable_o            (
            tiled_client_b_write_enable
        ),
        .shared_b_write_addr_o              (tiled_client_b_write_addr),
        .shared_b_write_data_o              (tiled_client_b_write_data),

        .shared_start_o                     (tiled_client_start),
        .shared_start_ready_i               (tiled_client_start_ready),

        .shared_precision_o                 (tiled_client_precision),
        .shared_k_token_count_o             (
            tiled_client_k_token_count
        ),

        .shared_busy_i                      (tiled_client_busy),
        .shared_done_i                      (tiled_client_done),
        .shared_error_i                     (tiled_client_error),
        .shared_error_code_i                (tiled_client_error_code),

        .shared_m_tile_i                    (tiled_client_m_tile),
        .shared_n_tile_i                    (tiled_client_n_tile),
        .shared_k_tile_i                    (tiled_client_k_tile),

        .shared_a_valid_mask_i              (tiled_client_a_valid_mask),
        .shared_b_valid_mask_i              (tiled_client_b_valid_mask),

        .shared_accumulator_i               (tiled_client_accumulator),
        .shared_accumulator_valid_i         (
            tiled_client_accumulator_valid
        ),

        .shared_invalid_i                   (tiled_client_invalid),
        .shared_overflow_i                  (tiled_client_overflow),
        .shared_underflow_i                 (tiled_client_underflow),
        .shared_inexact_i                   (tiled_client_inexact),

        .owner_o                            ()
    );

    // -------------------------------------------------------------------------
    // Tiled 8x8 M/N/K traversal controller
    // -------------------------------------------------------------------------

    assign tiled_gemm_claim =
        tiled_client_start &&
        tiled_client_start_ready;

    assign tiled_gemm_release =
        tiled_client_done ||
        tiled_client_error ||
        tiled_client_clear;

    nce_tiled_gemm_8x8_controller u_tiled_gemm_controller (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (tiled_client_clear),

        .a_write_enable_i            (tiled_client_a_write_enable),
        .a_write_addr_i              (tiled_client_a_write_addr),
        .a_write_data_i              (tiled_client_a_write_data),

        .b_write_enable_i            (tiled_client_b_write_enable),
        .b_write_addr_i              (tiled_client_b_write_addr),
        .b_write_data_i              (tiled_client_b_write_data),

        .a_valid_mask_o              (tiled_client_a_valid_mask),
        .b_valid_mask_o              (tiled_client_b_valid_mask),

        .start_i                     (tiled_client_start),
        .start_ready_o               (tiled_client_start_ready),

        .precision_i                 (tiled_client_precision),
        .k_token_count_i             (tiled_client_k_token_count),

        .busy_o                      (tiled_client_busy),
        .done_o                      (tiled_client_done),
        .error_o                     (tiled_client_error),
        .error_code_o                (tiled_client_error_code),

        .m_tile_o                    (tiled_client_m_tile),
        .n_tile_o                    (tiled_client_n_tile),
        .k_tile_o                    (tiled_client_k_tile),

        .accumulator_o               (tiled_client_accumulator),
        .accumulator_valid_o         (tiled_client_accumulator_valid),

        .invalid_o                   (tiled_client_invalid),
        .overflow_o                  (tiled_client_overflow),
        .underflow_o                 (tiled_client_underflow),
        .inexact_o                   (tiled_client_inexact),

        .engine_available_i          (tiled_engine_available),

        .engine_clear_o              (tiled_engine_clear),

        .engine_a_write_enable_o     (tiled_engine_a_write_enable),
        .engine_a_write_addr_o       (tiled_engine_a_write_addr),
        .engine_a_write_data_o       (tiled_engine_a_write_data),

        .engine_b_write_enable_o     (tiled_engine_b_write_enable),
        .engine_b_write_addr_o       (tiled_engine_b_write_addr),
        .engine_b_write_data_o       (tiled_engine_b_write_data),

        .engine_start_o              (tiled_engine_start),
        .engine_start_ready_i        (tiled_engine_start_ready),

        .engine_precision_o          (tiled_engine_precision),
        .engine_k_count_o            (tiled_engine_k_count),
        .engine_accumulate_o         (tiled_engine_accumulate),

        .engine_busy_i               (tiled_engine_busy),
        .engine_done_i               (tiled_engine_done),
        .engine_error_i              (tiled_engine_error),
        .engine_error_code_i         (tiled_engine_error_code),

        .engine_accumulator_i        (tiled_engine_accumulator),
        .engine_accumulator_valid_i  (
            tiled_engine_accumulator_valid
        ),

        .engine_invalid_i            (tiled_engine_invalid),
        .engine_overflow_i           (tiled_engine_overflow),
        .engine_underflow_i          (tiled_engine_underflow),
        .engine_inexact_i            (tiled_engine_inexact)
    );

    // -------------------------------------------------------------------------
    // One shared physical 4x4 systolic GEMM
    // -------------------------------------------------------------------------

    nce_shared_systolic_gemm_4x4 u_shared_systolic_gemm (
        .clk_i                           (clk_i),
        .rst_ni                          (rst_ni),

        // Direct native-4x4 AXI client
        .direct_clear_i                  (gemm_clear),

        .direct_a_write_enable_i         (gemm_a_write_enable),
        .direct_a_write_addr_i           (gemm_a_write_addr),
        .direct_a_write_data_i           (gemm_a_write_data),

        .direct_b_write_enable_i         (gemm_b_write_enable),
        .direct_b_write_addr_i           (gemm_b_write_addr),
        .direct_b_write_data_i           (gemm_b_write_data),

        .direct_start_i                  (gemm_start),
        .direct_start_ready_o            (gemm_start_ready),

        .direct_precision_i              (gemm_precision),
        .direct_k_count_i                (gemm_k_count),
        .direct_accumulate_i             (gemm_accumulate),

        .direct_busy_o                   (gemm_busy),
        .direct_done_o                   (gemm_done),
        .direct_error_o                  (gemm_error),
        .direct_error_code_o             (gemm_error_code),

        .direct_wavefront_cycle_o        (gemm_wavefront_cycle),

        .direct_a_valid_mask_o           (gemm_a_valid_mask),
        .direct_b_valid_mask_o           (gemm_b_valid_mask),

        .direct_accumulator_o            (gemm_accumulator),
        .direct_accumulator_valid_o      (gemm_accumulator_valid),
        .direct_accumulator_update_o     (gemm_accumulator_update),

        .direct_mac_fire_mask_o          (gemm_mac_fire_mask),

        .direct_invalid_o                (gemm_invalid),
        .direct_overflow_o               (gemm_overflow),
        .direct_underflow_o              (gemm_underflow),
        .direct_inexact_o                (gemm_inexact),

        // Tiled-controller ownership
        .tiled_claim_i                   (tiled_gemm_claim),
        .tiled_release_i                 (tiled_gemm_release),
        .tiled_engine_available_o        (tiled_engine_available),

        // Tiled controller -> physical engine
        .tiled_engine_clear_i            (tiled_engine_clear),

        .tiled_engine_a_write_enable_i   (
            tiled_engine_a_write_enable
        ),
        .tiled_engine_a_write_addr_i     (tiled_engine_a_write_addr),
        .tiled_engine_a_write_data_i     (tiled_engine_a_write_data),

        .tiled_engine_b_write_enable_i   (
            tiled_engine_b_write_enable
        ),
        .tiled_engine_b_write_addr_i     (tiled_engine_b_write_addr),
        .tiled_engine_b_write_data_i     (tiled_engine_b_write_data),

        .tiled_engine_start_i            (tiled_engine_start),
        .tiled_engine_start_ready_o      (tiled_engine_start_ready),

        .tiled_engine_precision_i        (tiled_engine_precision),
        .tiled_engine_k_count_i          (tiled_engine_k_count),
        .tiled_engine_accumulate_i       (tiled_engine_accumulate),

        // Physical engine -> tiled controller
        .tiled_engine_busy_o             (tiled_engine_busy),
        .tiled_engine_done_o             (tiled_engine_done),
        .tiled_engine_error_o            (tiled_engine_error),
        .tiled_engine_error_code_o       (tiled_engine_error_code),

        .tiled_engine_accumulator_o      (tiled_engine_accumulator),
        .tiled_engine_accumulator_valid_o(
            tiled_engine_accumulator_valid
        ),

        .tiled_engine_invalid_o          (tiled_engine_invalid),
        .tiled_engine_overflow_o         (tiled_engine_overflow),
        .tiled_engine_underflow_o        (tiled_engine_underflow),
        .tiled_engine_inexact_o          (tiled_engine_inexact)
    );

endmodule

`default_nettype wire
