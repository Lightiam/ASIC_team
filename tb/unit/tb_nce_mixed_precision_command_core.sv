`timescale 1ns/1ps
`default_nettype none

module tb_nce_mixed_precision_command_core;

    localparam logic [1:0] ERROR_NONE                  = 2'b00;
    localparam logic [1:0] ERROR_UNSUPPORTED_OPCODE    = 2'b01;
    localparam logic [1:0] ERROR_UNSUPPORTED_PRECISION = 2'b10;
    localparam logic [1:0] ERROR_INVALID_OPERAND       = 2'b11;

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

    logic         cmd_valid_i;
    logic         cmd_ready_o;
    logic [3:0]   cmd_opcode_i;
    logic [1:0]   cmd_precision_i;
    logic [3:0]   vector_source_addr_i;
    logic [3:0]   matrix_source_addr_i;

    logic         cmd_accept_o;
    logic         cmd_error_o;
    logic [1:0]   cmd_error_code_o;
    logic         execute_issue_o;
    logic         operand_valid_o;

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

    integer error_count;
    integer check_count;
    integer timeout_count;

    nce_mixed_precision_command_core dut (
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

    task automatic report_error (
        input string message
    );
        begin
            error_count = error_count + 1;

            if (error_count <= 20) begin
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

            if (
                accumulator_o !== 256'd0 ||
                accumulator_valid_o !== 1'b0 ||
                accumulator_update_o !== 1'b0
            ) begin
                report_error(
                    "Accumulator clear-state mismatch"
                );
            end

            @(negedge clk_i);
            accumulator_clear_i = 1'b0;
        end
    endtask

    task automatic issue_valid_command (
        input logic [3:0]   opcode,
        input logic [1:0]   precision,
        input logic [3:0]   vector_address,
        input logic [3:0]   matrix_address,
        input logic [255:0] expected_result
    );

        logic completed;

        begin
            completed = 1'b0;

            cmd_opcode_i          = opcode;
            cmd_precision_i       = precision;
            vector_source_addr_i  = vector_address;
            matrix_source_addr_i  = matrix_address;

            while (cmd_ready_o !== 1'b1) begin
                @(negedge clk_i);
            end

            @(negedge clk_i);
            cmd_valid_i = 1'b1;

            @(posedge clk_i);
            #1;

            check_count = check_count + 1;

            if (
                cmd_accept_o !== 1'b1 ||
                execute_issue_o !== 1'b1 ||
                cmd_error_o !== 1'b0 ||
                cmd_error_code_o !== ERROR_NONE
            ) begin
                report_error(
                    "Valid command was not issued correctly"
                );
            end

            @(negedge clk_i);
            cmd_valid_i = 1'b0;

            for (
                timeout_count = 0;
                timeout_count < 15;
                timeout_count = timeout_count + 1
            ) begin
                @(posedge clk_i);
                #1;

                if (
                    accumulator_update_o &&
                    !completed
                ) begin
                    completed = 1'b1;

                    if (
                        accumulator_o !== expected_result
                    ) begin
                        report_error(
                            "Command accumulator result mismatch"
                        );

                        if (error_count <= 20) begin
                            $display(
                                "  result  =%064h",
                                accumulator_o
                            );

                            $display(
                                "  expected=%064h",
                                expected_result
                            );
                        end
                    end

                    if (
                        accumulator_valid_o !== 1'b1
                    ) begin
                        report_error(
                            "Accumulator valid missing"
                        );
                    end
                end
            end

            if (!completed) begin
                report_error(
                    "Valid command did not complete"
                );
            end
        end
    endtask

    task automatic issue_rejected_command (
        input logic [3:0] opcode,
        input logic [1:0] precision,
        input logic [3:0] vector_address,
        input logic [3:0] matrix_address,
        input logic [1:0] expected_error
    );
        begin
            cmd_opcode_i          = opcode;
            cmd_precision_i       = precision;
            vector_source_addr_i  = vector_address;
            matrix_source_addr_i  = matrix_address;

            @(negedge clk_i);
            cmd_valid_i = 1'b1;

            #1;

            check_count = check_count + 1;

            if (
                cmd_ready_o !== 1'b1 ||
                cmd_accept_o !== 1'b1 ||
                execute_issue_o !== 1'b0 ||
                cmd_error_o !== 1'b1 ||
                cmd_error_code_o !== expected_error
            ) begin
                report_error(
                    "Rejected command status mismatch"
                );

                if (error_count <= 20) begin
                    $display(
                        "  ready/accept/issue/error/code=%b %b %b %b %b",
                        cmd_ready_o,
                        cmd_accept_o,
                        execute_issue_o,
                        cmd_error_o,
                        cmd_error_code_o
                    );
                end
            end

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            cmd_valid_i = 1'b0;

            repeat (4) begin
                @(posedge clk_i);
                #1;

                if (accumulator_update_o !== 1'b0) begin
                    report_error(
                        "Rejected command updated accumulator"
                    );
                end
            end
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

        cmd_valid_i          = 1'b0;
        cmd_opcode_i         = 4'h0;
        cmd_precision_i      = 2'b00;
        vector_source_addr_i = 4'd0;
        matrix_source_addr_i = 4'd0;

        error_count = 0;
        check_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        if (
            vector_valid_mask_o !== 16'd0 ||
            matrix_valid_mask_o !== 16'd0 ||
            operand_valid_o !== 1'b0
        ) begin
            report_error(
                "Reset state mismatch"
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        // ---------------------------------------------------------------------
        // Load and execute INT8X4 DOT4 command.
        //
        // Per lane:
        //   1*5 + 2*6 + 3*7 + 4*8 = 70
        // ---------------------------------------------------------------------

        write_vector(
            4'd2,
            {8{32'h0403_0201}}
        );

        write_matrix(
            4'd3,
            {8{32'h0807_0605}}
        );

        issue_valid_command(
            4'h4,
            2'b00,
            4'd2,
            4'd3,
            {8{32'h428C_0000}}
        );

        // ---------------------------------------------------------------------
        // Execute BF16X2 command into the same accumulators.
        //
        // Per lane:
        //   1*2 + 3*4 = 14
        //
        // Shared result:
        //   70 + 14 = 84
        // ---------------------------------------------------------------------

        write_vector(
            4'd4,
            {8{32'h4040_3F80}}
        );

        write_matrix(
            4'd5,
            {8{32'h4080_4000}}
        );

        issue_valid_command(
            4'h3,
            2'b01,
            4'd4,
            4'd5,
            {8{32'h42A8_0000}}
        );

        // ---------------------------------------------------------------------
        // Execute BF24 through the command path.
        //
        // Per lane:
        //
        //   2.0 * 5.0 = 10.0
        //
        // Shared accumulated result:
        //
        //   70 + 14 + 10 = 94.0
        // ---------------------------------------------------------------------

        write_vector(
            4'd6,
            {8{32'h0040_0000}}
        );

        write_matrix(
            4'd7,
            {8{32'h0040_A000}}
        );

        issue_valid_command(
            4'h3,
            2'b10,
            4'd6,
            4'd7,
            {8{32'h42BC_0000}}
        );

        // Wrong opcode/precision pair.
        issue_rejected_command(
            4'h4,
            2'b01,
            4'd4,
            4'd5,
            ERROR_UNSUPPORTED_PRECISION
        );

        // BF24 is supported only with the MAC opcode.
        issue_rejected_command(
            4'h4,
            2'b10,
            4'd6,
            4'd7,
            ERROR_UNSUPPORTED_PRECISION
        );

        issue_rejected_command(
            4'h3,
            2'b00,
            4'd2,
            4'd3,
            ERROR_UNSUPPORTED_PRECISION
        );

        // Unsupported opcode.
        issue_rejected_command(
            4'hF,
            2'b00,
            4'd2,
            4'd3,
            ERROR_UNSUPPORTED_OPCODE
        );

        // Native FP32 execution precision remains unsupported.
        issue_rejected_command(
            4'h3,
            2'b11,
            4'd6,
            4'd7,
            ERROR_UNSUPPORTED_PRECISION
        );

        // Invalid source registers.
        issue_rejected_command(
            4'h4,
            2'b00,
            4'd14,
            4'd15,
            ERROR_INVALID_OPERAND
        );

        // Accumulator clear keeps register contents and validity.
        clear_accumulators();

        // Execute BF24 again after clearing only the accumulators.
        // Source register contents and validity must remain intact.
        issue_valid_command(
            4'h3,
            2'b10,
            4'd6,
            4'd7,
            {8{32'h4120_0000}}
        );

        // Register clear invalidates all register sources.
        @(negedge clk_i);
        register_clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_count = check_count + 1;

        if (
            vector_valid_mask_o !== 16'd0 ||
            matrix_valid_mask_o !== 16'd0 ||
            operand_valid_o !== 1'b0 ||
            cmd_ready_o !== 1'b0
        ) begin
            report_error(
                "Register clear behavior mismatch"
            );
        end

        @(negedge clk_i);
        register_clear_i = 1'b0;

        if (
            lane_invalid_o !== 8'h00 ||
            lane_overflow_o !== 8'h00 ||
            lane_underflow_o !== 8'h00 ||
            lane_inexact_o !== 8'h00 ||
            invalid_o !== 1'b0 ||
            overflow_o !== 1'b0 ||
            underflow_o !== 1'b0 ||
            inexact_o !== 1'b0
        ) begin
            report_error(
                "Unexpected final arithmetic flags"
            );
        end

        if (error_count == 0) begin
            $display(
                "PASS: nce_mixed_precision_command_core passed all %0d integration checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d mixed-precision command-core errors detected.",
                error_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
