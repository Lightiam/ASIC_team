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
// Complete tensor compute subsystem.
//
// Integrates:
//
//   * 4 KB activation scratchpad
//   * 4 KB weight scratchpad
//   * 4 KB output/PSUM scratchpad
//   * shared 128-bit tensor loader
//   * autonomous 8x8 tensor GEMM execution
//   * conflict-safe four-lane FP32 result writeback
//
// Loader and GEMM commands are mutually exclusive in this integration to avoid
// software-visible read/write hazards. Output-memory reads remain available for
// result inspection through the external readback ports.
// -----------------------------------------------------------------------------

module nce_tensor_compute_subsystem #(
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
    // Autonomous memory-to-compute-to-memory GEMM execution
    // -------------------------------------------------------------------------

    nce_tensor_gemm_execution #(
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
    ) u_tensor_gemm_execution (
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

endmodule

`default_nettype wire
