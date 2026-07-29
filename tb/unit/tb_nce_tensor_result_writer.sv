`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_result_writer;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic start_i;
    logic start_ready_o;
    logic [9:0] output_base_addr_i;

    logic capture_i;
    logic [2047:0] result_data_i;
    logic [63:0] result_valid_i;

    logic [3:0] output_write_enable_o;
    logic [39:0] output_write_addr_o;
    logic [127:0] output_write_data_o;
    logic [15:0] output_write_strb_o;

    logic [3:0] output_write_ready_i;
    logic [3:0] output_write_conflict_i;

    logic busy_o;
    logic waiting_for_result_o;
    logic done_o;
    logic error_o;
    logic [2:0] error_code_o;
    logic [6:0] words_written_o;

    logic [3:0] allowed_ready_mask;
    logic [3:0] forced_conflict_mask;

    logic [31:0] output_memory [0:1023];
    logic output_memory_valid [0:1023];
    integer output_write_count [0:1023];

    integer check_count;
    integer error_count;

    integer initialize_index;
    integer result_index;
    integer write_lane_index;
    integer write_address;
    integer timeout_count;

    logic [3:0] held_enable;
    logic [39:0] held_addr;
    logic [127:0] held_data;
    logic [15:0] held_strb;

    nce_tensor_result_writer dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),
        .output_base_addr_i          (output_base_addr_i),

        .capture_i                   (capture_i),
        .result_data_i               (result_data_i),
        .result_valid_i              (result_valid_i),

        .output_write_enable_o       (output_write_enable_o),
        .output_write_addr_o         (output_write_addr_o),
        .output_write_data_o         (output_write_data_o),
        .output_write_strb_o         (output_write_strb_o),
        .output_write_ready_i        (output_write_ready_i),
        .output_write_conflict_i     (output_write_conflict_i),

        .busy_o                      (busy_o),
        .waiting_for_result_o        (waiting_for_result_o),

        .done_o                      (done_o),
        .error_o                     (error_o),
        .error_code_o                (error_code_o),
        .words_written_o             (words_written_o)
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

    task automatic clear_output_model;
        integer clear_index;

        begin
            for (
                clear_index = 0;
                clear_index < 1024;
                clear_index = clear_index + 1
            ) begin
                output_memory[clear_index] =
                    32'd0;

                output_memory_valid[clear_index] =
                    1'b0;

                output_write_count[clear_index] =
                    0;
            end
        end
    endtask

    task automatic issue_start (
        input logic [9:0] base_addr,
        input logic expected_error,
        input logic [2:0] expected_code
    );
        begin
            @(negedge clk_i);

            output_base_addr_i =
                base_addr;

            start_i =
                1'b1;

            #1;

            check_condition(
                start_ready_o === 1'b1,
                "writer was not start-ready"
            );

            @(posedge clk_i);
            #1;

            check_condition(
                error_o === expected_error,
                "start error response mismatch"
            );

            if (expected_error) begin
                check_condition(
                    error_code_o === expected_code,
                    "start error code mismatch"
                );

                check_condition(
                    busy_o === 1'b0,
                    "invalid writer command entered busy state"
                );
            end
            else begin
                check_condition(
                    busy_o === 1'b1,
                    "valid writer command did not enter busy state"
                );

                check_condition(
                    waiting_for_result_o === 1'b1,
                    "writer did not enter result-wait state"
                );
            end

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    task automatic pulse_capture (
        input logic [63:0] valid_mask
    );
        begin
            @(negedge clk_i);

            result_valid_i =
                valid_mask;

            capture_i =
                1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            capture_i =
                1'b0;
        end
    endtask

    assign output_write_ready_i =
        output_write_enable_o &
        allowed_ready_mask;

    assign output_write_conflict_i =
        output_write_enable_o &
        forced_conflict_mask;

    always_ff @(posedge clk_i) begin
        for (
            write_lane_index = 0;
            write_lane_index < 4;
            write_lane_index = write_lane_index + 1
        ) begin
            if (
                output_write_enable_o[write_lane_index] &&
                output_write_ready_i[write_lane_index] &&
                !output_write_conflict_i[write_lane_index]
            ) begin
                write_address =
                    output_write_addr_o[
                        (write_lane_index * 10) +:
                        10
                    ];

                output_memory[
                    write_address
                ] <=
                    output_write_data_o[
                        (write_lane_index * 32) +:
                        32
                    ];

                output_memory_valid[
                    write_address
                ] <=
                    1'b1;

                output_write_count[
                    write_address
                ] <=
                    output_write_count[
                        write_address
                    ] + 1;
            end
        end
    end

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        start_i = 1'b0;
        output_base_addr_i = '0;

        capture_i = 1'b0;
        result_data_i = '0;
        result_valid_i = '0;

        allowed_ready_mask   = 4'b1111;
        forced_conflict_mask = 4'b0000;

        check_count = 0;
        error_count = 0;

        clear_output_model();

        for (
            initialize_index = 0;
            initialize_index < 64;
            initialize_index = initialize_index + 1
        ) begin
            result_data_i[
                (initialize_index * 32) +:
                32
            ] =
                32'hC000_0000 +
                initialize_index;
        end

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "writer not ready after reset"
        );

        check_condition(
            busy_o === 1'b0,
            "writer busy after reset"
        );

        // Base 1000 cannot hold 64 output words.
        issue_start(
            10'd1000,
            1'b1,
            3'd1
        );

        // Invalid result mask.
        issue_start(
            10'd0,
            1'b0,
            3'd0
        );

        pulse_capture(
            64'hFFFF_FFFF_FFFF_FF7F
        );

        check_condition(
            error_o === 1'b1,
            "invalid result mask was not reported"
        );

        check_condition(
            error_code_o === 3'd2,
            "invalid-result error code mismatch"
        );

        check_condition(
            busy_o === 1'b0,
            "writer remained busy after invalid capture"
        );

        // Complete 64-word transfer.
        clear_output_model();

        issue_start(
            10'd100,
            1'b0,
            3'd0
        );

        allowed_ready_mask =
            4'b0000;

        pulse_capture(
            64'hFFFF_FFFF_FFFF_FFFF
        );

        #1;

        held_enable = output_write_enable_o;
        held_addr   = output_write_addr_o;
        held_data   = output_write_data_o;
        held_strb   = output_write_strb_o;

        repeat (3) begin
            @(posedge clk_i);
            #1;

            check_condition(
                output_write_enable_o === held_enable,
                "write enable changed during backpressure"
            );

            check_condition(
                output_write_addr_o === held_addr,
                "write address changed during backpressure"
            );

            check_condition(
                output_write_data_o === held_data,
                "write data changed during backpressure"
            );

            check_condition(
                output_write_strb_o === held_strb,
                "write strobe changed during backpressure"
            );

            check_condition(
                words_written_o === 7'd0,
                "writer counted an unaccepted word"
            );
        end

        // First batch: lanes 0, 2 and 3 are accepted; lane 1 conflicts.
        @(negedge clk_i);

        allowed_ready_mask =
            4'b1111;

        forced_conflict_mask =
            4'b0010;

        @(posedge clk_i);
        #1;

        check_condition(
            words_written_o === 7'd3,
            "partial first-batch count mismatch"
        );

        check_condition(
            output_write_count[100] == 1 &&
            output_write_count[102] == 1 &&
            output_write_count[103] == 1,
            "accepted first-batch lanes were not written"
        );

        check_condition(
            output_write_count[101] == 0,
            "conflicted lane was incorrectly written"
        );

        // Retry only lane 1.
        @(negedge clk_i);

        allowed_ready_mask =
            4'b0010;

        forced_conflict_mask =
            4'b0000;

        @(posedge clk_i);
        #1;

        check_condition(
            words_written_o === 7'd4,
            "first-batch completion count mismatch"
        );

        check_condition(
            output_write_count[101] == 1,
            "retried lane was not written exactly once"
        );

        @(negedge clk_i);
        allowed_ready_mask = 4'b1111;

        timeout_count = 0;

        while (
            done_o !== 1'b1 &&
            timeout_count < 100
        ) begin
            @(posedge clk_i);
            #1;

            timeout_count =
                timeout_count + 1;
        end

        check_condition(
            done_o === 1'b1,
            "64-word write completion timed out"
        );

        check_condition(
            words_written_o === 7'd64,
            "final written-word count mismatch"
        );

        check_condition(
            busy_o === 1'b0,
            "writer remained busy after completion"
        );

        check_condition(
            output_write_enable_o === 4'b0000,
            "write enables remained active after completion"
        );

        for (
            result_index = 0;
            result_index < 64;
            result_index = result_index + 1
        ) begin
            check_condition(
                output_memory_valid[
                    100 + result_index
                ] === 1'b1,
                "output word validity mismatch"
            );

            check_condition(
                output_memory[
                    100 + result_index
                ] ===
                (
                    32'hC000_0000 +
                    result_index
                ),
                "row-major output data mismatch"
            );

            check_condition(
                output_write_count[
                    100 + result_index
                ] == 1,
                "output word was not written exactly once"
            );
        end

        // Clear while waiting for result capture.
        issue_start(
            10'd300,
            1'b0,
            3'd0
        );

        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            busy_o === 1'b0,
            "clear did not cancel result wait"
        );

        check_condition(
            words_written_o === 7'd0,
            "clear did not reset written-word count"
        );

        @(negedge clk_i);
        clear_i = 1'b0;

        // Clear during active writes.
        issue_start(
            10'd400,
            1'b0,
            3'd0
        );

        allowed_ready_mask = 4'b1111;

        pulse_capture(
            64'hFFFF_FFFF_FFFF_FFFF
        );

        repeat (2) begin
            @(posedge clk_i);
            #1;
        end

        check_condition(
            words_written_o != 7'd0,
            "writer made no progress before clear"
        );

        @(negedge clk_i);
        clear_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            busy_o === 1'b0,
            "clear did not terminate active write"
        );

        check_condition(
            output_write_enable_o === 4'b0000,
            "write lanes remained active after clear"
        );

        check_condition(
            words_written_o === 7'd0,
            "clear did not reset active-write accounting"
        );

        @(negedge clk_i);
        clear_i = 1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "writer not ready after clear"
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor result writer passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tensor-result-writer errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
