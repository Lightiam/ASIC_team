`timescale 1ns/1ps
`default_nettype none

module tb_nce_tiled_gemm_8x8;

    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic        a_write_enable_i;
    logic [5:0]  a_write_addr_i;
    logic [31:0] a_write_data_i;

    logic        b_write_enable_i;
    logic [5:0]  b_write_addr_i;
    logic [31:0] b_write_data_i;

    logic [63:0] a_valid_mask_o;
    logic [63:0] b_valid_mask_o;

    logic       start_i;
    logic       start_ready_o;
    logic [1:0] precision_i;
    logic [3:0] k_token_count_i;

    logic       busy_o;
    logic       done_o;
    logic       error_o;
    logic [2:0] error_code_o;

    logic m_tile_o;
    logic n_tile_o;
    logic k_tile_o;

    logic [2047:0] accumulator_o;
    logic [63:0]   accumulator_valid_o;

    logic [63:0] invalid_o;
    logic [63:0] overflow_o;
    logic [63:0] underflow_o;
    logic [63:0] inexact_o;

    integer check_count;
    integer error_count;
    integer timeout_count;

    integer row_index;
    integer column_index;
    integer matrix_index;

    logic operation_complete;

    nce_tiled_gemm_8x8 dut (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .a_write_enable_i       (a_write_enable_i),
        .a_write_addr_i         (a_write_addr_i),
        .a_write_data_i         (a_write_data_i),

        .b_write_enable_i       (b_write_enable_i),
        .b_write_addr_i         (b_write_addr_i),
        .b_write_data_i         (b_write_data_i),

        .a_valid_mask_o         (a_valid_mask_o),
        .b_valid_mask_o         (b_valid_mask_o),

        .start_i                (start_i),
        .start_ready_o          (start_ready_o),

        .precision_i            (precision_i),
        .k_token_count_i        (k_token_count_i),

        .busy_o                 (busy_o),
        .done_o                 (done_o),
        .error_o                (error_o),
        .error_code_o           (error_code_o),

        .m_tile_o               (m_tile_o),
        .n_tile_o               (n_tile_o),
        .k_tile_o               (k_tile_o),

        .accumulator_o          (accumulator_o),
        .accumulator_valid_o    (accumulator_valid_o),

        .invalid_o              (invalid_o),
        .overflow_o             (overflow_o),
        .underflow_o            (underflow_o),
        .inexact_o              (inexact_o)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    task automatic check_condition (
        input logic  condition,
        input string message
    );
        begin
            check_count = check_count + 1;

            if (!condition) begin
                error_count = error_count + 1;

                $display(
                    "ERROR check=%0d: %s",
                    check_count,
                    message
                );
            end
        end
    endtask

    task automatic write_a (
        input logic [5:0]  address,
        input logic [31:0] data
    );
        begin
            @(negedge clk_i);

            a_write_enable_i = 1'b1;
            a_write_addr_i   = address;
            a_write_data_i   = data;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            a_write_enable_i = 1'b0;
            a_write_data_i   = 32'd0;
        end
    endtask

    task automatic write_b (
        input logic [5:0]  address,
        input logic [31:0] data
    );
        begin
            @(negedge clk_i);

            b_write_enable_i = 1'b1;
            b_write_addr_i   = address;
            b_write_data_i   = data;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            b_write_enable_i = 1'b0;
            b_write_data_i   = 32'd0;
        end
    endtask

    task automatic request_start (
        input logic [1:0] precision,
        input logic [3:0] k_tokens
    );
        begin
            @(negedge clk_i);

            precision_i     = precision;
            k_token_count_i = k_tokens;
            start_i         = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    function automatic logic [31:0] positive_integer_fp32 (
        input integer value
    );
        begin
            case (value)
                 1: positive_integer_fp32 = 32'h3F80_0000;
                 2: positive_integer_fp32 = 32'h4000_0000;
                 3: positive_integer_fp32 = 32'h4040_0000;
                 4: positive_integer_fp32 = 32'h4080_0000;
                 5: positive_integer_fp32 = 32'h40A0_0000;
                 6: positive_integer_fp32 = 32'h40C0_0000;
                 7: positive_integer_fp32 = 32'h40E0_0000;
                 8: positive_integer_fp32 = 32'h4100_0000;
                 9: positive_integer_fp32 = 32'h4110_0000;
                10: positive_integer_fp32 = 32'h4120_0000;
                11: positive_integer_fp32 = 32'h4130_0000;
                12: positive_integer_fp32 = 32'h4140_0000;
                13: positive_integer_fp32 = 32'h4150_0000;
                14: positive_integer_fp32 = 32'h4160_0000;
                15: positive_integer_fp32 = 32'h4170_0000;

                default:
                    positive_integer_fp32 = 32'd0;
            endcase
        end
    endfunction

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        a_write_enable_i = 1'b0;
        a_write_addr_i   = 6'd0;
        a_write_data_i   = 32'd0;

        b_write_enable_i = 1'b0;
        b_write_addr_i   = 6'd0;
        b_write_data_i   = 32'd0;

        start_i          = 1'b0;
        precision_i      = 2'b00;
        k_token_count_i  = 4'd0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        check_condition(
            start_ready_o === 1'b0 &&
            busy_o === 1'b0,
            "8x8 tiled GEMM reset state mismatch"
        );

        @(negedge clk_i);
        rst_ni = 1'b1;

        #1;

        check_condition(
            start_ready_o === 1'b1,
            "8x8 tiled GEMM did not become ready"
        );

        // Invalid K must be rejected.
        request_start(
            2'b00,
            4'd0
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_K,
            "Invalid 8x8 K-token count was not rejected"
        );

        // Clear all source/result state.
        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        clear_i = 1'b0;

        // ---------------------------------------------------------------------
        // A = 8x8 identity matrix.
        // ---------------------------------------------------------------------

        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                write_a(
                    matrix_index[5:0],
                    (row_index == column_index)
                    ? 32'h0000_0001
                    : 32'h0000_0000
                );
            end
        end

        // ---------------------------------------------------------------------
        // B[k][column] = k + column + 1.
        // ---------------------------------------------------------------------

        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                write_b(
                    matrix_index[5:0],
                    row_index +
                    column_index +
                    1
                );
            end
        end

        check_condition(
            a_valid_mask_o === 64'hFFFF_FFFF_FFFF_FFFF &&
            b_valid_mask_o === 64'hFFFF_FFFF_FFFF_FFFF,
            "8x8 source validity masks mismatch"
        );

        // FP32 precision remains unsupported.
        request_start(
            2'b11,
            4'd8
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_PRECISION,
            "Unsupported tiled-GEMM FP32 precision was not rejected"
        );

        // Execute the complete 8x8 token-matrix operation.
        request_start(
            2'b00,
            4'd8
        );

        check_condition(
            busy_o === 1'b1 &&
            start_ready_o === 1'b0,
            "8x8 tiled GEMM did not enter busy state"
        );

        operation_complete = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 1000 &&
            !operation_complete;
            timeout_count = timeout_count + 1
        ) begin
            @(posedge clk_i);
            #1;

            if (error_o) begin
                check_condition(
                    1'b0,
                    "8x8 tiled GEMM reported an execution error"
                );

                operation_complete = 1'b1;
            end
            else if (done_o) begin
                operation_complete = 1'b1;
            end
        end

        check_condition(
            operation_complete,
            "8x8 tiled GEMM timed out"
        );

        check_condition(
            busy_o === 1'b0 &&
            start_ready_o === 1'b1,
            "8x8 tiled GEMM completion state mismatch"
        );

        check_condition(
            accumulator_valid_o ===
            64'hFFFF_FFFF_FFFF_FFFF,
            "Not all 8x8 output elements became valid"
        );

        // Because A is identity, C[row][column] = row + column + 1.
        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                check_condition(
                    accumulator_o[
                        (matrix_index * 32) +: 32
                    ] ===
                    positive_integer_fp32(
                        row_index +
                        column_index +
                        1
                    ),
                    "8x8 tiled GEMM result mismatch"
                );

                if (
                    accumulator_o[
                        (matrix_index * 32) +: 32
                    ] !==
                    positive_integer_fp32(
                        row_index +
                        column_index +
                        1
                    )
                ) begin
                    $display(
                        "  row=%0d column=%0d result=%08h expected=%08h",
                        row_index,
                        column_index,
                        accumulator_o[
                            (matrix_index * 32) +: 32
                        ],
                        positive_integer_fp32(
                            row_index +
                            column_index +
                            1
                        )
                    );
                end
            end
        end

        check_condition(
            invalid_o === 64'd0 &&
            overflow_o === 64'd0 &&
            underflow_o === 64'd0 &&
            inexact_o === 64'd0,
            "Unexpected 8x8 tiled-GEMM arithmetic flags"
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_tiled_gemm_8x8 passed all %0d autonomous M/N/K tile checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tiled 8x8 GEMM errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
