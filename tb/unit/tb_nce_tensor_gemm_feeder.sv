`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_gemm_feeder;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic start_i;
    logic start_ready_o;

    logic [9:0] activation_base_addr_i;
    logic [9:0] weight_base_addr_i;
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

    logic tiled_a_write_enable_o;
    logic [5:0] tiled_a_write_addr_o;
    logic [31:0] tiled_a_write_data_o;

    logic tiled_b_write_enable_o;
    logic [5:0] tiled_b_write_addr_o;
    logic [31:0] tiled_b_write_data_o;

    logic tiled_start_o;
    logic tiled_start_ready_i;
    logic [1:0] tiled_precision_o;
    logic [3:0] tiled_k_token_count_o;

    logic tiled_busy_i;
    logic tiled_done_i;
    logic tiled_error_i;
    logic [2:0] tiled_error_code_i;

    logic busy_o;
    logic done_o;
    logic error_o;
    logic [2:0] error_code_o;
    logic [2:0] error_detail_o;
    logic [10:0] words_loaded_o;

    logic [31:0] activation_memory [0:1023];
    logic [31:0] weight_memory [0:1023];

    logic activation_memory_valid [0:1023];
    logic weight_memory_valid [0:1023];

    logic [31:0] captured_a [0:63];
    logic [31:0] captured_b [0:63];

    logic [63:0] captured_a_valid;
    logic [63:0] captured_b_valid;

    integer a_write_count;
    integer b_write_count;

    integer check_count;
    integer error_count;

    integer initialize_index;
    integer memory_lane_index;
    integer memory_address;
    integer expected_index;
    integer expected_address;
    integer timeout_count;

    nce_tensor_gemm_feeder dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),
        .activation_base_addr_i      (activation_base_addr_i),
        .weight_base_addr_i          (weight_base_addr_i),
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

        .tiled_a_write_enable_o      (tiled_a_write_enable_o),
        .tiled_a_write_addr_o        (tiled_a_write_addr_o),
        .tiled_a_write_data_o        (tiled_a_write_data_o),

        .tiled_b_write_enable_o      (tiled_b_write_enable_o),
        .tiled_b_write_addr_o        (tiled_b_write_addr_o),
        .tiled_b_write_data_o        (tiled_b_write_data_o),

        .tiled_start_o               (tiled_start_o),
        .tiled_start_ready_i         (tiled_start_ready_i),
        .tiled_precision_o           (tiled_precision_o),
        .tiled_k_token_count_o       (tiled_k_token_count_o),

        .tiled_busy_i                (tiled_busy_i),
        .tiled_done_i                (tiled_done_i),
        .tiled_error_i               (tiled_error_i),
        .tiled_error_code_i          (tiled_error_code_i),

        .busy_o                      (busy_o),
        .done_o                      (done_o),
        .error_o                     (error_o),
        .error_code_o                (error_code_o),
        .error_detail_o              (error_detail_o),
        .words_loaded_o              (words_loaded_o)
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

    task automatic clear_captured_operands;
        integer clear_index;
        begin
            captured_a_valid = '0;
            captured_b_valid = '0;

            a_write_count = 0;
            b_write_count = 0;

            for (
                clear_index = 0;
                clear_index < 64;
                clear_index = clear_index + 1
            ) begin
                captured_a[clear_index] = '0;
                captured_b[clear_index] = '0;
            end
        end
    endtask

    task automatic issue_command (
        input logic [9:0] activation_base,
        input logic [9:0] weight_base,
        input logic [1:0] command_precision,
        input logic [3:0] command_k,
        input logic expected_error,
        input logic [2:0] expected_code
    );
        begin
            @(negedge clk_i);

            start_i = 1'b1;

            activation_base_addr_i =
                activation_base;

            weight_base_addr_i =
                weight_base;

            precision_i =
                command_precision;

            k_token_count_i =
                command_k;

            #1;

            check_condition(
                start_ready_o === 1'b1,
                "feeder was not start-ready"
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

    task automatic wait_for_tiled_start;
        begin
            timeout_count = 0;
            #1;

            while (
                tiled_start_o !== 1'b1 &&
                timeout_count < 300
            ) begin
                @(negedge clk_i);
                #1;

                timeout_count =
                    timeout_count + 1;
            end

            check_condition(
                tiled_start_o === 1'b1,
                "tiled start timed out"
            );
        end
    endtask

    // Scratchpad request acceptance.
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

    // One-cycle synchronous read model.
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
                memory_lane_index = 0;
                memory_lane_index < 4;
                memory_lane_index = memory_lane_index + 1
            ) begin
                if (
                    activation_read_enable_o[
                        memory_lane_index
                    ] &&
                    activation_read_ready_i[
                        memory_lane_index
                    ]
                ) begin
                    memory_address =
                        activation_read_addr_o[
                            (memory_lane_index * 10) +:
                            10
                        ];

                    activation_read_data_i[
                        (memory_lane_index * 32) +:
                        32
                    ] <=
                        activation_memory[
                            memory_address
                        ];

                    activation_read_valid_i[
                        memory_lane_index
                    ] <=
                        activation_memory_valid[
                            memory_address
                        ];
                end

                if (
                    weight_read_enable_o[
                        memory_lane_index
                    ] &&
                    weight_read_ready_i[
                        memory_lane_index
                    ]
                ) begin
                    memory_address =
                        weight_read_addr_o[
                            (memory_lane_index * 10) +:
                            10
                        ];

                    weight_read_data_i[
                        (memory_lane_index * 32) +:
                        32
                    ] <=
                        weight_memory[
                            memory_address
                        ];

                    weight_read_valid_i[
                        memory_lane_index
                    ] <=
                        weight_memory_valid[
                            memory_address
                        ];
                end
            end
        end
    end

    // Capture tiled-GEMM operand writes.
    always_ff @(posedge clk_i) begin
        if (tiled_a_write_enable_o) begin
            captured_a[
                tiled_a_write_addr_o
            ] <=
                tiled_a_write_data_o;

            captured_a_valid[
                tiled_a_write_addr_o
            ] <=
                1'b1;

            a_write_count <=
                a_write_count + 1;
        end

        if (tiled_b_write_enable_o) begin
            captured_b[
                tiled_b_write_addr_o
            ] <=
                tiled_b_write_data_o;

            captured_b_valid[
                tiled_b_write_addr_o
            ] <=
                1'b1;

            b_write_count <=
                b_write_count + 1;
        end
    end

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        start_i = 1'b0;

        activation_base_addr_i = '0;
        weight_base_addr_i     = '0;
        precision_i            = 2'b00;
        k_token_count_i        = 4'd0;

        tiled_start_ready_i = 1'b0;
        tiled_busy_i        = 1'b0;
        tiled_done_i        = 1'b0;
        tiled_error_i       = 1'b0;
        tiled_error_code_i  = 3'd0;

        check_count = 0;
        error_count = 0;

        clear_captured_operands();

        for (
            initialize_index = 0;
            initialize_index < 1024;
            initialize_index = initialize_index + 1
        ) begin
            activation_memory[
                initialize_index
            ] =
                32'hA000_0000 +
                initialize_index;

            weight_memory[
                initialize_index
            ] =
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
            "feeder not ready after reset"
        );

        // Invalid precision.
        issue_command(
            10'd0,
            10'd0,
            2'b11,
            4'd3,
            1'b1,
            3'd1
        );

        // Invalid K values.
        issue_command(
            10'd0,
            10'd0,
            2'b00,
            4'd0,
            1'b1,
            3'd2
        );

        issue_command(
            10'd0,
            10'd0,
            2'b00,
            4'd9,
            1'b1,
            3'd2
        );

        // Feeder must not advertise ready while tiled backend is occupied.
        tiled_busy_i = 1'b1;
        #1;

        check_condition(
            start_ready_o === 1'b0,
            "feeder accepted command while tiled backend busy"
        );

        tiled_busy_i = 1'b0;

        // ---------------------------------------------------------------------
        // K=3 compact transfer.
        // ---------------------------------------------------------------------

        clear_captured_operands();

        tiled_start_ready_i = 1'b0;

        issue_command(
            10'd100,
            10'd200,
            2'b01,
            4'd3,
            1'b0,
            3'd0
        );

        wait_for_tiled_start();

        check_condition(
            a_write_count == 24,
            "K=3 A write count mismatch"
        );

        check_condition(
            b_write_count == 24,
            "K=3 B write count mismatch"
        );

        check_condition(
            words_loaded_o === 11'd24,
            "K=3 loaded-word count mismatch"
        );

        check_condition(
            tiled_precision_o === 2'b01,
            "latched tiled precision mismatch"
        );

        check_condition(
            tiled_k_token_count_o === 4'd3,
            "latched tiled K mismatch"
        );

        // A: row*8 + k. Source index: row*3 + k.
        for (
            expected_index = 0;
            expected_index < 24;
            expected_index = expected_index + 1
        ) begin
            expected_address =
                (
                    (expected_index / 3) * 8
                ) +
                (expected_index % 3);

            check_condition(
                captured_a_valid[
                    expected_address
                ] === 1'b1,
                "K=3 A destination validity mismatch"
            );

            check_condition(
                captured_a[
                    expected_address
                ] ===
                (
                    32'hA000_0000 +
                    100 +
                    expected_index
                ),
                "K=3 A data mapping mismatch"
            );

            // B occupies addresses 0 through 23.
            check_condition(
                captured_b_valid[
                    expected_index
                ] === 1'b1,
                "K=3 B destination validity mismatch"
            );

            check_condition(
                captured_b[
                    expected_index
                ] ===
                (
                    32'hB000_0000 +
                    200 +
                    expected_index
                ),
                "K=3 B data mapping mismatch"
            );
        end

        // Tiled start must remain asserted under start backpressure.
        repeat (3) begin
            @(posedge clk_i);
            #1;

            check_condition(
                tiled_start_o === 1'b1,
                "tiled start dropped while backend not ready"
            );
        end

        @(negedge clk_i);
        tiled_start_ready_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            busy_o === 1'b1,
            "feeder left busy state after tiled start"
        );

        @(negedge clk_i);
        tiled_start_ready_i = 1'b0;
        tiled_busy_i        = 1'b1;

        repeat (3) @(posedge clk_i);

        @(negedge clk_i);
        tiled_busy_i = 1'b0;
        tiled_done_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            done_o === 1'b1,
            "successful tiled completion was not forwarded"
        );

        check_condition(
            busy_o === 1'b0,
            "feeder remained busy after tiled completion"
        );

        @(negedge clk_i);
        tiled_done_i = 1'b0;

        // ---------------------------------------------------------------------
        // Reader-invalid-data propagation.
        // ---------------------------------------------------------------------

        activation_memory_valid[302] = 1'b0;

        issue_command(
            10'd300,
            10'd400,
            2'b00,
            4'd1,
            1'b0,
            3'd0
        );

        timeout_count = 0;

        while (
            error_o !== 1'b1 &&
            timeout_count < 50
        ) begin
            @(posedge clk_i);
            #1;

            timeout_count =
                timeout_count + 1;
        end

        check_condition(
            error_o === 1'b1,
            "reader error was not propagated"
        );

        check_condition(
            error_code_o === 3'd3,
            "reader feeder error code mismatch"
        );

        check_condition(
            error_detail_o === 3'd6,
            "reader detail code mismatch"
        );

        activation_memory_valid[302] = 1'b1;

        // ---------------------------------------------------------------------
        // Full K=8 transfer followed by tiled-backend error.
        // ---------------------------------------------------------------------

        clear_captured_operands();

        tiled_start_ready_i = 1'b0;

        issue_command(
            10'd500,
            10'd600,
            2'b10,
            4'd8,
            1'b0,
            3'd0
        );

        wait_for_tiled_start();

        check_condition(
            a_write_count == 64,
            "K=8 A write count mismatch"
        );

        check_condition(
            b_write_count == 64,
            "K=8 B write count mismatch"
        );

        check_condition(
            captured_a_valid === 64'hFFFF_FFFF_FFFF_FFFF,
            "K=8 A validity mask mismatch"
        );

        check_condition(
            captured_b_valid === 64'hFFFF_FFFF_FFFF_FFFF,
            "K=8 B validity mask mismatch"
        );

        for (
            expected_index = 0;
            expected_index < 64;
            expected_index = expected_index + 1
        ) begin
            check_condition(
                captured_a[expected_index] ===
                (
                    32'hA000_0000 +
                    500 +
                    expected_index
                ),
                "K=8 A data mismatch"
            );

            check_condition(
                captured_b[expected_index] ===
                (
                    32'hB000_0000 +
                    600 +
                    expected_index
                ),
                "K=8 B data mismatch"
            );
        end

        @(negedge clk_i);
        tiled_start_ready_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        tiled_start_ready_i = 1'b0;
        tiled_busy_i        = 1'b1;

        repeat (2) @(posedge clk_i);

        @(negedge clk_i);
        tiled_busy_i       = 1'b0;
        tiled_error_i      = 1'b1;
        tiled_error_code_i = 3'd5;

        @(posedge clk_i);
        #1;

        check_condition(
            error_o === 1'b1,
            "tiled backend error was not forwarded"
        );

        check_condition(
            error_code_o === 3'd4,
            "tiled backend feeder error code mismatch"
        );

        check_condition(
            error_detail_o === 3'd5,
            "tiled backend detail code mismatch"
        );

        check_condition(
            busy_o === 1'b0,
            "feeder remained busy after tiled error"
        );

        @(negedge clk_i);
        tiled_error_i      = 1'b0;
        tiled_error_code_i = 3'd0;

        // ---------------------------------------------------------------------
        // Clear during operand loading.
        // ---------------------------------------------------------------------

        clear_captured_operands();

        issue_command(
            10'd700,
            10'd800,
            2'b00,
            4'd8,
            1'b0,
            3'd0
        );

        while (a_write_count < 5) begin
            @(posedge clk_i);
            #1;
        end

        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            busy_o === 1'b0,
            "clear did not terminate feeder"
        );

        check_condition(
            tiled_start_o === 1'b0,
            "clear allowed tiled start"
        );

        check_condition(
            words_loaded_o === '0,
            "clear did not reset loaded count"
        );

        @(negedge clk_i);
        clear_i = 1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "feeder not ready after clear"
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor GEMM feeder passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tensor-GEMM-feeder errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
