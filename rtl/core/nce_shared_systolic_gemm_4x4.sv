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
// Shared physical 4x4 systolic-GEMM resource.
//
// Client 0: direct AXI-controlled native 4x4 GEMM.
// Client 1: autonomous 8x8 M/N/K tiled-GEMM controller.
//
// Ownership policy:
//
//   * The direct client acquires ownership when a direct start is accepted.
//   * Direct ownership remains active across consecutive starts, allowing
//     persistent K-tile accumulation.
//   * A direct clear releases direct ownership.
//   * The tiled client acquires ownership when its outer operation is accepted.
//   * Tiled ownership remains active for the complete M/N/K traversal.
//   * Tiled done, error, or clear releases tiled ownership.
//   * A simultaneous initial claim gives priority to the tiled client.
//
// Only one physical nce_systolic_gemm_4x4 is instantiated.
// -----------------------------------------------------------------------------

module nce_shared_systolic_gemm_4x4 #(
    parameter logic [1:0] INT8X4_PRECISION = 2'b00,
    parameter logic [1:0] BF16X2_PRECISION = 2'b01,
    parameter logic [1:0] BF24_PRECISION   = 2'b10
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    // -------------------------------------------------------------------------
    // Direct native-4x4 client
    // -------------------------------------------------------------------------

    input  logic         direct_clear_i,

    input  logic         direct_a_write_enable_i,
    input  logic [3:0]   direct_a_write_addr_i,
    input  logic [31:0]  direct_a_write_data_i,

    input  logic         direct_b_write_enable_i,
    input  logic [3:0]   direct_b_write_addr_i,
    input  logic [31:0]  direct_b_write_data_i,

    input  logic         direct_start_i,
    output logic         direct_start_ready_o,

    input  logic [1:0]   direct_precision_i,
    input  logic [2:0]   direct_k_count_i,
    input  logic         direct_accumulate_i,

    output logic         direct_busy_o,
    output logic         direct_done_o,
    output logic         direct_error_o,
    output logic [2:0]   direct_error_code_o,

    output logic [3:0]   direct_wavefront_cycle_o,

    output logic [15:0]  direct_a_valid_mask_o,
    output logic [15:0]  direct_b_valid_mask_o,

    output logic [511:0] direct_accumulator_o,
    output logic [15:0]  direct_accumulator_valid_o,
    output logic [15:0]  direct_accumulator_update_o,

    output logic [15:0]  direct_mac_fire_mask_o,

    output logic [15:0]  direct_invalid_o,
    output logic [15:0]  direct_overflow_o,
    output logic [15:0]  direct_underflow_o,
    output logic [15:0]  direct_inexact_o,

    // -------------------------------------------------------------------------
    // Tiled-controller ownership
    // -------------------------------------------------------------------------

    // Pulse when the outer tiled operation is accepted.
    input  logic         tiled_claim_i,

    // Pulse when the complete tiled operation finishes, fails, or is cleared.
    input  logic         tiled_release_i,

    // Tells the tiled controller whether it may accept a new outer operation.
    output logic         tiled_engine_available_o,

    // -------------------------------------------------------------------------
    // Tiled controller -> physical engine
    // -------------------------------------------------------------------------

    input  logic         tiled_engine_clear_i,

    input  logic         tiled_engine_a_write_enable_i,
    input  logic [3:0]   tiled_engine_a_write_addr_i,
    input  logic [31:0]  tiled_engine_a_write_data_i,

    input  logic         tiled_engine_b_write_enable_i,
    input  logic [3:0]   tiled_engine_b_write_addr_i,
    input  logic [31:0]  tiled_engine_b_write_data_i,

    input  logic         tiled_engine_start_i,
    output logic         tiled_engine_start_ready_o,

    input  logic [1:0]   tiled_engine_precision_i,
    input  logic [2:0]   tiled_engine_k_count_i,
    input  logic         tiled_engine_accumulate_i,

    // -------------------------------------------------------------------------
    // Physical engine -> tiled controller
    // -------------------------------------------------------------------------

    output logic         tiled_engine_busy_o,
    output logic         tiled_engine_done_o,
    output logic         tiled_engine_error_o,
    output logic [2:0]   tiled_engine_error_code_o,

    output logic [511:0] tiled_engine_accumulator_o,
    output logic [15:0]  tiled_engine_accumulator_valid_o,

    output logic [15:0]  tiled_engine_invalid_o,
    output logic [15:0]  tiled_engine_overflow_o,
    output logic [15:0]  tiled_engine_underflow_o,
    output logic [15:0]  tiled_engine_inexact_o
);

    localparam logic [1:0] OWNER_NONE   = 2'd0;
    localparam logic [1:0] OWNER_DIRECT = 2'd1;
    localparam logic [1:0] OWNER_TILED  = 2'd2;

    logic [1:0] owner_q;

    logic direct_start_accept;
    logic select_direct;

    // -------------------------------------------------------------------------
    // Shared physical-engine request signals
    // -------------------------------------------------------------------------

    logic        shared_clear;

    logic        shared_a_write_enable;
    logic [3:0]  shared_a_write_addr;
    logic [31:0] shared_a_write_data;

    logic        shared_b_write_enable;
    logic [3:0]  shared_b_write_addr;
    logic [31:0] shared_b_write_data;

    logic        shared_start;
    logic        shared_start_ready;

    logic [1:0]  shared_precision;
    logic [2:0]  shared_k_count;
    logic        shared_accumulate;

    // -------------------------------------------------------------------------
    // Shared physical-engine responses
    // -------------------------------------------------------------------------

    logic       shared_busy;
    logic       shared_done;
    logic       shared_error;
    logic [2:0] shared_error_code;

    logic [3:0] shared_wavefront_cycle;

    logic [15:0] shared_a_valid_mask;
    logic [15:0] shared_b_valid_mask;

    logic [511:0] shared_accumulator;
    logic [15:0]  shared_accumulator_valid;
    logic [15:0]  shared_accumulator_update;

    logic [15:0] shared_mac_fire_mask;

    logic [15:0] shared_invalid;
    logic [15:0] shared_overflow;
    logic [15:0] shared_underflow;
    logic [15:0] shared_inexact;

    // -------------------------------------------------------------------------
    // Ownership availability
    // -------------------------------------------------------------------------

    // Outer tiled-operation acceptance depends only on ownership
    // availability. Physical-engine start readiness is checked separately
    // through tiled_engine_start_ready_o after tiled ownership is acquired.
    // Keeping shared_start_ready out of this path prevents a combinational
    // claim/ready feedback loop through the tiled controller.
    assign tiled_engine_available_o =
        rst_ni &&
        (owner_q == OWNER_NONE);

    // Tiled claim receives priority if both clients request the idle engine in
    // the same cycle.
    assign direct_start_ready_o =
        rst_ni &&
        (owner_q != OWNER_TILED) &&
        shared_start_ready &&
        !(
            (owner_q == OWNER_NONE) &&
            tiled_claim_i
        );

    assign direct_start_accept =
        direct_start_i &&
        direct_start_ready_o;

    // A tiled claim has priority over every direct-side request only while
    // ownership is idle. Once direct ownership has been acquired, unrelated
    // tiled claim pulses cannot interfere with the active direct context.
    assign select_direct =
        (owner_q == OWNER_DIRECT) ||
        (
            (owner_q == OWNER_NONE) &&
            !tiled_claim_i
        );

    assign tiled_engine_start_ready_o =
        (owner_q == OWNER_TILED)
        ? shared_start_ready
        : 1'b0;

    // The direct CSR sees the shared resource as busy whenever the tiled
    // controller owns it. This blocks direct tile/configuration writes.
    assign direct_busy_o =
        shared_busy ||
        (owner_q == OWNER_TILED) ||
        (
            (owner_q == OWNER_NONE) &&
            tiled_claim_i
        );

    // Completion/error pulses are delivered only to the active owner.
    assign direct_done_o =
        (owner_q == OWNER_DIRECT)
        ? shared_done
        : 1'b0;

    assign direct_error_o =
        (owner_q == OWNER_DIRECT)
        ? shared_error
        : 1'b0;

    assign direct_error_code_o =
        (owner_q == OWNER_DIRECT)
        ? shared_error_code
        : 3'd0;

    assign tiled_engine_busy_o =
        (owner_q == OWNER_TILED)
        ? shared_busy
        : 1'b0;

    assign tiled_engine_done_o =
        (owner_q == OWNER_TILED)
        ? shared_done
        : 1'b0;

    assign tiled_engine_error_o =
        (owner_q == OWNER_TILED)
        ? shared_error
        : 1'b0;

    assign tiled_engine_error_code_o =
        (owner_q == OWNER_TILED)
        ? shared_error_code
        : 3'd0;

    // Datapath/status values are wired continuously. Pulse-style status is
    // owner-gated above.
    assign direct_wavefront_cycle_o =
        shared_wavefront_cycle;

    assign direct_a_valid_mask_o =
        shared_a_valid_mask;

    assign direct_b_valid_mask_o =
        shared_b_valid_mask;

    assign direct_accumulator_o =
        shared_accumulator;

    assign direct_accumulator_valid_o =
        shared_accumulator_valid;

    assign direct_accumulator_update_o =
        shared_accumulator_update;

    assign direct_mac_fire_mask_o =
        shared_mac_fire_mask;

    assign direct_invalid_o =
        shared_invalid;

    assign direct_overflow_o =
        shared_overflow;

    assign direct_underflow_o =
        shared_underflow;

    assign direct_inexact_o =
        shared_inexact;

    assign tiled_engine_accumulator_o =
        shared_accumulator;

    assign tiled_engine_accumulator_valid_o =
        shared_accumulator_valid;

    assign tiled_engine_invalid_o =
        shared_invalid;

    assign tiled_engine_overflow_o =
        shared_overflow;

    assign tiled_engine_underflow_o =
        shared_underflow;

    assign tiled_engine_inexact_o =
        shared_inexact;

    // -------------------------------------------------------------------------
    // Ownership state
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            owner_q <= OWNER_NONE;
        end
        else begin
            case (owner_q)
                OWNER_NONE: begin
                    if (tiled_claim_i) begin
                        owner_q <= OWNER_TILED;
                    end
                    else if (direct_start_accept) begin
                        owner_q <= OWNER_DIRECT;
                    end
                end

                OWNER_DIRECT: begin
                    // Preserve direct ownership across multiple direct starts
                    // so direct K-tile accumulation remains valid.
                    if (direct_clear_i) begin
                        owner_q <= OWNER_NONE;
                    end
                end

                OWNER_TILED: begin
                    if (tiled_release_i) begin
                        owner_q <= OWNER_NONE;
                    end
                end

                default: begin
                    owner_q <= OWNER_NONE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Request multiplexer
    // -------------------------------------------------------------------------

    always @* begin
        // Direct client is selected while the engine is unowned or directly
        // owned. Direct start is explicitly acceptance-gated.
        shared_clear =
            select_direct
            ? direct_clear_i
            : 1'b0;

        shared_a_write_enable =
            select_direct
            ? direct_a_write_enable_i
            : 1'b0;

        shared_a_write_addr =
            direct_a_write_addr_i;

        shared_a_write_data =
            direct_a_write_data_i;

        shared_b_write_enable =
            select_direct
            ? direct_b_write_enable_i
            : 1'b0;

        shared_b_write_addr =
            direct_b_write_addr_i;

        shared_b_write_data =
            direct_b_write_data_i;

        shared_start =
            select_direct
            ? direct_start_accept
            : 1'b0;

        shared_precision =
            direct_precision_i;

        shared_k_count =
            direct_k_count_i;

        shared_accumulate =
            direct_accumulate_i;

        if (owner_q == OWNER_TILED) begin
            shared_clear =
                tiled_engine_clear_i;

            shared_a_write_enable =
                tiled_engine_a_write_enable_i;

            shared_a_write_addr =
                tiled_engine_a_write_addr_i;

            shared_a_write_data =
                tiled_engine_a_write_data_i;

            shared_b_write_enable =
                tiled_engine_b_write_enable_i;

            shared_b_write_addr =
                tiled_engine_b_write_addr_i;

            shared_b_write_data =
                tiled_engine_b_write_data_i;

            shared_start =
                tiled_engine_start_i &&
                tiled_engine_start_ready_o;

            shared_precision =
                tiled_engine_precision_i;

            shared_k_count =
                tiled_engine_k_count_i;

            shared_accumulate =
                tiled_engine_accumulate_i;
        end
    end

    // -------------------------------------------------------------------------
    // Single physical 4x4 engine
    // -------------------------------------------------------------------------

    nce_systolic_gemm_4x4 #(
        .INT8X4_PRECISION (INT8X4_PRECISION),
        .BF16X2_PRECISION (BF16X2_PRECISION),
        .BF24_PRECISION   (BF24_PRECISION)
    ) u_shared_engine (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),

        .clear_i                  (shared_clear),

        .a_write_enable_i         (shared_a_write_enable),
        .a_write_addr_i           (shared_a_write_addr),
        .a_write_data_i           (shared_a_write_data),

        .b_write_enable_i         (shared_b_write_enable),
        .b_write_addr_i           (shared_b_write_addr),
        .b_write_data_i           (shared_b_write_data),

        .a_valid_mask_o           (shared_a_valid_mask),
        .b_valid_mask_o           (shared_b_valid_mask),

        .start_i                  (shared_start),
        .start_ready_o            (shared_start_ready),

        .precision_i              (shared_precision),
        .k_count_i                (shared_k_count),
        .accumulate_i             (shared_accumulate),

        .busy_o                   (shared_busy),
        .done_o                   (shared_done),
        .error_o                  (shared_error),
        .error_code_o             (shared_error_code),

        .wavefront_cycle_o        (shared_wavefront_cycle),

        .accumulator_o            (shared_accumulator),
        .accumulator_valid_o      (shared_accumulator_valid),
        .accumulator_update_o     (shared_accumulator_update),

        .mac_fire_mask_o          (shared_mac_fire_mask),

        .invalid_o                (shared_invalid),
        .overflow_o               (shared_overflow),
        .underflow_o              (shared_underflow),
        .inexact_o                (shared_inexact)
    );


    // -------------------------------------------------------------------------
    // Simulation-only ownership checks
    // -------------------------------------------------------------------------

