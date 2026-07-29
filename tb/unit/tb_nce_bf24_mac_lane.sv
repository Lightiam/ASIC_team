`timescale 1ns/1ps
`default_nettype none

module tb_nce_bf24_mac_lane;

    logic clk_i;
    logic rst_ni;

    logic clear_i;

    logic in_valid_i;
    logic in_ready_o;

    logic [31:0] lhs_i;
    logic [31:0] rhs_i;

    logic [31:0] accumulator_o;
    logic accumulator_valid_o;
    logic accumulator_update_o;

    logic invalid_o;
    logic overflow_o;
    logic underflow_o;
    logic inexact_o;

    integer vector_file;
    integer scan_count;

    integer vector_count;
    integer operation_count;
    integer error_count;
    integer timeout_count;

    integer clear_vector;

    logic [31:0] expected_accumulator;

    integer expected_invalid;
    integer expected_overflow;
    integer expected_underflow;
    integer expected_inexact;

    nce_bf24_mac_lane dut (
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

            in_valid_i = 1'b0;
            clear_i    = 1'b1;

            @(posedge clk_i);
            #1;

            if (
                accumulator_o !== 32'h0000_0000 ||
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

    task automatic apply_operation;
        logic completed;
        begin
            completed = 1'b0;

            while (in_ready_o !== 1'b1) begin
                @(negedge clk_i);
            end

            @(negedge clk_i);
            in_valid_i = 1'b1;

            @(posedge clk_i);
            #1;

            if (in_ready_o !== 1'b1) begin
                report_error(
                    "Operation was not accepted"
                );
            end

            @(negedge clk_i);
            in_valid_i = 1'b0;

            for (
                timeout_count = 0;
                timeout_count < 10;
                timeout_count = timeout_count + 1
            ) begin
                @(posedge clk_i);
                #1;

                if (
                    accumulator_update_o &&
                    !completed
                ) begin
                    completed = 1'b1;
                    operation_count = operation_count + 1;

                    if (
                        accumulator_o !==
                        expected_accumulator
                    ) begin
                        report_error(
                            "Accumulator result mismatch"
                        );

                        if (error_count <= 20) begin
                            $display(
                                "  lhs=%08h rhs=%08h",
                                lhs_i,
                                rhs_i
                            );

                            $display(
                                "  result=%08h expected=%08h",
                                accumulator_o,
                                expected_accumulator
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
                        invalid_o !== expected_invalid[0] ||
                        overflow_o !== expected_overflow[0] ||
                        underflow_o !== expected_underflow[0] ||
                        inexact_o !== expected_inexact[0]
                    ) begin
                        report_error(
                            "Arithmetic status mismatch"
                        );

                        if (error_count <= 20) begin
                            $display(
                                "  flags=%b%b%b%b expected=%0d%0d%0d%0d",
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
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        clear_i    = 1'b0;
        in_valid_i = 1'b0;

        lhs_i = 32'h0000_0000;
        rhs_i = 32'h0000_0000;

        expected_accumulator = 32'h0000_0000;

        expected_invalid   = 0;
        expected_overflow  = 0;
        expected_underflow = 0;
        expected_inexact   = 0;

        vector_count    = 0;
        operation_count = 0;
        error_count     = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/bf24_mac_lane_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Unable to open BF24 MAC vector file"
            );
        end

        while (!$feof(vector_file)) begin
            scan_count = $fscanf(
                vector_file,
                "%d %h %h %h %d %d %d %d\n",
                clear_vector,
                lhs_i,
                rhs_i,
                expected_accumulator,
                expected_invalid,
                expected_overflow,
                expected_underflow,
                expected_inexact
            );

            if (scan_count == 8) begin
                vector_count = vector_count + 1;

                if (clear_vector != 0) begin
                    apply_clear();
                end
                else begin
                    apply_operation();
                end
            end
            else if (scan_count != -1) begin
                $fatal(
                    1,
                    "Malformed vector file near vector %0d",
                    vector_count
                );
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_bf24_mac_lane passed %0d vectors and %0d operations.",
                vector_count,
                operation_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d BF24 MAC-lane errors in %0d vectors.",
                error_count,
                vector_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
