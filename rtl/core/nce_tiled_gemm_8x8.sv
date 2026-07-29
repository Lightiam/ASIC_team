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
// Compatibility wrapper for the autonomous 8x8 tiled GEMM.
//
// The M/N/K traversal logic lives in nce_tiled_gemm_8x8_controller. This
// wrapper supplies a private physical 4x4 engine so existing standalone tests
// and integrations remain unchanged.
//
// The AXI shared-array integration will instantiate the controller directly.
// -----------------------------------------------------------------------------

module nce_tiled_gemm_8x8 #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic          clk_i,
    input  logic          rst_ni,
    input  logic          clear_i,

    input  logic          a_write_enable_i,
    input  logic [5:0]    a_write_addr_i,
    input  logic [31:0]   a_write_data_i,

    input  logic          b_write_enable_i,
    input  logic [5:0]    b_write_addr_i,
    input  logic [31:0]   b_write_data_i,

    output logic [63:0]   a_valid_mask_o,
    output logic [63:0]   b_valid_mask_o,

    input  logic          start_i,
    output logic          start_ready_o,

    input  logic [1:0]    precision_i,
    input  logic [3:0]    k_token_count_i,

    output logic          busy_o,
    output logic          done_o,
    output logic          error_o,
    output logic [2:0]    error_code_o,

    output logic          m_tile_o,
    output logic          n_tile_o,
    output logic          k_tile_o,

    output logic [2047:0] accumulator_o,
    output logic [63:0]   accumulator_valid_o,

    output logic [63:0]   invalid_o,
    output logic [63:0]   overflow_o,
    output logic [63:0]   underflow_o,
    output logic [63:0]   inexact_o
);

    // -------------------------------------------------------------------------
    // Controller-to-engine request interface
    // -------------------------------------------------------------------------

    logic        engine_clear;

    logic        engine_a_write_enable;
    logic [3:0]  engine_a_write_addr;
    logic [31:0] engine_a_write_data;

    logic        engine_b_write_enable;
    logic [3:0]  engine_b_write_addr;
    logic [31:0] engine_b_write_data;

    logic       engine_start;
    logic       engine_start_ready;

    logic [1:0] engine_precision;
    logic [2:0] engine_k_count;
    logic       engine_accumulate;

    // -------------------------------------------------------------------------
    // Engine-to-controller response interface
    // -------------------------------------------------------------------------

    logic       engine_busy;
    logic       engine_done;
    logic       engine_error;
    logic [2:0] engine_error_code;

    logic [511:0] engine_accumulator;
    logic [15:0]  engine_accumulator_valid;

    logic [15:0] engine_invalid;
    logic [15:0] engine_overflow;
    logic [15:0] engine_underflow;
    logic [15:0] engine_inexact;

    // -------------------------------------------------------------------------
    // M/N/K traversal controller
    // -------------------------------------------------------------------------

    nce_tiled_gemm_8x8_controller #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_controller (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .a_write_enable_i            (a_write_enable_i),
        .a_write_addr_i              (a_write_addr_i),
        .a_write_data_i              (a_write_data_i),

        .b_write_enable_i            (b_write_enable_i),
        .b_write_addr_i              (b_write_addr_i),
        .b_write_data_i              (b_write_data_i),

        .a_valid_mask_o              (a_valid_mask_o),
        .b_valid_mask_o              (b_valid_mask_o),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),

        .precision_i                 (precision_i),
        .k_token_count_i             (k_token_count_i),

        .busy_o                      (busy_o),
        .done_o                      (done_o),
        .error_o                     (error_o),
        .error_code_o                (error_code_o),

        .m_tile_o                    (m_tile_o),
        .n_tile_o                    (n_tile_o),
        .k_tile_o                    (k_tile_o),

        .accumulator_o               (accumulator_o),
        .accumulator_valid_o         (accumulator_valid_o),

        .invalid_o                   (invalid_o),
        .overflow_o                  (overflow_o),
        .underflow_o                 (underflow_o),
        .inexact_o                   (inexact_o),

        .engine_available_i          (1'b1),

        .engine_clear_o              (engine_clear),

        .engine_a_write_enable_o     (engine_a_write_enable),
        .engine_a_write_addr_o       (engine_a_write_addr),
        .engine_a_write_data_o       (engine_a_write_data),

        .engine_b_write_enable_o     (engine_b_write_enable),
        .engine_b_write_addr_o       (engine_b_write_addr),
        .engine_b_write_data_o       (engine_b_write_data),

        .engine_start_o              (engine_start),
        .engine_start_ready_i        (engine_start_ready),

        .engine_precision_o          (engine_precision),
        .engine_k_count_o            (engine_k_count),
        .engine_accumulate_o         (engine_accumulate),

        .engine_busy_i               (engine_busy),
        .engine_done_i               (engine_done),
        .engine_error_i              (engine_error),
        .engine_error_code_i         (engine_error_code),

        .engine_accumulator_i        (engine_accumulator),
        .engine_accumulator_valid_i  (engine_accumulator_valid),

        .engine_invalid_i            (engine_invalid),
        .engine_overflow_i           (engine_overflow),
        .engine_underflow_i          (engine_underflow),
        .engine_inexact_i            (engine_inexact)
    );

    // -------------------------------------------------------------------------
    // Private physical engine used only by this compatibility wrapper
    // -------------------------------------------------------------------------

    nce_systolic_gemm_4x4 #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_private_engine (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),

        .clear_i                  (engine_clear),

        .a_write_enable_i         (engine_a_write_enable),
        .a_write_addr_i           (engine_a_write_addr),
        .a_write_data_i           (engine_a_write_data),

        .b_write_enable_i         (engine_b_write_enable),
        .b_write_addr_i           (engine_b_write_addr),
        .b_write_data_i           (engine_b_write_data),

        .a_valid_mask_o           (),
        .b_valid_mask_o           (),

        .start_i                  (engine_start),
        .start_ready_o            (engine_start_ready),

        .precision_i              (engine_precision),
        .k_count_i                (engine_k_count),
        .accumulate_i             (engine_accumulate),

        .busy_o                   (engine_busy),
        .done_o                   (engine_done),
        .error_o                  (engine_error),
        .error_code_o             (engine_error_code),

        .wavefront_cycle_o        (),

        .accumulator_o            (engine_accumulator),
        .accumulator_valid_o      (engine_accumulator_valid),
        .accumulator_update_o     (),

        .mac_fire_mask_o          (),

        .invalid_o                (engine_invalid),
        .overflow_o               (engine_overflow),
        .underflow_o              (engine_underflow),
        .inexact_o                (engine_inexact)
    );

endmodule

`default_nettype wire
