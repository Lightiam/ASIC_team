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
// Ownership mux for one nce_tiled_gemm_8x8_controller.
//
// Client 0: software-programmed tiled-GEMM CSR.
// Client 1: convolution-lowering controller.
// Client 2: autonomous tensor-memory GEMM.
//
// Ownership is context-preserving:
//
//   * Software claims on its first A/B write or accepted start.
//   * Software releases through software clear.
//   * Convolution claims when its high-level command is accepted.
//   * Convolution releases through convolution release.
//   * Tensor claims when its high-level command is accepted.
//   * Tensor releases after compute completion, error, or clear.
//
// Idle-state claim priority:
//
//   convolution > tensor > software
//
// Ownership remains active until explicit release so staged operands and
// completed result contexts cannot be overwritten by another client.
// -----------------------------------------------------------------------------

module nce_tiled_gemm_client_mux (
    input  logic          clk_i,
    input  logic          rst_ni,

    // -------------------------------------------------------------------------
    // Software-programmed tiled-GEMM client
    // -------------------------------------------------------------------------

    input  logic          software_clear_i,

    input  logic          software_a_write_enable_i,
    input  logic [5:0]    software_a_write_addr_i,
    input  logic [31:0]   software_a_write_data_i,

    input  logic          software_b_write_enable_i,
    input  logic [5:0]    software_b_write_addr_i,
    input  logic [31:0]   software_b_write_data_i,

    input  logic          software_start_i,
    output logic          software_start_ready_o,

    input  logic [1:0]    software_precision_i,
    input  logic [3:0]    software_k_token_count_i,

    output logic          software_busy_o,
    output logic          software_done_o,
    output logic          software_error_o,
    output logic [2:0]    software_error_code_o,

    output logic          software_m_tile_o,
    output logic          software_n_tile_o,
    output logic          software_k_tile_o,

    output logic [63:0]   software_a_valid_mask_o,
    output logic [63:0]   software_b_valid_mask_o,

    output logic [2047:0] software_accumulator_o,
    output logic [63:0]   software_accumulator_valid_o,

    output logic [63:0]   software_invalid_o,
    output logic [63:0]   software_overflow_o,
    output logic [63:0]   software_underflow_o,
    output logic [63:0]   software_inexact_o,

    // -------------------------------------------------------------------------
    // Convolution client ownership
    // -------------------------------------------------------------------------

    input  logic          convolution_claim_i,
    input  logic          convolution_release_i,
    output logic          convolution_available_o,

    // -------------------------------------------------------------------------
    // Convolution -> tiled-GEMM requests
    // -------------------------------------------------------------------------

    input  logic          convolution_clear_i,

    input  logic          convolution_a_write_enable_i,
    input  logic [5:0]    convolution_a_write_addr_i,
    input  logic [31:0]   convolution_a_write_data_i,

    input  logic          convolution_b_write_enable_i,
    input  logic [5:0]    convolution_b_write_addr_i,
    input  logic [31:0]   convolution_b_write_data_i,

    input  logic          convolution_start_i,
    output logic          convolution_start_ready_o,

    input  logic [1:0]    convolution_precision_i,
    input  logic [3:0]    convolution_k_token_count_i,

    output logic          convolution_busy_o,
    output logic          convolution_done_o,
    output logic          convolution_error_o,
    output logic [2:0]    convolution_error_code_o,

    output logic [2047:0] convolution_accumulator_o,
    output logic [63:0]   convolution_accumulator_valid_o,

    output logic [63:0]   convolution_invalid_o,
    output logic [63:0]   convolution_overflow_o,
    output logic [63:0]   convolution_underflow_o,
    output logic [63:0]   convolution_inexact_o,

    // -------------------------------------------------------------------------
    // Tensor-memory GEMM client ownership
    // -------------------------------------------------------------------------

    input  logic          tensor_claim_i,
    input  logic          tensor_release_i,
    output logic          tensor_available_o,

    // -------------------------------------------------------------------------
    // Tensor-memory GEMM -> tiled-GEMM requests
    // -------------------------------------------------------------------------

    input  logic          tensor_clear_i,

    input  logic          tensor_a_write_enable_i,
    input  logic [5:0]    tensor_a_write_addr_i,
    input  logic [31:0]   tensor_a_write_data_i,

    input  logic          tensor_b_write_enable_i,
    input  logic [5:0]    tensor_b_write_addr_i,
    input  logic [31:0]   tensor_b_write_data_i,

    input  logic          tensor_start_i,
    output logic          tensor_start_ready_o,

    input  logic [1:0]    tensor_precision_i,
    input  logic [3:0]    tensor_k_token_count_i,

    output logic          tensor_busy_o,
    output logic          tensor_done_o,
    output logic          tensor_error_o,
    output logic [2:0]    tensor_error_code_o,

    output logic [2047:0] tensor_accumulator_o,
    output logic [63:0]   tensor_accumulator_valid_o,

    output logic [63:0]   tensor_invalid_o,
    output logic [63:0]   tensor_overflow_o,
    output logic [63:0]   tensor_underflow_o,
    output logic [63:0]   tensor_inexact_o,

    // -------------------------------------------------------------------------
    // Shared tiled-GEMM-controller request interface
    // -------------------------------------------------------------------------

    output logic          shared_clear_o,

    output logic          shared_a_write_enable_o,
    output logic [5:0]    shared_a_write_addr_o,
    output logic [31:0]   shared_a_write_data_o,

    output logic          shared_b_write_enable_o,
    output logic [5:0]    shared_b_write_addr_o,
    output logic [31:0]   shared_b_write_data_o,

    output logic          shared_start_o,
    input  logic          shared_start_ready_i,

    output logic [1:0]    shared_precision_o,
    output logic [3:0]    shared_k_token_count_o,

    // -------------------------------------------------------------------------
    // Shared tiled-GEMM-controller responses
    // -------------------------------------------------------------------------

    input  logic          shared_busy_i,
    input  logic          shared_done_i,
    input  logic          shared_error_i,
    input  logic [2:0]    shared_error_code_i,

    input  logic          shared_m_tile_i,
    input  logic          shared_n_tile_i,
    input  logic          shared_k_tile_i,

    input  logic [63:0]   shared_a_valid_mask_i,
    input  logic [63:0]   shared_b_valid_mask_i,

    input  logic [2047:0] shared_accumulator_i,
    input  logic [63:0]   shared_accumulator_valid_i,

    input  logic [63:0]   shared_invalid_i,
    input  logic [63:0]   shared_overflow_i,
    input  logic [63:0]   shared_underflow_i,
    input  logic [63:0]   shared_inexact_i,

    output logic [1:0]    owner_o
);

    localparam logic [1:0] OWNER_NONE        = 2'd0;
    localparam logic [1:0] OWNER_SOFTWARE    = 2'd1;
    localparam logic [1:0] OWNER_CONVOLUTION = 2'd2;
    localparam logic [1:0] OWNER_TENSOR      = 2'd3;

    logic [1:0] owner_q;

    logic software_claim;
    logic select_convolution;
    logic select_tensor;

    assign owner_o =
        owner_q;

    // -------------------------------------------------------------------------
    // Availability and start acceptance
    // -------------------------------------------------------------------------

    assign software_start_ready_o =
        rst_ni &&
        (owner_q != OWNER_CONVOLUTION) &&
        (owner_q != OWNER_TENSOR) &&
        !convolution_claim_i &&
        !tensor_claim_i &&
        shared_start_ready_i;

    assign software_claim =
        software_a_write_enable_i ||
        software_b_write_enable_i ||
        (
            software_start_i &&
            software_start_ready_o
        );

    // Convolution has highest autonomous-client priority.
    assign convolution_available_o =
        rst_ni &&
        (owner_q == OWNER_NONE) &&
        shared_start_ready_i;

    // Tensor may accept only when convolution is not claiming in this cycle.
    assign tensor_available_o =
        rst_ni &&
        (owner_q == OWNER_NONE) &&
        !convolution_claim_i;

    assign convolution_start_ready_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_start_ready_i
        : 1'b0;

    assign tensor_start_ready_o =
        (owner_q == OWNER_TENSOR)
        ? shared_start_ready_i
        : 1'b0;

    // -------------------------------------------------------------------------
    // Busy and pulse-response isolation
    // -------------------------------------------------------------------------

    assign software_busy_o =
        shared_busy_i ||
        (owner_q == OWNER_CONVOLUTION) ||
        (owner_q == OWNER_TENSOR) ||
        convolution_claim_i ||
        tensor_claim_i;

    assign convolution_busy_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_busy_i
        : 1'b0;

    assign tensor_busy_o =
        (owner_q == OWNER_TENSOR)
        ? shared_busy_i
        : 1'b0;

    assign software_done_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_done_i
        : 1'b0;

    assign software_error_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_error_i
        : 1'b0;

    assign software_error_code_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_error_code_i
        : 3'd0;

    assign convolution_done_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_done_i
        : 1'b0;

    assign convolution_error_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_error_i
        : 1'b0;

    assign convolution_error_code_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_error_code_i
        : 3'd0;

    assign tensor_done_o =
        (owner_q == OWNER_TENSOR)
        ? shared_done_i
        : 1'b0;

    assign tensor_error_o =
        (owner_q == OWNER_TENSOR)
        ? shared_error_i
        : 1'b0;

    assign tensor_error_code_o =
        (owner_q == OWNER_TENSOR)
        ? shared_error_code_i
        : 3'd0;

    // -------------------------------------------------------------------------
    // Software response context
    // -------------------------------------------------------------------------

    assign software_m_tile_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_m_tile_i
        : 1'b0;

    assign software_n_tile_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_n_tile_i
        : 1'b0;

    assign software_k_tile_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_k_tile_i
        : 1'b0;

    assign software_a_valid_mask_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_a_valid_mask_i
        : 64'd0;

    assign software_b_valid_mask_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_b_valid_mask_i
        : 64'd0;

    assign software_accumulator_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_accumulator_i
        : 2048'd0;

    assign software_accumulator_valid_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_accumulator_valid_i
        : 64'd0;

    assign software_invalid_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_invalid_i
        : 64'd0;

    assign software_overflow_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_overflow_i
        : 64'd0;

    assign software_underflow_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_underflow_i
        : 64'd0;

    assign software_inexact_o =
        (owner_q == OWNER_SOFTWARE)
        ? shared_inexact_i
        : 64'd0;

    // -------------------------------------------------------------------------
    // Convolution response context
    // -------------------------------------------------------------------------

    assign convolution_accumulator_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_accumulator_i
        : 2048'd0;

    assign convolution_accumulator_valid_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_accumulator_valid_i
        : 64'd0;

    assign convolution_invalid_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_invalid_i
        : 64'd0;

    assign convolution_overflow_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_overflow_i
        : 64'd0;

    assign convolution_underflow_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_underflow_i
        : 64'd0;

    assign convolution_inexact_o =
        (owner_q == OWNER_CONVOLUTION)
        ? shared_inexact_i
        : 64'd0;

    // -------------------------------------------------------------------------
    // Tensor response context
    // -------------------------------------------------------------------------

    assign tensor_accumulator_o =
        (owner_q == OWNER_TENSOR)
        ? shared_accumulator_i
        : 2048'd0;

    assign tensor_accumulator_valid_o =
        (owner_q == OWNER_TENSOR)
        ? shared_accumulator_valid_i
        : 64'd0;

    assign tensor_invalid_o =
        (owner_q == OWNER_TENSOR)
        ? shared_invalid_i
        : 64'd0;

    assign tensor_overflow_o =
        (owner_q == OWNER_TENSOR)
        ? shared_overflow_i
        : 64'd0;

    assign tensor_underflow_o =
        (owner_q == OWNER_TENSOR)
        ? shared_underflow_i
        : 64'd0;

    assign tensor_inexact_o =
        (owner_q == OWNER_TENSOR)
        ? shared_inexact_i
        : 64'd0;

    // -------------------------------------------------------------------------
    // Ownership state
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            owner_q <=
                OWNER_NONE;
        end
        else begin
            case (owner_q)
                OWNER_NONE: begin
                    if (convolution_claim_i) begin
                        owner_q <=
                            OWNER_CONVOLUTION;
                    end
                    else if (tensor_claim_i) begin
                        owner_q <=
                            OWNER_TENSOR;
                    end
                    else if (software_claim) begin
                        owner_q <=
                            OWNER_SOFTWARE;
                    end
                end

                OWNER_SOFTWARE: begin
                    if (software_clear_i) begin
                        owner_q <=
                            OWNER_NONE;
                    end
                end

                OWNER_CONVOLUTION: begin
                    if (convolution_release_i) begin
                        owner_q <=
                            OWNER_NONE;
                    end
                end

                OWNER_TENSOR: begin
                    if (tensor_release_i) begin
                        owner_q <=
                            OWNER_NONE;
                    end
                end

                default: begin
                    owner_q <=
                        OWNER_NONE;
                end
            endcase
        end
    end

    // Convolution has final request-routing priority.
    assign select_convolution =
        (owner_q == OWNER_CONVOLUTION) ||
        (
            (owner_q == OWNER_NONE) &&
            (
                convolution_claim_i ||
                convolution_clear_i
            )
        );

    assign select_tensor =
        (owner_q == OWNER_TENSOR) ||
        (
            (owner_q == OWNER_NONE) &&
            !convolution_claim_i &&
            (
                tensor_claim_i ||
                tensor_clear_i
            )
        );

    // -------------------------------------------------------------------------
    // Request multiplexer
    // -------------------------------------------------------------------------

    always @* begin
        // Software is the default path while unowned or software-owned.
        shared_clear_o =
            software_clear_i &&
            (owner_q != OWNER_CONVOLUTION) &&
            (owner_q != OWNER_TENSOR) &&
            !convolution_claim_i &&
            !tensor_claim_i;

        shared_a_write_enable_o =
            software_a_write_enable_i &&
            (owner_q != OWNER_CONVOLUTION) &&
            (owner_q != OWNER_TENSOR) &&
            !convolution_claim_i &&
            !tensor_claim_i;

        shared_a_write_addr_o =
            software_a_write_addr_i;

        shared_a_write_data_o =
            software_a_write_data_i;

        shared_b_write_enable_o =
            software_b_write_enable_i &&
            (owner_q != OWNER_CONVOLUTION) &&
            (owner_q != OWNER_TENSOR) &&
            !convolution_claim_i &&
            !tensor_claim_i;

        shared_b_write_addr_o =
            software_b_write_addr_i;

        shared_b_write_data_o =
            software_b_write_data_i;

        shared_start_o =
            software_start_i &&
            software_start_ready_o;

        shared_precision_o =
            software_precision_i;

        shared_k_token_count_o =
            software_k_token_count_i;

        if (select_tensor) begin
            shared_clear_o =
                tensor_clear_i;

            shared_a_write_enable_o =
                tensor_a_write_enable_i;

            shared_a_write_addr_o =
                tensor_a_write_addr_i;

            shared_a_write_data_o =
                tensor_a_write_data_i;

            shared_b_write_enable_o =
                tensor_b_write_enable_i;

            shared_b_write_addr_o =
                tensor_b_write_addr_i;

            shared_b_write_data_o =
                tensor_b_write_data_i;

            shared_start_o =
                tensor_start_i &&
                tensor_start_ready_o;

            shared_precision_o =
                tensor_precision_i;

            shared_k_token_count_o =
                tensor_k_token_count_i;
        end

        if (select_convolution) begin
            shared_clear_o =
                convolution_clear_i;

            shared_a_write_enable_o =
                convolution_a_write_enable_i;

            shared_a_write_addr_o =
                convolution_a_write_addr_i;

            shared_a_write_data_o =
                convolution_a_write_data_i;

            shared_b_write_enable_o =
                convolution_b_write_enable_i;

            shared_b_write_addr_o =
                convolution_b_write_addr_i;

            shared_b_write_data_o =
                convolution_b_write_data_i;

            shared_start_o =
                convolution_start_i &&
                convolution_start_ready_o;

            shared_precision_o =
                convolution_precision_i;

            shared_k_token_count_o =
                convolution_k_token_count_i;
        end
    end


    // -------------------------------------------------------------------------
    // Simulation ownership assertions
    //
    // These checks are intentionally excluded from synthesis. They protect
    // arbitration invariants during unit and complete-top simulation.
    // -------------------------------------------------------------------------

