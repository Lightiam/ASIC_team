`timescale 1ns/1ps
`default_nettype none

module tb_nce_systolic_array_4x4;

    localparam integer ARRAY_SIZE = 4;
    localparam integer K_COUNT    = 4;
    localparam integer PE_COUNT   = 16;

    // Final arithmetic wave reaches:
    //
    //   cycle = (K - 1) + (row 3) + (column 3) = 9
    localparam integer LAST_WAVEFRONT_CYCLE = 9;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic step_i;
    logic ready_o;

    logic [1:0] precision_i;
    logic       precision_supported_o;

    logic [127:0] row_activation_i;
    logic [3:0]   row_activation_valid_i;

    logic [127:0] column_weight_i;
    logic [3:0]   column_weight_valid_i;

    logic [511:0] accumulator_o;

    logic [15:0] accumulator_valid_o;
    logic [15:0] accumulator_update_o;
    logic [15:0] mac_fire_mask_o;

    logic [15:0] invalid_o;
    logic [15:0] overflow_o;
    logic [15:0] underflow_o;
    logic [15:0] inexact_o;

    integer check_count;
    integer error_count;
    integer timeout_count;

    integer fire_count [0:PE_COUNT-1];
    integer update_count [0:PE_COUNT-1];

    integer pe_index;
    integer row_index;
    integer column_index;
    integer k_index;

    logic completed;

    nce_systolic_array_4x4 dut (
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

    // -------------------------------------------------------------------------
    // Test matrices
    // -------------------------------------------------------------------------

    function automatic integer matrix_a (
        input integer row,
        input integer k
    );
        begin
            case ((row * 4) + k)
                 0: matrix_a = 1;
                 1: matrix_a = 2;
                 2: matrix_a = 3;
                 3: matrix_a = 4;

                 4: matrix_a = 5;
                 5: matrix_a = 6;
                 6: matrix_a = 7;
                 7: matrix_a = 8;

                 8: matrix_a = 9;
                 9: matrix_a = 10;
                10: matrix_a = 11;
                11: matrix_a = 12;

                12: matrix_a = 13;
                13: matrix_a = 14;
                14: matrix_a = 15;
                15: matrix_a = 16;

                default: matrix_a = 0;
            endcase
        end
    endfunction

    function automatic integer matrix_b (
        input integer k,
        input integer column
    );
        begin
            case ((k * 4) + column)
                 0: matrix_b = 1;
                 1: matrix_b = 0;
                 2: matrix_b = 2;
                 3: matrix_b = 1;

                 4: matrix_b = 0;
                 5: matrix_b = 1;
                 6: matrix_b = 1;
                 7: matrix_b = 2;

                 8: matrix_b = 1;
                 9: matrix_b = 1;
                10: matrix_b = 0;
                11: matrix_b = 1;

                12: matrix_b = 2;
                13: matrix_b = 1;
                14: matrix_b = 1;
                15: matrix_b = 0;

                default: matrix_b = 0;
            endcase
        end
    endfunction

    function automatic logic [31:0] expected_fp32 (
        input integer index
    );
        begin
            case (index)
                 0: expected_fp32 = 32'h4140_0000; // 12
                 1: expected_fp32 = 32'h4110_0000; // 9
                 2: expected_fp32 = 32'h4100_0000; // 8
                 3: expected_fp32 = 32'h4100_0000; // 8

                 4: expected_fp32 = 32'h41E0_0000; // 28
                 5: expected_fp32 = 32'h41A8_0000; // 21
                 6: expected_fp32 = 32'h41C0_0000; // 24
                 7: expected_fp32 = 32'h41C0_0000; // 24

                 8: expected_fp32 = 32'h4230_0000; // 44
                 9: expected_fp32 = 32'h4204_0000; // 33
                10: expected_fp32 = 32'h4220_0000; // 40
                11: expected_fp32 = 32'h4220_0000; // 40

                12: expected_fp32 = 32'h4270_0000; // 60
                13: expected_fp32 = 32'h4234_0000; // 45
                14: expected_fp32 = 32'h4260_0000; // 56
                15: expected_fp32 = 32'h4260_0000; // 56

                default: expected_fp32 = 32'h0000_0000;
            endcase
        end
    endfunction

    function automatic logic [15:0] expected_fire_mask (
        input integer cycle_number
    );

        integer row;
        integer column;
        integer k;
        logic [15:0] mask;

        begin
            mask = 16'd0;

            for (
                row = 0;
                row < ARRAY_SIZE;
                row = row + 1
            ) begin
                for (
                    column = 0;
                    column < ARRAY_SIZE;
                    column = column + 1
                ) begin
                    for (
                        k = 0;
                        k < K_COUNT;
                        k = k + 1
                    ) begin
                        if (
                            cycle_number ==
                            (k + row + column)
                        ) begin
                            mask[
                                (row * ARRAY_SIZE) +
                                column
                            ] = 1'b1;
                        end
                    end
                end
            end

            expected_fire_mask = mask;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Monitoring and utility tasks
    // -------------------------------------------------------------------------

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (
                pe_index = 0;
                pe_index < PE_COUNT;
                pe_index = pe_index + 1
            ) begin
                fire_count[pe_index]   <= 0;
                update_count[pe_index] <= 0;
            end
        end
        else if (clear_i) begin
            for (
                pe_index = 0;
                pe_index < PE_COUNT;
                pe_index = pe_index + 1
            ) begin
                fire_count[pe_index]   <= 0;
                update_count[pe_index] <= 0;
            end
        end
        else begin
            for (
                pe_index = 0;
                pe_index < PE_COUNT;
                pe_index = pe_index + 1
            ) begin
                if (mac_fire_mask_o[pe_index]) begin
                    fire_count[pe_index] <=
                        fire_count[pe_index] + 1;
                end

                if (accumulator_update_o[pe_index]) begin
                    update_count[pe_index] <=
                        update_count[pe_index] + 1;
                end
            end
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
        input integer cycle_number
    );

        integer row;
        integer column;
        integer selected_k;

        logic [15:0] expected_mask;

        begin
            @(negedge clk_i);

            row_activation_i       = 128'd0;
            row_activation_valid_i = 4'b0000;

            column_weight_i       = 128'd0;
            column_weight_valid_i = 4'b0000;

            // A[row][k] enters row 'row' at cycle k + row.
            for (
                row = 0;
                row < ARRAY_SIZE;
                row = row + 1
            ) begin
                selected_k =
                    cycle_number -
                    row;

                if (
                    selected_k >= 0 &&
                    selected_k < K_COUNT
                ) begin
                    row_activation_i[
                        (row * 32) +: 32
                    ] = matrix_a(
                        row,
                        selected_k
                    );

                    row_activation_valid_i[row] =
                        1'b1;
                end
            end

            // B[k][column] enters column 'column' at cycle k + column.
            for (
                column = 0;
                column < ARRAY_SIZE;
                column = column + 1
            ) begin
                selected_k =
                    cycle_number -
                    column;

                if (
                    selected_k >= 0 &&
                    selected_k < K_COUNT
                ) begin
                    column_weight_i[
                        (column * 32) +: 32
                    ] = matrix_b(
                        selected_k,
                        column
                    );

                    column_weight_valid_i[column] =
                        1'b1;
                end
            end

            step_i = 1'b1;

            expected_mask =
                expected_fire_mask(
                    cycle_number
                );

            #1;

            check_condition(
                ready_o === 1'b1,
                "4x4 array was not ready"
            );

            check_condition(
                mac_fire_mask_o === expected_mask,
                "4x4 diagonal wavefront mismatch"
            );

            if (mac_fire_mask_o !== expected_mask) begin
                $display(
                    "  cycle=%0d fire=%04h expected=%04h",
                    cycle_number,
                    mac_fire_mask_o,
                    expected_mask
                );
            end

            @(posedge clk_i);
            #1;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        step_i      = 1'b0;
        precision_i = 2'b00;

        row_activation_i       = 128'd0;
        row_activation_valid_i = 4'b0000;

        column_weight_i       = 128'd0;
        column_weight_valid_i = 4'b0000;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        check_condition(
            ready_o === 1'b0 &&
            accumulator_valid_o === 16'h0000,
            "4x4 array reset state mismatch"
        );

        @(negedge clk_i);
        rst_ni = 1'b1;

        #1;

        check_condition(
            ready_o === 1'b1 &&
            precision_supported_o === 1'b1,
            "4x4 array did not become ready"
        );

        // Clear all PEs and all physical forwarding links.
        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            accumulator_o === 512'd0 &&
            accumulator_valid_o === 16'h0000 &&
            mac_fire_mask_o === 16'h0000,
            "4x4 array clear-state mismatch"
        );

        @(negedge clk_i);
        clear_i = 1'b0;

        // Drive all ten active/fill/drain wavefront cycles.
        for (
            k_index = 0;
            k_index <= LAST_WAVEFRONT_CYCLE;
            k_index = k_index + 1
        ) begin
            drive_wavefront_cycle(
                k_index
            );
        end

        @(negedge clk_i);

        step_i = 1'b0;

        row_activation_i       = 128'd0;
        row_activation_valid_i = 4'b0000;

        column_weight_i       = 128'd0;
        column_weight_valid_i = 4'b0000;

        // Wait for every PE's local arithmetic pipeline to drain.
        completed = 1'b0;

        for (
            timeout_count = 0;
            timeout_count < 80 && !completed;
            timeout_count = timeout_count + 1
        ) begin
            @(posedge clk_i);
            #1;

            completed = 1'b1;

            for (
                pe_index = 0;
                pe_index < PE_COUNT;
                pe_index = pe_index + 1
            ) begin
                if (
                    update_count[pe_index] !=
                    K_COUNT
                ) begin
                    completed = 1'b0;
                end
            end
        end

        check_condition(
            completed,
            "4x4 arithmetic pipelines did not drain"
        );

        for (
            pe_index = 0;
            pe_index < PE_COUNT;
            pe_index = pe_index + 1
        ) begin
            check_condition(
                fire_count[pe_index] === K_COUNT,
                "PE did not receive exactly four wavefront tokens"
            );

            check_condition(
                update_count[pe_index] === K_COUNT,
                "PE did not complete exactly four MAC updates"
            );

            check_condition(
                accumulator_valid_o[pe_index] === 1'b1,
                "PE accumulator did not become valid"
            );

            check_condition(
                accumulator_o[
                    (pe_index * 32) +: 32
                ] === expected_fp32(pe_index),
                "4x4 GEMM output mismatch"
            );

            if (
                accumulator_o[
                    (pe_index * 32) +: 32
                ] !== expected_fp32(pe_index)
            ) begin
                $display(
                    "  PE=%0d result=%08h expected=%08h",
                    pe_index,
                    accumulator_o[
                        (pe_index * 32) +: 32
                    ],
                    expected_fp32(pe_index)
                );
            end
        end

        check_condition(
            invalid_o === 16'h0000 &&
            overflow_o === 16'h0000 &&
            underflow_o === 16'h0000 &&
            inexact_o === 16'h0000,
            "Unexpected 4x4 arithmetic flags"
        );

        // Native FP32 remains unsupported.
        @(negedge clk_i);

        precision_i = 2'b11;
        step_i      = 1'b0;

        #1;

        check_condition(
            precision_supported_o === 1'b0 &&
            ready_o === 1'b0,
            "Unsupported FP32 precision was not blocked"
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_systolic_array_4x4 passed all %0d native wavefront and GEMM checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d native 4x4 systolic errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
