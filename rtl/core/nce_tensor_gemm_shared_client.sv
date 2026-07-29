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
// Autonomous tensor-memory GEMM execution subsystem.
//
// Command:
//   * activation memory contains a compact row-major 8 x K token matrix;
//   * weight memory contains a compact row-major K x 8 token matrix;
//   * output memory receives a row-major 8 x 8 FP32 result matrix.
//
// Completion is reported only after all 64 FP32 result words have been
// accepted by the output/PSUM scratchpad.
//
// This shared-client implementation does not instantiate a physical GEMM
// engine. It claims and drives an externally supplied tiled 8x8 controller,
// allowing tensor GEMM, convolution, and software-programmed tiled GEMM to
// reuse one shared physical 4x4 systolic array.
// -----------------------------------------------------------------------------

module nce_tensor_gemm_shared_client #(
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
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // -------------------------------------------------------------------------
    // Autonomous tensor GEMM command
    // -------------------------------------------------------------------------

    input  logic start_i,
    output logic start_ready_o,

    input  logic [FLAT_ADDR_WIDTH-1:0] activation_base_addr_i,
    input  logic [FLAT_ADDR_WIDTH-1:0] weight_base_addr_i,
    input  logic [FLAT_ADDR_WIDTH-1:0] output_base_addr_i,

    input  logic [1:0] precision_i,
    input  logic [3:0] k_token_count_i,

    // -------------------------------------------------------------------------
    // Activation scratchpad reads
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] activation_read_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] activation_read_addr_o,

    input  logic [PORT_COUNT-1:0] activation_read_ready_i,
    input  logic [PORT_COUNT-1:0] activation_read_conflict_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] activation_read_data_i,

    input  logic [PORT_COUNT-1:0] activation_read_valid_i,

    // -------------------------------------------------------------------------
    // Weight scratchpad reads
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] weight_read_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] weight_read_addr_o,

    input  logic [PORT_COUNT-1:0] weight_read_ready_i,
    input  logic [PORT_COUNT-1:0] weight_read_conflict_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] weight_read_data_i,

    input  logic [PORT_COUNT-1:0] weight_read_valid_i,

    // -------------------------------------------------------------------------
    // Output/PSUM scratchpad writes
    // -------------------------------------------------------------------------

    output logic [PORT_COUNT-1:0] output_write_enable_o,

    output logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_write_addr_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_write_data_o,

    output logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] output_write_strb_o,

    input  logic [PORT_COUNT-1:0] output_write_ready_i,
    input  logic [PORT_COUNT-1:0] output_write_conflict_i,

    // -------------------------------------------------------------------------
    // External shared tiled-GEMM client interface
    // -------------------------------------------------------------------------

    // High only when the tiled-client ownership mux can accept a tensor claim.
    input  logic tiled_available_i,

    // Pulses when a validated high-level tensor command is accepted.
    output logic tiled_claim_o,

    // Pulses after compute completion, tiled error, abort, or explicit clear.
    output logic tiled_release_o,

    // Clears the shared tiled controller while tensor owns its context.
    output logic tiled_clear_o,

    output logic tiled_a_write_enable_o,
    output logic [5:0] tiled_a_write_addr_o,
    output logic [31:0] tiled_a_write_data_o,

    output logic tiled_b_write_enable_o,
    output logic [5:0] tiled_b_write_addr_o,
    output logic [31:0] tiled_b_write_data_o,

    output logic tiled_start_o,
    input  logic tiled_start_ready_i,

    output logic [1:0] tiled_precision_o,
    output logic [3:0] tiled_k_token_count_o,

    input  logic tiled_busy_i,
    input  logic tiled_done_i,
    input  logic tiled_error_i,
    input  logic [2:0] tiled_error_code_i,

    input  logic tiled_m_tile_i,
    input  logic tiled_n_tile_i,
    input  logic tiled_k_tile_i,

    input  logic [63:0] tiled_a_valid_mask_i,
    input  logic [63:0] tiled_b_valid_mask_i,

    input  logic [2047:0] tiled_accumulator_i,
    input  logic [63:0] tiled_accumulator_valid_i,

    input  logic [63:0] tiled_invalid_i,
    input  logic [63:0] tiled_overflow_i,
    input  logic [63:0] tiled_underflow_i,
    input  logic [63:0] tiled_inexact_i,

    // -------------------------------------------------------------------------
    // Command status
    // -------------------------------------------------------------------------

    output logic busy_o,

    // Pulses after the tiled GEMM calculation completes, before output-memory
    // writeback necessarily completes.
    output logic compute_done_o,

    // Pulses only after all 64 output words have been accepted.
    output logic done_o,

    output logic error_o,

    // 0: command/configuration, 1: feeder, 2: result writer, 3: internal.
    output logic [1:0] error_source_o,

    output logic [2:0] error_code_o,
    output logic [2:0] error_detail_o,

    output logic [WORD_COUNT_WIDTH-1:0] words_loaded_o,
    output logic [6:0] words_written_o,

    // Complete tiled-GEMM result and arithmetic status.
    output logic [2047:0] result_data_o,
    output logic [63:0] result_valid_o,

    output logic [63:0] invalid_o,
    output logic [63:0] overflow_o,
    output logic [63:0] underflow_o,
    output logic [63:0] inexact_o
);

    localparam logic [1:0] INT8X4_PRECISION = 2'b00;
    localparam logic [1:0] BF16X2_PRECISION = 2'b01;
    localparam logic [1:0] BF24_PRECISION   = 2'b10;

    localparam logic STATE_IDLE = 1'b0;
    localparam logic STATE_RUN  = 1'b1;

    localparam logic [1:0] ERROR_SOURCE_COMMAND = 2'd0;
    localparam logic [1:0] ERROR_SOURCE_FEEDER  = 2'd1;
    localparam logic [1:0] ERROR_SOURCE_WRITER  = 2'd2;
    localparam logic [1:0] ERROR_SOURCE_INTERNAL = 2'd3;

    localparam logic [2:0] ERROR_NONE              = 3'd0;
    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_ACTIVATION_RANGE  = 3'd3;
    localparam logic [2:0] ERROR_WEIGHT_RANGE      = 3'd4;
    localparam logic [2:0] ERROR_OUTPUT_RANGE      = 3'd5;
    localparam logic [2:0] ERROR_INTERNAL_STATE    = 3'd6;

    localparam int unsigned RANGE_WIDTH =
        FLAT_ADDR_WIDTH + 1;

    localparam logic [RANGE_WIDTH-1:0] TOTAL_WORDS_EXT =
        RANGE_WIDTH'(TOTAL_WORDS);

    logic state_q;

    // The ownership mux isolates inactive clients by returning zeros. Preserve
    // the completed tensor result before releasing tiled-controller ownership.
    logic [2047:0] result_snapshot_q;
    logic [63:0]   result_valid_snapshot_q;

    logic [63:0] invalid_snapshot_q;
    logic [63:0] overflow_snapshot_q;
    logic [63:0] underflow_snapshot_q;
    logic [63:0] inexact_snapshot_q;

    logic precision_valid;
    logic k_count_valid;

    logic [WORD_COUNT_WIDTH-1:0] operand_word_count;

    logic [RANGE_WIDTH-1:0] activation_end_ext;
    logic [RANGE_WIDTH-1:0] weight_end_ext;
    logic [RANGE_WIDTH-1:0] output_end_ext;

    logic [2:0] configuration_error;

    logic command_accept;
    logic valid_command_accept;

    logic submodule_clear;
    logic internal_abort;

    // -------------------------------------------------------------------------
    // Feeder signals
    // -------------------------------------------------------------------------

    logic feeder_start;
    logic feeder_start_ready;

    logic feeder_busy;
    logic feeder_done;
    logic feeder_error;
    logic [2:0] feeder_error_code;
    logic [2:0] feeder_error_detail;

    logic tiled_a_write_enable;
    logic [5:0] tiled_a_write_addr;
    logic [31:0] tiled_a_write_data;

    logic tiled_b_write_enable;
    logic [5:0] tiled_b_write_addr;
    logic [31:0] tiled_b_write_data;

    logic tiled_start;
    logic tiled_start_ready;
    logic [1:0] tiled_precision;
    logic [3:0] tiled_k_token_count;

    // -------------------------------------------------------------------------
    // Tiled-GEMM signals
    // -------------------------------------------------------------------------

    logic tiled_busy;
    logic tiled_done;
    logic tiled_error;
    logic [2:0] tiled_error_code;

    logic [63:0] tiled_a_valid_mask;
    logic [63:0] tiled_b_valid_mask;

    logic tiled_m_tile;
    logic tiled_n_tile;
    logic tiled_k_tile;

    logic [2047:0] tiled_accumulator;
    logic [63:0] tiled_accumulator_valid;

    logic [63:0] tiled_invalid;
    logic [63:0] tiled_overflow;
    logic [63:0] tiled_underflow;
    logic [63:0] tiled_inexact;

    // -------------------------------------------------------------------------
    // Result-writer signals
    // -------------------------------------------------------------------------

    logic writer_start;
    logic writer_start_ready;

    logic writer_busy;
    logic writer_waiting;
    logic writer_done;
    logic writer_error;
    logic [2:0] writer_error_code;

    // -------------------------------------------------------------------------
    // Command validation
    // -------------------------------------------------------------------------

    assign operand_word_count =
        WORD_COUNT_WIDTH'(k_token_count_i) << 3;

    always @* begin
        precision_valid =
            (precision_i == INT8X4_PRECISION) ||
            (precision_i == BF16X2_PRECISION) ||
            (precision_i == BF24_PRECISION);

        k_count_valid =
            (k_token_count_i >= 4'd1) &&
            (k_token_count_i <= 4'd8);

        activation_end_ext =
            RANGE_WIDTH'(activation_base_addr_i) +
            RANGE_WIDTH'(operand_word_count);

        weight_end_ext =
            RANGE_WIDTH'(weight_base_addr_i) +
            RANGE_WIDTH'(operand_word_count);

        output_end_ext =
            RANGE_WIDTH'(output_base_addr_i) +
            RANGE_WIDTH'(64);

        configuration_error =
            ERROR_NONE;

        if (!precision_valid) begin
            configuration_error =
                ERROR_INVALID_PRECISION;
        end
        else if (!k_count_valid) begin
            configuration_error =
                ERROR_INVALID_K;
        end
        else if (
            activation_end_ext >
            TOTAL_WORDS_EXT
        ) begin
            configuration_error =
                ERROR_ACTIVATION_RANGE;
        end
        else if (
            weight_end_ext >
            TOTAL_WORDS_EXT
        ) begin
            configuration_error =
                ERROR_WEIGHT_RANGE;
        end
        else if (
            output_end_ext >
            TOTAL_WORDS_EXT
        ) begin
            configuration_error =
                ERROR_OUTPUT_RANGE;
        end
    end

    assign busy_o =
        (state_q == STATE_RUN);

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        (state_q == STATE_IDLE) &&
        tiled_available_i &&
        feeder_start_ready &&
        writer_start_ready;

    assign command_accept =
        start_i &&
        start_ready_o;

    assign valid_command_accept =
        command_accept &&
        (configuration_error == ERROR_NONE);

    assign feeder_start =
        valid_command_accept;

    assign writer_start =
        valid_command_accept;

    assign compute_done_o =
        feeder_done;

    assign result_data_o =
        result_snapshot_q;

    assign result_valid_o =
        result_valid_snapshot_q;

    assign invalid_o =
        invalid_snapshot_q;

    assign overflow_o =
        overflow_snapshot_q;

    assign underflow_o =
        underflow_snapshot_q;

    assign inexact_o =
        inexact_snapshot_q;

    // A feeder or writer error aborts every participating submodule on the
    // same active edge on which the top-level error is recorded.
    assign internal_abort =
        (state_q == STATE_RUN) &&
        (
            feeder_error ||
            writer_error
        );

    assign submodule_clear =
        clear_i ||
        internal_abort;

    // -------------------------------------------------------------------------
    // Ownership claim and completed-result context
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            result_snapshot_q <=
                2048'd0;

            result_valid_snapshot_q <=
                64'd0;

            invalid_snapshot_q <=
                64'd0;

            overflow_snapshot_q <=
                64'd0;

            underflow_snapshot_q <=
                64'd0;

            inexact_snapshot_q <=
                64'd0;
        end
        else if (clear_i) begin
            result_snapshot_q <=
                2048'd0;

            result_valid_snapshot_q <=
                64'd0;

            invalid_snapshot_q <=
                64'd0;

            overflow_snapshot_q <=
                64'd0;

            underflow_snapshot_q <=
                64'd0;

            inexact_snapshot_q <=
                64'd0;
        end
        else begin
            // Remove stale result context as soon as a new command is accepted.
            if (valid_command_accept) begin
                result_snapshot_q <=
                    2048'd0;

                result_valid_snapshot_q <=
                    64'd0;

                invalid_snapshot_q <=
                    64'd0;

                overflow_snapshot_q <=
                    64'd0;

                underflow_snapshot_q <=
                    64'd0;

                inexact_snapshot_q <=
                    64'd0;
            end
            else if (
                (state_q == STATE_RUN) &&
                tiled_done
            ) begin
                // Capture while the tensor client still owns the shared tiled
                // controller. Ownership may be released immediately afterward.
                result_snapshot_q <=
                    tiled_accumulator;

                result_valid_snapshot_q <=
                    tiled_accumulator_valid;

                invalid_snapshot_q <=
                    tiled_invalid;

                overflow_snapshot_q <=
                    tiled_overflow;

                underflow_snapshot_q <=
                    tiled_underflow;

                inexact_snapshot_q <=
                    tiled_inexact;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Top-level command state
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <=
                STATE_IDLE;

            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_source_o <=
                ERROR_SOURCE_COMMAND;

            error_code_o <=
                ERROR_NONE;

            error_detail_o <=
                3'd0;
        end
        else if (clear_i) begin
            state_q <=
                STATE_IDLE;

            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_source_o <=
                ERROR_SOURCE_COMMAND;

            error_code_o <=
                ERROR_NONE;

            error_detail_o <=
                3'd0;
        end
        else begin
            done_o <=
                1'b0;

            error_o <=
                1'b0;

            error_source_o <=
                ERROR_SOURCE_COMMAND;

            error_code_o <=
                ERROR_NONE;

            error_detail_o <=
                3'd0;

            case (state_q)
                STATE_IDLE: begin
                    if (command_accept) begin
                        if (
                            configuration_error !=
                            ERROR_NONE
                        ) begin
                            error_o <=
                                1'b1;

                            error_source_o <=
                                ERROR_SOURCE_COMMAND;

                            error_code_o <=
                                configuration_error;
                        end
                        else begin
                            state_q <=
                                STATE_RUN;
                        end
                    end
                end

                STATE_RUN: begin
                    if (feeder_error) begin
                        state_q <=
                            STATE_IDLE;

                        error_o <=
                            1'b1;

                        error_source_o <=
                            ERROR_SOURCE_FEEDER;

                        error_code_o <=
                            feeder_error_code;

                        error_detail_o <=
                            feeder_error_detail;
                    end
                    else if (writer_error) begin
                        state_q <=
                            STATE_IDLE;

                        error_o <=
                            1'b1;

                        error_source_o <=
                            ERROR_SOURCE_WRITER;

                        error_code_o <=
                            writer_error_code;
                    end
                    else if (writer_done) begin
                        state_q <=
                            STATE_IDLE;

                        done_o <=
                            1'b1;
                    end
                end

                default: begin
                    state_q <=
                        STATE_IDLE;

                    error_o <=
                        1'b1;

                    error_source_o <=
                        ERROR_SOURCE_INTERNAL;

                    error_code_o <=
                        ERROR_INTERNAL_STATE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Tensor-memory feeder
    // -------------------------------------------------------------------------

    nce_tensor_gemm_feeder #(
        .BANK_COUNT          (BANK_COUNT),
        .WORDS_PER_BANK      (WORDS_PER_BANK),
        .DATA_WIDTH          (DATA_WIDTH),
        .PORT_COUNT          (PORT_COUNT),
        .BANK_INDEX_WIDTH    (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH     (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH     (FLAT_ADDR_WIDTH),
        .TOTAL_WORDS         (TOTAL_WORDS),
        .WORD_COUNT_WIDTH    (WORD_COUNT_WIDTH)
    ) u_feeder (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (submodule_clear),

        .start_i                     (feeder_start),
        .start_ready_o               (feeder_start_ready),

        .activation_base_addr_i      (activation_base_addr_i),
        .weight_base_addr_i          (weight_base_addr_i),

        .precision_i                 (precision_i),
        .k_token_count_i             (k_token_count_i),

        .activation_read_enable_o    (activation_read_enable_o),
        .activation_read_addr_o      (activation_read_addr_o),
        .activation_read_ready_i     (activation_read_ready_i),
        .activation_read_conflict_i  (activation_read_conflict_i),
        .activation_read_data_i      (activation_read_data_i),
        .activation_read_valid_i     (activation_read_valid_i),

        .weight_read_enable_o        (weight_read_enable_o),
        .weight_read_addr_o          (weight_read_addr_o),
        .weight_read_ready_i         (weight_read_ready_i),
        .weight_read_conflict_i      (weight_read_conflict_i),
        .weight_read_data_i          (weight_read_data_i),
        .weight_read_valid_i         (weight_read_valid_i),

        .tiled_a_write_enable_o      (tiled_a_write_enable),
        .tiled_a_write_addr_o        (tiled_a_write_addr),
        .tiled_a_write_data_o        (tiled_a_write_data),

        .tiled_b_write_enable_o      (tiled_b_write_enable),
        .tiled_b_write_addr_o        (tiled_b_write_addr),
        .tiled_b_write_data_o        (tiled_b_write_data),

        .tiled_start_o               (tiled_start),
        .tiled_start_ready_i         (tiled_start_ready),

        .tiled_precision_o           (tiled_precision),
        .tiled_k_token_count_o       (tiled_k_token_count),

        .tiled_busy_i                (tiled_busy),
        .tiled_done_i                (tiled_done),
        .tiled_error_i               (tiled_error),
        .tiled_error_code_i          (tiled_error_code),

        .busy_o                      (feeder_busy),
        .done_o                      (feeder_done),
        .error_o                     (feeder_error),
        .error_code_o                (feeder_error_code),
        .error_detail_o              (feeder_error_detail),

        .words_loaded_o              (words_loaded_o)
    );

    // -------------------------------------------------------------------------
    // External shared tiled-controller adapter
    // -------------------------------------------------------------------------

    // Claim ownership in the same cycle in which the validated tensor command
    // is accepted. Tensor availability is ownership-only, so this path does not
    // feed back through tiled-controller or physical-engine readiness.
    assign tiled_claim_o =
        valid_command_accept;

    assign tiled_release_o =
        clear_i ||
        internal_abort ||
        (
            (state_q == STATE_RUN) &&
            (
                tiled_done_i ||
                tiled_error_i
            )
        );

    assign tiled_clear_o =
        submodule_clear;

    assign tiled_a_write_enable_o =
        tiled_a_write_enable;

    assign tiled_a_write_addr_o =
        tiled_a_write_addr;

    assign tiled_a_write_data_o =
        tiled_a_write_data;

    assign tiled_b_write_enable_o =
        tiled_b_write_enable;

    assign tiled_b_write_addr_o =
        tiled_b_write_addr;

    assign tiled_b_write_data_o =
        tiled_b_write_data;

    assign tiled_start_o =
        tiled_start;

    assign tiled_precision_o =
        tiled_precision;

    assign tiled_k_token_count_o =
        tiled_k_token_count;

    assign tiled_start_ready =
        tiled_start_ready_i;

    assign tiled_busy =
        tiled_busy_i;

    assign tiled_done =
        tiled_done_i;

    assign tiled_error =
        tiled_error_i;

    assign tiled_error_code =
        tiled_error_code_i;

    assign tiled_m_tile =
        tiled_m_tile_i;

    assign tiled_n_tile =
        tiled_n_tile_i;

    assign tiled_k_tile =
        tiled_k_tile_i;

    assign tiled_a_valid_mask =
        tiled_a_valid_mask_i;

    assign tiled_b_valid_mask =
        tiled_b_valid_mask_i;

    assign tiled_accumulator =
        tiled_accumulator_i;

    assign tiled_accumulator_valid =
        tiled_accumulator_valid_i;

    assign tiled_invalid =
        tiled_invalid_i;

    assign tiled_overflow =
        tiled_overflow_i;

    assign tiled_underflow =
        tiled_underflow_i;

    assign tiled_inexact =
        tiled_inexact_i;

    // -------------------------------------------------------------------------
    // Row-major result capture and output-memory writeback
    // -------------------------------------------------------------------------

    nce_tensor_result_writer #(
        .BANK_COUNT          (BANK_COUNT),
        .WORDS_PER_BANK      (WORDS_PER_BANK),
        .DATA_WIDTH          (DATA_WIDTH),
        .PORT_COUNT          (PORT_COUNT),
        .RESULT_WORDS        (64),
        .BANK_INDEX_WIDTH    (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH     (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH     (FLAT_ADDR_WIDTH),
        .TOTAL_WORDS         (TOTAL_WORDS),
        .RESULT_INDEX_WIDTH  (6),
        .RESULT_COUNT_WIDTH  (7),
        .BYTE_COUNT          (BYTE_COUNT)
    ) u_result_writer (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (submodule_clear),

        .start_i                     (writer_start),
        .start_ready_o               (writer_start_ready),
        .output_base_addr_i          (output_base_addr_i),

        .capture_i                   (
            tiled_done &&
            (state_q == STATE_RUN)
        ),

        .result_data_i               (tiled_accumulator),
        .result_valid_i              (tiled_accumulator_valid),

        .output_write_enable_o       (output_write_enable_o),
        .output_write_addr_o         (output_write_addr_o),
        .output_write_data_o         (output_write_data_o),
        .output_write_strb_o         (output_write_strb_o),

        .output_write_ready_i        (output_write_ready_i),
        .output_write_conflict_i     (output_write_conflict_i),

        .busy_o                      (writer_busy),
        .waiting_for_result_o        (writer_waiting),

        .done_o                      (writer_done),
        .error_o                     (writer_error),
        .error_code_o                (writer_error_code),

        .words_written_o             (words_written_o)
    );

    // Preserve useful internal status without changing the command interface.
    logic internal_status_unused;

    assign internal_status_unused =
        feeder_busy ^
        writer_busy ^
        writer_waiting ^
        (^tiled_a_valid_mask) ^
        (^tiled_b_valid_mask) ^
        tiled_m_tile ^
        tiled_n_tile ^
        tiled_k_tile;

endmodule

`default_nettype wire
