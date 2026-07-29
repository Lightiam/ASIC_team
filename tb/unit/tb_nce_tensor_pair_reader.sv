`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_pair_reader;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic start_i;
    logic start_ready_o;

    logic [9:0] activation_base_addr_i;
    logic [9:0] weight_base_addr_i;
    logic [10:0] word_count_i;

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

    logic pair_valid_o;
    logic pair_ready_i;
    logic [5:0] pair_index_o;
    logic [31:0] activation_word_o;
    logic [31:0] weight_word_o;
    logic pair_last_o;

    logic busy_o;
    logic done_o;
    logic error_o;
    logic [2:0] error_code_o;
    logic [10:0] words_emitted_o;

    logic force_activation_conflict;
    logic force_weight_conflict;

    logic [31:0] activation_memory [0:1023];
    logic [31:0] weight_memory [0:1023];

    logic activation_memory_valid [0:1023];
    logic weight_memory_valid [0:1023];

    integer check_count;
    integer error_count;

    integer initialize_index;
    integer ready_lane_index;
    integer model_lane_index;
    integer model_address;

    logic [31:0] held_activation;
    logic [31:0] held_weight;
    logic [5:0] held_index;
    logic held_last;

    nce_tensor_pair_reader dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),
        .activation_base_addr_i      (activation_base_addr_i),
        .weight_base_addr_i          (weight_base_addr_i),
        .word_count_i                (word_count_i),

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

        .pair_valid_o                (pair_valid_o),
        .pair_ready_i                (pair_ready_i),
        .pair_index_o                (pair_index_o),
        .activation_word_o           (activation_word_o),
        .weight_word_o               (weight_word_o),
        .pair_last_o                 (pair_last_o),

        .busy_o                      (busy_o),
        .done_o                      (done_o),
        .error_o                     (error_o),
        .error_code_o                (error_code_o),
        .words_emitted_o             (words_emitted_o)
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

    // -------------------------------------------------------------------------
    // Behavioral one-cycle scratchpad models
    // -------------------------------------------------------------------------

    always @* begin
        activation_read_ready_i    = '0;
        activation_read_conflict_i = '0;

        weight_read_ready_i    = '0;
        weight_read_conflict_i = '0;

        for (
            ready_lane_index = 0;
            ready_lane_index < 4;
            ready_lane_index = ready_lane_index + 1
        ) begin
            if (activation_read_enable_o[ready_lane_index]) begin
                if (force_activation_conflict) begin
                    activation_read_conflict_i[
                        ready_lane_index
                    ] = 1'b1;
                end
                else begin
                    activation_read_ready_i[
                        ready_lane_index
                    ] = 1'b1;
                end
            end

            if (weight_read_enable_o[ready_lane_index]) begin
                if (force_weight_conflict) begin
                    weight_read_conflict_i[
                        ready_lane_index
                    ] = 1'b1;
                end
                else begin
                    weight_read_ready_i[
                        ready_lane_index
                    ] = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            activation_read_data_i  <= '0;
            activation_read_valid_i <= '0;

            weight_read_data_i  <= '0;
            weight_read_valid_i <= '0;
        end
        else begin
            activation_read_valid_i <= '0;
            weight_read_valid_i     <= '0;

            for (
                model_lane_index = 0;
                model_lane_index < 4;
                model_lane_index = model_lane_index + 1
            ) begin
                if (
                    activation_read_enable_o[
                        model_lane_index
                    ] &&
                    activation_read_ready_i[
                        model_lane_index
                    ]
                ) begin
                    model_address =
                        activation_read_addr_o[
                            (model_lane_index * 10) +:
                            10
                        ];

                    activation_read_data_i[
                        (model_lane_index * 32) +:
                        32
                    ] <=
                        activation_memory[
                            model_address
                        ];

                    activation_read_valid_i[
                        model_lane_index
                    ] <=
                        activation_memory_valid[
                            model_address
                        ];
                end

                if (
                    weight_read_enable_o[
                        model_lane_index
                    ] &&
                    weight_read_ready_i[
                        model_lane_index
                    ]
                ) begin
                    model_address =
                        weight_read_addr_o[
                            (model_lane_index * 10) +:
                            10
                        ];

                    weight_read_data_i[
                        (model_lane_index * 32) +:
                        32
                    ] <=
                        weight_memory[
                            model_address
                        ];

                    weight_read_valid_i[
                        model_lane_index
                    ] <=
                        weight_memory_valid[
                            model_address
                        ];
                end
            end
        end
    end

    task automatic start_command (
        input logic [9:0] activation_base,
        input logic [9:0] weight_base,
        input logic [10:0] count,
        input logic expected_error,
        input logic [2:0] expected_code
    );
        begin
            @(negedge clk_i);

            start_i                = 1'b1;
            activation_base_addr_i = activation_base;
            weight_base_addr_i     = weight_base;
            word_count_i           = count;

            #1;

            check_condition(
                start_ready_o === 1'b1,
                "reader was not start-ready"
            );

            @(posedge clk_i);
            #1;

            check_condition(
                error_o === expected_error,
                "command error response mismatch"
            );

            if (expected_error) begin
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

    task automatic consume_pair (
        input integer expected_index,
        input logic [31:0] expected_activation,
        input logic [31:0] expected_weight,
        input logic expected_last,
        input integer stall_cycles,
        input logic expected_done
    );
        integer timeout_count;
        integer stall_index;
        begin
            pair_ready_i = 1'b0;

            timeout_count = 0;
            #1;

            while (
                pair_valid_o !== 1'b1 &&
                timeout_count < 30
            ) begin
                @(negedge clk_i);
                #1;

                timeout_count =
                    timeout_count + 1;
            end

            check_condition(
                pair_valid_o === 1'b1,
                "pair output timed out"
            );

            held_activation =
                activation_word_o;

            held_weight =
                weight_word_o;

            held_index =
                pair_index_o;

            held_last =
                pair_last_o;

            for (
                stall_index = 0;
                stall_index < stall_cycles;
                stall_index = stall_index + 1
            ) begin
                @(posedge clk_i);
                #1;

                check_condition(
                    pair_valid_o === 1'b1,
                    "pair valid dropped during backpressure"
                );

                check_condition(
                    activation_word_o === held_activation,
                    "activation word changed during backpressure"
                );

                check_condition(
                    weight_word_o === held_weight,
                    "weight word changed during backpressure"
                );

                check_condition(
                    pair_index_o === held_index,
                    "pair index changed during backpressure"
                );

                check_condition(
                    pair_last_o === held_last,
                    "pair-last changed during backpressure"
                );

                @(negedge clk_i);
                #1;
            end

            check_condition(
                pair_index_o === expected_index,
                "pair index mismatch"
            );

            check_condition(
                activation_word_o === expected_activation,
                "activation word mismatch"
            );

            check_condition(
                weight_word_o === expected_weight,
                "weight word mismatch"
            );

            check_condition(
                pair_last_o === expected_last,
                "pair-last mismatch"
            );

            pair_ready_i = 1'b1;
            #1;

            @(posedge clk_i);
            #1;

            check_condition(
                done_o === expected_done,
                "reader completion mismatch"
            );

            check_condition(
                error_o === 1'b0,
                "unexpected reader error"
            );

            @(negedge clk_i);
            pair_ready_i = 1'b0;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        start_i = 1'b0;

        activation_base_addr_i = '0;
        weight_base_addr_i     = '0;
        word_count_i           = '0;

        pair_ready_i = 1'b0;

        force_activation_conflict = 1'b0;
        force_weight_conflict     = 1'b0;

        check_count = 0;
        error_count = 0;

        for (
            initialize_index = 0;
            initialize_index < 1024;
            initialize_index = initialize_index + 1
        ) begin
            activation_memory[initialize_index] =
                32'hA000_0000 +
                initialize_index;

            weight_memory[initialize_index] =
                32'hB000_0000 +
                initialize_index;

            activation_memory_valid[
                initialize_index
            ] = 1'b1;

            weight_memory_valid[
                initialize_index
            ] = 1'b1;
        end

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "reader not ready after reset"
        );

        check_condition(
            busy_o === 1'b0,
            "reader busy after reset"
        );

        // Command validation.
        start_command(
            10'd0,
            10'd0,
            11'd0,
            1'b1,
            3'd1
        );

        start_command(
            10'd0,
            10'd0,
            11'd65,
            1'b1,
            3'd2
        );

        start_command(
            10'd1000,
            10'd0,
            11'd30,
            1'b1,
            3'd3
        );

        start_command(
            10'd0,
            10'd1000,
            11'd30,
            1'b1,
            3'd4
        );

        // Conflict reporting.
        start_command(
            10'd0,
            10'd0,
            11'd4,
            1'b0,
            3'd0
        );

        force_activation_conflict = 1'b1;
        #1;

        @(posedge clk_i);
        #1;

        check_condition(
            error_o === 1'b1,
            "read conflict was not reported"
        );

        check_condition(
            error_code_o === 3'd5,
            "read conflict code mismatch"
        );

        check_condition(
            busy_o === 1'b0,
            "reader remained busy after conflict"
        );

        @(negedge clk_i);
        force_activation_conflict = 1'b0;

        // Invalid activation response.
        activation_memory_valid[14] = 1'b0;

        start_command(
            10'd12,
            10'd40,
            11'd4,
            1'b0,
            3'd0
        );

        repeat (2) begin
            @(posedge clk_i);
            #1;
        end

        check_condition(
            error_o === 1'b1,
            "invalid activation response was not reported"
        );

        check_condition(
            error_code_o === 3'd6,
            "invalid activation error code mismatch"
        );

        activation_memory_valid[14] = 1'b1;

        // Invalid weight response.
        weight_memory_valid[52] = 1'b0;

        start_command(
            10'd20,
            10'd50,
            11'd4,
            1'b0,
            3'd0
        );

        repeat (2) begin
            @(posedge clk_i);
            #1;
        end

        check_condition(
            error_o === 1'b1,
            "invalid weight response was not reported"
        );

        check_condition(
            error_code_o === 3'd7,
            "invalid weight error code mismatch"
        );

        weight_memory_valid[52] = 1'b1;

        // Eight-word transfer with output backpressure.
        start_command(
            10'd10,
            10'd20,
            11'd8,
            1'b0,
            3'd0
        );

        consume_pair(
            0,
            32'hA000_000A,
            32'hB000_0014,
            1'b0,
            0,
            1'b0
        );

        consume_pair(
            1,
            32'hA000_000B,
            32'hB000_0015,
            1'b0,
            0,
            1'b0
        );

        consume_pair(
            2,
            32'hA000_000C,
            32'hB000_0016,
            1'b0,
            3,
            1'b0
        );

        consume_pair(
            3,
            32'hA000_000D,
            32'hB000_0017,
            1'b0,
            0,
            1'b0
        );

        consume_pair(
            4,
            32'hA000_000E,
            32'hB000_0018,
            1'b0,
            0,
            1'b0
        );

        consume_pair(
            5,
            32'hA000_000F,
            32'hB000_0019,
            1'b0,
            1,
            1'b0
        );

        consume_pair(
            6,
            32'hA000_0010,
            32'hB000_001A,
            1'b0,
            0,
            1'b0
        );

        consume_pair(
            7,
            32'hA000_0011,
            32'hB000_001B,
            1'b1,
            0,
            1'b1
        );

        check_condition(
            words_emitted_o === 11'd8,
            "eight-word accounting mismatch"
        );

        check_condition(
            start_ready_o === 1'b1,
            "reader not ready after completion"
        );

        // Three-word unaligned tail transfer.
        start_command(
            10'd101,
            10'd205,
            11'd3,
            1'b0,
            3'd0
        );

        consume_pair(
            0,
            32'hA000_0065,
            32'hB000_00CD,
            1'b0,
            1,
            1'b0
        );

        consume_pair(
            1,
            32'hA000_0066,
            32'hB000_00CE,
            1'b0,
            0,
            1'b0
        );

        consume_pair(
            2,
            32'hA000_0067,
            32'hB000_00CF,
            1'b1,
            0,
            1'b1
        );

        check_condition(
            words_emitted_o === 11'd3,
            "tail-transfer accounting mismatch"
        );

        // Clear an operation while an output pair is pending.
        start_command(
            10'd300,
            10'd400,
            11'd8,
            1'b0,
            3'd0
        );

        pair_ready_i = 1'b0;

        while (pair_valid_o !== 1'b1) begin
            @(negedge clk_i);
            #1;
        end

        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            busy_o === 1'b0,
            "clear did not terminate reader"
        );

        check_condition(
            pair_valid_o === 1'b0,
            "pair valid remained asserted after clear"
        );

        check_condition(
            words_emitted_o === '0,
            "clear did not reset emitted-word count"
        );

        @(negedge clk_i);
        clear_i = 1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "reader not ready after clear"
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor pair reader passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tensor-pair-reader errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
