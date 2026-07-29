`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_memory_subsystem;

    localparam logic [1:0] TARGET_ACTIVATION = 2'd0;
    localparam logic [1:0] TARGET_WEIGHT     = 2'd1;
    localparam logic [1:0] TARGET_OUTPUT     = 2'd2;
    localparam logic [1:0] TARGET_INVALID    = 2'd3;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic start_i;
    logic start_ready_o;
    logic [1:0] load_target_i;
    logic [9:0] base_addr_i;
    logic [10:0] word_count_i;

    logic stream_valid_i;
    logic stream_ready_o;
    logic stream_last_i;
    logic [127:0] stream_data_i;
    logic [15:0] stream_strb_i;

    logic busy_o;
    logic done_o;
    logic error_o;
    logic [2:0] error_code_o;
    logic [10:0] words_written_o;
    logic [1:0] active_target_o;

    logic [3:0] activation_read_enable_i;
    logic [39:0] activation_read_addr_i;
    logic [3:0] activation_read_ready_o;
    logic [3:0] activation_read_conflict_o;
    logic [127:0] activation_read_data_o;
    logic [3:0] activation_read_valid_o;

    logic [3:0] weight_read_enable_i;
    logic [39:0] weight_read_addr_i;
    logic [3:0] weight_read_ready_o;
    logic [3:0] weight_read_conflict_o;
    logic [127:0] weight_read_data_o;
    logic [3:0] weight_read_valid_o;

    logic [3:0] output_read_enable_i;
    logic [39:0] output_read_addr_i;
    logic [3:0] output_read_ready_o;
    logic [3:0] output_read_conflict_o;
    logic [127:0] output_read_data_o;
    logic [3:0] output_read_valid_o;

    logic [3:0] output_write_enable_i;
    logic [39:0] output_write_addr_i;
    logic [127:0] output_write_data_i;
    logic [15:0] output_write_strb_i;
    logic [3:0] output_write_ready_o;
    logic [3:0] output_write_conflict_o;

    integer check_count;
    integer error_count;

    nce_tensor_memory_subsystem dut (
        .clk_i                        (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .start_i                     (start_i),
        .start_ready_o               (start_ready_o),
        .load_target_i               (load_target_i),
        .base_addr_i                 (base_addr_i),
        .word_count_i                (word_count_i),

        .stream_valid_i              (stream_valid_i),
        .stream_ready_o              (stream_ready_o),
        .stream_last_i               (stream_last_i),
        .stream_data_i               (stream_data_i),
        .stream_strb_i               (stream_strb_i),

        .busy_o                      (busy_o),
        .done_o                      (done_o),
        .error_o                     (error_o),
        .error_code_o                (error_code_o),
        .words_written_o             (words_written_o),
        .active_target_o             (active_target_o),

        .activation_read_enable_i    (activation_read_enable_i),
        .activation_read_addr_i      (activation_read_addr_i),
        .activation_read_ready_o     (activation_read_ready_o),
        .activation_read_conflict_o  (activation_read_conflict_o),
        .activation_read_data_o      (activation_read_data_o),
        .activation_read_valid_o     (activation_read_valid_o),

        .weight_read_enable_i        (weight_read_enable_i),
        .weight_read_addr_i          (weight_read_addr_i),
        .weight_read_ready_o         (weight_read_ready_o),
        .weight_read_conflict_o      (weight_read_conflict_o),
        .weight_read_data_o          (weight_read_data_o),
        .weight_read_valid_o         (weight_read_valid_o),

        .output_read_enable_i        (output_read_enable_i),
        .output_read_addr_i          (output_read_addr_i),
        .output_read_ready_o         (output_read_ready_o),
        .output_read_conflict_o      (output_read_conflict_o),
        .output_read_data_o          (output_read_data_o),
        .output_read_valid_o         (output_read_valid_o),

        .output_write_enable_i       (output_write_enable_i),
        .output_write_addr_i         (output_write_addr_i),
        .output_write_data_i         (output_write_data_i),
        .output_write_strb_i         (output_write_strb_i),
        .output_write_ready_o        (output_write_ready_o),
        .output_write_conflict_o     (output_write_conflict_o)
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

    task automatic start_load (
        input logic [1:0] target,
        input logic [9:0] address,
        input logic [10:0] count,
        input logic expected_error,
        input logic [2:0] expected_code
    );
        begin
            @(negedge clk_i);

            check_condition(
                start_ready_o === 1'b1,
                "memory subsystem was not start-ready"
            );

            start_i       = 1'b1;
            load_target_i = target;
            base_addr_i   = address;
            word_count_i  = count;

            @(posedge clk_i);
            #1;

            check_condition(
                error_o === expected_error,
                "load-command error mismatch"
            );

            if (expected_error) begin
                check_condition(
                    error_code_o === expected_code,
                    "load-command error code mismatch"
                );

                check_condition(
                    busy_o === 1'b0,
                    "invalid load entered busy state"
                );
            end
            else begin
                check_condition(
                    busy_o === 1'b1,
                    "valid load did not enter busy state"
                );

                check_condition(
                    active_target_o === target,
                    "active load target mismatch"
                );
            end

            @(negedge clk_i);
            start_i = 1'b0;
        end
    endtask

    task automatic send_beat (
        input logic [127:0] data,
        input logic [15:0] strobe,
        input logic last_value,
        input logic expected_done
    );
        integer timeout_count;
        begin
            @(negedge clk_i);

            stream_valid_i = 1'b1;
            stream_data_i  = data;
            stream_strb_i  = strobe;
            stream_last_i  = last_value;

            #1;
            timeout_count = 0;

            while (
                stream_ready_o !== 1'b1 &&
                timeout_count < 50
            ) begin
                @(negedge clk_i);
                #1;
                timeout_count = timeout_count + 1;
            end

            check_condition(
                stream_ready_o === 1'b1,
                "stream beat timed out"
            );

            @(posedge clk_i);
            #1;

            check_condition(
                done_o === expected_done,
                "stream completion mismatch"
            );

            check_condition(
                error_o === 1'b0,
                "unexpected stream error"
            );

            @(negedge clk_i);

            stream_valid_i = 1'b0;
            stream_data_i  = '0;
            stream_strb_i  = '0;
            stream_last_i  = 1'b0;
        end
    endtask

    task automatic read_word (
        input logic [1:0] target,
        input logic [9:0] address,
        input logic expected_valid,
        input logic [31:0] expected_data,
        input string phase
    );
        begin
            @(negedge clk_i);

            case (target)
                TARGET_ACTIVATION: begin
                    activation_read_enable_i = 4'b0001;
                    activation_read_addr_i = {
                        10'd0, 10'd0, 10'd0, address
                    };
                end

                TARGET_WEIGHT: begin
                    weight_read_enable_i = 4'b0001;
                    weight_read_addr_i = {
                        10'd0, 10'd0, 10'd0, address
                    };
                end

                default: begin
                    output_read_enable_i = 4'b0001;
                    output_read_addr_i = {
                        10'd0, 10'd0, 10'd0, address
                    };
                end
            endcase

            #1;

            case (target)
                TARGET_ACTIVATION: begin
                    check_condition(
                        activation_read_ready_o[0] === 1'b1,
                        $sformatf("%s activation read not accepted", phase)
                    );
                end

                TARGET_WEIGHT: begin
                    check_condition(
                        weight_read_ready_o[0] === 1'b1,
                        $sformatf("%s weight read not accepted", phase)
                    );
                end

                default: begin
                    check_condition(
                        output_read_ready_o[0] === 1'b1,
                        $sformatf("%s output read not accepted", phase)
                    );
                end
            endcase

            @(posedge clk_i);
            #1;

            case (target)
                TARGET_ACTIVATION: begin
                    check_condition(
                        activation_read_valid_o[0] === expected_valid,
                        $sformatf("%s activation valid mismatch", phase)
                    );

                    check_condition(
                        activation_read_data_o[31:0] === expected_data,
                        $sformatf("%s activation data mismatch", phase)
                    );
                end

                TARGET_WEIGHT: begin
                    check_condition(
                        weight_read_valid_o[0] === expected_valid,
                        $sformatf("%s weight valid mismatch", phase)
                    );

                    check_condition(
                        weight_read_data_o[31:0] === expected_data,
                        $sformatf("%s weight data mismatch", phase)
                    );
                end

                default: begin
                    check_condition(
                        output_read_valid_o[0] === expected_valid,
                        $sformatf("%s output valid mismatch", phase)
                    );

                    check_condition(
                        output_read_data_o[31:0] === expected_data,
                        $sformatf("%s output data mismatch", phase)
                    );
                end
            endcase

            @(negedge clk_i);

            activation_read_enable_i = '0;
            activation_read_addr_i   = '0;
            weight_read_enable_i     = '0;
            weight_read_addr_i       = '0;
            output_read_enable_i     = '0;
            output_read_addr_i       = '0;
        end
    endtask

    task automatic clear_all;
        begin
            @(negedge clk_i);
            clear_i = 1'b1;

            @(posedge clk_i);
            #1;

            check_condition(
                busy_o === 1'b0,
                "subsystem remained busy during clear"
            );

            @(negedge clk_i);
            clear_i = 1'b0;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        start_i       = 1'b0;
        load_target_i = TARGET_ACTIVATION;
        base_addr_i   = '0;
        word_count_i  = '0;

        stream_valid_i = 1'b0;
        stream_last_i  = 1'b0;
        stream_data_i  = '0;
        stream_strb_i  = '0;

        activation_read_enable_i = '0;
        activation_read_addr_i   = '0;
        weight_read_enable_i     = '0;
        weight_read_addr_i       = '0;
        output_read_enable_i     = '0;
        output_read_addr_i       = '0;

        output_write_enable_i = '0;
        output_write_addr_i   = '0;
        output_write_data_i   = '0;
        output_write_strb_i   = '0;

        check_count = 0;
        error_count = 0;

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "subsystem was not ready after reset"
        );

        // Invalid target must be rejected locally.
        start_load(
            TARGET_INVALID,
            10'd0,
            11'd4,
            1'b1,
            3'd6
        );

        clear_all();

        // ---------------------------------------------------------------------
        // Activation load: six words from address one.
        // ---------------------------------------------------------------------

        start_load(
            TARGET_ACTIVATION,
            10'd1,
            11'd6,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd14,
                32'd13,
                32'd12,
                32'd11
            },
            16'hFFFF,
            1'b0,
            1'b0
        );

        send_beat(
            {
                32'd0,
                32'd0,
                32'd16,
                32'd15
            },
            16'h00FF,
            1'b1,
            1'b1
        );

        read_word(
            TARGET_ACTIVATION,
            10'd1,
            1'b1,
            32'd11,
            "activation word 1"
        );

        read_word(
            TARGET_ACTIVATION,
            10'd6,
            1'b1,
            32'd16,
            "activation word 6"
        );

        read_word(
            TARGET_WEIGHT,
            10'd1,
            1'b0,
            32'd0,
            "activation/weight isolation"
        );

        // ---------------------------------------------------------------------
        // Weight load.
        // ---------------------------------------------------------------------

        start_load(
            TARGET_WEIGHT,
            10'd20,
            11'd4,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'hA000_0004,
                32'hA000_0003,
                32'hA000_0002,
                32'hA000_0001
            },
            16'hFFFF,
            1'b1,
            1'b1
        );

        read_word(
            TARGET_WEIGHT,
            10'd20,
            1'b1,
            32'hA000_0001,
            "weight word 20"
        );

        read_word(
            TARGET_OUTPUT,
            10'd20,
            1'b0,
            32'd0,
            "weight/output isolation"
        );

        // ---------------------------------------------------------------------
        // Output memory load.
        // ---------------------------------------------------------------------

        start_load(
            TARGET_OUTPUT,
            10'd40,
            11'd3,
            1'b0,
            3'd0
        );

        // Compute output writes must be blocked while loader owns output.
        @(negedge clk_i);

        output_write_enable_i = 4'b0001;
        output_write_addr_i = {
            10'd0, 10'd0, 10'd0, 10'd100
        };
        output_write_data_i = {
            32'd0, 32'd0, 32'd0, 32'hBAD0_BAD0
        };
        output_write_strb_i = {
            4'h0, 4'h0, 4'h0, 4'hF
        };

        #1;

        check_condition(
            output_write_ready_o === 4'b0000,
            "compute output write accepted during output load"
        );

        check_condition(
            output_write_conflict_o === 4'b0001,
            "blocked output write conflict was not reported"
        );

        output_write_enable_i = '0;
        output_write_addr_i   = '0;
        output_write_data_i   = '0;
        output_write_strb_i   = '0;

        send_beat(
            {
                32'd0,
                32'hC000_0003,
                32'hC000_0002,
                32'hC000_0001
            },
            16'h0FFF,
            1'b1,
            1'b1
        );

        read_word(
            TARGET_OUTPUT,
            10'd40,
            1'b1,
            32'hC000_0001,
            "loaded output word 40"
        );

        read_word(
            TARGET_OUTPUT,
            10'd100,
            1'b0,
            32'd0,
            "blocked compute write suppression"
        );

        // ---------------------------------------------------------------------
        // Compute-side four-word output write while loader is idle.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        output_write_enable_i = 4'b1111;
        output_write_addr_i = {
            10'd203,
            10'd202,
            10'd201,
            10'd200
        };
        output_write_data_i = {
            32'hD000_0004,
            32'hD000_0003,
            32'hD000_0002,
            32'hD000_0001
        };
        output_write_strb_i = 16'hFFFF;

        #1;

        check_condition(
            output_write_ready_o === 4'b1111,
            "idle output write was not accepted"
        );

        check_condition(
            output_write_conflict_o === 4'b0000,
            "unexpected idle output-write conflict"
        );

        @(posedge clk_i);
        #1;

        @(negedge clk_i);

        output_write_enable_i = '0;
        output_write_addr_i   = '0;
        output_write_data_i   = '0;
        output_write_strb_i   = '0;

        read_word(
            TARGET_OUTPUT,
            10'd200,
            1'b1,
            32'hD000_0001,
            "compute output word 200"
        );

        read_word(
            TARGET_OUTPUT,
            10'd203,
            1'b1,
            32'hD000_0004,
            "compute output word 203"
        );

        // ---------------------------------------------------------------------
        // Output compute writes may run while activation loading is active.
        // ---------------------------------------------------------------------

        start_load(
            TARGET_ACTIVATION,
            10'd300,
            11'd4,
            1'b0,
            3'd0
        );

        @(negedge clk_i);

        output_write_enable_i = 4'b1111;
        output_write_addr_i = {
            10'd303,
            10'd302,
            10'd301,
            10'd300
        };
        output_write_data_i = {
            32'hE000_0004,
            32'hE000_0003,
            32'hE000_0002,
            32'hE000_0001
        };
        output_write_strb_i = 16'hFFFF;

        #1;

        check_condition(
            output_write_ready_o === 4'b1111,
            "output compute write blocked by activation load"
        );

        @(posedge clk_i);
        #1;

        @(negedge clk_i);

        output_write_enable_i = '0;
        output_write_addr_i   = '0;
        output_write_data_i   = '0;
        output_write_strb_i   = '0;

        send_beat(
            {
                32'hF000_0004,
                32'hF000_0003,
                32'hF000_0002,
                32'hF000_0001
            },
            16'hFFFF,
            1'b1,
            1'b1
        );

        read_word(
            TARGET_ACTIVATION,
            10'd300,
            1'b1,
            32'hF000_0001,
            "parallel activation load"
        );

        read_word(
            TARGET_OUTPUT,
            10'd300,
            1'b1,
            32'hE000_0001,
            "parallel output compute write"
        );

        // ---------------------------------------------------------------------
        // Simultaneous independent reads from all three regions.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        activation_read_enable_i = 4'b0001;
        activation_read_addr_i = {
            10'd0, 10'd0, 10'd0, 10'd1
        };

        weight_read_enable_i = 4'b0001;
        weight_read_addr_i = {
            10'd0, 10'd0, 10'd0, 10'd20
        };

        output_read_enable_i = 4'b0001;
        output_read_addr_i = {
            10'd0, 10'd0, 10'd0, 10'd200
        };

        #1;

        check_condition(
            activation_read_ready_o[0] &&
            weight_read_ready_o[0] &&
            output_read_ready_o[0],
            "independent simultaneous reads were not accepted"
        );

        @(posedge clk_i);
        #1;

        check_condition(
            activation_read_valid_o[0] &&
            weight_read_valid_o[0] &&
            output_read_valid_o[0],
            "independent simultaneous reads were not valid"
        );

        check_condition(
            activation_read_data_o[31:0] === 32'd11,
            "simultaneous activation read mismatch"
        );

        check_condition(
            weight_read_data_o[31:0] === 32'hA000_0001,
            "simultaneous weight read mismatch"
        );

        check_condition(
            output_read_data_o[31:0] === 32'hD000_0001,
            "simultaneous output read mismatch"
        );

        @(negedge clk_i);

        activation_read_enable_i = '0;
        weight_read_enable_i     = '0;
        output_read_enable_i     = '0;

        // Global clear invalidates all three regions.
        clear_all();

        read_word(
            TARGET_ACTIVATION,
            10'd1,
            1'b0,
            32'd0,
            "activation post-clear"
        );

        read_word(
            TARGET_WEIGHT,
            10'd20,
            1'b0,
            32'd0,
            "weight post-clear"
        );

        read_word(
            TARGET_OUTPUT,
            10'd200,
            1'b0,
            32'd0,
            "output post-clear"
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor memory subsystem passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d memory-subsystem errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end




endmodule

`default_nettype wire
