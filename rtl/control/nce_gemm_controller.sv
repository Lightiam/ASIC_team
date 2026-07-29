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
// Register-resident GEMM K-loop controller.
//
// The controller performs one output-vector accumulation:
//
//   accumulator[lane] +=
//       vector_register[vector_base + k] *
//       matrix_register[matrix_base + k]
//
// for k = 0 .. K-1.
//
// One command is kept outstanding at a time. The controller waits for the
// corresponding accumulator update before issuing the next command.
//
// Supported precision mappings:
//
//   INT8X4 -> DOT4_MAC
//   BF16X2 -> MAC
//   BF24   -> MAC
//
// K must be in the range 1..16. Source-address ranges must not wrap beyond
// architectural register address 15.
// -----------------------------------------------------------------------------

module nce_gemm_controller #(
    parameter logic [3:0] MAC_OPCODE        = 4'h3,
    parameter logic [3:0] DOT4_MAC_OPCODE   = 4'h4,

    parameter logic [1:0] INT8X4_PRECISION  = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION  = 2'b01,
    parameter logic [1:0] BF24_PRECISION    = 2'b10
) (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       flush_i,

    // GEMM configuration/start interface
    input  logic       start_i,
    output logic       start_ready_o,

    input  logic [1:0] precision_i,
    input  logic [3:0] vector_base_addr_i,
    input  logic [3:0] matrix_base_addr_i,
    input  logic [4:0] k_count_i,

    // Command stream toward the existing command core
    output logic       cmd_valid_o,
    input  logic       cmd_ready_i,

    output logic [3:0] cmd_opcode_o,
    output logic [1:0] cmd_precision_o,
    output logic [3:0] cmd_vector_source_addr_o,
    output logic [3:0] cmd_matrix_source_addr_o,

    // Command-core response
    input  logic       cmd_error_i,
    input  logic [1:0] cmd_error_code_i,
    input  logic       execute_issue_i,
    input  logic       accumulator_update_i,

    // Controller status
    output logic       busy_o,
    output logic       done_o,
    output logic       error_o,
    output logic [2:0] error_code_o,
    output logic [1:0] command_error_code_o,

    output logic [4:0] completed_iterations_o,
    output logic [4:0] total_iterations_o
);

    localparam logic [2:0] ERROR_NONE              = 3'd0;
    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_VECTOR_RANGE      = 3'd3;
    localparam logic [2:0] ERROR_MATRIX_RANGE      = 3'd4;
    localparam logic [2:0] ERROR_COMMAND_REJECTED  = 3'd5;
    localparam logic [2:0] ERROR_ISSUE_PROTOCOL    = 3'd6;

    localparam logic [1:0] STATE_IDLE        = 2'd0;
    localparam logic [1:0] STATE_ISSUE       = 2'd1;
    localparam logic [1:0] STATE_WAIT_RESULT = 2'd2;

    logic [1:0] state_q;

    logic [1:0] precision_q;
    logic [3:0] vector_addr_q;
    logic [3:0] matrix_addr_q;

    logic [4:0] k_count_q;
    logic [4:0] completed_iterations_q;

    logic [4:0] vector_last_address;
    logic [4:0] matrix_last_address;

    logic [2:0] configuration_error;

    assign vector_last_address =
        {1'b0, vector_base_addr_i} +
        k_count_i -
        5'd1;

    assign matrix_last_address =
        {1'b0, matrix_base_addr_i} +
        k_count_i -
        5'd1;

    always_comb begin
        configuration_error = ERROR_NONE;

        if (
            precision_i != INT8X4_PRECISION &&
            precision_i != BF16X2_PRECISION &&
            precision_i != BF24_PRECISION
        ) begin
            configuration_error =
                ERROR_INVALID_PRECISION;
        end
        else if (
            k_count_i == 5'd0 ||
            k_count_i > 5'd16
        ) begin
            configuration_error =
                ERROR_INVALID_K;
        end
        else if (vector_last_address > 5'd15) begin
            configuration_error =
                ERROR_VECTOR_RANGE;
        end
        else if (matrix_last_address > 5'd15) begin
            configuration_error =
                ERROR_MATRIX_RANGE;
        end
    end

    assign start_ready_o =
        (state_q == STATE_IDLE);

    assign busy_o =
        (state_q != STATE_IDLE);

    assign cmd_valid_o =
        (state_q == STATE_ISSUE);

    assign cmd_precision_o =
        precision_q;

    assign cmd_opcode_o =
        (precision_q == INT8X4_PRECISION)
        ? DOT4_MAC_OPCODE
        : MAC_OPCODE;

    assign cmd_vector_source_addr_o =
        vector_addr_q;

    assign cmd_matrix_source_addr_o =
        matrix_addr_q;

    assign completed_iterations_o =
        completed_iterations_q;

    assign total_iterations_o =
        k_count_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;

            precision_q   <= INT8X4_PRECISION;
            vector_addr_q <= 4'd0;
            matrix_addr_q <= 4'd0;

            k_count_q              <= 5'd0;
            completed_iterations_q <= 5'd0;

            done_o  <= 1'b0;
            error_o <= 1'b0;

            error_code_o         <= ERROR_NONE;
            command_error_code_o <= 2'd0;
        end
        else begin
            done_o  <= 1'b0;
            error_o <= 1'b0;

            if (flush_i) begin
                state_q <= STATE_IDLE;

                precision_q   <= INT8X4_PRECISION;
                vector_addr_q <= 4'd0;
                matrix_addr_q <= 4'd0;

                k_count_q              <= 5'd0;
                completed_iterations_q <= 5'd0;

                error_code_o         <= ERROR_NONE;
                command_error_code_o <= 2'd0;
            end
            else begin
                case (state_q)
                    STATE_IDLE: begin
                        if (start_i) begin
                            completed_iterations_q <= 5'd0;
                            command_error_code_o   <= 2'd0;

                            if (
                                configuration_error !=
                                ERROR_NONE
                            ) begin
                                k_count_q <= 5'd0;

                                error_o      <= 1'b1;
                                error_code_o <=
                                    configuration_error;
                            end
                            else begin
                                precision_q <= precision_i;

                                vector_addr_q <=
                                    vector_base_addr_i;

                                matrix_addr_q <=
                                    matrix_base_addr_i;

                                k_count_q <= k_count_i;

                                error_code_o <= ERROR_NONE;
                                state_q      <= STATE_ISSUE;
                            end
                        end
                    end

                    STATE_ISSUE: begin
                        if (cmd_ready_i) begin
                            if (cmd_error_i) begin
                                error_o <= 1'b1;

                                error_code_o <=
                                    ERROR_COMMAND_REJECTED;

                                command_error_code_o <=
                                    cmd_error_code_i;

                                state_q <= STATE_IDLE;
                            end
                            else if (!execute_issue_i) begin
                                error_o <= 1'b1;

                                error_code_o <=
                                    ERROR_ISSUE_PROTOCOL;

                                state_q <= STATE_IDLE;
                            end
                            else begin
                                state_q <= STATE_WAIT_RESULT;
                            end
                        end
                    end

                    STATE_WAIT_RESULT: begin
                        if (accumulator_update_i) begin
                            completed_iterations_q <=
                                completed_iterations_q +
                                5'd1;

                            if (
                                completed_iterations_q +
                                5'd1
                                ==
                                k_count_q
                            ) begin
                                done_o  <= 1'b1;
                                state_q <= STATE_IDLE;
                            end
                            else begin
                                vector_addr_q <=
                                    vector_addr_q +
                                    4'd1;

                                matrix_addr_q <=
                                    matrix_addr_q +
                                    4'd1;

                                state_q <= STATE_ISSUE;
                            end
                        end
                    end

                    default: begin
                        state_q <= STATE_IDLE;

                        error_o      <= 1'b1;
                        error_code_o <=
                            ERROR_ISSUE_PROTOCOL;
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
