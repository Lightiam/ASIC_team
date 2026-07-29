`timescale 1ns/1ps
`default_nettype none

module tb_nce_mixed_precision_mac_lane;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic        in_valid_i;
    logic        in_ready_o;

    logic [1:0]  precision_i;
    logic [31:0] lhs_i;
    logic [31:0] rhs_i;

    logic precision_supported_o;

    logic [31:0] accumulator_o;
    logic        accumulator_valid_o;
    logic        accumulator_update_o;

    logic invalid_o;
    logic overflow_o;
    logic underflow_o;
    logic inexact_o;

    integer vector_file;
    integer scan_count;

    integer clear_value;
    integer expected_invalid;
    integer expected_overflow;
    integer expected_underflow;
    integer expected_inexact;

    integer vector_count;
    integer operation_count;
    integer error_count;
    integer timeout_count;

    logic [1:0]  vector_precision;
    logic [31:0] vector_lhs;
    logic [31:0] vector_rhs;
    logic [31:0] expected_accumulator;

    nce_mixed_precision_mac_lane dut (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .clear_i                (clear_i),

        .in_valid_i             (in_valid_i),
        .in_ready_o             (in_ready_o),

        .precision_i            (precision_i),
        .lhs_i                  (lhs_i),
        .rhs_i                  (rhs_i),

        .precision_supported_o  (precision_supported_o),

        .accumulator_o          (accumulator_o),
        .accumulator_valid_o    (accumulator_valid_o),
        .accumulator_update_o   (accumulator_update_o),

        .invalid_o              (invalid_o),
        .overflow_o             (overflow_o),
        .underflow_o            (underflow_o),
        .inexact_o              (inexact_o)
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
                    "ERROR vector=%0d operation=%0d: %s",
                    vector_count,
                    operation_count,
                    message
                );
            end
        end
    endtask

    task automatic apply_clear;
        begin
            @(negedge clk_i);

            clear_i     = 1'b1;
            in_valid_i  = 1'b0;
            precision_i = 2'b00;
            lhs_i       = 32'd0;
            rhs_i       = 32'd0;

            @(posedge clk_i);
            #1;

            if (
                accumulator_o !== 32'd0 ||
                accumulator_valid_o !== 1'b0 ||
                accumulator_update_o !== 1'b0 ||
                invalid_o !== 1'b0 ||
                overflow_o !== 1'b0 ||
                underflow_o !== 1'b0 ||
                inexact_o !== 1'b0
            ) begin
                report_error(
                    "Clear-state mismatch"
                );
            end

            @(negedge clk_i);
            clear_i = 1'b0;
        end
    endtask

    task automatic issue_operation (
        input logic [1:0]  operation_precision,
        input logic [31:0] operation_lhs,
        input logic [31:0] operation_rhs,
        input logic [31:0] expected_result,

        input logic expected_invalid_flag,
        input logic expected_overflow_flag,
        input logic expected_underflow_flag,
        input logic expected_inexact_flag
    );

        logic completed;

        begin
            completed = 1'b0;

            precision_i = operation_precision;

            while (in_ready_o !== 1'b1) begin
                @(negedge clk_i);
            end

            @(negedge clk_i);

            precision_i = operation_precision;
            lhs_i       = operation_lhs;
            rhs_i       = operation_rhs;
            in_valid_i  = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            in_valid_i = 1'b0;
            lhs_i      = 32'd0;
            rhs_i      = 32'd0;

            for (
                timeout_count = 0;
                timeout_count < 12;
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
                                "  precision=%b lhs=%08h rhs=%08h",
                                operation_precision,
                                operation_lhs,
                                operation_rhs
                            );

                            $display(
                                "  result=%08h expected=%08h",
                                accumulator_o,
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
                        invalid_o !==
                            expected_invalid_flag ||
                        overflow_o !==
                            expected_overflow_flag ||
                        underflow_o !==
                            expected_underflow_flag ||
                        inexact_o !==
                            expected_inexact_flag
                    ) begin
                        report_error(
                            "Exception flag mismatch"
                        );

                        if (error_count <= 20) begin
                            $display(
                                "  flags=%b%b%b%b expected=%b%b%b%b",
                                invalid_o,
                                overflow_o,
                                underflow_o,
                                inexact_o,
                                expected_invalid_flag,
                                expected_overflow_flag,
                                expected_underflow_flag,
                                expected_inexact_flag
                            );
                        end
                    end
                end
            end

            if (!completed) begin
                report_error(
                    "Operation did not complete"
                );
            end

            operation_count =
                operation_count + 1;
        end
    endtask

    initial begin
        rst_ni      = 1'b0;
        clear_i     = 1'b0;
        in_valid_i  = 1'b0;
        precision_i = 2'b00;
        lhs_i       = 32'd0;
        rhs_i       = 32'd0;

        vector_count    = 0;
        operation_count = 0;
        error_count     = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        if (
            in_ready_o !== 1'b0 ||
            accumulator_valid_o !== 1'b0
        ) begin
            $fatal(
                1,
                "Mixed-precision lane reset state is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/mixed_precision_mac_lane_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Unable to open mixed-precision vector file."
            );
        end

        while (!$feof(vector_file)) begin
            scan_count = $fscanf(
                vector_file,
                "%d %h %h %h %h %d %d %d %d\n",
                clear_value,
                vector_precision,
                vector_lhs,
                vector_rhs,
                expected_accumulator,
                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact
            );

            if (scan_count == 9) begin
                vector_count =
                    vector_count + 1;

                if (clear_value != 0) begin
                    apply_clear();
                end
                else begin
                    issue_operation(
                        vector_precision,
                        vector_lhs,
                        vector_rhs,
                        expected_accumulator,
                        expected_invalid[0],
                        expected_overflow[0],
                        expected_underflow[0],
                        expected_inexact[0]
                    );
                end
            end
        end

        $fclose(vector_file);

        // Unsupported FP32 precision must not be accepted.
        apply_clear();

        @(negedge clk_i);

        precision_i = 2'b11;
        lhs_i       = 32'h1234_5678;
        rhs_i       = 32'h8765_4321;
        in_valid_i  = 1'b1;

        repeat (3) begin
            @(posedge clk_i);
            #1;

            if (
                precision_supported_o !== 1'b0 ||
                in_ready_o !== 1'b0 ||
                accumulator_update_o !== 1'b0
            ) begin
                report_error(
                    "Unsupported FP32 precision was not blocked"
                );
            end
        end

        @(negedge clk_i);

        in_valid_i  = 1'b0;
        precision_i = 2'b00;
        lhs_i       = 32'd0;
        rhs_i       = 32'd0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_mixed_precision_mac_lane passed %0d vectors and %0d operations.",
                vector_count,
                operation_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d mixed-precision MAC errors detected.",
                error_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
