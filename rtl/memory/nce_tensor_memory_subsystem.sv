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
// NCE tensor-memory subsystem.
//
// One shared streaming loader writes one selected memory region:
//
//   target 0: activation scratchpad
//   target 1: weight scratchpad
//   target 2: output/partial-sum scratchpad
//   target 3: invalid
//
// Default capacity:
//
//   activation:  4 KB
//   weight:      4 KB
//   output/PSUM: 4 KB
//   total:      12 KB
//
// All three memories expose four independent flat-address read lanes.
//
// The output/PSUM memory additionally exposes four compute-side write lanes.
// Compute writes are blocked only while the stream loader owns the output
// memory. Compute output writes may proceed while activation or weight loading
// is active.
// -----------------------------------------------------------------------------

module nce_tensor_memory_subsystem #(
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
    // Shared loader command and stream
    // -------------------------------------------------------------------------

    input  logic start_i,
    output logic start_ready_o,

    input  logic [1:0] load_target_i,

    input  logic [FLAT_ADDR_WIDTH-1:0] base_addr_i,
    input  logic [WORD_COUNT_WIDTH-1:0] word_count_i,

    input  logic stream_valid_i,
    output logic stream_ready_o,
    input  logic stream_last_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] stream_data_i,

    input  logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] stream_strb_i,

    output logic busy_o,
    output logic done_o,
    output logic error_o,
    output logic [2:0] error_code_o,

    output logic [
        WORD_COUNT_WIDTH-1:0
    ] words_written_o,

    output logic [1:0] active_target_o,

    // -------------------------------------------------------------------------
    // Activation-memory compute reads
    // -------------------------------------------------------------------------

    input  logic [PORT_COUNT-1:0] activation_read_enable_i,

    input  logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] activation_read_addr_i,

    output logic [PORT_COUNT-1:0] activation_read_ready_o,
    output logic [PORT_COUNT-1:0] activation_read_conflict_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] activation_read_data_o,

    output logic [PORT_COUNT-1:0] activation_read_valid_o,

    // -------------------------------------------------------------------------
    // Weight-memory compute reads
    // -------------------------------------------------------------------------

    input  logic [PORT_COUNT-1:0] weight_read_enable_i,

    input  logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] weight_read_addr_i,

    output logic [PORT_COUNT-1:0] weight_read_ready_o,
    output logic [PORT_COUNT-1:0] weight_read_conflict_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] weight_read_data_o,

    output logic [PORT_COUNT-1:0] weight_read_valid_o,

    // -------------------------------------------------------------------------
    // Output/PSUM-memory compute reads
    // -------------------------------------------------------------------------

    input  logic [PORT_COUNT-1:0] output_read_enable_i,

    input  logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_read_addr_i,

    output logic [PORT_COUNT-1:0] output_read_ready_o,
    output logic [PORT_COUNT-1:0] output_read_conflict_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_read_data_o,

    output logic [PORT_COUNT-1:0] output_read_valid_o,

    // -------------------------------------------------------------------------
    // Output/PSUM-memory compute writes
    // -------------------------------------------------------------------------

    input  logic [PORT_COUNT-1:0] output_write_enable_i,

    input  logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_write_addr_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_write_data_i,

    input  logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] output_write_strb_i,

    output logic [PORT_COUNT-1:0] output_write_ready_o,
    output logic [PORT_COUNT-1:0] output_write_conflict_o
);

    localparam logic [1:0] TARGET_ACTIVATION = 2'd0;
    localparam logic [1:0] TARGET_WEIGHT     = 2'd1;
    localparam logic [1:0] TARGET_OUTPUT     = 2'd2;

    localparam logic [2:0] ERROR_INVALID_TARGET = 3'd6;

    logic loader_start;
    logic loader_start_ready;
    logic loader_busy;
    logic loader_done;
    logic loader_error;
    logic [2:0] loader_error_code;

    logic invalid_target_error_q;

    logic target_valid;
    logic valid_start_accept;
    logic invalid_start_accept;

    logic [1:0] active_target_q;

    logic [PORT_COUNT-1:0] loader_write_enable;

    logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] loader_write_addr;

    logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] loader_write_data;

    logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] loader_write_strb;

    logic [PORT_COUNT-1:0] loader_write_ready;

    // Activation scratchpad write interface.
    logic [PORT_COUNT-1:0] activation_write_enable;
    logic [PORT_COUNT-1:0] activation_write_ready;
    logic [PORT_COUNT-1:0] activation_write_conflict;
    logic [PORT_COUNT-1:0] activation_write_accept;

    // Weight scratchpad write interface.
    logic [PORT_COUNT-1:0] weight_write_enable;
    logic [PORT_COUNT-1:0] weight_write_ready;
    logic [PORT_COUNT-1:0] weight_write_conflict;
    logic [PORT_COUNT-1:0] weight_write_accept;

    // Output scratchpad selected write interface.
    logic [PORT_COUNT-1:0] output_memory_write_enable;

    logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] output_memory_write_addr;

    logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] output_memory_write_data;

    logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] output_memory_write_strb;

    logic [PORT_COUNT-1:0] output_memory_write_ready;
    logic [PORT_COUNT-1:0] output_memory_write_conflict;
    logic [PORT_COUNT-1:0] output_memory_write_accept;

    logic loader_owns_output;

    assign target_valid =
        (load_target_i == TARGET_ACTIVATION) ||
        (load_target_i == TARGET_WEIGHT) ||
        (load_target_i == TARGET_OUTPUT);

    assign start_ready_o =
        loader_start_ready;

    assign valid_start_accept =
        start_i &&
        start_ready_o &&
        target_valid;

    assign invalid_start_accept =
        start_i &&
        start_ready_o &&
        !target_valid;

    assign loader_start =
        valid_start_accept;

    assign active_target_o =
        active_target_q;

    assign busy_o =
        loader_busy;

    assign done_o =
        loader_done;

    assign error_o =
        invalid_target_error_q ||
        loader_error;

    assign error_code_o =
        invalid_target_error_q
        ? ERROR_INVALID_TARGET
        : loader_error_code;

    assign loader_owns_output =
        loader_busy &&
        (active_target_q == TARGET_OUTPUT);

    // -------------------------------------------------------------------------
    // Capture the selected memory for the complete transfer.
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            active_target_q       <= TARGET_ACTIVATION;
            invalid_target_error_q <= 1'b0;
        end
        else if (clear_i) begin
            active_target_q       <= TARGET_ACTIVATION;
            invalid_target_error_q <= 1'b0;
        end
        else begin
            invalid_target_error_q <=
                invalid_start_accept;

            if (valid_start_accept) begin
                active_target_q <=
                    load_target_i;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Loader-write routing.
    // -------------------------------------------------------------------------

    always @* begin
        activation_write_enable = '0;
        weight_write_enable     = '0;

        loader_write_ready = '0;

        case (active_target_q)
            TARGET_ACTIVATION: begin
                activation_write_enable =
                    loader_write_enable;

                loader_write_ready =
                    activation_write_accept;
            end

            TARGET_WEIGHT: begin
                weight_write_enable =
                    loader_write_enable;

                loader_write_ready =
                    weight_write_accept;
            end

            TARGET_OUTPUT: begin
                loader_write_ready =
                    output_memory_write_accept;
            end

            default: begin
                loader_write_ready = '0;
            end
        endcase
    end

    assign activation_write_accept =
        activation_write_ready &
        ~activation_write_conflict;

    assign weight_write_accept =
        weight_write_ready &
        ~weight_write_conflict;

    assign output_memory_write_accept =
        output_memory_write_ready &
        ~output_memory_write_conflict;

    // -------------------------------------------------------------------------
    // Output-memory ownership.
    //
    // Loader receives exclusive output-memory writes only while loading the
    // output target. Otherwise, compute-side writes own the output memory.
    // -------------------------------------------------------------------------

    always @* begin
        output_memory_write_enable = '0;
        output_memory_write_addr   = '0;
        output_memory_write_data   = '0;
        output_memory_write_strb   = '0;

        output_write_ready_o       = '0;
        output_write_conflict_o    = '0;

        if (loader_owns_output) begin
            output_memory_write_enable =
                loader_write_enable;

            output_memory_write_addr =
                loader_write_addr;

            output_memory_write_data =
                loader_write_data;

            output_memory_write_strb =
                loader_write_strb;

            // Explicitly indicate that compute writes are blocked while the
            // loader owns the output/PSUM memory.
            output_write_conflict_o =
                output_write_enable_i;
        end
        else begin
            output_memory_write_enable =
                output_write_enable_i;

            output_memory_write_addr =
                output_write_addr_i;

            output_memory_write_data =
                output_write_data_i;

            output_memory_write_strb =
                output_write_strb_i;

            output_write_ready_o =
                output_memory_write_ready;

            output_write_conflict_o =
                output_memory_write_conflict;
        end
    end

    // -------------------------------------------------------------------------
    // Shared stream loader.
    // -------------------------------------------------------------------------

    nce_tensor_stream_loader #(
        .BANK_COUNT         (BANK_COUNT),
        .WORDS_PER_BANK     (WORDS_PER_BANK),
        .DATA_WIDTH         (DATA_WIDTH),
        .PORT_COUNT         (PORT_COUNT),
        .BANK_INDEX_WIDTH   (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH    (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH    (FLAT_ADDR_WIDTH),
        .TOTAL_WORDS        (TOTAL_WORDS),
        .WORD_COUNT_WIDTH   (WORD_COUNT_WIDTH),
        .BYTE_COUNT         (BYTE_COUNT)
    ) u_loader (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .start_i                (loader_start),
        .start_ready_o          (loader_start_ready),

        .base_addr_i            (base_addr_i),
        .word_count_i           (word_count_i),

        .stream_valid_i         (stream_valid_i),
        .stream_ready_o         (stream_ready_o),
        .stream_last_i          (stream_last_i),
        .stream_data_i          (stream_data_i),
        .stream_strb_i          (stream_strb_i),

        .memory_write_enable_o  (loader_write_enable),
        .memory_write_addr_o    (loader_write_addr),
        .memory_write_data_o    (loader_write_data),
        .memory_write_strb_o    (loader_write_strb),
        .memory_write_ready_i   (loader_write_ready),

        .busy_o                 (loader_busy),
        .done_o                 (loader_done),
        .error_o                (loader_error),
        .error_code_o           (loader_error_code),
        .words_written_o        (words_written_o)
    );

    // -------------------------------------------------------------------------
    // Activation scratchpad.
    // -------------------------------------------------------------------------

    nce_tensor_scratchpad #(
        .BANK_COUNT        (BANK_COUNT),
        .WORDS_PER_BANK    (WORDS_PER_BANK),
        .DATA_WIDTH        (DATA_WIDTH),
        .PORT_COUNT        (PORT_COUNT),
        .BANK_INDEX_WIDTH  (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH   (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH   (FLAT_ADDR_WIDTH),
        .BYTE_COUNT        (BYTE_COUNT)
    ) u_activation_memory (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),

        .read_enable_i     (activation_read_enable_i),
        .read_addr_i       (activation_read_addr_i),
        .read_ready_o      (activation_read_ready_o),
        .read_conflict_o   (activation_read_conflict_o),
        .read_data_o       (activation_read_data_o),
        .read_valid_o      (activation_read_valid_o),

        .write_enable_i    (activation_write_enable),
        .write_addr_i      (loader_write_addr),
        .write_data_i      (loader_write_data),
        .write_strb_i      (loader_write_strb),
        .write_ready_o     (activation_write_ready),
        .write_conflict_o  (activation_write_conflict)
    );

    // -------------------------------------------------------------------------
    // Weight scratchpad.
    // -------------------------------------------------------------------------

    nce_tensor_scratchpad #(
        .BANK_COUNT        (BANK_COUNT),
        .WORDS_PER_BANK    (WORDS_PER_BANK),
        .DATA_WIDTH        (DATA_WIDTH),
        .PORT_COUNT        (PORT_COUNT),
        .BANK_INDEX_WIDTH  (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH   (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH   (FLAT_ADDR_WIDTH),
        .BYTE_COUNT        (BYTE_COUNT)
    ) u_weight_memory (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),

        .read_enable_i     (weight_read_enable_i),
        .read_addr_i       (weight_read_addr_i),
        .read_ready_o      (weight_read_ready_o),
        .read_conflict_o   (weight_read_conflict_o),
        .read_data_o       (weight_read_data_o),
        .read_valid_o      (weight_read_valid_o),

        .write_enable_i    (weight_write_enable),
        .write_addr_i      (loader_write_addr),
        .write_data_i      (loader_write_data),
        .write_strb_i      (loader_write_strb),
        .write_ready_o     (weight_write_ready),
        .write_conflict_o  (weight_write_conflict)
    );

    // -------------------------------------------------------------------------
    // Output/partial-sum scratchpad.
    // -------------------------------------------------------------------------

    nce_tensor_scratchpad #(
        .BANK_COUNT        (BANK_COUNT),
        .WORDS_PER_BANK    (WORDS_PER_BANK),
        .DATA_WIDTH        (DATA_WIDTH),
        .PORT_COUNT        (PORT_COUNT),
        .BANK_INDEX_WIDTH  (BANK_INDEX_WIDTH),
        .BANK_ADDR_WIDTH   (BANK_ADDR_WIDTH),
        .FLAT_ADDR_WIDTH   (FLAT_ADDR_WIDTH),
        .BYTE_COUNT        (BYTE_COUNT)
    ) u_output_memory (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),

        .read_enable_i     (output_read_enable_i),
        .read_addr_i       (output_read_addr_i),
        .read_ready_o      (output_read_ready_o),
        .read_conflict_o   (output_read_conflict_o),
        .read_data_o       (output_read_data_o),
        .read_valid_o      (output_read_valid_o),

        .write_enable_i    (output_memory_write_enable),
        .write_addr_i      (output_memory_write_addr),
        .write_data_i      (output_memory_write_data),
        .write_strb_i      (output_memory_write_strb),
        .write_ready_o     (output_memory_write_ready),
        .write_conflict_o  (output_memory_write_conflict)
    );

endmodule

`default_nettype wire