`ifndef SYNTHESIS
    // Ordinary procedural block is used because this block contains only
    // simulation checks and does not describe sequential hardware.
    always @(posedge clk_i or negedge rst_ni) begin
        if (rst_ni) begin
            assert (
                owner_q == OWNER_NONE ||
                owner_q == OWNER_SOFTWARE ||
                owner_q == OWNER_CONVOLUTION ||
                owner_q == OWNER_TENSOR
            )
            else begin
                $fatal(
                    1,
                    "Illegal tiled-GEMM client owner value: %0d",
                    owner_q
                );
            end

            assert (
                !(select_convolution && select_tensor)
            )
            else begin
                $fatal(
                    1,
                    "Convolution and tensor were selected simultaneously"
                );
            end

            assert (
                !(
                    software_done_o &&
                    (
                        convolution_done_o ||
                        tensor_done_o
                    )
                ) &&
                !(
                    convolution_done_o &&
                    tensor_done_o
                )
            )
            else begin
                $fatal(
                    1,
                    "Shared completion leaked to multiple clients"
                );
            end

            assert (
                !(
                    software_error_o &&
                    (
                        convolution_error_o ||
                        tensor_error_o
                    )
                ) &&
                !(
                    convolution_error_o &&
                    tensor_error_o
                )
            )
            else begin
                $fatal(
                    1,
                    "Shared error leaked to multiple clients"
                );
            end

            if (
                software_done_o ||
                software_error_o
            ) begin
                assert (
                    owner_q == OWNER_SOFTWARE
                )
                else begin
                    $fatal(
                        1,
                        "Software response occurred without software ownership"
                    );
                end
            end

            if (
                convolution_done_o ||
                convolution_error_o
            ) begin
                assert (
                    owner_q == OWNER_CONVOLUTION
                )
                else begin
                    $fatal(
                        1,
                        "Convolution response occurred without convolution ownership"
                    );
                end
            end

            if (
                tensor_done_o ||
                tensor_error_o
            ) begin
                assert (
                    owner_q == OWNER_TENSOR
                )
                else begin
                    $fatal(
                        1,
                        "Tensor response occurred without tensor ownership"
                    );
                end
            end

            if (owner_q != OWNER_NONE) begin
                assert (
                    !convolution_available_o &&
                    !tensor_available_o
                )
                else begin
                    $fatal(
                        1,
                        "Autonomous client advertised availability while owned"
                    );
                end
            end
        end
    end
`endif

endmodule

`default_nettype wire