`ifndef SYNTHESIS
    always @(posedge clk_i or negedge rst_ni) begin
        if (rst_ni) begin
            if (
                owner_q != OWNER_NONE &&
                owner_q != OWNER_DIRECT &&
                owner_q != OWNER_TILED
            ) begin
                $fatal(
                    1,
                    "Illegal shared physical-engine owner: %0d",
                    owner_q
                );
            end

            if (
                direct_done_o &&
                tiled_engine_done_o
            ) begin
                $fatal(
                    1,
                    "Physical-engine completion reached both clients"
                );
            end

            if (
                direct_error_o &&
                tiled_engine_error_o
            ) begin
                $fatal(
                    1,
                    "Physical-engine error reached both clients"
                );
            end

            if (
                (
                    direct_done_o ||
                    direct_error_o
                ) &&
                owner_q != OWNER_DIRECT
            ) begin
                $fatal(
                    1,
                    "Direct response occurred without direct ownership"
                );
            end

            if (
                (
                    tiled_engine_done_o ||
                    tiled_engine_error_o
                ) &&
                owner_q != OWNER_TILED
            ) begin
                $fatal(
                    1,
                    "Tiled response occurred without tiled ownership"
                );
            end

            if (
                owner_q == OWNER_TILED &&
                direct_start_ready_o
            ) begin
                $fatal(
                    1,
                    "Direct start advertised ready during tiled ownership"
                );
            end

            if (
                owner_q != OWNER_NONE &&
                tiled_engine_available_o
            ) begin
                $fatal(
                    1,
                    "Tiled engine advertised availability while owned"
                );
            end

            if (
                owner_q == OWNER_NONE &&
                tiled_claim_i &&
                (
                    select_direct ||
                    direct_start_ready_o ||
                    shared_clear ||
                    shared_a_write_enable ||
                    shared_b_write_enable ||
                    shared_start
                )
            ) begin
                $fatal(
                    1,
                    "Direct request leaked during priority tiled claim"
                );
            end
        end
    end
`endif

endmodule

`default_nettype wire
