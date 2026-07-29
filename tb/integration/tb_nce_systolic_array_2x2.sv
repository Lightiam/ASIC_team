`timescale 1ns/1ps
`default_nettype none

module tb_nce_systolic_array_2x2;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic step_i;
    logic ready_o;

    logic [1:0] precision_i;
    logic       precision_supported_o;

    logic [63:0] row_activation_i;
    logic [1:0]  row_activation_valid_i;

    logic [63:0] column_weight_i;
    logic [1:0]  column_weight_valid_i;

    logic [127:0] accumulator_o;
    logic [3:0]   accumulator_valid_o;
    logic [3:0]   accumulator_update_o;

    logic [3:0] mac_fire_mask_o;

    logic [3:0] invalid_o;
    logic [3:0] overflow_o;
    logic [3:0] underflow_o;
    logic [3:0] inexact_o;

    integer check_count;
    integer error_count;
    integer timeout_count;

    integer pe00_update_count;
    integer pe01_update_count;
    integer pe10_update_count;
    integer pe11_update_count;

    logic completed;

    nce_systolic_array_2x2 dut (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .clear_i                  (clear_i),

        .step_i                   (step_i),
        .ready_o                  (ready_o),

        .precision_i              (precision_i),
        .precision_supported_o    (precision_supported_o),

        .row_activation_i         (row_activation_i),
        .row_activation_valid_i   (row_activation_valid_i),

        .column_weight_i          (column_weight_i),
        .column_weight_valid_i    (column_weight_valid_i),

        .accumulator_o            (accumulator_o),
        .accumulator_valid_o      (accumulator_valid_o),
        .accumulator_update_o     (accumulator_update_o),

        .mac_fire_mask_o          (mac_fire_mask_o),

        .invalid_o                (invalid_o),
        .overflow_o               (overflow_o),
        .underflow_o              (underflow_o),
        .inexact_o                (inexact_o)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pe00_update_count <= 0;
            pe01_update_count <= 0;
            pe10_update_count <= 0;
            pe11_update_count <= 0;
        end
        else if (clear_i) begin
            pe00_update_count <= 0;
            pe01_update_count <= 0;
            pe10_update_count <= 0;
            pe11_update_count <= 0;
        end
        else begin
            if (accumulator_update_o[0])
                pe00_update_count <= pe00_update_count + 1;

            if (accumulator_update_o[1])
                pe01_update_count <= pe01_update_count + 1;

            if (accumulator_update_o[2])
                pe10_update_count <= pe10_update_count + 1;

            if (accumulator_update_o[3])
                pe11_update_count <= pe11_update_count + 1;
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

    task automatic drive_wavefront_cycle (
        input logic [31:0] row0_activation,
        input logic        row0_valid,

        input logic [31:0] row1_activation,
        input logic        row1_valid,

        input logic [31:0] column0_weight,
        input logic        column0_valid,

        input logic [31:0] column1_weight,
        input logic        column1_valid,

        input logic [3:0] expected_fire_mask
    );
        begin
            @(negedge clk_i);

            row_activation_i[31:0]  = row0_activation;
            row_activation_i[63:32] = row1_activation;

            row_activation_valid_i[0] = row0_valid;
            row_activation_valid_i[1] = row1_valid;

            column_weight_i[31:0]  = column0_weight;
            column_weight_i[63:32] = column1_weight;

            column_weight_valid_i[0] = column0_valid;
            column_weight_valid_i[1] = column1_valid;

            step_i = 1'b1;

            #1;

            check_condition(
                ready_o === 1'b1,
                "Array was not ready for a native systolic step"
            );

            check_condition(
                mac_fire_mask_o === expected_fire_mask,
                "Diagonal MAC-fire wavefront mismatch"
            );

            if (mac_fire_mask_o !== expected_fire_mask) begin
                $display(
                    "  fire=%b expected=%b",
                    mac_fire_mask_o,
                    expected_fire_mask
                );
            end

            @(posedge clk_i);
            #1;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;
        step_i  = 1'b0;

        precision_i = 2'b00;

        row_activation_i       = 64'd0;
        row_activation_valid_i = 2'b00;

        column_weight_i       = 64'd0;
        column_weight_valid_i = 2'b00;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        check_condition(
            ready_o === 1'b0 &&
            accumulator_valid_o === 4'b0000,
            "Array reset state mismatch"
        );

        @(negedge clk_i);
        rst_ni = 1'b1;

        #1;

        check_condition(
            ready_o === 1'b1 &&
            precision_supported_o === 1'b1,
            "Array did not become ready after reset"
        );

        // Clear all local output-stationary accumulators and link registers.
        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            accumulator_o === 128'd0 &&
            accumulator_valid_o === 4'b0000 &&
            mac_fire_mask_o === 4'b0000,
            "Array clear state mismatch"
        );

        @(negedge clk_i);
        clear_i = 1'b0;

        // ---------------------------------------------------------------------
        // Native skewed injection schedule.
        //
        // Cycle 0:
        //   A00 enters row 0
        //   B00 enters column 0
        //   Only PE00 computes.
        // ---------------------------------------------------------------------

        drive_wavefront_cycle(
            32'h0000_0001, 1'b1,
            32'h0000_0000, 1'b0,

            32'h0000_0005, 1'b1,
            32'h0000_0000, 1'b0,

            4'b0001
        );

        // ---------------------------------------------------------------------
        // Cycle 1:
        //   A01 and B10 enter PE00.
        //   A10 meets forwarded B00 in PE10.
        //   forwarded A00 meets B01 in PE01.
        //
        // Active diagonal: PE00, PE01, PE10.
        // ---------------------------------------------------------------------

        drive_wavefront_cycle(
            32'h0000_0002, 1'b1,
            32'h0000_0003, 1'b1,

            32'h0000_0007, 1'b1,
            32'h0000_0006, 1'b1,

            4'b0111
        );

        // ---------------------------------------------------------------------
        // Cycle 2:
        //   forwarded tokens create activity in PE01, PE10 and PE11.
        // ---------------------------------------------------------------------

        drive_wavefront_cycle(
            32'h0000_0000, 1'b0,
            32'h0000_0004, 1'b1,

            32'h0000_0000, 1'b0,
            32'h0000_0008, 1'b1,

            4'b1110
        );

        // ---------------------------------------------------------------------
        // Cycle 3:
        //   Final A11/B11 pair reaches PE11.
        // ---------------------------------------------------------------------

        drive_wavefront_cycle(
            32'h0000_0000, 1'b0,
            32'h0000_0000, 1'b0,

            32'h0000_0000, 1'b0,
            32'h0000_0000, 1'b0,

            4'b1000
        );

        @(negedge clk_i);

        step_i = 1'b0;

        row_activation_i       = 64'd0;
        row_activation_valid_i = 2'b00;

        column_weight_i       = 64'd0;
        column_weight_valid_i = 2'b00;

        // Wait for the local MAC pipelines to drain.
        completed = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 40 && !completed;
            timeout_count = timeout_count + 1
        ) begin
            @(posedge clk_i);
            #1;

            if (
                pe00_update_count == 2 &&
                pe01_update_count == 2 &&
                pe10_update_count == 2 &&
                pe11_update_count == 2
            ) begin
                completed = 1'b1;
            end
        end

        check_condition(
            completed,
            "Systolic array arithmetic pipelines did not drain"
        );

        check_condition(
            pe00_update_count == 2 &&
            pe01_update_count == 2 &&
            pe10_update_count == 2 &&
            pe11_update_count == 2,
            "Each PE did not perform exactly K=2 MAC operations"
        );

        check_condition(
            accumulator_valid_o === 4'b1111,
            "Not all output-stationary results became valid"
        );

        // C00 = 1*5 + 2*7 = 19
        check_condition(
            accumulator_o[31:0] === 32'h4198_0000,
            "C00 result mismatch"
        );

        // C01 = 1*6 + 2*8 = 22
        check_condition(
            accumulator_o[63:32] === 32'h41B0_0000,
            "C01 result mismatch"
        );

        // C10 = 3*5 + 4*7 = 43
        check_condition(
            accumulator_o[95:64] === 32'h422C_0000,
            "C10 result mismatch"
        );

        // C11 = 3*6 + 4*8 = 50
        check_condition(
            accumulator_o[127:96] === 32'h4248_0000,
            "C11 result mismatch"
        );

        check_condition(
            invalid_o === 4'b0000 &&
            overflow_o === 4'b0000 &&
            underflow_o === 4'b0000 &&
            inexact_o === 4'b0000,
            "Unexpected arithmetic status flags"
        );

        // Native FP32 remains unsupported.
        @(negedge clk_i);

        precision_i = 2'b11;
        step_i      = 1'b0;

        #1;

        check_condition(
            precision_supported_o === 1'b0 &&
            ready_o === 1'b0,
            "Unsupported native FP32 precision was not blocked"
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_systolic_array_2x2 passed all %0d native wavefront and GEMM checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d native systolic-array errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
