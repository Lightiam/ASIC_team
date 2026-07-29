`timescale 1ns/1ps
`default_nettype none

module tb_nce_systolic_gemm_4x4;

    localparam integer PE_COUNT = 16;

    localparam logic [2:0] ERROR_INVALID_PRECISION = 3'd1;
    localparam logic [2:0] ERROR_INVALID_K         = 3'd2;
    localparam logic [2:0] ERROR_A_TILE_INVALID    = 3'd3;
    localparam logic [2:0] ERROR_B_TILE_INVALID    = 3'd4;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic        a_write_enable_i;
    logic [3:0]  a_write_addr_i;
    logic [31:0] a_write_data_i;

    logic        b_write_enable_i;
    logic [3:0]  b_write_addr_i;
    logic [31:0] b_write_data_i;

    logic [15:0] a_valid_mask_o;
    logic [15:0] b_valid_mask_o;

    logic       start_i;
    logic       start_ready_o;
    logic [1:0] precision_i;
    logic [2:0] k_count_i;

    logic       busy_o;
    logic       done_o;
    logic       error_o;
    logic [2:0] error_code_o;

    logic [3:0] wavefront_cycle_o;

    logic [511:0] accumulator_o;
    logic [15:0]  accumulator_valid_o;
    logic [15:0]  accumulator_update_o;
    logic [15:0]  mac_fire_mask_o;

    logic [15:0] invalid_o;
    logic [15:0] overflow_o;
    logic [15:0] underflow_o;
    logic [15:0] inexact_o;

    integer check_count;
    integer error_count;
    integer timeout_count;
    integer index;

    logic operation_finished;

    nce_systolic_gemm_4x4 dut (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .clear_i                  (clear_i),

        .a_write_enable_i         (a_write_enable_i),
        .a_write_addr_i           (a_write_addr_i),
        .a_write_data_i           (a_write_data_i),

        .b_write_enable_i         (b_write_enable_i),
        .b_write_addr_i           (b_write_addr_i),
        .b_write_data_i           (b_write_data_i),

        .a_valid_mask_o           (a_valid_mask_o),
        .b_valid_mask_o           (b_valid_mask_o),

        .start_i                  (start_i),
        .start_ready_o            (start_ready_o),

        .precision_i              (precision_i),
        .k_count_i                (k_count_i),
        .accumulate_i             (1'b0),

        .busy_o                   (busy_o),
        .done_o                   (done_o),
        .error_o                  (error_o),
        .error_code_o             (error_code_o),

        .wavefront_cycle_o        (wavefront_cycle_o),

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

    task automatic clear_engine;
        begin
            @(negedge clk_i);

            clear_i = 1'b1;
            start_i = 1'b0;

            a_write_enable_i = 1'b0;
            b_write_enable_i = 1'b0;

            @(posedge clk_i);
            #1;

            check_condition(
                busy_o === 1'b0 &&
                a_valid_mask_o === 16'h0000 &&
                b_valid_mask_o === 16'h0000 &&
                accumulator_valid_o === 16'h0000,
                "Engine clear state mismatch"
            );

            @(negedge clk_i);
            clear_i = 1'b0;
        end
    endtask

    task automatic write_a (
        input logic [3:0]  address,
        input logic [31:0] data
    );
        begin
            @(negedge clk_i);

            a_write_enable_i = 1'b1;
            a_write_addr_i   = address;
            a_write_data_i   = data;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            a_write_enable_i = 1'b0;
            a_write_data_i   = 32'd0;
        end
    endtask

    task automatic write_b (
        input logic [3:0]  address,
        input logic [31:0] data
    );
        begin
            @(negedge clk_i);

            b_write_enable_i = 1'b1;
            b_write_addr_i   = address;
            b_write_data_i   = data;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            b_write_enable_i = 1'b0;
            b_write_data_i   = 32'd0;
        end
    endtask

    task automatic request_start (
        input logic [1:0] precision,
        input logic [2:0] k_count
    );
        begin
            @(negedge clk_i);

            precision_i = precision;
            k_count_i   = k_count;
            start_i     = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        begin
            operation_finished = 1'b0;

            for (
                timeout_count = 0;
                timeout_count < 150 &&
                !operation_finished;
                timeout_count = timeout_count + 1
            ) begin
                @(posedge clk_i);
                #1;

                if (error_o) begin
                    check_condition(
                        1'b0,
                        "Valid GEMM operation reported an error"
                    );

                    operation_finished = 1'b1;
                end
                else if (done_o) begin
                    operation_finished = 1'b1;
                end
            end

            check_condition(
                operation_finished,
                "Autonomous GEMM operation timed out"
            );

            check_condition(
                busy_o === 1'b0,
                "GEMM remained busy after completion"
            );

            check_condition(
                accumulator_valid_o === 16'hFFFF,
                "Not all GEMM outputs became valid"
            );

            check_condition(
                invalid_o === 16'h0000 &&
                overflow_o === 16'h0000 &&
                underflow_o === 16'h0000 &&
                inexact_o === 16'h0000,
                "Unexpected GEMM arithmetic flags"
            );
        end
    endtask

    function automatic logic [31:0] expected_int8 (
        input integer pe
    );
        begin
            case (pe)
                 0: expected_int8 = 32'h4140_0000; // 12
                 1: expected_int8 = 32'h4110_0000; // 9
                 2: expected_int8 = 32'h4100_0000; // 8
                 3: expected_int8 = 32'h4100_0000; // 8

                 4: expected_int8 = 32'h41E0_0000; // 28
                 5: expected_int8 = 32'h41A8_0000; // 21
                 6: expected_int8 = 32'h41C0_0000; // 24
                 7: expected_int8 = 32'h41C0_0000; // 24

                 8: expected_int8 = 32'h4230_0000; // 44
                 9: expected_int8 = 32'h4204_0000; // 33
                10: expected_int8 = 32'h4220_0000; // 40
                11: expected_int8 = 32'h4220_0000; // 40

                12: expected_int8 = 32'h4270_0000; // 60
                13: expected_int8 = 32'h4234_0000; // 45
                14: expected_int8 = 32'h4260_0000; // 56
                15: expected_int8 = 32'h4260_0000; // 56

                default: expected_int8 = 32'd0;
            endcase
        end
    endfunction

    function automatic integer matrix_a_int8 (
        input integer address
    );
        begin
            matrix_a_int8 = address + 1;
        end
    endfunction

    function automatic integer matrix_b_int8 (
        input integer address
    );
        begin
            case (address)
                 0: matrix_b_int8 = 1;
                 1: matrix_b_int8 = 0;
                 2: matrix_b_int8 = 2;
                 3: matrix_b_int8 = 1;

                 4: matrix_b_int8 = 0;
                 5: matrix_b_int8 = 1;
                 6: matrix_b_int8 = 1;
                 7: matrix_b_int8 = 2;

                 8: matrix_b_int8 = 1;
                 9: matrix_b_int8 = 1;
                10: matrix_b_int8 = 0;
                11: matrix_b_int8 = 1;

                12: matrix_b_int8 = 2;
                13: matrix_b_int8 = 1;
                14: matrix_b_int8 = 1;
                15: matrix_b_int8 = 0;

                default: matrix_b_int8 = 0;
            endcase
        end
    endfunction

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        a_write_enable_i = 1'b0;
        a_write_addr_i   = 4'd0;
        a_write_data_i   = 32'd0;

        b_write_enable_i = 1'b0;
        b_write_addr_i   = 4'd0;
        b_write_data_i   = 32'd0;

        start_i    = 1'b0;
        precision_i = 2'b00;
        k_count_i   = 3'd0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        #1;

        check_condition(
            start_ready_o === 1'b0 &&
            busy_o === 1'b0,
            "Reset state mismatch"
        );

        @(negedge clk_i);
        rst_ni = 1'b1;

        #1;

        check_condition(
            start_ready_o === 1'b1,
            "Engine did not become ready"
        );

        // ---------------------------------------------------------------------
        // Configuration-error checks
        // ---------------------------------------------------------------------

        request_start(
            2'b11,
            3'd4
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_PRECISION,
            "Unsupported precision was not rejected"
        );

        request_start(
            2'b00,
            3'd0
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_INVALID_K,
            "Invalid K count was not rejected"
        );

        request_start(
            2'b00,
            3'd4
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_A_TILE_INVALID,
            "Missing A tile was not rejected"
        );

        // Write A only.
        for (index = 0; index < 16; index = index + 1) begin
            write_a(
                index[3:0],
                matrix_a_int8(index)
            );
        end

        request_start(
            2'b00,
            3'd4
        );

        check_condition(
            error_o === 1'b1 &&
            error_code_o === ERROR_B_TILE_INVALID,
            "Missing B tile was not rejected"
        );

        // ---------------------------------------------------------------------
        // INT8X4 native 4x4 GEMM
        // ---------------------------------------------------------------------

        for (index = 0; index < 16; index = index + 1) begin
            write_b(
                index[3:0],
                matrix_b_int8(index)
            );
        end

        check_condition(
            a_valid_mask_o === 16'hFFFF &&
            b_valid_mask_o === 16'hFFFF,
            "INT8 tile validity mismatch"
        );

        request_start(
            2'b00,
            3'd4
        );

        check_condition(
            busy_o === 1'b1 &&
            start_ready_o === 1'b0,
            "INT8 GEMM did not enter busy state"
        );

        wait_for_done();

        for (index = 0; index < 16; index = index + 1) begin
            check_condition(
                accumulator_o[
                    (index * 32) +: 32
                ] === expected_int8(index),
                "INT8 GEMM output mismatch"
            );

            if (
                accumulator_o[
                    (index * 32) +: 32
                ] !== expected_int8(index)
            ) begin
                $display(
                    "  INT8 PE=%0d result=%08h expected=%08h",
                    index,
                    accumulator_o[
                        (index * 32) +: 32
                    ],
                    expected_int8(index)
                );
            end
        end

        // ---------------------------------------------------------------------
        // BF16X2:
        //
        // A contains 1.0 in the lower BF16 slot.
        // B is an identity matrix containing 1.0.
        // Therefore every output is 1.0.
        // ---------------------------------------------------------------------

        for (index = 0; index < 16; index = index + 1) begin
            write_a(
                index[3:0],
                32'h0000_3F80
            );

            if (
                (index / 4) ==
                (index % 4)
            ) begin
                write_b(
                    index[3:0],
                    32'h0000_3F80
                );
            end
            else begin
                write_b(
                    index[3:0],
                    32'h0000_0000
                );
            end
        end

        request_start(
            2'b01,
            3'd4
        );

        wait_for_done();

        for (index = 0; index < 16; index = index + 1) begin
            check_condition(
                accumulator_o[
                    (index * 32) +: 32
                ] === 32'h3F80_0000,
                "BF16X2 GEMM output mismatch"
            );
        end

        // ---------------------------------------------------------------------
        // BF24:
        //
        // A contains 2.0.
        // B is an identity matrix containing 3.0.
        // Therefore every output is 6.0.
        // ---------------------------------------------------------------------

        for (index = 0; index < 16; index = index + 1) begin
            write_a(
                index[3:0],
                32'h0040_0000
            );

            if (
                (index / 4) ==
                (index % 4)
            ) begin
                write_b(
                    index[3:0],
                    32'h0040_4000
                );
            end
            else begin
                write_b(
                    index[3:0],
                    32'h0000_0000
                );
            end
        end

        request_start(
            2'b10,
            3'd4
        );

        wait_for_done();

        for (index = 0; index < 16; index = index + 1) begin
            check_condition(
                accumulator_o[
                    (index * 32) +: 32
                ] === 32'h40C0_0000,
                "BF24 GEMM output mismatch"
            );
        end

        if (error_count == 0) begin
            $display(
                "PASS: nce_systolic_gemm_4x4 passed all %0d autonomous mixed-precision GEMM checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d autonomous GEMM errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
