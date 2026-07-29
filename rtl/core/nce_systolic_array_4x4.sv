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
// Native 4x4 output-stationary mixed-precision systolic array.
//
// Activations propagate left to right.
// Weights propagate top to bottom.
// Properly skewed boundary injection produces diagonal compute wavefronts.
//
// Each PE owns one local FP32 accumulator.
//
// Flattened PE ordering:
//
//   0  1  2  3       PE00 PE01 PE02 PE03
//   4  5  6  7       PE10 PE11 PE12 PE13
//   8  9 10 11       PE20 PE21 PE22 PE23
//  12 13 14 15       PE30 PE31 PE32 PE33
// -----------------------------------------------------------------------------

module nce_systolic_array_4x4 #(
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

    // Four row-boundary activation inputs.
    //
    //   [31:0]    row 0
    //   [63:32]   row 1
    //   [95:64]   row 2
    //   [127:96]  row 3
    input  logic [127:0] row_activation_i,
    input  logic [3:0]   row_activation_valid_i,

    // Four column-boundary weight inputs.
    //
    //   [31:0]    column 0
    //   [63:32]   column 1
    //   [95:64]   column 2
    //   [127:96]  column 3
    input  logic [127:0] column_weight_i,
    input  logic [3:0]   column_weight_valid_i,

    // Sixteen row-major FP32 output-stationary accumulators.
    output logic [511:0] accumulator_o,

    output logic [15:0] accumulator_valid_o,
    output logic [15:0] accumulator_update_o,

    // One bit per PE, asserted when that PE accepts a matched pair.
    output logic [15:0] mac_fire_mask_o,

    output logic [15:0] invalid_o,
    output logic [15:0] overflow_o,
    output logic [15:0] underflow_o,
    output logic [15:0] inexact_o
);

    logic array_step;

    logic [15:0] pe_ready;
    logic [15:0] pe_precision_supported;

    // activation_link[row][column boundary]
    //
    // Boundary 0 is the external left input.
    // Boundaries 1..4 are registered PE outputs.
    logic [31:0] activation_link [0:3][0:4];
    logic        activation_valid_link [0:3][0:4];

    // weight_link[row boundary][column]
    //
    // Boundary 0 is the external top input.
    // Boundaries 1..4 are registered PE outputs.
    logic [31:0] weight_link [0:4][0:3];
    logic        weight_valid_link [0:4][0:3];

    assign ready_o =
        &pe_ready;

    assign precision_supported_o =
        &pe_precision_supported;

    assign array_step =
        step_i &&
        ready_o;

    genvar boundary_index;

    generate
        // Left activation boundaries.
        for (
            boundary_index = 0;
            boundary_index < 4;
            boundary_index = boundary_index + 1
        ) begin : generate_activation_boundaries

            assign activation_link[boundary_index][0] =
                row_activation_i[
                    (boundary_index * 32) +: 32
                ];

            assign activation_valid_link[boundary_index][0] =
                row_activation_valid_i[boundary_index];

        end

        // Top weight boundaries.
        for (
            boundary_index = 0;
            boundary_index < 4;
            boundary_index = boundary_index + 1
        ) begin : generate_weight_boundaries

            assign weight_link[0][boundary_index] =
                column_weight_i[
                    (boundary_index * 32) +: 32
                ];

            assign weight_valid_link[0][boundary_index] =
                column_weight_valid_i[boundary_index];

        end
    endgenerate

    genvar row_index;
    genvar column_index;

    generate
        for (
            row_index = 0;
            row_index < 4;
            row_index = row_index + 1
        ) begin : generate_rows

            for (
                column_index = 0;
                column_index < 4;
                column_index = column_index + 1
            ) begin : generate_columns

                localparam integer PE_INDEX =
                    (row_index * 4) +
                    column_index;

                nce_systolic_pe #(
                    .INT8X4_PRECISION (INT8X4_PRECISION),
                    .BF16X2_PRECISION (BF16X2_PRECISION),
                    .BF24_PRECISION   (BF24_PRECISION)
                ) u_pe (
                    .clk_i (
                        clk_i
                    ),

                    .rst_ni (
                        rst_ni
                    ),

                    .clear_i (
                        clear_i
                    ),

                    .step_i (
                        array_step
                    ),

                    .ready_o (
                        pe_ready[PE_INDEX]
                    ),

                    .precision_i (
                        precision_i
                    ),

                    .precision_supported_o (
                        pe_precision_supported[PE_INDEX]
                    ),

                    // Left-to-right activation propagation.
                    .activation_i (
                        activation_link[
                            row_index
                        ][
                            column_index
                        ]
                    ),

                    .activation_valid_i (
                        activation_valid_link[
                            row_index
                        ][
                            column_index
                        ]
                    ),

                    .activation_o (
                        activation_link[
                            row_index
                        ][
                            column_index + 1
                        ]
                    ),

                    .activation_valid_o (
                        activation_valid_link[
                            row_index
                        ][
                            column_index + 1
                        ]
                    ),

                    // Top-to-bottom weight propagation.
                    .weight_i (
                        weight_link[
                            row_index
                        ][
                            column_index
                        ]
                    ),

                    .weight_valid_i (
                        weight_valid_link[
                            row_index
                        ][
                            column_index
                        ]
                    ),

                    .weight_o (
                        weight_link[
                            row_index + 1
                        ][
                            column_index
                        ]
                    ),

                    .weight_valid_o (
                        weight_valid_link[
                            row_index + 1
                        ][
                            column_index
                        ]
                    ),

                    .mac_fire_o (
                        mac_fire_mask_o[PE_INDEX]
                    ),

                    .accumulator_o (
                        accumulator_o[
                            (PE_INDEX * 32) +: 32
                        ]
                    ),

                    .accumulator_valid_o (
                        accumulator_valid_o[PE_INDEX]
                    ),

                    .accumulator_update_o (
                        accumulator_update_o[PE_INDEX]
                    ),

                    .invalid_o (
                        invalid_o[PE_INDEX]
                    ),

                    .overflow_o (
                        overflow_o[PE_INDEX]
                    ),

                    .underflow_o (
                        underflow_o[PE_INDEX]
                    ),

                    .inexact_o (
                        inexact_o[PE_INDEX]
                    )
                );

            end
        end
    endgenerate

endmodule

`default_nettype wire
