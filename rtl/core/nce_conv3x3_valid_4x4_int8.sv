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
// Compatibility wrapper for the reference convolution frontend.
//
// The convolution controller produces tiled-GEMM requests. This wrapper gives
// it a private nce_tiled_gemm_8x8 backend so the verified standalone regression
// remains unchanged.
//
// The AXI integration will instantiate the controller directly and route these
// same requests into the already shared tiled-GEMM controller.
// -----------------------------------------------------------------------------

module nce_conv3x3_valid_4x4_int8 (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    input  logic         pixel_write_enable_i,
    input  logic [3:0]   pixel_write_addr_i,
    input  logic [7:0]   pixel_write_data_i,

    input  logic         kernel_write_enable_i,
    input  logic [3:0]   kernel_write_addr_i,
    input  logic [7:0]   kernel_write_data_i,

    output logic [15:0]  pixel_valid_mask_o,
    output logic [8:0]   kernel_valid_mask_o,

    input  logic         start_i,
    output logic         start_ready_o,

    output logic         busy_o,
    output logic         done_o,
    output logic         error_o,
    output logic [2:0]   error_code_o,

    output logic [127:0] result_o,
    output logic [3:0]   result_valid_o,

    output logic [3:0]   invalid_o,
    output logic [3:0]   overflow_o,
    output logic [3:0]   underflow_o,
    output logic [3:0]   inexact_o
);

    logic gemm_clear;

    logic        gemm_a_write_enable;
    logic [5:0]  gemm_a_write_addr;
    logic [31:0] gemm_a_write_data;

    logic        gemm_b_write_enable;
    logic [5:0]  gemm_b_write_addr;
    logic [31:0] gemm_b_write_data;

    logic       gemm_start;
    logic       gemm_start_ready;

    logic [1:0] gemm_precision;
    logic [3:0] gemm_k_token_count;

    logic gemm_done;
    logic gemm_error;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [2047:0] gemm_accumulator;
    logic [63:0]   gemm_accumulator_valid;

    logic [63:0] gemm_invalid;
    logic [63:0] gemm_overflow;
    logic [63:0] gemm_underflow;
    logic [63:0] gemm_inexact;
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Convolution lowering controller
    // -------------------------------------------------------------------------

    nce_conv3x3_valid_4x4_int8_controller u_controller (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .clear_i                  (clear_i),

        .pixel_write_enable_i     (pixel_write_enable_i),
        .pixel_write_addr_i       (pixel_write_addr_i),
        .pixel_write_data_i       (pixel_write_data_i),

        .kernel_write_enable_i    (kernel_write_enable_i),
        .kernel_write_addr_i      (kernel_write_addr_i),
        .kernel_write_data_i      (kernel_write_data_i),

        .pixel_valid_mask_o       (pixel_valid_mask_o),
        .kernel_valid_mask_o      (kernel_valid_mask_o),

        .start_i                  (start_i),
        .start_ready_o            (start_ready_o),

        .busy_o                   (busy_o),
        .done_o                   (done_o),
        .error_o                  (error_o),
        .error_code_o             (error_code_o),

        .result_o                 (result_o),
        .result_valid_o           (result_valid_o),

        .invalid_o                (invalid_o),
        .overflow_o               (overflow_o),
        .underflow_o              (underflow_o),
        .inexact_o                (inexact_o),

        .gemm_available           (1'b1),

        .gemm_clear               (gemm_clear),

        .gemm_a_write_enable      (gemm_a_write_enable),
        .gemm_a_write_addr        (gemm_a_write_addr),
        .gemm_a_write_data        (gemm_a_write_data),

        .gemm_b_write_enable      (gemm_b_write_enable),
        .gemm_b_write_addr        (gemm_b_write_addr),
        .gemm_b_write_data        (gemm_b_write_data),

        .gemm_start               (gemm_start),
        .gemm_start_ready         (gemm_start_ready),

        .gemm_precision           (gemm_precision),
        .gemm_k_token_count       (gemm_k_token_count),

        .gemm_done                (gemm_done),
        .gemm_error               (gemm_error),

        .gemm_accumulator         (gemm_accumulator),
        .gemm_accumulator_valid   (gemm_accumulator_valid),

        .gemm_invalid             (gemm_invalid),
        .gemm_overflow            (gemm_overflow),
        .gemm_underflow           (gemm_underflow),
        .gemm_inexact             (gemm_inexact)
    );

    // -------------------------------------------------------------------------
    // Private tiled-GEMM backend used only by the standalone reference wrapper
    // -------------------------------------------------------------------------

    nce_tiled_gemm_8x8 u_tiled_gemm (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .clear_i                  (gemm_clear),

        .a_write_enable_i         (gemm_a_write_enable),
        .a_write_addr_i           (gemm_a_write_addr),
        .a_write_data_i           (gemm_a_write_data),

        .b_write_enable_i         (gemm_b_write_enable),
        .b_write_addr_i           (gemm_b_write_addr),
        .b_write_data_i           (gemm_b_write_data),

        .a_valid_mask_o           (),
        .b_valid_mask_o           (),

        .start_i                  (gemm_start),
        .start_ready_o            (gemm_start_ready),

        .precision_i              (gemm_precision),
        .k_token_count_i          (gemm_k_token_count),

        .busy_o                   (),
        .done_o                   (gemm_done),
        .error_o                  (gemm_error),
        .error_code_o             (),

        .m_tile_o                 (),
        .n_tile_o                 (),
        .k_tile_o                 (),

        .accumulator_o            (gemm_accumulator),
        .accumulator_valid_o      (gemm_accumulator_valid),

        .invalid_o                (gemm_invalid),
        .overflow_o               (gemm_overflow),
        .underflow_o              (gemm_underflow),
        .inexact_o                (gemm_inexact)
    );

endmodule

`default_nettype wire
