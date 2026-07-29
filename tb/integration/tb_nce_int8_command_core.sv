`timescale 1ns/1ps
`default_nettype none

module tb_nce_int8_command_core;

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

    logic       cmd_valid_i;
    logic       cmd_ready_o;
    logic [3:0] cmd_opcode_i;
    logic [1:0] cmd_precision_i;
    logic [3:0] vector_source_addr_i;
    logic [3:0] matrix_source_addr_i;

    logic       cmd_accept_o;
    logic       cmd_error_o;
    logic [1:0] cmd_error_code_o;
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

    logic vector_register_clear;
    logic vector_accumulator_clear;

    logic vector_write_enable;
    logic [3:0] vector_write_addr;
    logic [7:0] vector_write_lane_enable;
    logic [255:0] vector_write_data;

    logic matrix_write_enable;
    logic [3:0] matrix_write_addr;
    logic [7:0] matrix_write_lane_enable;
    logic [255:0] matrix_write_data;

    logic vector_cmd_valid;
    logic [3:0] vector_opcode;
    logic [1:0] vector_precision;
    logic [3:0] vector_source_addr;
    logic [3:0] matrix_source_addr;

    logic expected_cmd_ready;
    logic expected_cmd_accept;
    logic expected_cmd_error;
    logic [1:0] expected_cmd_error_code;
    logic expected_execute_issue;
    logic expected_operand_valid;

    logic [255:0] expected_accumulator;
    logic expected_accumulator_valid;
    logic expected_accumulator_update;

    logic [7:0] expected_lane_invalid;
    logic [7:0] expected_lane_overflow;
    logic [7:0] expected_lane_underflow;
    logic [7:0] expected_lane_inexact;

    logic expected_invalid;
    logic expected_overflow;
    logic expected_underflow;
    logic expected_inexact;

    logic [15:0] expected_vector_valid_mask;
    logic [15:0] expected_matrix_valid_mask;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_int8_command_core dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .register_clear_i            (register_clear_i),
        .accumulator_clear_i         (accumulator_clear_i),

        .vector_write_enable_i       (vector_write_enable_i),
        .vector_write_addr_i         (vector_write_addr_i),
        .vector_write_lane_enable_i  (vector_write_lane_enable_i),
        .vector_write_data_i         (vector_write_data_i),

        .matrix_write_enable_i       (matrix_write_enable_i),
        .matrix_write_addr_i         (matrix_write_addr_i),
        .matrix_write_lane_enable_i  (matrix_write_lane_enable_i),
        .matrix_write_data_i         (matrix_write_data_i),

        .cmd_valid_i                 (cmd_valid_i),
        .cmd_ready_o                 (cmd_ready_o),
        .cmd_opcode_i                (cmd_opcode_i),
        .cmd_precision_i             (cmd_precision_i),

        .vector_source_addr_i        (vector_source_addr_i),
        .matrix_source_addr_i        (matrix_source_addr_i),

        .cmd_accept_o                (cmd_accept_o),
        .cmd_error_o                 (cmd_error_o),
        .cmd_error_code_o            (cmd_error_code_o),
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

    initial begin
        rst_ni = 1'b0;

        register_clear_i = 1'b0;
        accumulator_clear_i = 1'b0;

        vector_write_enable_i = 1'b0;
        vector_write_addr_i = '0;
        vector_write_lane_enable_i = '0;
        vector_write_data_i = '0;

        matrix_write_enable_i = 1'b0;
        matrix_write_addr_i = '0;
        matrix_write_lane_enable_i = '0;
        matrix_write_data_i = '0;

        cmd_valid_i = 1'b0;
        cmd_opcode_i = '0;
        cmd_precision_i = '0;
        vector_source_addr_i = '0;
        matrix_source_addr_i = '0;

        test_count = 0;
        error_count = 0;

        repeat (3) @(posedge clk_i);

        #1;

        if (
            accumulator_o !== 256'd0 ||
            accumulator_valid_o !== 1'b0 ||
            vector_valid_mask_o !== 16'd0 ||
            matrix_valid_mask_o !== 16'd0
        ) begin
            $fatal(1, "Command core reset state is incorrect.");
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/int8_command_core_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(1, "Could not open command-core vectors.");
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",

                vector_register_clear,
                vector_accumulator_clear,

                vector_write_enable,
                vector_write_addr,
                vector_write_lane_enable,
                vector_write_data,

                matrix_write_enable,
                matrix_write_addr,
                matrix_write_lane_enable,
                matrix_write_data,

                vector_cmd_valid,
                vector_opcode,
                vector_precision,
                vector_source_addr,
                matrix_source_addr,

                expected_cmd_ready,
                expected_cmd_accept,
                expected_cmd_error,
                expected_cmd_error_code,
                expected_execute_issue,
                expected_operand_valid,

                expected_accumulator,
                expected_accumulator_valid,
                expected_accumulator_update,

                expected_lane_invalid,
                expected_lane_overflow,
                expected_lane_underflow,
                expected_lane_inexact,

                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact,

                expected_vector_valid_mask,
                expected_matrix_valid_mask
            );

            if (scan_result == 34) begin
                @(negedge clk_i);

                register_clear_i = vector_register_clear;
                accumulator_clear_i = vector_accumulator_clear;

                vector_write_enable_i = vector_write_enable;
                vector_write_addr_i = vector_write_addr;
                vector_write_lane_enable_i =
                    vector_write_lane_enable;
                vector_write_data_i = vector_write_data;

                matrix_write_enable_i = matrix_write_enable;
                matrix_write_addr_i = matrix_write_addr;
                matrix_write_lane_enable_i =
                    matrix_write_lane_enable;
                matrix_write_data_i = matrix_write_data;

                cmd_valid_i = vector_cmd_valid;
                cmd_opcode_i = vector_opcode;
                cmd_precision_i = vector_precision;
                vector_source_addr_i = vector_source_addr;
                matrix_source_addr_i = matrix_source_addr;

                #1;

                if (
                    cmd_ready_o !== expected_cmd_ready ||
                    cmd_accept_o !== expected_cmd_accept ||
                    cmd_error_o !== expected_cmd_error ||
                    cmd_error_code_o !== expected_cmd_error_code ||
                    execute_issue_o !== expected_execute_issue ||
                    operand_valid_o !== expected_operand_valid
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "CONTROL ERROR test=%0d ready=%h/%h accept=%h/%h error=%h/%h code=%h/%h issue=%h/%h operands=%h/%h",
                            test_count + 1,
                            cmd_ready_o,
                            expected_cmd_ready,
                            cmd_accept_o,
                            expected_cmd_accept,
                            cmd_error_o,
                            expected_cmd_error,
                            cmd_error_code_o,
                            expected_cmd_error_code,
                            execute_issue_o,
                            expected_execute_issue,
                            operand_valid_o,
                            expected_operand_valid
                        );
                    end
                end

                @(posedge clk_i);
                #1;

                test_count = test_count + 1;

                if (
                    accumulator_o !== expected_accumulator ||
                    accumulator_valid_o !== expected_accumulator_valid ||
                    accumulator_update_o !== expected_accumulator_update ||

                    lane_invalid_o !== expected_lane_invalid ||
                    lane_overflow_o !== expected_lane_overflow ||
                    lane_underflow_o !== expected_lane_underflow ||
                    lane_inexact_o !== expected_lane_inexact ||

                    invalid_o !== expected_invalid ||
                    overflow_o !== expected_overflow ||
                    underflow_o !== expected_underflow ||
                    inexact_o !== expected_inexact ||

                    vector_valid_mask_o !== expected_vector_valid_mask ||
                    matrix_valid_mask_o !== expected_matrix_valid_mask
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "STATE ERROR test=%0d acc=%064h/%064h valid=%h/%h update=%h/%h masks=%04h,%04h/%04h,%04h",
                            test_count,
                            accumulator_o,
                            expected_accumulator,
                            accumulator_valid_o,
                            expected_accumulator_valid,
                            accumulator_update_o,
                            expected_accumulator_update,
                            vector_valid_mask_o,
                            matrix_valid_mask_o,
                            expected_vector_valid_mask,
                            expected_matrix_valid_mask
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_int8_command_core passed all %0d cycles.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d cycles.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
