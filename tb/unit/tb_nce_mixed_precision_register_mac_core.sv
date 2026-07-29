`timescale 1ns/1ps
`default_nettype none

module tb_nce_mixed_precision_register_mac_core;

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

    logic         exec_valid_i;
    logic         exec_ready_o;
    logic [1:0]   exec_precision_i;
    logic [3:0]   vector_source_addr_i;
    logic [3:0]   matrix_source_addr_i;

    logic operand_valid_o;
    logic operand_error_o;
    logic precision_supported_o;

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

    integer error_count;
    integer operation_count;
    integer timeout_count;

    nce_mixed_precision_register_mac_core dut (
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
        .exec_precision_i            (exec_precision_i),

        .vector_source_addr_i        (vector_source_addr_i),
        .matrix_source_addr_i        (matrix_source_addr_i),

        .operand_valid_o             (operand_valid_o),
        .operand_error_o             (operand_error_o),
        .precision_supported_o       (precision_supported_o),

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
        forever #5 clk_i = ~clk_i;
    end

    task automatic report_error (
        input string message
    );
        begin
            error_count = error_count + 1;

            if (error_count <= 20) begin
                $display(
                    "ERROR operation=%0d: %s",
                    operation_count,
                    message
                );
            end
        end
    endtask

    task automatic write_vector (
        input logic [3:0]   address,
        input logic [7:0]   lane_enable,
        input logic [255:0] data
    );
        begin
            @(negedge clk_i);

            vector_write_enable_i      = 1'b1;
            vector_write_addr_i        = address;
            vector_write_lane_enable_i = lane_enable;
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
        input logic [7:0]   lane_enable,
        input logic [255:0] data
    );
        begin
            @(negedge clk_i);

            matrix_write_enable_i      = 1'b1;
            matrix_write_addr_i        = address;
            matrix_write_lane_enable_i = lane_enable;
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

    task automatic issue_execution (
        input logic [1:0]   precision,
        input logic [3:0]   vector_address,
        input logic [3:0]   matrix_address,
        input logic [255:0] expected_result
    );

        logic completed;

        begin
            completed = 1'b0;

            exec_precision_i       = precision;
            vector_source_addr_i   = vector_address;
            matrix_source_addr_i   = matrix_address;

            while (exec_ready_o !== 1'b1) begin
                @(negedge clk_i);
            end

            @(negedge clk_i);
            exec_valid_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            exec_valid_i = 1'b0;

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
                        accumulator_o !==
                        expected_result
                    ) begin
                        report_error(
                            "Accumulator result mismatch"
                        );

                        if (error_count <= 20) begin
                            $display(
                                "  result  = %064h",
                                accumulator_o
                            );

                            $display(
                                "  expected= %064h",
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

                    if (
                        lane_invalid_o !== 8'h00 ||
                        lane_overflow_o !== 8'h00 ||
                        lane_underflow_o !== 8'h00 ||
                        lane_inexact_o !== 8'h00
                    ) begin
                        report_error(
                            "Unexpected arithmetic status flags"
                        );
                    end
                end
            end

            if (!completed) begin
                report_error(
                    "Execution did not complete"
                );
            end

            operation_count =
                operation_count + 1;
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        register_clear_i    = 1'b0;
        accumulator_clear_i = 1'b0;

        vector_write_enable_i      = 1'b0;
        vector_write_addr_i        = 4'd0;
        vector_write_lane_enable_i = 8'd0;
        vector_write_data_i        = 256'd0;

        matrix_write_enable_i      = 1'b0;
        matrix_write_addr_i        = 4'd0;
        matrix_write_lane_enable_i = 8'd0;
        matrix_write_data_i        = 256'd0;

        exec_valid_i          = 1'b0;
        exec_precision_i      = 2'b00;
        vector_source_addr_i  = 4'd0;
        matrix_source_addr_i  = 4'd0;

        vector_debug_addr_i = 4'd0;
        matrix_debug_addr_i = 4'd0;

        error_count     = 0;
        operation_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        if (
            vector_valid_mask_o !== 16'd0 ||
            matrix_valid_mask_o !== 16'd0 ||
            operand_valid_o !== 1'b0 ||
            exec_ready_o !== 1'b0
        ) begin
            report_error(
                "Reset state mismatch"
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        // ---------------------------------------------------------------------
        // Load packed INT8 operands.
        //
        // Per lane:
        //   1*5 + 2*6 + 3*7 + 4*8 = 70.0
        // ---------------------------------------------------------------------

        write_vector(
            4'd2,
            8'hFF,
            {8{32'h0403_0201}}
        );

        write_matrix(
            4'd3,
            8'hFF,
            {8{32'h0807_0605}}
        );

        if (
            vector_valid_mask_o[2] !== 1'b1 ||
            matrix_valid_mask_o[3] !== 1'b1
        ) begin
            report_error(
                "Register valid masks were not updated"
            );
        end

        issue_execution(
            2'b00,
            4'd2,
            4'd3,
            {8{32'h428C_0000}}
        );

        // ---------------------------------------------------------------------
        // Load packed BF16X2 operands.
        //
        // Per lane:
        //   1*2 + 3*4 = 14.0
        //
        // Shared accumulated result:
        //   70 + 14 = 84.0
        // ---------------------------------------------------------------------

        write_vector(
            4'd4,
            8'hFF,
            {8{32'h4040_3F80}}
        );

        write_matrix(
            4'd5,
            8'hFF,
            {8{32'h4080_4000}}
        );

        issue_execution(
            2'b01,
            4'd4,
            4'd5,
            {8{32'h42A8_0000}}
        );

        // ---------------------------------------------------------------------
        // Load BF24 operands.
        //
        // Each 32-bit lane contains:
        //
        //   bits [23:0]  = one BF24 value
        //   bits [31:24] = reserved and zero
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
            8'hFF,
            {8{32'h0040_0000}}
        );

        write_matrix(
            4'd7,
            8'hFF,
            {8{32'h0040_A000}}
        );

        if (
            vector_valid_mask_o[6] !== 1'b1 ||
            matrix_valid_mask_o[7] !== 1'b1
        ) begin
            report_error(
                "BF24 register valid masks were not updated"
            );
        end

        issue_execution(
            2'b10,
            4'd6,
            4'd7,
            {8{32'h42BC_0000}}
        );

        // Accumulator clear must not clear source registers.
        clear_accumulators();

        if (
            vector_valid_mask_o[2] !== 1'b1 ||
            vector_valid_mask_o[4] !== 1'b1 ||
            vector_valid_mask_o[6] !== 1'b1 ||
            matrix_valid_mask_o[3] !== 1'b1 ||
            matrix_valid_mask_o[5] !== 1'b1 ||
            matrix_valid_mask_o[7] !== 1'b1
        ) begin
            report_error(
                "Accumulator clear incorrectly changed register validity"
            );
        end

        // Execute BF24 again after accumulator clear.
        //
        // The register contents remain valid, and each accumulator must
        // contain only the BF24 product 10.0.
        issue_execution(
            2'b10,
            4'd6,
            4'd7,
            {8{32'h4120_0000}}
        );

        // ---------------------------------------------------------------------
        // Invalid source registers must not execute.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        exec_precision_i      = 2'b00;
        vector_source_addr_i  = 4'd14;
        matrix_source_addr_i  = 4'd15;
        exec_valid_i          = 1'b1;

        #1;

        if (
            operand_valid_o !== 1'b0 ||
            operand_error_o !== 1'b1 ||
            exec_ready_o !== 1'b0
        ) begin
            report_error(
                "Invalid operands were not blocked"
            );
        end

        repeat (3) begin
            @(posedge clk_i);
            #1;

            if (accumulator_update_o !== 1'b0) begin
                report_error(
                    "Invalid operands caused an accumulator update"
                );
            end
        end

        @(negedge clk_i);
        exec_valid_i = 1'b0;

        // ---------------------------------------------------------------------
        // Native FP32 execution precision is not implemented and must remain
        // blocked.
        // ---------------------------------------------------------------------

        exec_precision_i      = 2'b11;
        vector_source_addr_i  = 4'd6;
        matrix_source_addr_i  = 4'd7;
        exec_valid_i          = 1'b1;

        #1;

        if (
            precision_supported_o !== 1'b0 ||
            exec_ready_o !== 1'b0
        ) begin
            report_error(
                "Unsupported FP32 precision was not blocked"
            );
        end

        repeat (3) begin
            @(posedge clk_i);
            #1;

            if (accumulator_update_o !== 1'b0) begin
                report_error(
                    "Unsupported precision caused an accumulator update"
                );
            end
        end

        @(negedge clk_i);

        exec_valid_i     = 1'b0;
        exec_precision_i = 2'b00;

        // ---------------------------------------------------------------------
        // Register clear removes all source validity.
        // ---------------------------------------------------------------------

        register_clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        if (
            vector_valid_mask_o !== 16'd0 ||
            matrix_valid_mask_o !== 16'd0
        ) begin
            report_error(
                "Register clear did not reset valid masks"
            );
        end

        @(negedge clk_i);
        register_clear_i = 1'b0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_mixed_precision_register_mac_core passed all integration checks."
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d mixed-precision register-core errors detected.",
                error_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
