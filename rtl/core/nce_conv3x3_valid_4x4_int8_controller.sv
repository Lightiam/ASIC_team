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
// Reference single-channel 3x3 valid convolution.
//
// Fixed initial scope:
//
//   Input feature map:  4x4 signed INT8
//   Kernel:             3x3 signed INT8
//   Stride:             1
//   Padding:            none
//   Output:             2x2 FP32
//
// The frontend lowers four 3x3 windows into four rows of the existing 8x8
// tiled GEMM. Nine scalar K terms are packed into three INT8X4 tokens:
//
//   token 0: terms 0,1,2,3
//   token 1: terms 4,5,6,7
//   token 2: term 8 plus three zero-padding sublanes
//
// Unused GEMM rows and columns are explicitly loaded with zero operands.
// -----------------------------------------------------------------------------

module nce_conv3x3_valid_4x4_int8_controller (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    // Row-major 4x4 input-feature-map storage.
    input  logic         pixel_write_enable_i,
    input  logic [3:0]   pixel_write_addr_i,
    input  logic [7:0]   pixel_write_data_i,

    // Row-major 3x3 kernel storage. Legal addresses are 0 through 8.
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

    // Four row-major FP32 results:
    //
    //   result 0 = output[0][0]
    //   result 1 = output[0][1]
    //   result 2 = output[1][0]
    //   result 3 = output[1][1]
    output logic [127:0] result_o,
    output logic [3:0]   result_valid_o,

    output logic [3:0]   invalid_o,
    output logic [3:0]   overflow_o,
    output logic [3:0]   underflow_o,
    output logic [3:0]   inexact_o,

    // -------------------------------------------------------------------------
    // External tiled-GEMM interface
    // -------------------------------------------------------------------------

    // High-level convolution start is accepted only when this backend is
    // available for the complete lowering and execution transaction.
    input  logic          gemm_available,

    output logic          gemm_clear,

    output logic          gemm_a_write_enable,
    output logic [5:0]    gemm_a_write_addr,
    output logic [31:0]   gemm_a_write_data,

    output logic          gemm_b_write_enable,
    output logic [5:0]    gemm_b_write_addr,
    output logic [31:0]   gemm_b_write_data,

    output logic          gemm_start,
    input  logic          gemm_start_ready,

    output logic [1:0]    gemm_precision,
    output logic [3:0]    gemm_k_token_count,

    input  logic          gemm_done,
    input  logic          gemm_error,

    // This reference frontend has one output channel and therefore consumes
    // only column zero of GEMM rows 0 through 3. The remaining tiled-GEMM
    // result fields are intentionally unused.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [2047:0] gemm_accumulator,
    input  logic [63:0]   gemm_accumulator_valid,

    input  logic [63:0]   gemm_invalid,
    input  logic [63:0]   gemm_overflow,
    input  logic [63:0]   gemm_underflow,
    input  logic [63:0]   gemm_inexact
    /* verilator lint_on UNUSEDSIGNAL */
);

    localparam logic [2:0] ERROR_NONE           = 3'd0;
    localparam logic [2:0] ERROR_INPUT_INVALID  = 3'd1;
    localparam logic [2:0] ERROR_KERNEL_INVALID = 3'd2;
    localparam logic [2:0] ERROR_GEMM_FAILURE   = 3'd3;

    localparam logic [2:0] STATE_IDLE    = 3'd0;
    localparam logic [2:0] STATE_CLEAR   = 3'd1;
    localparam logic [2:0] STATE_LOAD_A  = 3'd2;
    localparam logic [2:0] STATE_LOAD_B  = 3'd3;
    localparam logic [2:0] STATE_START   = 3'd4;
    localparam logic [2:0] STATE_WAIT    = 3'd5;
    localparam logic [2:0] STATE_CAPTURE = 3'd6;

    logic [2:0] state_q;

    logic [7:0] pixel_q  [0:15];
    logic [7:0] kernel_q [0:8];

    logic [15:0] pixel_valid_q;
    logic [8:0]  kernel_valid_q;

    integer storage_index;

    // -------------------------------------------------------------------------
    // Input and kernel storage
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pixel_valid_q  <= 16'd0;
            kernel_valid_q <= 9'd0;

            for (
                storage_index = 0;
                storage_index < 16;
                storage_index = storage_index + 1
            ) begin
                pixel_q[storage_index] <= 8'd0;
            end

            for (
                storage_index = 0;
                storage_index < 9;
                storage_index = storage_index + 1
            ) begin
                kernel_q[storage_index] <= 8'd0;
            end
        end
        else if (clear_i) begin
            pixel_valid_q  <= 16'd0;
            kernel_valid_q <= 9'd0;

            for (
                storage_index = 0;
                storage_index < 16;
                storage_index = storage_index + 1
            ) begin
                pixel_q[storage_index] <= 8'd0;
            end

            for (
                storage_index = 0;
                storage_index < 9;
                storage_index = storage_index + 1
            ) begin
                kernel_q[storage_index] <= 8'd0;
            end
        end
        else begin
            if (
                pixel_write_enable_i &&
                !busy_o
            ) begin
                pixel_q[pixel_write_addr_i] <=
                    pixel_write_data_i;

                pixel_valid_q[pixel_write_addr_i] <=
                    1'b1;
            end

            if (
                kernel_write_enable_i &&
                !busy_o &&
                kernel_write_addr_i < 4'd9
            ) begin
                kernel_q[kernel_write_addr_i] <=
                    kernel_write_data_i;

                kernel_valid_q[kernel_write_addr_i] <=
                    1'b1;
            end
        end
    end

    assign pixel_valid_mask_o =
        pixel_valid_q;

    assign kernel_valid_mask_o =
        kernel_valid_q;

    // -------------------------------------------------------------------------
    // Tiled-GEMM request interface
    // -------------------------------------------------------------------------

    logic [2:0] load_row_q;
    logic [2:0] load_column_q;
    logic [1:0] load_token_q;

    integer patch_base;

    function automatic logic [31:0] pack_int8x4 (
        input logic [7:0] lane0,
        input logic [7:0] lane1,
        input logic [7:0] lane2,
        input logic [7:0] lane3
    );
        begin
            pack_int8x4 = {
                lane3,
                lane2,
                lane1,
                lane0
            };
        end
    endfunction

    // Clear before loading a new lowered matrix and again while capturing
    // completed results. At STATE_CAPTURE, the convolution controller samples
    // the old tiled-GEMM result registers on the same clock edge that the
    // backend is cleared. This prevents stale im2col matrices from leaking
    // into the next software-owned tiled operation.
    //
    // An engine failure also clears the tiled context before ownership is
    // released.
    assign gemm_clear =
        clear_i ||
        (state_q == STATE_CLEAR) ||
        (state_q == STATE_CAPTURE) ||
        (
            (state_q == STATE_WAIT) &&
            gemm_error
        );

    assign gemm_precision =
        2'b00;

    assign gemm_k_token_count =
        4'd3;

    assign gemm_a_write_enable =
        (state_q == STATE_LOAD_A);

    assign gemm_a_write_addr =
        {load_row_q, 3'b000} +
        {4'b0000, load_token_q};

    assign gemm_b_write_enable =
        (state_q == STATE_LOAD_B);

    assign gemm_b_write_addr =
        {1'b0, load_token_q, 3'b000} +
        {3'b000, load_column_q};

    assign gemm_start =
        (state_q == STATE_START) &&
        gemm_start_ready;

    // -------------------------------------------------------------------------
    // im2col A-matrix generation
    //
    // GEMM rows 0..3 correspond to the four output windows:
    //
    //   row 0 -> window starting at input (0,0)
    //   row 1 -> window starting at input (0,1)
    //   row 2 -> window starting at input (1,0)
    //   row 3 -> window starting at input (1,1)
    //
    // Rows 4..7 are zero-filled.
    // -------------------------------------------------------------------------

    always @* begin
        gemm_a_write_data = 32'd0;
        patch_base = 0;

        if (load_row_q < 3'd4) begin
            case (load_row_q[1:0])
                2'd0: patch_base = 0;
                2'd1: patch_base = 1;
                2'd2: patch_base = 4;
                2'd3: patch_base = 5;

                default:
                    patch_base = 0;
            endcase

            case (load_token_q)
                2'd0: begin
                    gemm_a_write_data = pack_int8x4(
                        pixel_q[patch_base],
                        pixel_q[patch_base + 1],
                        pixel_q[patch_base + 2],
                        pixel_q[patch_base + 4]
                    );
                end

                2'd1: begin
                    gemm_a_write_data = pack_int8x4(
                        pixel_q[patch_base + 5],
                        pixel_q[patch_base + 6],
                        pixel_q[patch_base + 8],
                        pixel_q[patch_base + 9]
                    );
                end

                2'd2: begin
                    gemm_a_write_data = pack_int8x4(
                        pixel_q[patch_base + 10],
                        8'd0,
                        8'd0,
                        8'd0
                    );
                end

                default: begin
                    gemm_a_write_data = 32'd0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Kernel B-matrix generation
    //
    // Column 0 contains the real kernel. Columns 1..7 are zero-filled because
    // this initial reference engine has one output channel.
    // -------------------------------------------------------------------------

    always @* begin
        gemm_b_write_data = 32'd0;

        if (load_column_q == 3'd0) begin
            case (load_token_q)
                2'd0: begin
                    gemm_b_write_data = pack_int8x4(
                        kernel_q[0],
                        kernel_q[1],
                        kernel_q[2],
                        kernel_q[3]
                    );
                end

                2'd1: begin
                    gemm_b_write_data = pack_int8x4(
                        kernel_q[4],
                        kernel_q[5],
                        kernel_q[6],
                        kernel_q[7]
                    );
                end

                2'd2: begin
                    gemm_b_write_data = pack_int8x4(
                        kernel_q[8],
                        8'd0,
                        8'd0,
                        8'd0
                    );
                end

                default: begin
                    gemm_b_write_data = 32'd0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Lowering and execution controller
    // -------------------------------------------------------------------------

    assign start_ready_o =
        rst_ni &&
        !clear_i &&
        gemm_available &&
        (state_q == STATE_IDLE);

    assign busy_o =
        (state_q != STATE_IDLE);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;

            load_row_q    <= 3'd0;
            load_column_q <= 3'd0;
            load_token_q  <= 2'd0;

            done_o       <= 1'b0;
            error_o      <= 1'b0;
            error_code_o <= ERROR_NONE;

            result_o       <= 128'd0;
            result_valid_o <= 4'd0;

            invalid_o   <= 4'd0;
            overflow_o  <= 4'd0;
            underflow_o <= 4'd0;
            inexact_o   <= 4'd0;
        end
        else if (clear_i) begin
            state_q <= STATE_IDLE;

            load_row_q    <= 3'd0;
            load_column_q <= 3'd0;
            load_token_q  <= 2'd0;

            done_o       <= 1'b0;
            error_o      <= 1'b0;
            error_code_o <= ERROR_NONE;

            result_o       <= 128'd0;
            result_valid_o <= 4'd0;

            invalid_o   <= 4'd0;
            overflow_o  <= 4'd0;
            underflow_o <= 4'd0;
            inexact_o   <= 4'd0;
        end
        else begin
            done_o  <= 1'b0;
            error_o <= 1'b0;

            case (state_q)
                STATE_IDLE: begin
                    if (
                        start_i &&
                        start_ready_o
                    ) begin
                        if (!(&pixel_valid_q)) begin
                            error_o      <= 1'b1;
                            error_code_o <= ERROR_INPUT_INVALID;
                        end
                        else if (!(&kernel_valid_q)) begin
                            error_o      <= 1'b1;
                            error_code_o <= ERROR_KERNEL_INVALID;
                        end
                        else begin
                            error_code_o <= ERROR_NONE;

                            result_valid_o <= 4'd0;

                            invalid_o   <= 4'd0;
                            overflow_o  <= 4'd0;
                            underflow_o <= 4'd0;
                            inexact_o   <= 4'd0;

                            state_q <= STATE_CLEAR;
                        end
                    end
                end

                STATE_CLEAR: begin
                    load_row_q    <= 3'd0;
                    load_column_q <= 3'd0;
                    load_token_q  <= 2'd0;

                    state_q <= STATE_LOAD_A;
                end

                STATE_LOAD_A: begin
                    if (load_token_q == 2'd2) begin
                        load_token_q <= 2'd0;

                        if (load_row_q == 3'd7) begin
                            load_row_q    <= 3'd0;
                            load_column_q <= 3'd0;
                            state_q       <= STATE_LOAD_B;
                        end
                        else begin
                            load_row_q <=
                                load_row_q + 3'd1;
                        end
                    end
                    else begin
                        load_token_q <=
                            load_token_q + 2'd1;
                    end
                end

                STATE_LOAD_B: begin
                    if (load_column_q == 3'd7) begin
                        load_column_q <= 3'd0;

                        if (load_token_q == 2'd2) begin
                            load_token_q <= 2'd0;
                            state_q      <= STATE_START;
                        end
                        else begin
                            load_token_q <=
                                load_token_q + 2'd1;
                        end
                    end
                    else begin
                        load_column_q <=
                            load_column_q + 3'd1;
                    end
                end

                STATE_START: begin
                    if (gemm_start_ready) begin
                        state_q <= STATE_WAIT;
                    end
                end

                STATE_WAIT: begin
                    if (gemm_error) begin
                        error_o      <= 1'b1;
                        error_code_o <= ERROR_GEMM_FAILURE;
                        state_q      <= STATE_IDLE;
                    end
                    else if (gemm_done) begin
                        state_q <= STATE_CAPTURE;
                    end
                end

                STATE_CAPTURE: begin
                    // GEMM result indices:
                    //
                    //   row 0, column 0 -> 0
                    //   row 1, column 0 -> 8
                    //   row 2, column 0 -> 16
                    //   row 3, column 0 -> 24

                    result_o[31:0] <=
                        gemm_accumulator[31:0];

                    result_o[63:32] <=
                        gemm_accumulator[287:256];

                    result_o[95:64] <=
                        gemm_accumulator[543:512];

                    result_o[127:96] <=
                        gemm_accumulator[799:768];

                    result_valid_o <= {
                        gemm_accumulator_valid[24],
                        gemm_accumulator_valid[16],
                        gemm_accumulator_valid[8],
                        gemm_accumulator_valid[0]
                    };

                    invalid_o <= {
                        gemm_invalid[24],
                        gemm_invalid[16],
                        gemm_invalid[8],
                        gemm_invalid[0]
                    };

                    overflow_o <= {
                        gemm_overflow[24],
                        gemm_overflow[16],
                        gemm_overflow[8],
                        gemm_overflow[0]
                    };

                    underflow_o <= {
                        gemm_underflow[24],
                        gemm_underflow[16],
                        gemm_underflow[8],
                        gemm_underflow[0]
                    };

                    inexact_o <= {
                        gemm_inexact[24],
                        gemm_inexact[16],
                        gemm_inexact[8],
                        gemm_inexact[0]
                    };

                    done_o       <= 1'b1;
                    error_code_o <= ERROR_NONE;
                    state_q      <= STATE_IDLE;
                end

                default: begin
                    error_o      <= 1'b1;
                    error_code_o <= ERROR_GEMM_FAILURE;
                    state_q      <= STATE_IDLE;
                end
            endcase
        end
    end


endmodule

`default_nettype wire
