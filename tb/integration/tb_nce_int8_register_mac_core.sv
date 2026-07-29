`timescale 1ns/1ps
`default_nettype none

module tb_nce_int8_register_mac_core;

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

    logic       exec_valid_i;
    logic       exec_ready_o;
    logic [3:0] vector_source_addr_i;
    logic [3:0] matrix_source_addr_i;

    logic operand_valid_o;
    logic operand_error_o;

    logic [3:0]   vector_debug_addr_i;
    logic [255:0] vector_debug_data_o;
    logic         vector_debug_valid_o;

    logic [3:0]   matrix_debug_addr_i;
    logic [255:0] matrix_debug_data_o;
    logic         matrix_debug_valid_o;

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

    logic vector_exec_valid;
    logic [3:0] vector_source_addr;
    logic [3:0] matrix_source_addr;

    logic expected_exec_ready;
    logic expected_operand_valid;
    logic expected_operand_error;

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

    nce_int8_register_mac_core dut (
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

        .exec_valid_i                (exec_valid_i),
        .exec_ready_o                (exec_ready_o),
        .vector_source_addr_i        (vector_source_addr_i),
        .matrix_source_addr_i        (matrix_source_addr_i),

        .operand_valid_o             (operand_valid_o),
        .operand_error_o             (operand_error_o),

        .vector_debug_addr_i         (vector_debug_addr_i),
        .vector_debug_data_o         (vector_debug_data_o),
        .vector_debug_valid_o        (vector_debug_valid_o),

        .matrix_debug_addr_i         (matrix_debug_addr_i),
        .matrix_debug_data_o         (matrix_debug_data_o),
        .matrix_debug_valid_o        (matrix_debug_valid_o),

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

        forever begin
            #5 clk_i = ~clk_i;
        end
    end

    initial begin
        rst_ni                     = 1'b0;

        register_clear_i           = 1'b0;
        accumulator_clear_i        = 1'b0;

        vector_write_enable_i      = 1'b0;
        vector_write_addr_i        = 4'd0;
        vector_write_lane_enable_i = 8'd0;
        vector_write_data_i        = 256'd0;

        matrix_write_enable_i      = 1'b0;
        matrix_write_addr_i        = 4'd0;
        matrix_write_lane_enable_i = 8'd0;
        matrix_write_data_i        = 256'd0;

        exec_valid_i               = 1'b0;
        vector_source_addr_i       = 4'd0;
        matrix_source_addr_i       = 4'd0;

        vector_debug_addr_i        = 4'd0;
        matrix_debug_addr_i        = 4'd0;

        test_count                 = 0;
        error_count                = 0;

        repeat (3) begin
            @(posedge clk_i);
        end

        #1;

        if (
            accumulator_o !== 256'd0 ||
            accumulator_valid_o !== 1'b0 ||
            accumulator_update_o !== 1'b0 ||
            vector_valid_mask_o !== 16'd0 ||
            matrix_valid_mask_o !== 16'd0
        ) begin
            $fatal(
                1,
                "Register-MAC core reset state is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/int8_register_mac_core_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open register-MAC core vectors."
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",

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

                vector_exec_valid,
                vector_source_addr,
                matrix_source_addr,

                expected_exec_ready,
                expected_operand_valid,
                expected_operand_error,

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

            if (scan_result == 29) begin
                @(negedge clk_i);

                register_clear_i =
                    vector_register_clear;

                accumulator_clear_i =
                    vector_accumulator_clear;

                vector_write_enable_i =
                    vector_write_enable;

                vector_write_addr_i =
                    vector_write_addr;

                vector_write_lane_enable_i =
                    vector_write_lane_enable;

                vector_write_data_i =
                    vector_write_data;

                matrix_write_enable_i =
                    matrix_write_enable;

                matrix_write_addr_i =
                    matrix_write_addr;

                matrix_write_lane_enable_i =
                    matrix_write_lane_enable;

                matrix_write_data_i =
                    matrix_write_data;

                exec_valid_i =
                    vector_exec_valid;

                vector_source_addr_i =
                    vector_source_addr;

                matrix_source_addr_i =
                    matrix_source_addr;

                vector_debug_addr_i =
                    vector_source_addr;

                matrix_debug_addr_i =
                    matrix_source_addr;

                #1;

                if (
                    exec_ready_o !== expected_exec_ready ||
                    operand_valid_o !== expected_operand_valid ||
                    operand_error_o !== expected_operand_error
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "CONTROL ERROR test=%0d ready=%h/%h operand_valid=%h/%h operand_error=%h/%h",
                            test_count + 1,
                            exec_ready_o,
                            expected_exec_ready,
                            operand_valid_o,
                            expected_operand_valid,
                            operand_error_o,
                            expected_operand_error
                        );
                    end
                end

                @(posedge clk_i);
                #1;

                test_count = test_count + 1;

                if (
                    accumulator_o !== expected_accumulator ||
                    accumulator_valid_o !==
                        expected_accumulator_valid ||
                    accumulator_update_o !==
                        expected_accumulator_update ||

                    lane_invalid_o !== expected_lane_invalid ||
                    lane_overflow_o !== expected_lane_overflow ||
                    lane_underflow_o !== expected_lane_underflow ||
                    lane_inexact_o !== expected_lane_inexact ||

                    invalid_o !== expected_invalid ||
                    overflow_o !== expected_overflow ||
                    underflow_o !== expected_underflow ||
                    inexact_o !== expected_inexact ||

                    vector_valid_mask_o !==
                        expected_vector_valid_mask ||
                    matrix_valid_mask_o !==
                        expected_matrix_valid_mask
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "STATE ERROR test=%0d acc=%064h/%064h valid=%h/%h update=%h/%h lane_flags=%02h,%02h,%02h,%02h/%02h,%02h,%02h,%02h masks=%04h,%04h/%04h,%04h",
                            test_count,
                            accumulator_o,
                            expected_accumulator,
                            accumulator_valid_o,
                            expected_accumulator_valid,
                            accumulator_update_o,
                            expected_accumulator_update,
                            lane_invalid_o,
                            lane_overflow_o,
                            lane_underflow_o,
                            lane_inexact_o,
                            expected_lane_invalid,
                            expected_lane_overflow,
                            expected_lane_underflow,
                            expected_lane_inexact,
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
                "PASS: nce_int8_register_mac_core passed all %0d cycles.",
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
