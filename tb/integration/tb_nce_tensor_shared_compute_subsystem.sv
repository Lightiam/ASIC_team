`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_shared_compute_subsystem;

    localparam logic [1:0] TARGET_ACTIVATION = 2'd0;
    localparam logic [1:0] TARGET_WEIGHT     = 2'd1;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic load_start_i;
    logic load_start_ready_o;
    logic [1:0] load_target_i;
    logic [9:0] load_base_addr_i;
    logic [10:0] load_word_count_i;

    logic load_stream_valid_i;
    logic load_stream_ready_o;
    logic load_stream_last_i;
    logic [127:0] load_stream_data_i;
    logic [15:0] load_stream_strb_i;

    logic load_busy_o;
    logic load_done_o;
    logic load_error_o;
    logic [2:0] load_error_code_o;
    logic [10:0] load_words_written_o;
    logic [1:0] load_active_target_o;

    logic gemm_start_i;
    logic gemm_start_ready_o;
    logic [9:0] gemm_activation_base_addr_i;
    logic [9:0] gemm_weight_base_addr_i;
    logic [9:0] gemm_output_base_addr_i;
    logic [1:0] gemm_precision_i;
    logic [3:0] gemm_k_token_count_i;

    logic gemm_busy_o;
    logic gemm_compute_done_o;
    logic gemm_done_o;
    logic gemm_error_o;
    logic [1:0] gemm_error_source_o;
    logic [2:0] gemm_error_code_o;
    logic [2:0] gemm_error_detail_o;
    logic [10:0] gemm_words_loaded_o;
    logic [6:0] gemm_words_written_o;

    logic [2047:0] gemm_result_data_o;
    logic [63:0] gemm_result_valid_o;
    logic [63:0] gemm_invalid_o;
    logic [63:0] gemm_overflow_o;
    logic [63:0] gemm_underflow_o;
    logic [63:0] gemm_inexact_o;

    logic [3:0] output_read_enable_i;
    logic [39:0] output_read_addr_i;
    logic [3:0] output_read_ready_o;
    logic [3:0] output_read_conflict_o;
    logic [127:0] output_read_data_o;
    logic [3:0] output_read_valid_o;

    integer check_count;
    integer error_count;

    integer stream_offset;
    integer stream_lane;
    integer stream_index;
    integer stream_row;
    integer stream_column;
    integer stream_k;

    integer batch_index;
    integer read_lane;
    integer result_index;
    integer result_row;
    integer result_column;
    integer timeout_count;

    logic [127:0] generated_beat_data;
    logic [15:0] generated_beat_strb;
    logic generated_beat_last;
    logic load_done_seen;
    logic compute_done_seen;

    nce_tensor_shared_compute_subsystem dut (
        .clk_i                          (clk_i),
        .rst_ni                         (rst_ni),
        .clear_i                        (clear_i),

        .load_start_i                   (load_start_i),
        .load_start_ready_o             (load_start_ready_o),
        .load_target_i                  (load_target_i),
        .load_base_addr_i               (load_base_addr_i),
        .load_word_count_i              (load_word_count_i),

        .load_stream_valid_i            (load_stream_valid_i),
        .load_stream_ready_o            (load_stream_ready_o),
        .load_stream_last_i             (load_stream_last_i),
        .load_stream_data_i             (load_stream_data_i),
        .load_stream_strb_i             (load_stream_strb_i),

        .load_busy_o                    (load_busy_o),
        .load_done_o                    (load_done_o),
        .load_error_o                   (load_error_o),
        .load_error_code_o              (load_error_code_o),
        .load_words_written_o           (load_words_written_o),
        .load_active_target_o           (load_active_target_o),

        .gemm_start_i                   (gemm_start_i),
        .gemm_start_ready_o             (gemm_start_ready_o),

        .gemm_activation_base_addr_i    (
            gemm_activation_base_addr_i
        ),

        .gemm_weight_base_addr_i        (
            gemm_weight_base_addr_i
        ),

        .gemm_output_base_addr_i        (
            gemm_output_base_addr_i
        ),

        .gemm_precision_i               (gemm_precision_i),
        .gemm_k_token_count_i           (gemm_k_token_count_i),

        .gemm_busy_o                    (gemm_busy_o),
        .gemm_compute_done_o            (gemm_compute_done_o),
        .gemm_done_o                    (gemm_done_o),

        .gemm_error_o                   (gemm_error_o),
        .gemm_error_source_o            (gemm_error_source_o),
        .gemm_error_code_o              (gemm_error_code_o),
        .gemm_error_detail_o            (gemm_error_detail_o),

        .gemm_words_loaded_o            (gemm_words_loaded_o),
        .gemm_words_written_o           (gemm_words_written_o),

        .gemm_result_data_o             (gemm_result_data_o),
        .gemm_result_valid_o            (gemm_result_valid_o),

        .gemm_invalid_o                 (gemm_invalid_o),
        .gemm_overflow_o                (gemm_overflow_o),
        .gemm_underflow_o               (gemm_underflow_o),
        .gemm_inexact_o                 (gemm_inexact_o),

        .output_read_enable_i           (output_read_enable_i),
        .output_read_addr_i             (output_read_addr_i),
        .output_read_ready_o            (output_read_ready_o),
        .output_read_conflict_o         (output_read_conflict_o),
        .output_read_data_o             (output_read_data_o),
        .output_read_valid_o            (output_read_valid_o)
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

    task automatic stream_load_compact_matrix (
        input logic [1:0] target,
        input logic [9:0] base_addr,
        input integer k_count
    );
        integer total_words;
        integer accepted_words;

        begin
            total_words =
                8 * k_count;

            @(negedge clk_i);

            load_target_i =
                target;

            load_base_addr_i =
                base_addr;

            load_word_count_i =
                11'(total_words);

            load_start_i =
                1'b1;

            #1;

            check_condition(
                load_start_ready_o === 1'b1,
                "tensor loader was not command-ready"
            );

            @(posedge clk_i);
            #1;

            check_condition(
                load_busy_o === 1'b1,
                "accepted tensor load did not enter busy state"
            );

            check_condition(
                gemm_start_ready_o === 1'b0,
                "GEMM remained command-ready during tensor loading"
            );

            @(negedge clk_i);

            load_start_i =
                1'b0;

            accepted_words =
                0;

            load_done_seen =
                1'b0;

            while (accepted_words < total_words) begin
                generated_beat_data =
                    '0;

                generated_beat_strb =
                    '0;

                for (
                    stream_lane = 0;
                    stream_lane < 4;
                    stream_lane = stream_lane + 1
                ) begin
                    stream_index =
                        accepted_words +
                        stream_lane;

                    if (stream_index < total_words) begin
                        if (target == TARGET_ACTIVATION) begin
                            stream_row =
                                stream_index /
                                k_count;

                            stream_k =
                                stream_index %
                                k_count;

                            generated_beat_data[
                                (stream_lane * 32) +:
                                32
                            ] =
                                (stream_row == stream_k)
                                ? 32'h0000_0001
                                : 32'h0000_0000;
                        end
                        else begin
                            stream_k =
                                stream_index / 8;

                            stream_column =
                                stream_index % 8;

                            generated_beat_data[
                                (stream_lane * 32) +:
                                32
                            ] =
                                stream_k +
                                stream_column +
                                1;
                        end

                        generated_beat_strb[
                            (stream_lane * 4) +:
                            4
                        ] =
                            4'hF;
                    end
                end

                generated_beat_last =
                    (
                        accepted_words + 4
                    ) >=
                    total_words;

                @(negedge clk_i);

                load_stream_data_i =
                    generated_beat_data;

                load_stream_strb_i =
                    generated_beat_strb;

                load_stream_last_i =
                    generated_beat_last;

                load_stream_valid_i =
                    1'b1;

                #1;

                while (
                    load_stream_ready_o !== 1'b1
                ) begin
                    @(negedge clk_i);
                    #1;
                end

                @(posedge clk_i);
                #1;

                check_condition(
                    load_error_o === 1'b0,
                    "tensor loader reported a stream error"
                );

                if (load_done_o) begin
                    load_done_seen =
                        1'b1;
                end

                @(negedge clk_i);

                load_stream_valid_i =
                    1'b0;

                load_stream_last_i =
                    1'b0;

                load_stream_data_i =
                    '0;

                load_stream_strb_i =
                    '0;

                if (
                    accepted_words + 4 <=
                    total_words
                ) begin
                    accepted_words =
                        accepted_words + 4;
                end
                else begin
                    accepted_words =
                        total_words;
                end
            end

            timeout_count =
                0;

            while (
                !load_done_seen &&
                timeout_count < 20
            ) begin
                @(posedge clk_i);
                #1;

                if (load_done_o) begin
                    load_done_seen =
                        1'b1;
                end

                timeout_count =
                    timeout_count + 1;
            end

            check_condition(
                load_done_seen,
                "tensor loader completion timed out"
            );

            check_condition(
                load_words_written_o === 11'(total_words),
                "tensor loader word-count mismatch"
            );

            check_condition(
                load_active_target_o === target,
                "tensor loader active-target mismatch"
            );

            check_condition(
                load_busy_o === 1'b0,
                "tensor loader remained busy after completion"
            );
        end
    endtask

    task automatic execute_gemm (
        input logic [9:0] activation_base,
        input logic [9:0] weight_base,
        input logic [9:0] output_base,
        input integer k_count
    );
        begin
            @(negedge clk_i);

            gemm_activation_base_addr_i =
                activation_base;

            gemm_weight_base_addr_i =
                weight_base;

            gemm_output_base_addr_i =
                output_base;

            gemm_precision_i =
                2'b00;

            gemm_k_token_count_i =
                4'(k_count);

            gemm_start_i =
                1'b1;

            #1;

            check_condition(
                gemm_start_ready_o === 1'b1,
                "tensor GEMM was not command-ready"
            );

            @(posedge clk_i);
            #1;

            check_condition(
                gemm_busy_o === 1'b1,
                "accepted tensor GEMM did not enter busy state"
            );

            check_condition(
                load_start_ready_o === 1'b0,
                "loader remained command-ready during GEMM execution"
            );

            @(negedge clk_i);

            gemm_start_i =
                1'b0;

            compute_done_seen =
                1'b0;

            timeout_count =
                0;

            while (
                gemm_done_o !== 1'b1 &&
                gemm_error_o !== 1'b1 &&
                timeout_count < 5000
            ) begin
                @(posedge clk_i);
                #1;

                if (gemm_compute_done_o) begin
                    compute_done_seen =
                        1'b1;
                end

                timeout_count =
                    timeout_count + 1;
            end

            check_condition(
                gemm_error_o === 1'b0,
                "tensor GEMM reported an execution error"
            );

            check_condition(
                gemm_done_o === 1'b1,
                "tensor GEMM final completion timed out"
            );

            check_condition(
                compute_done_seen,
                "tensor GEMM compute completion was not observed"
            );

            check_condition(
                gemm_busy_o === 1'b0,
                "tensor GEMM remained busy after writeback"
            );

            check_condition(
                gemm_words_loaded_o ===
                11'(8 * k_count),
                "tensor GEMM operand count mismatch"
            );

            check_condition(
                gemm_words_written_o ===
                7'd64,
                "tensor GEMM output count mismatch"
            );

            check_condition(
                gemm_result_valid_o ===
                64'hFFFF_FFFF_FFFF_FFFF,
                "tensor GEMM result-valid mask mismatch"
            );

            check_condition(
                gemm_invalid_o === 64'd0 &&
                gemm_overflow_o === 64'd0 &&
                gemm_underflow_o === 64'd0 &&
                gemm_inexact_o === 64'd0,
                "tensor GEMM arithmetic flags mismatch"
            );
        end
    endtask

    task automatic check_output_matrix (
        input logic [9:0] output_base,
        input integer k_count
    );
        logic [31:0] observed_word;
        logic [31:0] expected_word;

        begin
            for (
                batch_index = 0;
                batch_index < 16;
                batch_index = batch_index + 1
            ) begin
                @(negedge clk_i);

                output_read_enable_i =
                    4'b1111;

                for (
                    read_lane = 0;
                    read_lane < 4;
                    read_lane = read_lane + 1
                ) begin
                    output_read_addr_i[
                        (read_lane * 10) +:
                        10
                    ] =
                        output_base +
                        10'(
                            (batch_index * 4) +
                            read_lane
                        );
                end

                #1;

                check_condition(
                    output_read_ready_o === 4'b1111,
                    "output read batch was not accepted"
                );

                check_condition(
                    output_read_conflict_o === 4'b0000,
                    "unexpected output read-bank conflict"
                );

                @(posedge clk_i);
                #1;

                check_condition(
                    output_read_valid_o === 4'b1111,
                    "output read-valid batch mismatch"
                );

                for (
                    read_lane = 0;
                    read_lane < 4;
                    read_lane = read_lane + 1
                ) begin
                    result_index =
                        (batch_index * 4) +
                        read_lane;

                    result_row =
                        result_index / 8;

                    result_column =
                        result_index % 8;

                    observed_word =
                        output_read_data_o[
                            (read_lane * 32) +:
                            32
                        ];

                    expected_word =
                        positive_integer_fp32(
                            (result_row < k_count)
                            ? result_row +
                              result_column +
                              1
                            : 0
                        );

                    check_condition(
                        observed_word === expected_word,
                        "output scratchpad numerical mismatch"
                    );

                    check_condition(
                        gemm_result_data_o[
                            (result_index * 32) +:
                            32
                        ] === expected_word,
                        "GEMM result vector/readback mismatch"
                    );
                end

                @(negedge clk_i);

                output_read_enable_i =
                    '0;

                output_read_addr_i =
                    '0;
            end
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        load_start_i =
            1'b0;

        load_target_i =
            TARGET_ACTIVATION;

        load_base_addr_i =
            '0;

        load_word_count_i =
            '0;

        load_stream_valid_i =
            1'b0;

        load_stream_last_i =
            1'b0;

        load_stream_data_i =
            '0;

        load_stream_strb_i =
            '0;

        gemm_start_i =
            1'b0;

        gemm_activation_base_addr_i =
            '0;

        gemm_weight_base_addr_i =
            '0;

        gemm_output_base_addr_i =
            '0;

        gemm_precision_i =
            2'b00;

        gemm_k_token_count_i =
            4'd0;

        output_read_enable_i =
            '0;

        output_read_addr_i =
            '0;

        check_count =
            0;

        error_count =
            0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            load_start_ready_o === 1'b1,
            "loader not ready after reset"
        );

        check_condition(
            gemm_start_ready_o === 1'b1,
            "GEMM not ready after reset"
        );

        // ---------------------------------------------------------------------
        // Full K=8 identity-matrix numerical operation.
        // ---------------------------------------------------------------------

        stream_load_compact_matrix(
            TARGET_ACTIVATION,
            10'd100,
            8
        );

        stream_load_compact_matrix(
            TARGET_WEIGHT,
            10'd300,
            8
        );

        execute_gemm(
            10'd100,
            10'd300,
            10'd500,
            8
        );

        check_output_matrix(
            10'd500,
            8
        );

        // ---------------------------------------------------------------------
        // Partial K=3 compact numerical operation using the same physical
        // memories and a second autonomous command.
        // ---------------------------------------------------------------------

        stream_load_compact_matrix(
            TARGET_ACTIVATION,
            10'd20,
            3
        );

        stream_load_compact_matrix(
            TARGET_WEIGHT,
            10'd60,
            3
        );

        execute_gemm(
            10'd20,
            10'd60,
            10'd700,
            3
        );

        check_output_matrix(
            10'd700,
            3
        );

        // Clear must invalidate all memory metadata.
        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        clear_i = 1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            load_start_ready_o === 1'b1 &&
            gemm_start_ready_o === 1'b1,
            "subsystem did not recover after clear"
        );

        @(negedge clk_i);

        output_read_enable_i =
            4'b0001;

        output_read_addr_i[9:0] =
            10'd500;

        #1;

        check_condition(
            output_read_ready_o[0] === 1'b1,
            "post-clear output read was not accepted"
        );

        @(posedge clk_i);
        #1;

        check_condition(
            output_read_valid_o[0] === 1'b0,
            "clear did not invalidate output-memory metadata"
        );

        @(negedge clk_i);

        output_read_enable_i =
            '0;

        if (error_count == 0) begin
            $display(
                "PASS: shared-engine tensor compute subsystem passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d shared-engine tensor-compute-subsystem errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
