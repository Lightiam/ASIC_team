`timescale 1ns/1ps
`default_nettype none

module tb_nce_int8_simd8_mac;

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

    logic         vector_clear;
    logic         vector_valid;
    logic [255:0] vector_lhs;
    logic [255:0] vector_rhs;

    logic         expected_ready;
    logic [255:0] expected_accumulator;
    logic         expected_accumulator_valid;
    logic         expected_accumulator_update;

    logic [7:0] expected_lane_invalid;
    logic [7:0] expected_lane_overflow;
    logic [7:0] expected_lane_underflow;
    logic [7:0] expected_lane_inexact;

    logic expected_invalid;
    logic expected_overflow;
    logic expected_underflow;
    logic expected_inexact;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_int8_simd8_mac dut (
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

        forever begin
            #5 clk_i = ~clk_i;
        end
    end

    initial begin
        rst_ni                      = 1'b0;
        clear_i                     = 1'b0;
        in_valid_i                  = 1'b0;
        lhs_i                       = '0;
        rhs_i                       = '0;

        vector_clear                = '0;
        vector_valid                = '0;
        vector_lhs                  = '0;
        vector_rhs                  = '0;

        expected_ready              = '0;
        expected_accumulator        = '0;
        expected_accumulator_valid  = '0;
        expected_accumulator_update = '0;

        expected_lane_invalid       = '0;
        expected_lane_overflow      = '0;
        expected_lane_underflow     = '0;
        expected_lane_inexact       = '0;

        expected_invalid            = '0;
        expected_overflow           = '0;
        expected_underflow          = '0;
        expected_inexact            = '0;

        test_count                  = 0;
        error_count                 = 0;

        repeat (3) begin
            @(posedge clk_i);
        end

        #1;

        if (
            accumulator_o !== 256'd0 ||
            accumulator_valid_o !== 1'b0 ||
            accumulator_update_o !== 1'b0 ||
            lane_invalid_o !== 8'd0 ||
            lane_overflow_o !== 8'd0 ||
            lane_underflow_o !== 8'd0 ||
            lane_inexact_o !== 8'd0 ||
            invalid_o !== 1'b0 ||
            overflow_o !== 1'b0 ||
            underflow_o !== 1'b0 ||
            inexact_o !== 1'b0
        ) begin
            $fatal(
                1,
                "SIMD8 MAC reset state is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/int8_simd8_mac_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open SIMD8 MAC vectors."
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                vector_clear,
                vector_valid,
                vector_lhs,
                vector_rhs,
                expected_ready,
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
                expected_inexact
            );

            if (scan_result == 16) begin
                @(negedge clk_i);

                clear_i    = vector_clear;
                in_valid_i = vector_valid;
                lhs_i      = vector_lhs;
                rhs_i      = vector_rhs;

                #1;

                if (in_ready_o !== expected_ready) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "READY ERROR test=%0d ready=%h/%h",
                            test_count + 1,
                            in_ready_o,
                            expected_ready
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
                    inexact_o !== expected_inexact
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "STATE ERROR test=%0d acc=%064h/%064h valid=%h/%h update=%h/%h lane_flags=%02h,%02h,%02h,%02h/%02h,%02h,%02h,%02h global=%h%h%h%h/%h%h%h%h",
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

        $fclose(vector_file);

        clear_i    = 1'b0;
        in_valid_i = 1'b0;
        lhs_i      = '0;
        rhs_i      = '0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_int8_simd8_mac passed all %0d cycles.",
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
