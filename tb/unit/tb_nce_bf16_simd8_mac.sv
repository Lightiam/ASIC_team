`timescale 1ns/1ps
`default_nettype none

module tb_nce_bf16_simd8_mac;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic         in_valid_i;
    logic         in_ready_o;
    logic [255:0] lhs_i;
    logic [255:0] rhs_i;

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

    integer vector_file;
    integer scan_count;
    integer clear_value;

    integer vector_count;
    integer operation_count;
    integer error_count;
    integer timeout_count;

    logic [255:0] vector_lhs;
    logic [255:0] vector_rhs;
    logic [255:0] expected_accumulator;

    logic [255:0] directed_lhs;
    logic [255:0] directed_rhs;
    logic [255:0] directed_expected;

    nce_bf16_simd8_mac dut (
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

        .lane_invalid_o       (lane_invalid_o),
        .lane_overflow_o      (lane_overflow_o),
        .lane_underflow_o     (lane_underflow_o),
        .lane_inexact_o       (lane_inexact_o),

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
            lhs_i      = 256'd0;
            rhs_i      = 256'd0;

            @(posedge clk_i);
            #1;

            if (
                accumulator_o !== 256'd0 ||
                accumulator_valid_o !== 1'b0 ||
                accumulator_update_o !== 1'b0 ||
                lane_invalid_o !== 8'd0 ||
                lane_overflow_o !== 8'd0 ||
                lane_underflow_o !== 8'd0 ||
                lane_inexact_o !== 8'd0
            ) begin
                report_error(
                    "SIMD clear-state mismatch"
                );
            end

            @(negedge clk_i);
            clear_i = 1'b0;
        end
    endtask

    task automatic issue_operation (
        input logic [255:0] operation_lhs,
        input logic [255:0] operation_rhs,
        input logic [255:0] expected_result,

        input logic [7:0] expected_lane_invalid,
        input logic [7:0] expected_lane_overflow,
        input logic [7:0] expected_lane_underflow,
        input logic [7:0] expected_lane_inexact
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

            lhs_i      = 256'd0;
            rhs_i      = 256'd0;
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
                            "SIMD accumulator mismatch"
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
                            "SIMD accumulator valid missing"
                        );
                    end

                    if (
                        lane_invalid_o !==
                        expected_lane_invalid ||
                        lane_overflow_o !==
                        expected_lane_overflow ||
                        lane_underflow_o !==
                        expected_lane_underflow ||
                        lane_inexact_o !==
                        expected_lane_inexact
                    ) begin
                        report_error(
                            "SIMD lane flag mismatch"
                        );
                    end

                    if (
                        invalid_o !==
                            (|expected_lane_invalid) ||
                        overflow_o !==
                            (|expected_lane_overflow) ||
                        underflow_o !==
                            (|expected_lane_underflow) ||
                        inexact_o !==
                            (|expected_lane_inexact)
                    ) begin
                        report_error(
                            "SIMD global flag mismatch"
                        );
                    end
                end
            end

            if (!completed) begin
                report_error(
                    "SIMD operation did not complete"
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
        lhs_i      = 256'd0;
        rhs_i      = 256'd0;

        vector_count    = 0;
        operation_count = 0;
        error_count     = 0;

        directed_lhs      = 256'd0;
        directed_rhs      = 256'd0;
        directed_expected = 256'd0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/bf16_simd8_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Unable to open BF16X2 SIMD vector file."
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
                        8'h00,
                        8'h00,
                        8'h00,
                        8'h00
                    );
                end
            end
        end

        $fclose(vector_file);

        // Lane 3: infinity*0 + 1*1 -> invalid.
        apply_clear();

        directed_lhs      = 256'd0;
        directed_rhs      = 256'd0;
        directed_expected = 256'd0;

        directed_lhs[(3 * 32) +: 32] =
            32'h3F80_7F80;

        directed_rhs[(3 * 32) +: 32] =
            32'h3F80_0000;

        directed_expected[(3 * 32) +: 32] =
            32'h7FC0_0000;

        issue_operation(
            directed_lhs,
            directed_rhs,
            directed_expected,
            8'h08,
            8'h00,
            8'h00,
            8'h00
        );

        // Lane 5: largest finite squared -> overflow and inexact.
        apply_clear();

        directed_lhs      = 256'd0;
        directed_rhs      = 256'd0;
        directed_expected = 256'd0;

        directed_lhs[(5 * 32) +: 32] =
            32'h0000_7F7F;

        directed_rhs[(5 * 32) +: 32] =
            32'h0000_7F7F;

        directed_expected[(5 * 32) +: 32] =
            32'h7F80_0000;

        issue_operation(
            directed_lhs,
            directed_rhs,
            directed_expected,
            8'h00,
            8'h20,
            8'h00,
            8'h20
        );

        // Lane 2: smallest subnormal squared -> underflow and inexact.
        apply_clear();

        directed_lhs      = 256'd0;
        directed_rhs      = 256'd0;
        directed_expected = 256'd0;

        directed_lhs[(2 * 32) +: 32] =
            32'h0000_0001;

        directed_rhs[(2 * 32) +: 32] =
            32'h0000_0001;

        issue_operation(
            directed_lhs,
            directed_rhs,
            directed_expected,
            8'h00,
            8'h00,
            8'h04,
            8'h04
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_bf16_simd8_mac passed %0d vectors and %0d BF16X2 operations.",
                vector_count,
                operation_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d BF16X2 SIMD errors detected.",
                error_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
