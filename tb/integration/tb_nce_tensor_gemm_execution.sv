`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_gemm_execution;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic start_i;
    logic start_ready_o;

    logic [9:0] activation_base_addr_i;
    logic [9:0] weight_base_addr_i;
    logic [9:0] output_base_addr_i;

    logic [1:0] precision_i;
    logic [3:0] k_token_count_i;

    logic [3:0] activation_read_enable_o;
    logic [39:0] activation_read_addr_o;
    logic [3:0] activation_read_ready_i;
    logic [3:0] activation_read_conflict_i;
    logic [127:0] activation_read_data_i;
    logic [3:0] activation_read_valid_i;

    logic [3:0] weight_read_enable_o;
    logic [39:0] weight_read_addr_o;
    logic [3:0] weight_read_ready_i;
    logic [3:0] weight_read_conflict_i;
    logic [127:0] weight_read_data_i;
    logic [3:0] weight_read_valid_i;

    logic [3:0] output_write_enable_o;
    logic [39:0] output_write_addr_o;
    logic [127:0] output_write_data_o;
    logic [15:0] output_write_strb_o;
    logic [3:0] output_write_ready_i;
    logic [3:0] output_write_conflict_i;

    logic busy_o;
    logic compute_done_o;
    logic done_o;
    logic error_o;
    logic [1:0] error_source_o;
    logic [2:0] error_code_o;
    logic [2:0] error_detail_o;

    logic [10:0] words_loaded_o;
    logic [6:0] words_written_o;

    logic [2047:0] result_data_o;
    logic [63:0] result_valid_o;

    logic [63:0] invalid_o;
    logic [63:0] overflow_o;
    logic [63:0] underflow_o;
    logic [63:0] inexact_o;

    logic [31:0] activation_memory [0:1023];
    logic [31:0] weight_memory [0:1023];
    logic [31:0] output_memory [0:1023];

    logic activation_memory_valid [0:1023];
    logic weight_memory_valid [0:1023];
    logic output_memory_valid [0:1023];

    integer output_write_count [0:1023];

    logic [3:0] output_ready_mask;
    logic [3:0] output_conflict_mask;

    integer check_count;
    integer error_count;

    integer initialize_index;
    integer read_lane_index;
    integer write_lane_index;

    integer activation_address;
    integer weight_address;
    integer output_address;

    integer row_index;
    integer column_index;
    integer matrix_index;
    integer timeout_count;

    nce_tensor_gemm_execution dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),

        .activation_base_addr_i      (activation_base_addr_i),
        .weight_base_addr_i          (weight_base_addr_i),
        .output_base_addr_i          (output_base_addr_i),

        .precision_i                 (precision_i),
        .k_token_count_i             (k_token_count_i),

        .activation_read_enable_o    (activation_read_enable_o),
        .activation_read_addr_o      (activation_read_addr_o),
        .activation_read_ready_i     (activation_read_ready_i),
        .activation_read_conflict_i  (activation_read_conflict_i),
        .activation_read_data_i      (activation_read_data_i),
        .activation_read_valid_i     (activation_read_valid_i),

        .weight_read_enable_o        (weight_read_enable_o),
        .weight_read_addr_o          (weight_read_addr_o),
        .weight_read_ready_i         (weight_read_ready_i),
        .weight_read_conflict_i      (weight_read_conflict_i),
        .weight_read_data_i          (weight_read_data_i),
        .weight_read_valid_i         (weight_read_valid_i),

        .output_write_enable_o       (output_write_enable_o),
        .output_write_addr_o         (output_write_addr_o),
        .output_write_data_o         (output_write_data_o),
        .output_write_strb_o         (output_write_strb_o),
        .output_write_ready_i        (output_write_ready_i),
        .output_write_conflict_i     (output_write_conflict_i),

        .busy_o                      (busy_o),
        .compute_done_o              (compute_done_o),
        .done_o                      (done_o),

        .error_o                     (error_o),
        .error_source_o              (error_source_o),
        .error_code_o                (error_code_o),
        .error_detail_o              (error_detail_o),

        .words_loaded_o              (words_loaded_o),
        .words_written_o             (words_written_o),

        .result_data_o               (result_data_o),
        .result_valid_o              (result_valid_o),

        .invalid_o                   (invalid_o),
        .overflow_o                  (overflow_o),
        .underflow_o                 (underflow_o),
        .inexact_o                   (inexact_o)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    task automatic check_condition (
        input logic condition,
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

    function automatic logic [31:0] positive_integer_fp32 (
        input integer value
    );
        begin
            case (value)
                 0: positive_integer_fp32 = 32'h0000_0000;
                 1: positive_integer_fp32 = 32'h3F80_0000;
                 2: positive_integer_fp32 = 32'h4000_0000;
                 3: positive_integer_fp32 = 32'h4040_0000;
                 4: positive_integer_fp32 = 32'h4080_0000;
                 5: positive_integer_fp32 = 32'h40A0_0000;
                 6: positive_integer_fp32 = 32'h40C0_0000;
                 7: positive_integer_fp32 = 32'h40E0_0000;
                 8: positive_integer_fp32 = 32'h4100_0000;
                 9: positive_integer_fp32 = 32'h4110_0000;
                10: positive_integer_fp32 = 32'h4120_0000;
                11: positive_integer_fp32 = 32'h4130_0000;
                12: positive_integer_fp32 = 32'h4140_0000;
                13: positive_integer_fp32 = 32'h4150_0000;
                14: positive_integer_fp32 = 32'h4160_0000;
                15: positive_integer_fp32 = 32'h4170_0000;

                default:
                    positive_integer_fp32 = 32'd0;
            endcase
        end
    endfunction

    task automatic clear_memory_models;
        integer clear_index;

        begin
            for (
                clear_index = 0;
                clear_index < 1024;
                clear_index = clear_index + 1
            ) begin
                activation_memory[clear_index] =
                    32'd0;

                weight_memory[clear_index] =
                    32'd0;

                output_memory[clear_index] =
                    32'd0;

                activation_memory_valid[clear_index] =
                    1'b0;

                weight_memory_valid[clear_index] =
                    1'b0;

                output_memory_valid[clear_index] =
                    1'b0;

                output_write_count[clear_index] =
                    0;
            end
        end
    endtask

    task automatic pulse_clear;
        begin
            @(negedge clk_i);
            clear_i = 1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            clear_i = 1'b0;

            @(posedge clk_i);
            #1;
        end
    endtask

    task automatic issue_command (
        input logic [9:0] activation_base,
        input logic [9:0] weight_base,
        input logic [9:0] output_base,
        input logic [1:0] command_precision,
        input logic [3:0] command_k,
        input logic expected_error,
        input logic [1:0] expected_source,
        input logic [2:0] expected_code
    );
        begin
            @(negedge clk_i);

            activation_base_addr_i =
                activation_base;

            weight_base_addr_i =
                weight_base;

            output_base_addr_i =
                output_base;

            precision_i =
                command_precision;

            k_token_count_i =
                command_k;

            start_i =
                1'b1;

            #1;

            check_condition(
                start_ready_o === 1'b1,
                "execution subsystem was not start-ready"
            );

            @(posedge clk_i);
            #1;

            check_condition(
                error_o === expected_error,
                "command error response mismatch"
            );

            if (expected_error) begin
                check_condition(
                    error_source_o === expected_source,
                    "command error source mismatch"
                );

                check_condition(
                    error_code_o === expected_code,
                    "command error code mismatch"
                );

                check_condition(
                    busy_o === 1'b0,
                    "invalid command entered busy state"
                );
            end
            else begin
                check_condition(
                    busy_o === 1'b1,
                    "valid command did not enter busy state"
                );
            end

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    task automatic wait_for_compute_done;
        begin
            timeout_count = 0;

            while (
                compute_done_o !== 1'b1 &&
                timeout_count < 3000
            ) begin
                @(posedge clk_i);
                #1;

                timeout_count =
                    timeout_count + 1;
            end

            check_condition(
                compute_done_o === 1'b1,
                "tiled GEMM compute completion timed out"
            );
        end
    endtask

    task automatic wait_for_command_done;
        begin
            timeout_count = 0;

            while (
                done_o !== 1'b1 &&
                error_o !== 1'b1 &&
                timeout_count < 4000
            ) begin
                @(posedge clk_i);
                #1;

                timeout_count =
                    timeout_count + 1;
            end

            check_condition(
                done_o === 1'b1,
                "final tensor GEMM completion timed out"
            );

            check_condition(
                error_o === 1'b0,
                "tensor GEMM unexpectedly reported an error"
            );
        end
    endtask

    // -------------------------------------------------------------------------
    // One-cycle activation and weight scratchpad models
    // -------------------------------------------------------------------------

    always @* begin
        activation_read_ready_i =
            activation_read_enable_o;

        activation_read_conflict_i =
            '0;

        weight_read_ready_i =
            weight_read_enable_o;

        weight_read_conflict_i =
            '0;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            activation_read_data_i <=
                '0;

            activation_read_valid_i <=
                '0;

            weight_read_data_i <=
                '0;

            weight_read_valid_i <=
                '0;
        end
        else begin
            activation_read_valid_i <=
                '0;

            weight_read_valid_i <=
                '0;

            for (
                read_lane_index = 0;
                read_lane_index < 4;
                read_lane_index = read_lane_index + 1
            ) begin
                if (
                    activation_read_enable_o[
                        read_lane_index
                    ] &&
                    activation_read_ready_i[
                        read_lane_index
                    ]
                ) begin
                    activation_address =
                        activation_read_addr_o[
                            (read_lane_index * 10) +:
                            10
                        ];

                    activation_read_data_i[
                        (read_lane_index * 32) +:
                        32
                    ] <=
                        activation_memory[
                            activation_address
                        ];

                    activation_read_valid_i[
                        read_lane_index
                    ] <=
                        activation_memory_valid[
                            activation_address
                        ];
                end

                if (
                    weight_read_enable_o[
                        read_lane_index
                    ] &&
                    weight_read_ready_i[
                        read_lane_index
                    ]
                ) begin
                    weight_address =
                        weight_read_addr_o[
                            (read_lane_index * 10) +:
                            10
                        ];

                    weight_read_data_i[
                        (read_lane_index * 32) +:
                        32
                    ] <=
                        weight_memory[
                            weight_address
                        ];

                    weight_read_valid_i[
                        read_lane_index
                    ] <=
                        weight_memory_valid[
                            weight_address
                        ];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Output scratchpad model
    // -------------------------------------------------------------------------

    assign output_write_ready_i =
        output_write_enable_o &
        output_ready_mask;

    assign output_write_conflict_i =
        output_write_enable_o &
        output_conflict_mask;

    always_ff @(posedge clk_i) begin
        for (
            write_lane_index = 0;
            write_lane_index < 4;
            write_lane_index = write_lane_index + 1
        ) begin
            if (
                output_write_enable_o[
                    write_lane_index
                ] &&
                output_write_ready_i[
                    write_lane_index
                ] &&
                !output_write_conflict_i[
                    write_lane_index
                ]
            ) begin
                output_address =
                    output_write_addr_o[
                        (write_lane_index * 10) +:
                        10
                    ];

                output_memory[
                    output_address
                ] <=
                    output_write_data_o[
                        (write_lane_index * 32) +:
                        32
                    ];

                output_memory_valid[
                    output_address
                ] <=
                    1'b1;

                output_write_count[
                    output_address
                ] <=
                    output_write_count[
                        output_address
                    ] + 1;
            end
        end
    end

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        start_i = 1'b0;

        activation_base_addr_i = '0;
        weight_base_addr_i     = '0;
        output_base_addr_i     = '0;

        precision_i     = 2'b00;
        k_token_count_i = 4'd0;

        output_ready_mask    = 4'b1111;
        output_conflict_mask = 4'b0000;

        check_count = 0;
        error_count = 0;

        clear_memory_models();

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "execution subsystem not ready after reset"
        );

        check_condition(
            busy_o === 1'b0,
            "execution subsystem busy after reset"
        );

        // Invalid precision.
        issue_command(
            10'd0,
            10'd0,
            10'd0,
            2'b11,
            4'd8,
            1'b1,
            2'd0,
            3'd1
        );

        // Output range cannot contain 64 words.
        issue_command(
            10'd0,
            10'd100,
            10'd1000,
            2'b00,
            4'd8,
            1'b1,
            2'd0,
            3'd5
        );

        // ---------------------------------------------------------------------
        // Full K=8 identity-matrix numerical operation.
        // ---------------------------------------------------------------------

        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                activation_memory[
                    100 + matrix_index
                ] =
                    (row_index == column_index)
                    ? 32'h0000_0001
                    : 32'h0000_0000;

                activation_memory_valid[
                    100 + matrix_index
                ] = 1'b1;

                weight_memory[
                    300 + matrix_index
                ] =
                    row_index +
                    column_index +
                    1;

                weight_memory_valid[
                    300 + matrix_index
                ] = 1'b1;
            end
        end

        issue_command(
            10'd100,
            10'd300,
            10'd500,
            2'b00,
            4'd8,
            1'b0,
            2'd0,
            3'd0
        );

        wait_for_compute_done();

        check_condition(
            words_loaded_o === 11'd64,
            "K=8 operand load count mismatch"
        );

        check_condition(
            result_valid_o ===
            64'hFFFF_FFFF_FFFF_FFFF,
            "K=8 result-valid mask mismatch"
        );

        check_condition(
            invalid_o === 64'd0 &&
            overflow_o === 64'd0 &&
            underflow_o === 64'd0 &&
            inexact_o === 64'd0,
            "K=8 arithmetic flags mismatch"
        );

        // Block output writeback after compute has completed.
        @(negedge clk_i);
        output_ready_mask = 4'b0000;

        repeat (3) begin
            @(posedge clk_i);
            #1;

            check_condition(
                busy_o === 1'b1,
                "command completed while output memory was blocked"
            );

            check_condition(
                done_o === 1'b0,
                "done asserted before output writeback"
            );

            check_condition(
                words_written_o === 7'd0,
                "blocked output words were counted"
            );
        end

        // Accept three lanes and force lane one to retry.
        @(negedge clk_i);

        output_ready_mask =
            4'b1111;

        output_conflict_mask =
            4'b0010;

        @(posedge clk_i);
        #1;

        check_condition(
            words_written_o === 7'd3,
            "partial output acceptance count mismatch"
        );

        @(negedge clk_i);
        output_conflict_mask = 4'b0000;

        wait_for_command_done();

        check_condition(
            words_written_o === 7'd64,
            "K=8 final output count mismatch"
        );

        check_condition(
            busy_o === 1'b0,
            "K=8 command remained busy after writeback"
        );

        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                check_condition(
                    output_memory_valid[
                        500 + matrix_index
                    ] === 1'b1,
                    "K=8 output validity mismatch"
                );

                check_condition(
                    output_memory[
                        500 + matrix_index
                    ] ===
                    positive_integer_fp32(
                        row_index +
                        column_index +
                        1
                    ),
                    "K=8 output numerical mismatch"
                );

                check_condition(
                    output_write_count[
                        500 + matrix_index
                    ] == 1,
                    "K=8 output was not written exactly once"
                );
            end
        end

        // ---------------------------------------------------------------------
        // Partial K=3 compact tensor operation.
        // ---------------------------------------------------------------------

        pulse_clear();

        output_ready_mask    = 4'b1111;
        output_conflict_mask = 4'b0000;

        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 3;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 3) +
                    column_index;

                activation_memory[
                    20 + matrix_index
                ] =
                    (
                        row_index < 3 &&
                        row_index == column_index
                    )
                    ? 32'h0000_0001
                    : 32'h0000_0000;

                activation_memory_valid[
                    20 + matrix_index
                ] = 1'b1;
            end
        end

        for (
            row_index = 0;
            row_index < 3;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                weight_memory[
                    60 + matrix_index
                ] =
                    row_index +
                    column_index +
                    1;

                weight_memory_valid[
                    60 + matrix_index
                ] = 1'b1;
            end
        end

        issue_command(
            10'd20,
            10'd60,
            10'd700,
            2'b00,
            4'd3,
            1'b0,
            2'd0,
            3'd0
        );

        wait_for_command_done();

        check_condition(
            words_loaded_o === 11'd24,
            "K=3 operand load count mismatch"
        );

        check_condition(
            words_written_o === 7'd64,
            "K=3 output count mismatch"
        );

        for (
            row_index = 0;
            row_index < 8;
            row_index = row_index + 1
        ) begin
            for (
                column_index = 0;
                column_index < 8;
                column_index = column_index + 1
            ) begin
                matrix_index =
                    (row_index * 8) +
                    column_index;

                check_condition(
                    output_memory[
                        700 + matrix_index
                    ] ===
                    positive_integer_fp32(
                        (row_index < 3)
                        ? row_index + column_index + 1
                        : 0
                    ),
                    "K=3 output numerical mismatch"
                );
            end
        end

        // ---------------------------------------------------------------------
        // Reader-invalid-data propagation and writer cancellation.
        // ---------------------------------------------------------------------

        pulse_clear();

        for (
            initialize_index = 0;
            initialize_index < 8;
            initialize_index = initialize_index + 1
        ) begin
            activation_memory[
                900 + initialize_index
            ] =
                32'h0000_0001;

            activation_memory_valid[
                900 + initialize_index
            ] = 1'b1;

            weight_memory[
                920 + initialize_index
            ] =
                32'h0000_0001;

            weight_memory_valid[
                920 + initialize_index
            ] = 1'b1;
        end

        activation_memory_valid[902] =
            1'b0;

        issue_command(
            10'd900,
            10'd920,
            10'd800,
            2'b00,
            4'd1,
            1'b0,
            2'd0,
            3'd0
        );

        timeout_count = 0;

        while (
            error_o !== 1'b1 &&
            timeout_count < 200
        ) begin
            @(posedge clk_i);
            #1;

            timeout_count =
                timeout_count + 1;
        end

        check_condition(
            error_o === 1'b1,
            "reader invalid-data error was not propagated"
        );

        check_condition(
            error_source_o === 2'd1,
            "reader failure source mismatch"
        );

        check_condition(
            error_code_o === 3'd3,
            "feeder reader-error code mismatch"
        );

        check_condition(
            error_detail_o === 3'd6,
            "activation-invalid detail code mismatch"
        );

        check_condition(
            busy_o === 1'b0,
            "failed command remained busy"
        );

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "subsystem did not recover after feeder failure"
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor GEMM execution passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tensor-GEMM-execution errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
