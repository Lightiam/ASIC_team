`timescale 1ns/1ps
`default_nettype none

module tb_nce_bf16_dot2_mac_lane;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic        in_valid_i;
    logic        in_ready_o;
    logic [31:0] lhs_i;
    logic [31:0] rhs_i;

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

    integer vector_count;
    integer operation_count;
    integer error_count;
    integer timeout_count;

    logic [31:0] vector_lhs;
    logic [31:0] vector_rhs;
    logic [31:0] expected_accumulator;

    nce_bf16_dot2_mac_lane dut (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),

        .clear_i              (clear_i),

        .in_valid_i           (in_valid_i),
        .in_ready_o           (in_ready_o),

        .lhs_i                (lhs_i),
        .rhs_i                (rhs_i),

        .accumulator_o        (accumulator_o),
        .accumulator_valid_o  (accumulator_valid_o),
        .accumulator_update_o (accumulator_update_o),

        .invalid_o            (invalid_o),
        .overflow_o           (overflow_o),
        .underflow_o          (underflow_o),
        .inexact_o            (inexact_o)
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

            clear_i    = 1'b1;
            in_valid_i = 1'b0;
            lhs_i      = 32'd0;
            rhs_i      = 32'd0;

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
        input logic [31:0] operation_lhs,
        input logic [31:0] operation_rhs,
        input logic [31:0] expected_result,

        input logic expected_invalid,
        input logic expected_overflow,
        input logic expected_underflow,
        input logic expected_inexact
    );

        logic completed;

        begin
            completed = 1'b0;

            while (in_ready_o !== 1'b1) begin
                @(negedge clk_i);
            end

            @(negedge clk_i);

            lhs_i      = operation_lhs;
            rhs_i      = operation_rhs;
            in_valid_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            lhs_i      = 32'd0;
            rhs_i      = 32'd0;
            in_valid_i = 1'b0;

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
                                "  lhs=%08h rhs=%08h result=%08h expected=%08h",
                                operation_lhs,
                                operation_rhs,
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
                        invalid_o !== expected_invalid ||
                        overflow_o !== expected_overflow ||
                        underflow_o !== expected_underflow ||
                        inexact_o !== expected_inexact
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
                                expected_invalid,
                                expected_overflow,
                                expected_underflow,
                                expected_inexact
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
        rst_ni     = 1'b0;
        clear_i    = 1'b0;
        in_valid_i = 1'b0;
        lhs_i      = 32'd0;
        rhs_i      = 32'd0;

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
                "BF16X2 DOT2 lane reset state is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/bf16_dot2_mac_lane_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Unable to open BF16X2 DOT2 vector file."
            );
        end

        while (!$feof(vector_file)) begin
            scan_count = $fscanf(
                vector_file,
                "%d %h %h %h\n",
                clear_value,
                vector_lhs,
                vector_rhs,
                expected_accumulator
            );

            if (scan_count == 4) begin
                vector_count =
                    vector_count + 1;

                if (clear_value != 0) begin
                    apply_clear();
                end
                else begin
                    issue_operation(
                        vector_lhs,
                        vector_rhs,
                        expected_accumulator,
                        1'b0,
                        1'b0,
                        1'b0,
                        1'b0
                    );
                end
            end
        end

        $fclose(vector_file);

        // 1*2 + 3*4 = 14.0
        apply_clear();

        issue_operation(
            32'h4040_3F80,
            32'h4080_4000,
            32'h4160_0000,
            1'b0,
            1'b0,
            1'b0,
            1'b0
        );

        // 1*2 + (-1)*2 = 0.0
        apply_clear();

        issue_operation(
            32'hBF80_3F80,
            32'h4000_4000,
            32'h0000_0000,
            1'b0,
            1'b0,
            1'b0,
            1'b0
        );

        // Infinity*0 + 1*1 -> NaN and invalid.
        apply_clear();

        issue_operation(
            32'h3F80_7F80,
            32'h3F80_0000,
            32'h7FC0_0000,
            1'b1,
            1'b0,
            1'b0,
            1'b0
        );

        // Largest finite squared + zero -> infinity.
        apply_clear();

        issue_operation(
            32'h0000_7F7F,
            32'h0000_7F7F,
            32'h7F80_0000,
            1'b0,
            1'b1,
            1'b0,
            1'b1
        );

        // Smallest BF16 subnormal squared + zero -> rounded zero.
        apply_clear();

        issue_operation(
            32'h0000_0001,
            32'h0000_0001,
            32'h0000_0000,
            1'b0,
            1'b0,
            1'b1,
            1'b1
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_bf16_dot2_mac_lane passed %0d vectors and %0d completed operations.",
                vector_count,
                operation_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d BF16X2 DOT2 lane errors detected.",
                error_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
