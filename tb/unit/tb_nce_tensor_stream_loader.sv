`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_stream_loader;

    localparam int unsigned PORT_COUNT      = 4;
    localparam int unsigned DATA_WIDTH      = 32;
    localparam int unsigned BYTE_COUNT      = 4;
    localparam int unsigned FLAT_ADDR_WIDTH = 10;
    localparam int unsigned COUNT_WIDTH     = 11;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic start_i;
    logic start_ready_o;
    logic [FLAT_ADDR_WIDTH-1:0] base_addr_i;
    logic [COUNT_WIDTH-1:0] word_count_i;

    logic stream_valid_i;
    logic stream_ready_o;
    logic stream_last_i;
    logic [127:0] stream_data_i;
    logic [15:0] stream_strb_i;

    logic [3:0] loader_write_enable;
    logic [39:0] loader_write_addr;
    logic [127:0] loader_write_data;
    logic [15:0] loader_write_strb;
    logic [3:0] loader_write_ready;

    logic busy_o;
    logic done_o;
    logic error_o;
    logic [2:0] error_code_o;
    logic [COUNT_WIDTH-1:0] words_written_o;

    logic [3:0] scratch_write_enable;
    logic [3:0] scratch_write_ready;
    logic [3:0] scratch_write_conflict;

    logic [3:0] memory_accept_mask;

    logic [3:0] read_enable;
    logic [39:0] read_addr;
    logic [3:0] read_ready;
    logic [3:0] read_conflict;
    logic [127:0] read_data;
    logic [3:0] read_valid;

    integer check_count;
    integer error_count;

    assign loader_write_ready =
        scratch_write_ready &
        memory_accept_mask;

    assign scratch_write_enable =
        loader_write_enable &
        memory_accept_mask;

    nce_tensor_stream_loader dut (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .start_i                (start_i),
        .start_ready_o          (start_ready_o),
        .base_addr_i            (base_addr_i),
        .word_count_i           (word_count_i),

        .stream_valid_i         (stream_valid_i),
        .stream_ready_o         (stream_ready_o),
        .stream_last_i          (stream_last_i),
        .stream_data_i          (stream_data_i),
        .stream_strb_i          (stream_strb_i),

        .memory_write_enable_o  (loader_write_enable),
        .memory_write_addr_o    (loader_write_addr),
        .memory_write_data_o    (loader_write_data),
        .memory_write_strb_o    (loader_write_strb),
        .memory_write_ready_i   (loader_write_ready),

        .busy_o                 (busy_o),
        .done_o                 (done_o),
        .error_o                (error_o),
        .error_code_o           (error_code_o),
        .words_written_o        (words_written_o)
    );

    nce_tensor_scratchpad u_memory (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),

        .read_enable_i     (read_enable),
        .read_addr_i       (read_addr),
        .read_ready_o      (read_ready),
        .read_conflict_o   (read_conflict),
        .read_data_o       (read_data),
        .read_valid_o      (read_valid),

        .write_enable_i    (scratch_write_enable),
        .write_addr_i      (loader_write_addr),
        .write_data_i      (loader_write_data),
        .write_strb_i      (loader_write_strb),
        .write_ready_o     (scratch_write_ready),
        .write_conflict_o  (scratch_write_conflict)
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

    task automatic pulse_clear;
        begin
            @(negedge clk_i);
            clear_i = 1'b1;

            @(posedge clk_i);
            #1;

            check_condition(
                busy_o === 1'b0,
                "loader remained busy during clear"
            );

            @(negedge clk_i);
            clear_i = 1'b0;

            @(posedge clk_i);
            #1;
        end
    endtask

    task automatic start_transfer (
        input logic [9:0] address,
        input logic [10:0] count,
        input logic expected_error,
        input logic [2:0] expected_code
    );
        begin
            @(negedge clk_i);

            check_condition(
                start_ready_o === 1'b1,
                "loader was not ready for transfer command"
            );

            start_i      = 1'b1;
            base_addr_i  = address;
            word_count_i = count;

            @(posedge clk_i);
            #1;

            check_condition(
                error_o === expected_error,
                "transfer-command error mismatch"
            );

            if (expected_error) begin
                check_condition(
                    error_code_o === expected_code,
                    "transfer-command error code mismatch"
                );

                check_condition(
                    busy_o === 1'b0,
                    "invalid transfer entered busy state"
                );
            end
            else begin
                check_condition(
                    busy_o === 1'b1,
                    "valid transfer did not enter busy state"
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
        input logic expected_done,
        input logic expected_error,
        input logic [2:0] expected_code
    );

        integer timeout_count;

        begin
            @(negedge clk_i);

            stream_valid_i = 1'b1;
            stream_data_i  = data;
            stream_strb_i  = strobe;
            stream_last_i  = last_value;

            timeout_count = 0;

            // Allow valid, data, last and strobes to propagate through the
            // combinational ready path before evaluating the handshake.
            #1;

            // Wait only at negative edges while ready is low. No transfer can
            // occur at those edges, so an accepted beat cannot be missed and
            // accidentally submitted a second time.
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
                "stream beat timed out waiting for ready"
            );

            // Exactly one valid/ready transfer occurs on this positive edge.
            @(posedge clk_i);
            #1;



            check_condition(
                done_o === expected_done,
                "stream-beat done response mismatch"
            );

            check_condition(
                error_o === expected_error,
                "stream-beat error response mismatch"
            );

            if (expected_error) begin
                check_condition(
                    error_code_o === expected_code,
                    "stream-beat error code mismatch"
                );
            end

            @(negedge clk_i);

            stream_valid_i = 1'b0;
            stream_data_i  = '0;
            stream_strb_i  = '0;
            stream_last_i  = 1'b0;
        end
    endtask

    task automatic read_word (
        input logic [9:0] address,
        input logic expected_valid,
        input logic [31:0] expected_data,
        input string phase
    );
        begin
            @(negedge clk_i);

            read_enable = 4'b0001;
            read_addr   = {
                10'd0,
                10'd0,
                10'd0,
                address
            };

            #1;

            check_condition(
                read_ready[0] === 1'b1,
                $sformatf("%s read was not accepted", phase)
            );

            @(posedge clk_i);
            #1;

            check_condition(
                read_valid[0] === expected_valid,
                $sformatf("%s valid mismatch", phase)
            );

            check_condition(
                read_data[31:0] === expected_data,
                $sformatf("%s data mismatch", phase)
            );

            if (read_data[31:0] !== expected_data) begin
                $display(
                    "  address=%0d data=%08h expected=%08h",
                    address,
                    read_data[31:0],
                    expected_data
                );
            end

            @(negedge clk_i);

            read_enable = '0;
            read_addr   = '0;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        start_i      = 1'b0;
        base_addr_i  = '0;
        word_count_i = '0;

        stream_valid_i = 1'b0;
        stream_last_i  = 1'b0;
        stream_data_i  = '0;
        stream_strb_i  = '0;

        memory_accept_mask = 4'hF;

        read_enable = '0;
        read_addr   = '0;

        check_count = 0;
        error_count = 0;

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            start_ready_o === 1'b1,
            "loader was not ready after reset"
        );

        check_condition(
            busy_o === 1'b0 &&
            done_o === 1'b0 &&
            error_o === 1'b0,
            "loader reset status mismatch"
        );

        // Invalid command: zero transfer length.
        start_transfer(
            10'd0,
            11'd0,
            1'b1,
            3'd1
        );

        // Invalid command: address range exceeds 1024 words.
        start_transfer(
            10'd1020,
            11'd8,
            1'b1,
            3'd2
        );

        // ---------------------------------------------------------------------
        // Aligned 8-word load: two complete four-word beats.
        // ---------------------------------------------------------------------

        pulse_clear();

        start_transfer(
            10'd0,
            11'd8,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'h0000_0004,
                32'h0000_0003,
                32'h0000_0002,
                32'h0000_0001
            },
            16'hFFFF,
            1'b0,
            1'b0,
            1'b0,
            3'd0
        );

        check_condition(
            words_written_o === 11'd4,
            "first beat word count mismatch"
        );

        send_beat(
            {
                32'h0000_0008,
                32'h0000_0007,
                32'h0000_0006,
                32'h0000_0005
            },
            16'hFFFF,
            1'b1,
            1'b1,
            1'b0,
            3'd0
        );

        check_condition(
            words_written_o === 11'd8 &&
            busy_o === 1'b0,
            "completed aligned-load accounting mismatch"
        );

        read_word(10'd0, 1'b1, 32'd1, "aligned word 0");
        read_word(10'd1, 1'b1, 32'd2, "aligned word 1");
        read_word(10'd2, 1'b1, 32'd3, "aligned word 2");
        read_word(10'd3, 1'b1, 32'd4, "aligned word 3");
        read_word(10'd4, 1'b1, 32'd5, "aligned word 4");
        read_word(10'd5, 1'b1, 32'd6, "aligned word 5");
        read_word(10'd6, 1'b1, 32'd7, "aligned word 6");
        read_word(10'd7, 1'b1, 32'd8, "aligned word 7");

        // ---------------------------------------------------------------------
        // Unaligned six-word transfer crossing rows and banks.
        // ---------------------------------------------------------------------

        pulse_clear();

        start_transfer(
            10'd3,
            11'd6,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd13,
                32'd12,
                32'd11,
                32'd10
            },
            16'hFFFF,
            1'b0,
            1'b0,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'hDEAD_BEEF,
                32'hDEAD_BEEF,
                32'd15,
                32'd14
            },
            16'h00FF,
            1'b1,
            1'b1,
            1'b0,
            3'd0
        );

        read_word(10'd3, 1'b1, 32'd10, "unaligned word 3");
        read_word(10'd4, 1'b1, 32'd11, "unaligned word 4");
        read_word(10'd5, 1'b1, 32'd12, "unaligned word 5");
        read_word(10'd6, 1'b1, 32'd13, "unaligned word 6");
        read_word(10'd7, 1'b1, 32'd14, "unaligned word 7");
        read_word(10'd8, 1'b1, 32'd15, "unaligned word 8");
        read_word(10'd9, 1'b0, 32'd0,  "inactive tail lane");

        // ---------------------------------------------------------------------
        // Partial byte strobes.
        // ---------------------------------------------------------------------

        pulse_clear();

        start_transfer(
            10'd20,
            11'd2,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd0,
                32'd0,
                32'h1122_3344,
                32'hAABB_CCDD
            },
            {
                4'h0,
                4'h0,
                4'b0011,
                4'b0101
            },
            1'b1,
            1'b1,
            1'b0,
            3'd0
        );

        read_word(
            10'd20,
            1'b1,
            32'h00BB_00DD,
            "partial strobe word 20"
        );

        read_word(
            10'd21,
            1'b1,
            32'h0000_3344,
            "partial strobe word 21"
        );

        // ---------------------------------------------------------------------
        // Downstream backpressure.
        // ---------------------------------------------------------------------

        pulse_clear();

        start_transfer(
            10'd40,
            11'd4,
            1'b0,
            3'd0
        );

        memory_accept_mask = 4'h0;

        @(negedge clk_i);

        stream_valid_i = 1'b1;
        stream_last_i  = 1'b1;
        stream_data_i  = {
            32'd44,
            32'd43,
            32'd42,
            32'd41
        };
        stream_strb_i = 16'hFFFF;

        repeat (3) begin
            @(posedge clk_i);
            #1;

            check_condition(
                stream_ready_o === 1'b0,
                "loader ignored downstream backpressure"
            );

            check_condition(
                words_written_o === 11'd0,
                "word count advanced during backpressure"
            );
        end

        @(negedge clk_i);
        memory_accept_mask = 4'hF;

        #1;

        check_condition(
            stream_ready_o === 1'b1,
            "loader did not recover after backpressure"
        );

        @(posedge clk_i);
        #1;

        check_condition(
            done_o === 1'b1 &&
            words_written_o === 11'd4,
            "backpressured transfer completion mismatch"
        );

        @(negedge clk_i);

        stream_valid_i = 1'b0;
        stream_last_i  = 1'b0;
        stream_data_i  = '0;
        stream_strb_i  = '0;

        read_word(10'd40, 1'b1, 32'd41, "backpressure word 40");
        read_word(10'd41, 1'b1, 32'd42, "backpressure word 41");
        read_word(10'd42, 1'b1, 32'd43, "backpressure word 42");
        read_word(10'd43, 1'b1, 32'd44, "backpressure word 43");

        // ---------------------------------------------------------------------
        // Early stream_last must abort without writing the beat.
        // ---------------------------------------------------------------------

        pulse_clear();

        start_transfer(
            10'd100,
            11'd8,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd4,
                32'd3,
                32'd2,
                32'd1
            },
            16'hFFFF,
            1'b1,
            1'b0,
            1'b1,
            3'd3
        );

        read_word(
            10'd100,
            1'b0,
            32'd0,
            "early-last write suppression"
        );

        // Missing stream_last on the final beat.
        pulse_clear();

        start_transfer(
            10'd120,
            11'd3,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd0,
                32'd3,
                32'd2,
                32'd1
            },
            16'h0FFF,
            1'b0,
            1'b0,
            1'b1,
            3'd4
        );

        read_word(
            10'd120,
            1'b0,
            32'd0,
            "missing-last write suppression"
        );

        // Zero strobe on an active word.
        pulse_clear();

        start_transfer(
            10'd140,
            11'd2,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd0,
                32'd0,
                32'h2222_2222,
                32'h1111_1111
            },
            {
                4'h0,
                4'h0,
                4'h0,
                4'hF
            },
            1'b1,
            1'b0,
            1'b1,
            3'd5
        );

        read_word(
            10'd140,
            1'b0,
            32'd0,
            "zero-strobe write suppression"
        );

        // Maximum legal range.
        pulse_clear();

        start_transfer(
            10'd1021,
            11'd3,
            1'b0,
            3'd0
        );

        send_beat(
            {
                32'd0,
                32'd103,
                32'd102,
                32'd101
            },
            16'h0FFF,
            1'b1,
            1'b1,
            1'b0,
            3'd0
        );

        read_word(10'd1021, 1'b1, 32'd101, "maximum word 1021");
        read_word(10'd1022, 1'b1, 32'd102, "maximum word 1022");
        read_word(10'd1023, 1'b1, 32'd103, "maximum word 1023");

        if (error_count == 0) begin
            $display(
                "PASS: tensor stream loader passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d loader errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end



endmodule

`default_nettype wire
