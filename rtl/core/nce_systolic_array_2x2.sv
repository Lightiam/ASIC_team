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
// Native 2x2 output-stationary systolic array.
//
//                       column weights
//                     col0          col1
//                       |             |
//                       v             v
//
// row0 activation ->  PE00  ------> PE01
//                       |             |
//                       v             v
// row1 activation ->  PE10  ------> PE11
//
// Activations move left-to-right.
// Weights move top-to-bottom.
// Properly skewed boundary inputs create a diagonal compute wavefront.
// -----------------------------------------------------------------------------

module nce_systolic_array_2x2 #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    input  logic         step_i,
    output logic         ready_o,

    input  logic [1:0]   precision_i,
    output logic         precision_supported_o,

    // row_activation_i[31:0]  = row 0
    // row_activation_i[63:32] = row 1
    input  logic [63:0]  row_activation_i,
    input  logic [1:0]   row_activation_valid_i,

    // column_weight_i[31:0]  = column 0
    // column_weight_i[63:32] = column 1
    input  logic [63:0]  column_weight_i,
    input  logic [1:0]   column_weight_valid_i,

    // PE mapping:
    //   bits  31:0   = PE00
    //   bits  63:32  = PE01
    //   bits  95:64  = PE10
    //   bits 127:96  = PE11
    output logic [127:0] accumulator_o,

    output logic [3:0]   accumulator_valid_o,
    output logic [3:0]   accumulator_update_o,

    // Directly exposes the diagonal wavefront for verification
    output logic [3:0]   mac_fire_mask_o,

    output logic [3:0]   invalid_o,
    output logic [3:0]   overflow_o,
    output logic [3:0]   underflow_o,
    output logic [3:0]   inexact_o
);

    logic array_step;

    logic [3:0] pe_ready;
    logic [3:0] pe_precision_supported;

    logic [31:0] pe00_activation_right;
    logic        pe00_activation_right_valid;
    logic [31:0] pe00_weight_down;
    logic        pe00_weight_down_valid;

    logic [31:0] pe01_activation_right_unused;
    logic        pe01_activation_right_valid_unused;
    logic [31:0] pe01_weight_down;
    logic        pe01_weight_down_valid;

    logic [31:0] pe10_activation_right;
    logic        pe10_activation_right_valid;
    logic [31:0] pe10_weight_down_unused;
    logic        pe10_weight_down_valid_unused;

    logic [31:0] pe11_activation_right_unused;
    logic        pe11_activation_right_valid_unused;
    logic [31:0] pe11_weight_down_unused;
    logic        pe11_weight_down_valid_unused;

    assign ready_o =
        &pe_ready;

    assign precision_supported_o =
        &pe_precision_supported;

    assign array_step =
        step_i &&
        ready_o;

    // -------------------------------------------------------------------------
    // PE(0,0)
    // -------------------------------------------------------------------------

    nce_systolic_pe #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_pe00 (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .step_i                 (array_step),
        .ready_o                (pe_ready[0]),

        .precision_i            (precision_i),
        .precision_supported_o  (pe_precision_supported[0]),

        .activation_i           (row_activation_i[31:0]),
        .activation_valid_i     (row_activation_valid_i[0]),

        .activation_o           (pe00_activation_right),
        .activation_valid_o     (
            pe00_activation_right_valid
        ),

        .weight_i               (column_weight_i[31:0]),
        .weight_valid_i         (column_weight_valid_i[0]),

        .weight_o               (pe00_weight_down),
        .weight_valid_o         (pe00_weight_down_valid),

        .mac_fire_o             (mac_fire_mask_o[0]),

        .accumulator_o          (accumulator_o[31:0]),
        .accumulator_valid_o    (accumulator_valid_o[0]),
        .accumulator_update_o   (accumulator_update_o[0]),

        .invalid_o              (invalid_o[0]),
        .overflow_o             (overflow_o[0]),
        .underflow_o            (underflow_o[0]),
        .inexact_o              (inexact_o[0])
    );

    // -------------------------------------------------------------------------
    // PE(0,1)
    // -------------------------------------------------------------------------

    nce_systolic_pe #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_pe01 (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .step_i                 (array_step),
        .ready_o                (pe_ready[1]),

        .precision_i            (precision_i),
        .precision_supported_o  (pe_precision_supported[1]),

        .activation_i           (pe00_activation_right),
        .activation_valid_i     (
            pe00_activation_right_valid
        ),

        .activation_o           (pe01_activation_right_unused),
        .activation_valid_o     (
            pe01_activation_right_valid_unused
        ),

        .weight_i               (column_weight_i[63:32]),
        .weight_valid_i         (column_weight_valid_i[1]),

        .weight_o               (pe01_weight_down),
        .weight_valid_o         (pe01_weight_down_valid),

        .mac_fire_o             (mac_fire_mask_o[1]),

        .accumulator_o          (accumulator_o[63:32]),
        .accumulator_valid_o    (accumulator_valid_o[1]),
        .accumulator_update_o   (accumulator_update_o[1]),

        .invalid_o              (invalid_o[1]),
        .overflow_o             (overflow_o[1]),
        .underflow_o            (underflow_o[1]),
        .inexact_o              (inexact_o[1])
    );

    // -------------------------------------------------------------------------
    // PE(1,0)
    // -------------------------------------------------------------------------

    nce_systolic_pe #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_pe10 (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .step_i                 (array_step),
        .ready_o                (pe_ready[2]),

        .precision_i            (precision_i),
        .precision_supported_o  (pe_precision_supported[2]),

        .activation_i           (row_activation_i[63:32]),
        .activation_valid_i     (row_activation_valid_i[1]),

        .activation_o           (pe10_activation_right),
        .activation_valid_o     (
            pe10_activation_right_valid
        ),

        .weight_i               (pe00_weight_down),
        .weight_valid_i         (pe00_weight_down_valid),

        .weight_o               (pe10_weight_down_unused),
        .weight_valid_o         (
            pe10_weight_down_valid_unused
        ),

        .mac_fire_o             (mac_fire_mask_o[2]),

        .accumulator_o          (accumulator_o[95:64]),
        .accumulator_valid_o    (accumulator_valid_o[2]),
        .accumulator_update_o   (accumulator_update_o[2]),

        .invalid_o              (invalid_o[2]),
        .overflow_o             (overflow_o[2]),
        .underflow_o            (underflow_o[2]),
        .inexact_o              (inexact_o[2])
    );

    // -------------------------------------------------------------------------
    // PE(1,1)
    // -------------------------------------------------------------------------

    nce_systolic_pe #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_pe11 (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .step_i                 (array_step),
        .ready_o                (pe_ready[3]),

        .precision_i            (precision_i),
        .precision_supported_o  (pe_precision_supported[3]),

        .activation_i           (pe10_activation_right),
        .activation_valid_i     (
            pe10_activation_right_valid
        ),

        .activation_o           (pe11_activation_right_unused),
        .activation_valid_o     (
            pe11_activation_right_valid_unused
        ),

        .weight_i               (pe01_weight_down),
        .weight_valid_i         (pe01_weight_down_valid),

        .weight_o               (pe11_weight_down_unused),
        .weight_valid_o         (
            pe11_weight_down_valid_unused
        ),

        .mac_fire_o             (mac_fire_mask_o[3]),

        .accumulator_o          (accumulator_o[127:96]),
        .accumulator_valid_o    (accumulator_valid_o[3]),
        .accumulator_update_o   (accumulator_update_o[3]),

        .invalid_o              (invalid_o[3]),
        .overflow_o             (overflow_o[3]),
        .underflow_o            (underflow_o[3]),
        .inexact_o              (inexact_o[3])
    );

endmodule

`default_nettype wire
