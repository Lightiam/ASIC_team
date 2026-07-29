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
// Shared-engine tensor compute subsystem.
//
// Integrates:
//
//   * 4 KB activation scratchpad
//   * 4 KB weight scratchpad
//   * 4 KB output/PSUM scratchpad
//   * shared 128-bit tensor loader
//   * autonomous tensor GEMM feeder and result writer
//   * three-client tiled-GEMM ownership mux
//   * one shared 8x8 tiled controller
//   * one shared physical 4x4 systolic engine
//   * conflict-safe four-lane FP32 result writeback
//
// Loader and GEMM commands are mutually exclusive in this integration to avoid
// software-visible read/write hazards. Output-memory reads remain available for
// result inspection through the external readback ports.
// -----------------------------------------------------------------------------

module nce_tensor_shared_compute_subsystem #(
    parameter int unsigned BANK_COUNT = 4,
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned PORT_COUNT = 4,

    parameter int unsigned BANK_INDEX_WIDTH =
        (BANK_COUNT <= 1)
        ? 1
        : $clog2(BANK_COUNT),

    parameter int unsigned BANK_ADDR_WIDTH =
        (WORDS_PER_BANK <= 1)
        ? 1
        : $clog2(WORDS_PER_BANK),

    parameter int unsigned FLAT_ADDR_WIDTH =
        BANK_INDEX_WIDTH + BANK_ADDR_WIDTH,

    parameter int unsigned TOTAL_WORDS =
        BANK_COUNT * WORDS_PER_BANK,

    parameter int unsigned WORD_COUNT_WIDTH =
        (TOTAL_WORDS <= 1)
        ? 1
        : $clog2(TOTAL_WORDS + 1),

    parameter int unsigned BYTE_COUNT =
        DATA_WIDTH / 8
) (
    input logic clk_i,
    input logic rst_ni,
    input logic clear_i,

    // -------------------------------------------------------------------------
    // Tensor loader command and 128-bit stream
    // -------------------------------------------------------------------------

    input  logic load_start_i,
    output logic load_start_ready_o,

    input logic [1:0] load_target_i,

    input logic [
        FLAT_ADDR_WIDTH-1:0
    ] load_base_addr_i,

    input logic [
        WORD_COUNT_WIDTH-1:0
    ] load_word_count_i,

    input  logic load_stream_valid_i,
    output logic load_stream_ready_o,
    input  logic load_stream_last_i,

    input logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] load_stream_data_i,

    input logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] load_stream_strb_i,

    output logic load_busy_o,
    output logic load_done_o,
    output logic load_error_o,
    output logic [2:0] load_error_code_o,

    output logic [
        WORD_COUNT_WIDTH-1:0
    ] load_words_written_o,

    output logic [1:0] load_active_target_o,

    // -------------------------------------------------------------------------
    // Autonomous tensor GEMM command
    // -------------------------------------------------------------------------

    input  logic gemm_start_i,
    output logic gemm_start_ready_o,

    input logic [
        FLAT_ADDR_WIDTH-1:0
    ] gemm_activation_base_addr_i,

    input logic [
        FLAT_ADDR_WIDTH-1:0
    ] gemm_weight_base_addr_i,

    input logic [
        FLAT_ADDR_WIDTH-1:0
    ] gemm_output_base_addr_i,

    input logic [1:0] gemm_precision_i,
    input logic [3:0] gemm_k_token_count_i,

    output logic gemm_busy_o,
    output logic gemm_compute_done_o,
    output logic gemm_done_o,
    output logic gemm_error_o,

    output logic [1:0] gemm_error_source_o,
    output logic [2:0] gemm_error_code_o,
    output logic [2:0] gemm_error_detail_o,

    output logic [
        WORD_COUNT_WIDTH-1:0
    ] gemm_words_loaded_o,

    output logic [6:0] gemm_words_written_o,

    output logic [2047:0] gemm_result_data_o,
    output logic [63:0] gemm_result_valid_o,

    output logic [63:0] gemm_invalid_o,
    output logic [63:0] gemm_overflow_o,
    output logic [63:0] gemm_underflow_o,
    output logic [63:0] gemm_inexact_o,

    // -------------------------------------------------------------------------
    // Output/PSUM scratchpad readback
    // -------------------------------------------------------------------------

    input logic [
        PORT_COUNT-1:0
    ] output_read_enable_i,

    input logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_read_addr_i,

    output logic [
        PORT_COUNT-1:0
    ] output_read_ready_o,

    output logic [
        PORT_COUNT-1:0
    ] output_read_conflict_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_read_data_o,

    output logic [
        PORT_COUNT-1:0
    ] output_read_valid_o
);

    // -------------------------------------------------------------------------
    // Loader status and arbitration
    // -------------------------------------------------------------------------

    logic memory_start;
    logic memory_start_ready;

    logic memory_busy;
    logic memory_done;
    logic memory_error;
    logic [2:0] memory_error_code;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] memory_words_written;

    logic [1:0] memory_active_target;

    // -------------------------------------------------------------------------
    // GEMM execution status and arbitration
    // -------------------------------------------------------------------------

    logic execution_start;
    logic execution_start_ready;

    logic execution_busy;
    logic execution_compute_done;
    logic execution_done;
    logic execution_error;

    logic [1:0] execution_error_source;
    logic [2:0] execution_error_code;
    logic [2:0] execution_error_detail;

    logic [
        WORD_COUNT_WIDTH-1:0
    ] execution_words_loaded;

    logic [6:0] execution_words_written;

    // -------------------------------------------------------------------------
    // GEMM execution <-> tensor-memory interfaces
    // -------------------------------------------------------------------------

    logic [
        PORT_COUNT-1:0
    ] activation_read_enable;

    logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] activation_read_addr;

    logic [
        PORT_COUNT-1:0
    ] activation_read_ready;

    logic [
        PORT_COUNT-1:0
    ] activation_read_conflict;

    logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] activation_read_data;

    logic [
        PORT_COUNT-1:0
    ] activation_read_valid;

    logic [
        PORT_COUNT-1:0
    ] weight_read_enable;

    logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] weight_read_addr;

    logic [
        PORT_COUNT-1:0
    ] weight_read_ready;

    logic [
        PORT_COUNT-1:0
    ] weight_read_conflict;

    logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] weight_read_data;

    logic [
        PORT_COUNT-1:0
    ] weight_read_valid;

    logic [
        PORT_COUNT-1:0
    ] output_write_enable;

    logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_write_addr;

    logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_write_data;

    logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] output_write_strb;

    logic [
        PORT_COUNT-1:0
    ] output_write_ready;

    logic [
        PORT_COUNT-1:0
    ] output_write_conflict;


    // -------------------------------------------------------------------------
    // Tensor shared tiled-controller client
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // Three-client mux -> one tiled 8x8 controller
    // -------------------------------------------------------------------------

    logic shared_tiled_clear;

    logic shared_tiled_a_write_enable;
    logic [5:0] shared_tiled_a_write_addr;
    logic [31:0] shared_tiled_a_write_data;

    logic shared_tiled_b_write_enable;
    logic [5:0] shared_tiled_b_write_addr;
    logic [31:0] shared_tiled_b_write_data;

    logic shared_tiled_start;
    logic shared_tiled_start_ready;

    logic [1:0] shared_tiled_precision;
    logic [3:0] shared_tiled_k_token_count;

    logic shared_tiled_busy;
    logic shared_tiled_done;
    logic shared_tiled_error;
    logic [2:0] shared_tiled_error_code;

    logic shared_tiled_m_tile;
    logic shared_tiled_n_tile;
    logic shared_tiled_k_tile;

    logic [63:0] shared_tiled_a_valid_mask;
    logic [63:0] shared_tiled_b_valid_mask;

    logic [2047:0] shared_tiled_accumulator;
    logic [63:0] shared_tiled_accumulator_valid;

    logic [63:0] shared_tiled_invalid;
    logic [63:0] shared_tiled_overflow;
    logic [63:0] shared_tiled_underflow;
    logic [63:0] shared_tiled_inexact;

    // -------------------------------------------------------------------------
    // Tiled controller -> shared physical 4x4 engine
    // -------------------------------------------------------------------------

    logic physical_tiled_claim;
    logic physical_tiled_release;
    logic tiled_engine_available;

    logic tiled_engine_clear;

    logic tiled_engine_a_write_enable;
    logic [3:0] tiled_engine_a_write_addr;
    logic [31:0] tiled_engine_a_write_data;

    logic tiled_engine_b_write_enable;
    logic [3:0] tiled_engine_b_write_addr;
    logic [31:0] tiled_engine_b_write_data;

    logic tiled_engine_start;
    logic tiled_engine_start_ready;

    logic [1:0] tiled_engine_precision;
    logic [2:0] tiled_engine_k_count;
    logic tiled_engine_accumulate;

    logic tiled_engine_busy;
    logic tiled_engine_done;
    logic tiled_engine_error;
    logic [2:0] tiled_engine_error_code;

    logic [511:0] tiled_engine_accumulator;
    logic [15:0] tiled_engine_accumulator_valid;

    logic [15:0] tiled_engine_invalid;
    logic [15:0] tiled_engine_overflow;
    logic [15:0] tiled_engine_underflow;
    logic [15:0] tiled_engine_inexact;

    // -------------------------------------------------------------------------
    // Mutually exclusive command arbitration
    //
    // An acceptable GEMM command has priority if both requests are asserted in
    // the same idle cycle.
    // -------------------------------------------------------------------------

    assign gemm_start_ready_o =
        execution_start_ready &&
        !memory_busy;

    assign execution_start =
        gemm_start_i &&
        gemm_start_ready_o;

    assign load_start_ready_o =
        memory_start_ready &&
        !execution_busy &&
        !execution_start;

    assign memory_start =
        load_start_i &&
        load_start_ready_o;

    assign load_busy_o =
        memory_busy;

    assign load_done_o =
        memory_done;

    assign load_error_o =
        memory_error;

    assign load_error_code_o =
        memory_error_code;

    assign load_words_written_o =
        memory_words_written;

    assign load_active_target_o =
        memory_active_target;

    assign gemm_busy_o =
        execution_busy;

    assign gemm_compute_done_o =
        execution_compute_done;

    assign gemm_done_o =
        execution_done;

    assign gemm_error_o =
        execution_error;

    assign gemm_error_source_o =
        execution_error_source;

    assign gemm_error_code_o =
        execution_error_code;

    assign gemm_error_detail_o =
        execution_error_detail;

    assign gemm_words_loaded_o =
        execution_words_loaded;

    assign gemm_words_written_o =
        execution_words_written;

    // -------------------------------------------------------------------------
    // Physical tensor memories and shared stream loader
    // -------------------------------------------------------------------------

    nce_tensor_memory_subsystem #(
        .BANK_COUNT          (BANK_COUNT),
        .WORDS_PER_BANK      (WORDS_PER_BANK),
        .DATA_WIDTH          (DATA_WIDTH),
        .PORT_COUNT          (PORT_COUNT),
        .BANK_INDEX_WIDTH    (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH     (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH     (FLAT_ADDR_WIDTH),
        .TOTAL_WORDS         (TOTAL_WORDS),
        .WORD_COUNT_WIDTH    (WORD_COUNT_WIDTH),
        .BYTE_COUNT          (BYTE_COUNT)
    ) u_tensor_memory (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (memory_start),
        .start_ready_o               (memory_start_ready),

        .load_target_i               (load_target_i),
        .base_addr_i                 (load_base_addr_i),
        .word_count_i                (load_word_count_i),

        .stream_valid_i              (load_stream_valid_i),
        .stream_ready_o              (load_stream_ready_o),
        .stream_last_i               (load_stream_last_i),
        .stream_data_i               (load_stream_data_i),
        .stream_strb_i               (load_stream_strb_i),

        .busy_o                      (memory_busy),
        .done_o                      (memory_done),
        .error_o                     (memory_error),
        .error_code_o                (memory_error_code),
        .words_written_o             (memory_words_written),
        .active_target_o             (memory_active_target),

        .activation_read_enable_i    (activation_read_enable),
        .activation_read_addr_i      (activation_read_addr),
        .activation_read_ready_o     (activation_read_ready),
        .activation_read_conflict_o  (activation_read_conflict),
        .activation_read_data_o      (activation_read_data),
        .activation_read_valid_o     (activation_read_valid),

        .weight_read_enable_i        (weight_read_enable),
        .weight_read_addr_i          (weight_read_addr),
        .weight_read_ready_o         (weight_read_ready),
        .weight_read_conflict_o      (weight_read_conflict),
        .weight_read_data_o          (weight_read_data),
        .weight_read_valid_o         (weight_read_valid),

        .output_read_enable_i        (output_read_enable_i),
        .output_read_addr_i          (output_read_addr_i),
        .output_read_ready_o         (output_read_ready_o),
        .output_read_conflict_o      (output_read_conflict_o),
        .output_read_data_o          (output_read_data_o),
        .output_read_valid_o         (output_read_valid_o),

        .output_write_enable_i       (output_write_enable),
        .output_write_addr_i         (output_write_addr),
        .output_write_data_i         (output_write_data),
        .output_write_strb_i         (output_write_strb),
        .output_write_ready_o        (output_write_ready),
        .output_write_conflict_o     (output_write_conflict)
    );

    // -------------------------------------------------------------------------
    // Tensor memory-to-shared-controller execution client
    // -------------------------------------------------------------------------

    nce_tensor_gemm_shared_client #(
        .BANK_COUNT          (BANK_COUNT),
        .WORDS_PER_BANK      (WORDS_PER_BANK),
        .DATA_WIDTH          (DATA_WIDTH),
        .PORT_COUNT          (PORT_COUNT),
        .BANK_INDEX_WIDTH    (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH     (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH     (FLAT_ADDR_WIDTH),
        .TOTAL_WORDS         (TOTAL_WORDS),
        .WORD_COUNT_WIDTH    (WORD_COUNT_WIDTH),
        .BYTE_COUNT          (BYTE_COUNT)
    ) u_tensor_gemm_shared_client (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (execution_start),
        .start_ready_o               (execution_start_ready),

        .activation_base_addr_i      (
            gemm_activation_base_addr_i
        ),

        .weight_base_addr_i          (
            gemm_weight_base_addr_i
        ),

        .output_base_addr_i          (
            gemm_output_base_addr_i
        ),

        .precision_i                 (gemm_precision_i),
        .k_token_count_i             (gemm_k_token_count_i),

        .activation_read_enable_o    (activation_read_enable),
        .activation_read_addr_o      (activation_read_addr),
        .activation_read_ready_i     (activation_read_ready),
        .activation_read_conflict_i  (activation_read_conflict),
        .activation_read_data_i      (activation_read_data),
        .activation_read_valid_i     (activation_read_valid),

        .weight_read_enable_o        (weight_read_enable),
        .weight_read_addr_o          (weight_read_addr),
        .weight_read_ready_i         (weight_read_ready),
        .weight_read_conflict_i      (weight_read_conflict),
        .weight_read_data_i          (weight_read_data),
        .weight_read_valid_i         (weight_read_valid),

        .output_write_enable_o       (output_write_enable),
        .output_write_addr_o         (output_write_addr),
        .output_write_data_o         (output_write_data),
        .output_write_strb_o         (output_write_strb),
        .output_write_ready_i        (output_write_ready),
        .output_write_conflict_i     (output_write_conflict),

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
        .tiled_k_token_count_o       (tensor_tiled_k_token_count),

        .tiled_busy_i                (tensor_tiled_busy),
        .tiled_done_i                (tensor_tiled_done),
        .tiled_error_i               (tensor_tiled_error),
        .tiled_error_code_i          (tensor_tiled_error_code),

        // Tile position and source-valid masks are not required by the tensor
        // feeder or writer. The complete result and flags are owner-isolated
        // through the client mux below.
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

        .busy_o                      (execution_busy),
        .compute_done_o              (execution_compute_done),
        .done_o                      (execution_done),

        .error_o                     (execution_error),
        .error_source_o              (execution_error_source),
        .error_code_o                (execution_error_code),
        .error_detail_o              (execution_error_detail),

        .words_loaded_o              (execution_words_loaded),
        .words_written_o             (execution_words_written),

        .result_data_o               (gemm_result_data_o),
        .result_valid_o              (gemm_result_valid_o),

        .invalid_o                   (gemm_invalid_o),
        .overflow_o                  (gemm_overflow_o),
        .underflow_o                 (gemm_underflow_o),
        .inexact_o                   (gemm_inexact_o)
    );

    // -------------------------------------------------------------------------
    // Three-client context-preserving ownership mux
    //
    // Software and convolution clients are inactive in this standalone
    // numerical integration. Their fully connected use remains in the AXI top.
    // -------------------------------------------------------------------------

    nce_tiled_gemm_client_mux u_tiled_client_mux (
        .clk_i                              (clk_i),
        .rst_ni                             (rst_ni),

        .software_clear_i                   (1'b0),

        .software_a_write_enable_i          (1'b0),
        .software_a_write_addr_i            (6'd0),
        .software_a_write_data_i            (32'd0),

        .software_b_write_enable_i          (1'b0),
        .software_b_write_addr_i            (6'd0),
        .software_b_write_data_i            (32'd0),

        .software_start_i                   (1'b0),
        .software_start_ready_o             (),

        .software_precision_i               (2'd0),
        .software_k_token_count_i           (4'd0),

        .software_busy_o                    (),
        .software_done_o                    (),
        .software_error_o                   (),
        .software_error_code_o              (),

        .software_m_tile_o                  (),
        .software_n_tile_o                  (),
        .software_k_tile_o                  (),

        .software_a_valid_mask_o            (),
        .software_b_valid_mask_o            (),

        .software_accumulator_o             (),
        .software_accumulator_valid_o       (),

        .software_invalid_o                 (),
        .software_overflow_o                (),
        .software_underflow_o               (),
        .software_inexact_o                 (),

        .convolution_claim_i                (1'b0),
        .convolution_release_i              (1'b0),
        .convolution_available_o            (),

        .convolution_clear_i                (1'b0),

        .convolution_a_write_enable_i       (1'b0),
        .convolution_a_write_addr_i         (6'd0),
        .convolution_a_write_data_i         (32'd0),

        .convolution_b_write_enable_i       (1'b0),
        .convolution_b_write_addr_i         (6'd0),
        .convolution_b_write_data_i         (32'd0),

        .convolution_start_i                (1'b0),
        .convolution_start_ready_o          (),

        .convolution_precision_i            (2'd0),
        .convolution_k_token_count_i        (4'd0),

        .convolution_busy_o                 (),
        .convolution_done_o                 (),
        .convolution_error_o                (),
        .convolution_error_code_o           (),

        .convolution_accumulator_o          (),
        .convolution_accumulator_valid_o    (),

        .convolution_invalid_o              (),
        .convolution_overflow_o             (),
        .convolution_underflow_o            (),
        .convolution_inexact_o              (),

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
        .tensor_k_token_count_i             (tensor_tiled_k_token_count),

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

        .shared_clear_o                     (shared_tiled_clear),

        .shared_a_write_enable_o            (
            shared_tiled_a_write_enable
        ),

        .shared_a_write_addr_o              (shared_tiled_a_write_addr),
        .shared_a_write_data_o              (shared_tiled_a_write_data),

        .shared_b_write_enable_o            (
            shared_tiled_b_write_enable
        ),

        .shared_b_write_addr_o              (shared_tiled_b_write_addr),
        .shared_b_write_data_o              (shared_tiled_b_write_data),

        .shared_start_o                     (shared_tiled_start),
        .shared_start_ready_i               (shared_tiled_start_ready),

        .shared_precision_o                 (shared_tiled_precision),
        .shared_k_token_count_o             (shared_tiled_k_token_count),

        .shared_busy_i                      (shared_tiled_busy),
        .shared_done_i                      (shared_tiled_done),
        .shared_error_i                     (shared_tiled_error),
        .shared_error_code_i                (shared_tiled_error_code),

        .shared_m_tile_i                    (shared_tiled_m_tile),
        .shared_n_tile_i                    (shared_tiled_n_tile),
        .shared_k_tile_i                    (shared_tiled_k_tile),

        .shared_a_valid_mask_i              (shared_tiled_a_valid_mask),
        .shared_b_valid_mask_i              (shared_tiled_b_valid_mask),

        .shared_accumulator_i               (shared_tiled_accumulator),

        .shared_accumulator_valid_i         (
            shared_tiled_accumulator_valid
        ),

        .shared_invalid_i                   (shared_tiled_invalid),
        .shared_overflow_i                  (shared_tiled_overflow),
        .shared_underflow_i                 (shared_tiled_underflow),
        .shared_inexact_i                   (shared_tiled_inexact),

        .owner_o                            ()
    );

    // -------------------------------------------------------------------------
    // One shared 8x8 tiled traversal controller
    // -------------------------------------------------------------------------

    assign physical_tiled_claim =
        shared_tiled_start &&
        shared_tiled_start_ready;

    assign physical_tiled_release =
        shared_tiled_done ||
        shared_tiled_error ||
        shared_tiled_clear;

    nce_tiled_gemm_8x8_controller u_tiled_gemm_controller (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (shared_tiled_clear),

        .a_write_enable_i            (shared_tiled_a_write_enable),
        .a_write_addr_i              (shared_tiled_a_write_addr),
        .a_write_data_i              (shared_tiled_a_write_data),

        .b_write_enable_i            (shared_tiled_b_write_enable),
        .b_write_addr_i              (shared_tiled_b_write_addr),
        .b_write_data_i              (shared_tiled_b_write_data),

        .a_valid_mask_o              (shared_tiled_a_valid_mask),
        .b_valid_mask_o              (shared_tiled_b_valid_mask),

        .start_i                     (shared_tiled_start),
        .start_ready_o               (shared_tiled_start_ready),

        .precision_i                 (shared_tiled_precision),
        .k_token_count_i             (shared_tiled_k_token_count),

        .busy_o                      (shared_tiled_busy),
        .done_o                      (shared_tiled_done),
        .error_o                     (shared_tiled_error),
        .error_code_o                (shared_tiled_error_code),

        .m_tile_o                    (shared_tiled_m_tile),
        .n_tile_o                    (shared_tiled_n_tile),
        .k_tile_o                    (shared_tiled_k_tile),

        .accumulator_o               (shared_tiled_accumulator),

        .accumulator_valid_o         (
            shared_tiled_accumulator_valid
        ),

        .invalid_o                   (shared_tiled_invalid),
        .overflow_o                  (shared_tiled_overflow),
        .underflow_o                 (shared_tiled_underflow),
        .inexact_o                   (shared_tiled_inexact),

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
    // One shared physical 4x4 systolic engine
    //
    // The direct client is inactive in this standalone numerical integration.
    // The AXI top connects both direct and tiled clients to this same wrapper.
    // -------------------------------------------------------------------------

    nce_shared_systolic_gemm_4x4 u_shared_systolic_gemm (
        .clk_i                           (clk_i),
        .rst_ni                          (rst_ni),

        .direct_clear_i                  (1'b0),

        .direct_a_write_enable_i         (1'b0),
        .direct_a_write_addr_i           (4'd0),
        .direct_a_write_data_i           (32'd0),

        .direct_b_write_enable_i         (1'b0),
        .direct_b_write_addr_i           (4'd0),
        .direct_b_write_data_i           (32'd0),

        .direct_start_i                  (1'b0),
        .direct_start_ready_o            (),

        .direct_precision_i              (2'd0),
        .direct_k_count_i                (3'd0),
        .direct_accumulate_i             (1'b0),

        .direct_busy_o                   (),
        .direct_done_o                   (),
        .direct_error_o                  (),
        .direct_error_code_o             (),

        .direct_wavefront_cycle_o        (),

        .direct_a_valid_mask_o           (),
        .direct_b_valid_mask_o           (),

        .direct_accumulator_o            (),
        .direct_accumulator_valid_o      (),
        .direct_accumulator_update_o     (),

        .direct_mac_fire_mask_o          (),

        .direct_invalid_o                (),
        .direct_overflow_o               (),
        .direct_underflow_o              (),
        .direct_inexact_o                (),

        .tiled_claim_i                   (physical_tiled_claim),
        .tiled_release_i                 (physical_tiled_release),
        .tiled_engine_available_o        (tiled_engine_available),

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
