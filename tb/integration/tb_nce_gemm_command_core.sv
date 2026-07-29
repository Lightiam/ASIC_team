`timescale 1ns/1ps
`default_nettype none

module tb_nce_gemm_command_core;

    localparam logic [2:0] GEMM_ERROR_COMMAND_REJECTED = 3'd5;
    localparam logic [1:0] COMMAND_ERROR_INVALID_OPERAND = 2'b11;

    logic clk_i;
    logic rst_ni;

    logic register_clear_i;
    logic accumulator_clear_i;

    logic         vector_write_enable_i;
    logic [3:0]   vector_write_addr_i;
    logic [7:0]   vector_write_lane_enable_i;
    logic [255:0] vector_write_data_i;

    logic         matrix_write_enable_i;
    logic [3:0]   matrix_write_addr_i;
    logic [7:0]   matrix_write_lane_enable_i;
    logic [255:0] matrix_write_data_i;

    logic       gemm_start_i;
    logic       gemm_start_ready_o;
    logic [1:0] gemm_precision_i;
    logic [3:0] gemm_vector_base_addr_i;
    logic [3:0] gemm_matrix_base_addr_i;
    logic [4:0] gemm_k_count_i;

    logic       gemm_busy_o;
    logic       gemm_done_o;
    logic       gemm_error_o;
    logic [2:0] gemm_error_code_o;
    logic [1:0] gemm_command_error_code_o;

    logic [4:0] gemm_completed_iterations_o;
    logic [4:0] gemm_total_iterations_o;

    logic       command_accept_o;
    logic       command_error_o;
    logic [1:0] command_error_code_o;
    logic       execute_issue_o;
    logic       operand_valid_o;

    logic [255:0] accumulator_o;
    logic         accumulator_valid_o;
    logic         accumulator_update_o;

    logic [7:0] lane_invalid_o;
    logic [7:0] lane_overflow_o;
    logic [7:0] lane_underflow_o;
    logic [7:0] lane_inexact_o;

    logic invalid_o;
    logic overflow_o;
    logic underflow_o;
    logic inexact_o;

    logic [15:0] vector_valid_mask_o;
    logic [15:0] matrix_valid_mask_o;

    integer check_count;
    integer error_count;
    integer timeout_count;

    integer command_accept_count;
    integer execute_issue_count;
    integer accumulator_update_count;

    nce_gemm_command_core dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .register_clear_i            (register_clear_i),
        .accumulator_clear_i         (accumulator_clear_i),

        .vector_write_enable_i       (vector_write_enable_i),
        .vector_write_addr_i         (vector_write_addr_i),
        .vector_write_lane_enable_i  (
            vector_write_lane_enable_i
        ),
        .vector_write_data_i         (vector_write_data_i),

        .matrix_write_enable_i       (matrix_write_enable_i),
        .matrix_write_addr_i         (matrix_write_addr_i),
        .matrix_write_lane_enable_i  (
            matrix_write_lane_enable_i
        ),
        .matrix_write_data_i         (matrix_write_data_i),

        .gemm_start_i                (gemm_start_i),
        .gemm_start_ready_o          (gemm_start_ready_o),

        .gemm_precision_i            (gemm_precision_i),
        .gemm_vector_base_addr_i     (
            gemm_vector_base_addr_i
        ),
        .gemm_matrix_base_addr_i     (
            gemm_matrix_base_addr_i
        ),
        .gemm_k_count_i              (gemm_k_count_i),

        .gemm_busy_o                 (gemm_busy_o),
        .gemm_done_o                 (gemm_done_o),
        .gemm_error_o                (gemm_error_o),
        .gemm_error_code_o           (gemm_error_code_o),
        .gemm_command_error_code_o   (
            gemm_command_error_code_o
        ),

        .gemm_completed_iterations_o (
            gemm_completed_iterations_o
        ),
        .gemm_total_iterations_o     (
            gemm_total_iterations_o
        ),

        .command_accept_o            (command_accept_o),
        .command_error_o             (command_error_o),
        .command_error_code_o        (command_error_code_o),
        .execute_issue_o             (execute_issue_o),
        .operand_valid_o             (operand_valid_o),

        .accumulator_o               (accumulator_o),
        .accumulator_valid_o         (accumulator_valid_o),
        .accumulator_update_o        (accumulator_update_o),

        .lane_invalid_o              (lane_invalid_o),
        .lane_overflow_o             (lane_overflow_o),
        .lane_underflow_o            (lane_underflow_o),
        .lane_inexact_o              (lane_inexact_o),

        .invalid_o                   (invalid_o),
        .overflow_o                  (overflow_o),
        .underflow_o                 (underflow_o),
        .inexact_o                   (inexact_o),

        .vector_valid_mask_o         (vector_valid_mask_o),
        .matrix_valid_mask_o         (matrix_valid_mask_o)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            command_accept_count     <= 0;
            execute_issue_count      <= 0;
            accumulator_update_count <= 0;
        end
        else begin
            if (command_accept_o) begin
                command_accept_count <=
                    command_accept_count + 1;
            end

            if (execute_issue_o) begin
                execute_issue_count <=
                    execute_issue_count + 1;
            end

            if (accumulator_update_o) begin
                accumulator_update_count <=
                    accumulator_update_count + 1;
            end
        end
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

    task automatic write_vector (
        input logic [3:0]   address,
        input logic [255:0] data
    );
        begin
            @(negedge clk_i);

            vector_write_enable_i      = 1'b1;
            vector_write_addr_i        = address;
            vector_write_lane_enable_i = 8'hFF;
            vector_write_data_i        = data;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            vector_write_enable_i      = 1'b0;
            vector_write_lane_enable_i = 8'h00;
            vector_write_data_i        = 256'd0;
        end
    endtask

    task automatic write_matrix (
        input logic [3:0]   address,
        input logic [255:0] data
    );
        begin
            @(negedge clk_i);

            matrix_write_enable_i      = 1'b1;
            matrix_write_addr_i        = address;
            matrix_write_lane_enable_i = 8'hFF;
            matrix_write_data_i        = data;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            matrix_write_enable_i      = 1'b0;
            matrix_write_lane_enable_i = 8'h00;
            matrix_write_data_i        = 256'd0;
        end
    endtask

    task automatic clear_accumulators;
        begin
            @(negedge clk_i);
            accumulator_clear_i = 1'b1;

            @(posedge clk_i);
            #1;

            check_condition(
                accumulator_o === 256'd0 &&
                accumulator_valid_o === 1'b0,
                "Accumulator clear-state mismatch"
            );

            @(negedge clk_i);
            accumulator_clear_i = 1'b0;
        end
    endtask

    task automatic start_gemm (
        input logic [1:0] precision,
        input logic [3:0] vector_base,
        input logic [3:0] matrix_base,
        input logic [4:0] k_count
    );
        begin
            while (gemm_start_ready_o !== 1'b1) begin
                @(negedge clk_i);
            end

            @(negedge clk_i);

            gemm_precision_i        = precision;
            gemm_vector_base_addr_i = vector_base;
            gemm_matrix_base_addr_i = matrix_base;
            gemm_k_count_i          = k_count;
            gemm_start_i            = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            gemm_start_i = 1'b0;
        end
    endtask

    task automatic run_successful_gemm (
        input logic [1:0]   precision,
        input logic [3:0]   vector_base,
        input logic [3:0]   matrix_base,
        input logic [4:0]   k_count,
        input logic [255:0] expected_accumulator
    );

        integer accepts_before;
        integer issues_before;
        integer updates_before;

        logic finished;

        begin
            accepts_before = command_accept_count;
            issues_before  = execute_issue_count;
            updates_before = accumulator_update_count;

            start_gemm(
                precision,
                vector_base,
                matrix_base,
                k_count
            );

            check_condition(
                gemm_busy_o === 1'b1,
                "GEMM controller did not become busy"
            );

            finished = 1'b0;

            for (
                timeout_count = 0;
                timeout_count < 200 && !finished;
                timeout_count = timeout_count + 1
            ) begin
                @(posedge clk_i);
                #1;

                if (gemm_error_o) begin
                    check_condition(
                        1'b0,
                        "Successful GEMM reported an error"
                    );

                    finished = 1'b1;
                end
                else if (gemm_done_o) begin
                    finished = 1'b1;

                    check_condition(
                        accumulator_o === expected_accumulator,
                        "GEMM accumulator result mismatch"
                    );

                    check_condition(
                        accumulator_valid_o === 1'b1,
                        "GEMM accumulator valid missing"
                    );

                    check_condition(
                        gemm_completed_iterations_o === k_count,
                        "Completed-iteration count mismatch"
                    );

                    check_condition(
                        gemm_total_iterations_o === k_count,
                        "Total-iteration count mismatch"
                    );

                    check_condition(
                        gemm_busy_o === 1'b0,
                        "GEMM busy remained set after completion"
                    );

                    check_condition(
                        lane_invalid_o === 8'h00 &&
                        lane_overflow_o === 8'h00 &&
                        lane_underflow_o === 8'h00 &&
                        lane_inexact_o === 8'h00,
                        "Unexpected per-lane arithmetic flags"
                    );
                end
            end

            check_condition(
                finished,
                "GEMM operation timed out"
            );

            check_condition(
                command_accept_count - accepts_before == k_count,
                "Command acceptance count mismatch"
            );

            check_condition(
                execute_issue_count - issues_before == k_count,
                "Execution issue count mismatch"
            );

            check_condition(
                accumulator_update_count - updates_before == k_count,
                "Accumulator update count mismatch"
            );
        end
    endtask

    task automatic run_invalid_operand_gemm;
        integer accepts_before;
        integer issues_before;
        integer updates_before;

        logic finished;

        begin
            accepts_before = command_accept_count;
            issues_before  = execute_issue_count;
            updates_before = accumulator_update_count;

            start_gemm(
                2'b10,
                4'd14,
                4'd14,
                5'd1
            );

            finished = 1'b0;

            for (
                timeout_count = 0;
                timeout_count < 30 && !finished;
                timeout_count = timeout_count + 1
            ) begin
                @(posedge clk_i);
                #1;

                if (gemm_error_o) begin
                    finished = 1'b1;

                    check_condition(
                        gemm_error_code_o ===
                            GEMM_ERROR_COMMAND_REJECTED,
                        "Invalid operand produced wrong GEMM error"
                    );

                    check_condition(
                        gemm_command_error_code_o ===
                            COMMAND_ERROR_INVALID_OPERAND,
                        "Invalid operand command error mismatch"
                    );

                    check_condition(
                        gemm_busy_o === 1'b0,
                        "GEMM remained busy after command rejection"
                    );
                end
            end

            check_condition(
                finished,
                "Invalid-operand GEMM did not report an error"
            );

            check_condition(
                command_accept_count - accepts_before == 1,
                "Rejected command acceptance count mismatch"
            );

            check_condition(
                execute_issue_count - issues_before == 0,
                "Rejected command reached execution"
            );

            check_condition(
                accumulator_update_count - updates_before == 0,
                "Rejected command updated the accumulators"
            );
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        register_clear_i    = 1'b0;
        accumulator_clear_i = 1'b0;

        vector_write_enable_i      = 1'b0;
        vector_write_addr_i        = 4'd0;
        vector_write_lane_enable_i = 8'h00;
        vector_write_data_i        = 256'd0;

        matrix_write_enable_i      = 1'b0;
        matrix_write_addr_i        = 4'd0;
        matrix_write_lane_enable_i = 8'h00;
        matrix_write_data_i        = 256'd0;

        gemm_start_i            = 1'b0;
        gemm_precision_i        = 2'b00;
        gemm_vector_base_addr_i = 4'd0;
        gemm_matrix_base_addr_i = 4'd0;
        gemm_k_count_i          = 5'd0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        check_condition(
            gemm_start_ready_o === 1'b0 &&
            gemm_busy_o === 1'b0 &&
            accumulator_valid_o === 1'b0,
            "Reset state mismatch"
        );

        @(negedge clk_i);
        rst_ni = 1'b1;

        #1;

        check_condition(
            gemm_start_ready_o === 1'b1,
            "GEMM start interface did not become ready"
        );

        // ---------------------------------------------------------------------
        // INT8X4 K=3
        //
        // 4 + 8 + 12 = 24.0
        // ---------------------------------------------------------------------

        write_vector(
            4'd2,
            {8{32'h0101_0101}}
        );

        write_matrix(
            4'd5,
            {8{32'h0101_0101}}
        );

        write_vector(
            4'd3,
            {8{32'h0202_0202}}
        );

        write_matrix(
            4'd6,
            {8{32'h0101_0101}}
        );

        write_vector(
            4'd4,
            {8{32'h0303_0303}}
        );

        write_matrix(
            4'd7,
            {8{32'h0101_0101}}
        );

        run_successful_gemm(
            2'b00,
            4'd2,
            4'd5,
            5'd3,
            {8{32'h41C0_0000}}
        );

        clear_accumulators();

        // ---------------------------------------------------------------------
        // BF16X2 K=2
        //
        // Iteration 0: 1*2 + 3*4 = 14
        // Iteration 1: 2*3 + 4*5 = 26
        // Total: 40.0
        // ---------------------------------------------------------------------

        write_vector(
            4'd8,
            {8{32'h4040_3F80}}
        );

        write_matrix(
            4'd10,
            {8{32'h4080_4000}}
        );

        write_vector(
            4'd9,
            {8{32'h4080_4000}}
        );

        write_matrix(
            4'd11,
            {8{32'h40A0_4040}}
        );

        run_successful_gemm(
            2'b01,
            4'd8,
            4'd10,
            5'd2,
            {8{32'h4220_0000}}
        );

        clear_accumulators();

        // ---------------------------------------------------------------------
        // BF24 K=1
        //
        // 2.0 * 5.0 = 10.0
        // ---------------------------------------------------------------------

        write_vector(
            4'd12,
            {8{32'h0040_0000}}
        );

        write_matrix(
            4'd13,
            {8{32'h0040_A000}}
        );

        run_successful_gemm(
            2'b10,
            4'd12,
            4'd13,
            5'd1,
            {8{32'h4120_0000}}
        );

        clear_accumulators();

        // Registers 14 remain invalid.
        run_invalid_operand_gemm();

        // Register clear removes all source validity.
        @(negedge clk_i);
        register_clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            vector_valid_mask_o === 16'd0 &&
            matrix_valid_mask_o === 16'd0,
            "Register clear did not invalidate operand registers"
        );

        @(negedge clk_i);
        register_clear_i = 1'b0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_gemm_command_core passed all %0d integration checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d GEMM command-core errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
