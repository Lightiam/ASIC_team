`timescale 1ns/1ps
`default_nettype none

module tb_nce_gemm_controller;

    localparam logic [2:0] ERROR_NONE              = 3'd0;
    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_VECTOR_RANGE      = 3'd3;
    localparam logic [2:0] ERROR_MATRIX_RANGE      = 3'd4;
    localparam logic [2:0] ERROR_COMMAND_REJECTED  = 3'd5;
    localparam logic [2:0] ERROR_ISSUE_PROTOCOL    = 3'd6;

    logic clk_i;
    logic rst_ni;
    logic flush_i;

    logic       start_i;
    logic       start_ready_o;
    logic [1:0] precision_i;
    logic [3:0] vector_base_addr_i;
    logic [3:0] matrix_base_addr_i;
    logic [4:0] k_count_i;

    logic       cmd_valid_o;
    logic       cmd_ready_i;
    logic [3:0] cmd_opcode_o;
    logic [1:0] cmd_precision_o;
    logic [3:0] cmd_vector_source_addr_o;
    logic [3:0] cmd_matrix_source_addr_o;

    logic       cmd_error_i;
    logic [1:0] cmd_error_code_i;
    logic       execute_issue_i;
    logic       accumulator_update_i;

    logic       busy_o;
    logic       done_o;
    logic       error_o;
    logic [2:0] error_code_o;
    logic [1:0] command_error_code_o;
    logic [4:0] completed_iterations_o;
    logic [4:0] total_iterations_o;

    integer check_count;
    integer error_count;

    nce_gemm_controller dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .flush_i                     (flush_i),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),

        .precision_i                 (precision_i),
        .vector_base_addr_i          (vector_base_addr_i),
        .matrix_base_addr_i          (matrix_base_addr_i),
        .k_count_i                   (k_count_i),

        .cmd_valid_o                 (cmd_valid_o),
        .cmd_ready_i                 (cmd_ready_i),

        .cmd_opcode_o                (cmd_opcode_o),
        .cmd_precision_o             (cmd_precision_o),
        .cmd_vector_source_addr_o    (
            cmd_vector_source_addr_o
        ),
        .cmd_matrix_source_addr_o    (
            cmd_matrix_source_addr_o
        ),

        .cmd_error_i                 (cmd_error_i),
        .cmd_error_code_i            (cmd_error_code_i),
        .execute_issue_i             (execute_issue_i),
        .accumulator_update_i        (accumulator_update_i),

        .busy_o                      (busy_o),
        .done_o                      (done_o),
        .error_o                     (error_o),
        .error_code_o                (error_code_o),
        .command_error_code_o        (command_error_code_o),

        .completed_iterations_o      (completed_iterations_o),
        .total_iterations_o          (total_iterations_o)
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

    task automatic request_start (
        input logic [1:0] precision,
        input logic [3:0] vector_base,
        input logic [3:0] matrix_base,
        input logic [4:0] k_count
    );
        begin
            @(negedge clk_i);

            precision_i        = precision;
            vector_base_addr_i = vector_base;
            matrix_base_addr_i = matrix_base;
            k_count_i          = k_count;
            start_i            = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    task automatic complete_successful_command (
        input logic [3:0] expected_opcode,
        input logic [1:0] expected_precision,
        input logic [3:0] expected_vector_address,
        input logic [3:0] expected_matrix_address
    );
        begin
            check_condition(
                cmd_valid_o === 1'b1,
                "Command valid was not asserted"
            );

            check_condition(
                cmd_opcode_o === expected_opcode,
                "Command opcode mismatch"
            );

            check_condition(
                cmd_precision_o === expected_precision,
                "Command precision mismatch"
            );

            check_condition(
                cmd_vector_source_addr_o ===
                    expected_vector_address,
                "Vector source address mismatch"
            );

            check_condition(
                cmd_matrix_source_addr_o ===
                    expected_matrix_address,
                "Matrix source address mismatch"
            );

            // Apply one cycle of command backpressure.
            @(posedge clk_i);
            #1;

            check_condition(
                cmd_valid_o === 1'b1,
                "Command valid was not held during backpressure"
            );

            @(negedge clk_i);

            cmd_ready_i     = 1'b1;
            cmd_error_i     = 1'b0;
            execute_issue_i = 1'b1;

            @(posedge clk_i);
            #1;

            check_condition(
                cmd_valid_o === 1'b0,
                "Command remained valid after acceptance"
            );

            @(negedge clk_i);

            cmd_ready_i     = 1'b0;
            execute_issue_i = 1'b0;

            // Model execution latency.
            repeat (2) begin
                @(posedge clk_i);
            end

            @(negedge clk_i);
            accumulator_update_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            accumulator_update_i = 1'b0;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        flush_i = 1'b0;

        start_i             = 1'b0;
        precision_i         = 2'b00;
        vector_base_addr_i  = 4'd0;
        matrix_base_addr_i  = 4'd0;
        k_count_i           = 5'd0;

        cmd_ready_i         = 1'b0;
        cmd_error_i         = 1'b0;
        cmd_error_code_i    = 2'd0;
        execute_issue_i     = 1'b0;
        accumulator_update_i = 1'b0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        check_condition(
            busy_o === 1'b0 &&
            start_ready_o === 1'b1 &&
            cmd_valid_o === 1'b0,
            "Reset state mismatch"
        );

        @(negedge clk_i);
        rst_ni = 1'b1;

        // Unsupported native FP32 precision.
        request_start(
            2'b11,
            4'd0,
            4'd0,
            5'd1
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_PRECISION &&
            busy_o === 1'b0,
            "Invalid precision was not rejected"
        );

        // K = 0.
        request_start(
            2'b00,
            4'd0,
            4'd0,
            5'd0
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_K,
            "Zero K count was not rejected"
        );

        // K > 16.
        request_start(
            2'b00,
            4'd0,
            4'd0,
            5'd17
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_K,
            "K count above 16 was not rejected"
        );

        // Vector-address range overflow.
        request_start(
            2'b00,
            4'd14,
            4'd0,
            5'd3
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_VECTOR_RANGE,
            "Vector source range overflow was not rejected"
        );

        // Matrix-address range overflow.
        request_start(
            2'b00,
            4'd0,
            4'd15,
            5'd2
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_MATRIX_RANGE,
            "Matrix source range overflow was not rejected"
        );

        // ---------------------------------------------------------------------
        // INT8X4 K=3 sequence.
        // ---------------------------------------------------------------------

        request_start(
            2'b00,
            4'd2,
            4'd5,
            5'd3
        );

        check_condition(
            busy_o === 1'b1 &&
            total_iterations_o === 5'd3 &&
            completed_iterations_o === 5'd0,
            "INT8 GEMM start state mismatch"
        );

        complete_successful_command(
            4'h4,
            2'b00,
            4'd2,
            4'd5
        );

        check_condition(
            completed_iterations_o === 5'd1 &&
            busy_o === 1'b1 &&
            done_o === 1'b0,
            "INT8 iteration 1 completion mismatch"
        );

        complete_successful_command(
            4'h4,
            2'b00,
            4'd3,
            4'd6
        );

        check_condition(
            completed_iterations_o === 5'd2 &&
            busy_o === 1'b1,
            "INT8 iteration 2 completion mismatch"
        );

        complete_successful_command(
            4'h4,
            2'b00,
            4'd4,
            4'd7
        );

        check_condition(
            completed_iterations_o === 5'd3 &&
            busy_o === 1'b0 &&
            done_o === 1'b1 &&
            error_o === 1'b0,
            "INT8 GEMM completion mismatch"
        );

        // ---------------------------------------------------------------------
        // BF16X2 K=2 sequence.
        // ---------------------------------------------------------------------

        request_start(
            2'b01,
            4'd8,
            4'd10,
            5'd2
        );

        complete_successful_command(
            4'h3,
            2'b01,
            4'd8,
            4'd10
        );

        complete_successful_command(
            4'h3,
            2'b01,
            4'd9,
            4'd11
        );

        check_condition(
            completed_iterations_o === 5'd2 &&
            busy_o === 1'b0 &&
            done_o === 1'b1,
            "BF16 GEMM completion mismatch"
        );

        // ---------------------------------------------------------------------
        // BF24 K=1 sequence.
        // ---------------------------------------------------------------------

        request_start(
            2'b10,
            4'd12,
            4'd13,
            5'd1
        );

        complete_successful_command(
            4'h3,
            2'b10,
            4'd12,
            4'd13
        );

        check_condition(
            completed_iterations_o === 5'd1 &&
            busy_o === 1'b0 &&
            done_o === 1'b1,
            "BF24 GEMM completion mismatch"
        );

        // ---------------------------------------------------------------------
        // Command-core rejection propagation.
        // ---------------------------------------------------------------------

        request_start(
            2'b10,
            4'd1,
            4'd1,
            5'd1
        );

        @(negedge clk_i);

        cmd_ready_i      = 1'b1;
        cmd_error_i      = 1'b1;
        cmd_error_code_i = 2'b11;
        execute_issue_i  = 1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_COMMAND_REJECTED &&
            command_error_code_o === 2'b11 &&
            busy_o === 1'b0,
            "Command rejection was not propagated"
        );

        @(negedge clk_i);

        cmd_ready_i      = 1'b0;
        cmd_error_i      = 1'b0;
        cmd_error_code_i = 2'd0;

        // Accepted command without execute_issue is a protocol error.
        request_start(
            2'b01,
            4'd1,
            4'd1,
            5'd1
        );

        @(negedge clk_i);

        cmd_ready_i     = 1'b1;
        cmd_error_i     = 1'b0;
        execute_issue_i = 1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_ISSUE_PROTOCOL &&
            busy_o === 1'b0,
            "Issue-protocol error was not detected"
        );

        @(negedge clk_i);
        cmd_ready_i = 1'b0;

        // Flush aborts an active sequence.
        request_start(
            2'b00,
            4'd0,
            4'd0,
            5'd4
        );

        check_condition(
            busy_o === 1'b1,
            "Controller did not become busy before flush"
        );

        @(negedge clk_i);
        flush_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            busy_o === 1'b0 &&
            cmd_valid_o === 1'b0 &&
            completed_iterations_o === 5'd0 &&
            total_iterations_o === 5'd0 &&
            error_code_o === ERROR_NONE,
            "Flush did not return controller to idle"
        );

        @(negedge clk_i);
        flush_i = 1'b0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_gemm_controller passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: nce_gemm_controller detected %0d errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
