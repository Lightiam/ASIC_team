`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_tensor_compute_csr;

    localparam logic [31:0] ADDR_LOADER_CONTROL =
        32'h0000_0500;

    localparam logic [31:0] ADDR_LOADER_STATUS =
        32'h0000_0504;

    localparam logic [31:0] ADDR_LOADER_CONFIG =
        32'h0000_0508;

    localparam logic [31:0] ADDR_LOADER_BASE =
        32'h0000_050C;

    localparam logic [31:0] ADDR_LOADER_WORD_COUNT =
        32'h0000_0510;

    localparam logic [31:0] ADDR_LOADER_WORDS_WRITTEN =
        32'h0000_0514;

    localparam logic [31:0] ADDR_STREAM_DATA_0 =
        32'h0000_0520;

    localparam logic [31:0] ADDR_STREAM_DATA_1 =
        32'h0000_0524;

    localparam logic [31:0] ADDR_STREAM_DATA_2 =
        32'h0000_0528;

    localparam logic [31:0] ADDR_STREAM_DATA_3 =
        32'h0000_052C;

    localparam logic [31:0] ADDR_STREAM_STROBE =
        32'h0000_0530;

    localparam logic [31:0] ADDR_STREAM_CONTROL =
        32'h0000_0534;

    localparam logic [31:0] ADDR_GEMM_ACTIVATION_BASE =
        32'h0000_0540;

    localparam logic [31:0] ADDR_GEMM_WEIGHT_BASE =
        32'h0000_0544;

    localparam logic [31:0] ADDR_GEMM_OUTPUT_BASE =
        32'h0000_0548;

    localparam logic [31:0] ADDR_GEMM_CONFIG =
        32'h0000_054C;

    localparam logic [31:0] ADDR_GEMM_CONTROL =
        32'h0000_0550;

    localparam logic [31:0] ADDR_GEMM_STATUS =
        32'h0000_0554;

    localparam logic [31:0] ADDR_GEMM_ERROR =
        32'h0000_0558;

    localparam logic [31:0] ADDR_GEMM_WORDS_LOADED =
        32'h0000_055C;

    localparam logic [31:0] ADDR_GEMM_WORDS_WRITTEN =
        32'h0000_0560;

    localparam logic [31:0] ADDR_RESULT_VALID_LOW =
        32'h0000_0564;

    localparam logic [31:0] ADDR_RESULT_VALID_HIGH =
        32'h0000_0568;

    localparam logic [31:0] ADDR_ARITHMETIC_SUMMARY =
        32'h0000_056C;

    localparam logic [31:0] ADDR_OUTPUT_READ_ADDRESS =
        32'h0000_0570;

    localparam logic [31:0] ADDR_OUTPUT_READ_CONTROL =
        32'h0000_0574;

    localparam logic [31:0] ADDR_OUTPUT_READ_DATA =
        32'h0000_0578;

    logic clk_i;
    logic rst_ni;

    logic write_valid_i;
    logic write_ready_o;
    logic [31:0] write_addr_i;
    logic [31:0] write_data_i;
    logic [3:0] write_strb_i;
    logic write_error_o;

    logic read_valid_i;
    logic read_ready_o;
    logic [31:0] read_addr_i;
    logic [31:0] read_data_o;
    logic read_error_o;

    logic tensor_clear_o;

    logic loader_start_o;
    logic loader_start_ready_i;
    logic [1:0] loader_target_o;
    logic [9:0] loader_base_addr_o;
    logic [10:0] loader_word_count_o;

    logic stream_valid_o;
    logic stream_ready_i;
    logic stream_last_o;
    logic [127:0] stream_data_o;
    logic [15:0] stream_strb_o;

    logic loader_busy_i;
    logic loader_done_i;
    logic loader_error_i;
    logic [2:0] loader_error_code_i;
    logic [10:0] loader_words_written_i;
    logic [1:0] loader_active_target_i;

    logic gemm_start_o;
    logic gemm_start_ready_i;

    logic [9:0] gemm_activation_base_addr_o;
    logic [9:0] gemm_weight_base_addr_o;
    logic [9:0] gemm_output_base_addr_o;

    logic [1:0] gemm_precision_o;
    logic [3:0] gemm_k_token_count_o;

    logic gemm_busy_i;
    logic gemm_compute_done_i;
    logic gemm_done_i;
    logic gemm_error_i;

    logic [1:0] gemm_error_source_i;
    logic [2:0] gemm_error_code_i;
    logic [2:0] gemm_error_detail_i;

    logic [10:0] gemm_words_loaded_i;
    logic [6:0] gemm_words_written_i;

    logic [63:0] gemm_result_valid_i;
    logic [63:0] gemm_invalid_i;
    logic [63:0] gemm_overflow_i;
    logic [63:0] gemm_underflow_i;
    logic [63:0] gemm_inexact_i;

    logic [3:0] output_read_enable_o;
    logic [39:0] output_read_addr_o;
    logic [3:0] output_read_ready_i;
    logic [3:0] output_read_conflict_i;
    logic [127:0] output_read_data_i;
    logic [3:0] output_read_valid_i;

    integer check_count;
    integer error_count;

    nce_axi_tensor_compute_csr dut (
        .*
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

    task automatic csr_write (
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [3:0] strobe,
        input logic expected_error
    );
        begin
            @(negedge clk_i);

            write_valid_i =
                1'b1;

            write_addr_i =
                address;

            write_data_i =
                data;

            write_strb_i =
                strobe;

            @(posedge clk_i);
            #1;

            check_condition(
                write_error_o === expected_error,
                "CSR write error response mismatch"
            );

            @(negedge clk_i);

            write_valid_i =
                1'b0;
        end
    endtask

    task automatic csr_read (
        input logic [31:0] address,
        input logic [31:0] expected_data,
        input logic expected_error
    );
        begin
            @(negedge clk_i);

            read_valid_i =
                1'b1;

            read_addr_i =
                address;

            #1;

            check_condition(
                read_error_o === expected_error,
                "CSR read error response mismatch"
            );

            if (!expected_error) begin
                check_condition(
                    read_data_o === expected_data,
                    "CSR read data mismatch"
                );

                if (read_data_o !== expected_data) begin
                    $display(
                        "  address=%08h data=%08h expected=%08h",
                        address,
                        read_data_o,
                        expected_data
                    );
                end
            end

            @(negedge clk_i);

            read_valid_i =
                1'b0;
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        write_valid_i = 1'b0;
        write_addr_i = 32'd0;
        write_data_i = 32'd0;
        write_strb_i = 4'd0;

        read_valid_i = 1'b0;
        read_addr_i = 32'd0;

        loader_start_ready_i = 1'b1;
        stream_ready_i = 1'b1;

        loader_busy_i = 1'b0;
        loader_done_i = 1'b0;
        loader_error_i = 1'b0;
        loader_error_code_i = 3'd0;
        loader_words_written_i = 11'd0;
        loader_active_target_i = 2'd0;

        gemm_start_ready_i = 1'b1;
        gemm_busy_i = 1'b0;
        gemm_compute_done_i = 1'b0;
        gemm_done_i = 1'b0;
        gemm_error_i = 1'b0;

        gemm_error_source_i = 2'd0;
        gemm_error_code_i = 3'd0;
        gemm_error_detail_i = 3'd0;

        gemm_words_loaded_i = 11'd0;
        gemm_words_written_i = 7'd0;

        gemm_result_valid_i = 64'd0;
        gemm_invalid_i = 64'd0;
        gemm_overflow_i = 64'd0;
        gemm_underflow_i = 64'd0;
        gemm_inexact_i = 64'd0;

        output_read_ready_i = 4'b1111;
        output_read_conflict_i = 4'd0;
        output_read_data_i = 128'd0;
        output_read_valid_i = 4'd0;

        check_count = 0;
        error_count = 0;

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            write_ready_o === 1'b1 &&
            read_ready_o === 1'b1,
            "CSR was not ready after reset"
        );

        // Alignment and strobe validation.
        csr_write(
            ADDR_LOADER_CONFIG + 32'd1,
            32'd0,
            4'b1111,
            1'b1
        );

        csr_write(
            ADDR_LOADER_CONFIG,
            32'd0,
            4'b0001,
            1'b1
        );

        // Loader configuration.
        csr_write(
            ADDR_LOADER_CONFIG,
            32'd1,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_LOADER_BASE,
            32'd100,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_LOADER_WORD_COUNT,
            32'd64,
            4'b1111,
            1'b0
        );

        csr_read(
            ADDR_LOADER_CONFIG,
            32'd1,
            1'b0
        );

        csr_read(
            ADDR_LOADER_BASE,
            32'd100,
            1'b0
        );

        csr_read(
            ADDR_LOADER_WORD_COUNT,
            32'd64,
            1'b0
        );

        // Loader start rejection and accepted pulse.
        loader_start_ready_i = 1'b0;

        csr_write(
            ADDR_LOADER_CONTROL,
            32'd1,
            4'b1111,
            1'b1
        );

        check_condition(
            loader_start_o === 1'b0,
            "Unavailable loader start was emitted"
        );

        loader_start_ready_i = 1'b1;

        csr_write(
            ADDR_LOADER_CONTROL,
            32'd1,
            4'b1111,
            1'b0
        );

        check_condition(
            loader_start_o === 1'b1,
            "Valid loader start was not emitted"
        );

        // Loader configuration must be protected while active.
        loader_busy_i = 1'b1;

        csr_write(
            ADDR_LOADER_BASE,
            32'd200,
            4'b1111,
            1'b1
        );

        // Stage and push one complete 128-bit stream beat.
        csr_write(
            ADDR_STREAM_DATA_0,
            32'h1111_1111,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_STREAM_DATA_1,
            32'h2222_2222,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_STREAM_DATA_2,
            32'h3333_3333,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_STREAM_DATA_3,
            32'h4444_4444,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_STREAM_STROBE,
            32'h0000_FFFF,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_STREAM_CONTROL,
            32'd3,
            4'b1111,
            1'b0
        );

        check_condition(
            stream_valid_o === 1'b1 &&
            stream_last_o === 1'b1 &&
            stream_data_o === {
                32'h4444_4444,
                32'h3333_3333,
                32'h2222_2222,
                32'h1111_1111
            } &&
            stream_strb_o === 16'hFFFF,
            "Staged stream beat was not emitted correctly"
        );

        // The first ready-high beat is consumed on the following clock.
        @(posedge clk_i);
        #1;

        check_condition(
            stream_valid_o === 1'b0,
            "Accepted stream beat did not complete its ready/valid handshake"
        );

        // Backpressure must not reject the software command. The CSR accepts
        // the beat and holds valid until downstream ready is asserted.
        stream_ready_i = 1'b0;

        csr_write(
            ADDR_STREAM_CONTROL,
            32'd1,
            4'b1111,
            1'b0
        );

        check_condition(
            stream_valid_o === 1'b1 &&
            stream_last_o === 1'b0,
            "Backpressured stream beat was not held valid"
        );

        repeat (2) begin
            @(posedge clk_i);
            #1;

            check_condition(
                stream_valid_o === 1'b1,
                "Backpressured stream valid was not held"
            );
        end

        // A second push cannot replace the held beat.
        csr_write(
            ADDR_STREAM_CONTROL,
            32'd1,
            4'b1111,
            1'b1
        );

        stream_ready_i = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            stream_valid_o === 1'b0,
            "Held stream beat did not clear after ready"
        );

        loader_busy_i = 1'b0;

        // Loader sticky status.
        loader_active_target_i = 2'd2;
        loader_words_written_i = 11'd64;

        @(negedge clk_i);
        loader_done_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        loader_done_i = 1'b0;

        @(negedge clk_i);
        loader_error_i = 1'b1;
        loader_error_code_i = 3'd5;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        loader_error_i = 1'b0;

        csr_read(
            ADDR_LOADER_STATUS,
            32'h0000_045D,
            1'b0
        );

        csr_read(
            ADDR_LOADER_WORDS_WRITTEN,
            32'd64,
            1'b0
        );

        csr_write(
            ADDR_LOADER_CONTROL,
            32'd4,
            4'b1111,
            1'b0
        );

        csr_read(
            ADDR_LOADER_STATUS,
            32'h0000_0401,
            1'b0
        );

        // GEMM configuration.
        csr_write(
            ADDR_GEMM_ACTIVATION_BASE,
            32'd20,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_GEMM_WEIGHT_BASE,
            32'd300,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_GEMM_OUTPUT_BASE,
            32'd700,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_GEMM_CONFIG,
            32'h0000_0081,
            4'b1111,
            1'b0
        );

        csr_read(
            ADDR_GEMM_ACTIVATION_BASE,
            32'd20,
            1'b0
        );

        csr_read(
            ADDR_GEMM_WEIGHT_BASE,
            32'd300,
            1'b0
        );

        csr_read(
            ADDR_GEMM_OUTPUT_BASE,
            32'd700,
            1'b0
        );

        csr_read(
            ADDR_GEMM_CONFIG,
            32'h0000_0081,
            1'b0
        );

        // GEMM start rejection and accepted pulse.
        gemm_start_ready_i = 1'b0;

        csr_write(
            ADDR_GEMM_CONTROL,
            32'd1,
            4'b1111,
            1'b1
        );

        check_condition(
            gemm_start_o === 1'b0,
            "Unavailable GEMM start was emitted"
        );

        gemm_start_ready_i = 1'b1;

        csr_write(
            ADDR_GEMM_CONTROL,
            32'd1,
            4'b1111,
            1'b0
        );

        check_condition(
            gemm_start_o === 1'b1,
            "Valid GEMM start was not emitted"
        );

        gemm_busy_i = 1'b1;

        csr_write(
            ADDR_GEMM_OUTPUT_BASE,
            32'd900,
            4'b1111,
            1'b1
        );

        gemm_busy_i = 1'b0;

        // GEMM completion, error, counters, masks, and flags.
        gemm_result_valid_i =
            64'hFFFF_FFFF_FFFF_FFFF;

        gemm_invalid_i =
            64'h1;

        gemm_overflow_i =
            64'h2;

        gemm_underflow_i =
            64'h4;

        gemm_inexact_i =
            64'h8;

        gemm_words_loaded_i =
            11'd128;

        gemm_words_written_i =
            7'd64;

        @(negedge clk_i);
        gemm_compute_done_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        gemm_compute_done_i = 1'b0;
        gemm_done_i = 1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        gemm_done_i = 1'b0;
        gemm_error_i = 1'b1;
        gemm_error_source_i = 2'd2;
        gemm_error_code_i = 3'd5;
        gemm_error_detail_i = 3'd3;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);
        gemm_error_i = 1'b0;

        csr_read(
            ADDR_GEMM_STATUS,
            32'h0000_F11D,
            1'b0
        );

        csr_read(
            ADDR_GEMM_ERROR,
            32'h0000_0352,
            1'b0
        );

        csr_read(
            ADDR_GEMM_WORDS_LOADED,
            32'd128,
            1'b0
        );

        csr_read(
            ADDR_GEMM_WORDS_WRITTEN,
            32'd64,
            1'b0
        );

        csr_read(
            ADDR_RESULT_VALID_LOW,
            32'hFFFF_FFFF,
            1'b0
        );

        csr_read(
            ADDR_RESULT_VALID_HIGH,
            32'hFFFF_FFFF,
            1'b0
        );

        csr_read(
            ADDR_ARITHMETIC_SUMMARY,
            32'h0000_000F,
            1'b0
        );

        // Single-word output-memory read. Accept the software request while
        // memory-ready is low and hold read-enable until acceptance.
        output_read_ready_i[0] =
            1'b0;

        csr_write(
            ADDR_OUTPUT_READ_ADDRESS,
            32'd77,
            4'b1111,
            1'b0
        );

        csr_write(
            ADDR_OUTPUT_READ_CONTROL,
            32'd1,
            4'b1111,
            1'b0
        );

        check_condition(
            output_read_enable_o === 4'b0001 &&
            output_read_addr_o[9:0] === 10'd77 &&
            output_read_addr_o[39:10] === 30'd0,
            "Output-memory read request mismatch"
        );

        repeat (2) begin
            @(posedge clk_i);
            #1;

            check_condition(
                output_read_enable_o[0] === 1'b1,
                "Backpressured output-read request was not held"
            );
        end

        @(negedge clk_i);

        output_read_ready_i[0] =
            1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            output_read_enable_o[0] === 1'b0,
            "Output-read request did not release after memory-ready"
        );

        @(negedge clk_i);

        output_read_data_i[31:0] =
            32'hDEAD_BEEF;

        output_read_valid_i[0] =
            1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);

        output_read_valid_i[0] =
            1'b0;

        csr_read(
            ADDR_OUTPUT_READ_CONTROL,
            32'h0000_0015,
            1'b0
        );

        csr_read(
            ADDR_OUTPUT_READ_DATA,
            32'hDEAD_BEEF,
            1'b0
        );

        csr_write(
            ADDR_OUTPUT_READ_CONTROL,
            32'd2,
            4'b1111,
            1'b0
        );

        csr_read(
            ADDR_OUTPUT_READ_CONTROL,
            32'h0000_0011,
            1'b0
        );

        // Output reads are blocked while GEMM is active.
        gemm_busy_i = 1'b1;

        csr_write(
            ADDR_OUTPUT_READ_CONTROL,
            32'd1,
            4'b1111,
            1'b1
        );

        gemm_busy_i = 1'b0;

        // Exercise output-read conflict status.
        csr_write(
            ADDR_OUTPUT_READ_CONTROL,
            32'd1,
            4'b1111,
            1'b0
        );

        @(negedge clk_i);

        output_read_conflict_i[0] =
            1'b1;

        @(posedge clk_i);
        #1;

        @(negedge clk_i);

        output_read_conflict_i[0] =
            1'b0;

        csr_read(
            ADDR_OUTPUT_READ_CONTROL,
            32'h0000_0019,
            1'b0
        );

        // Unsupported accesses.
        csr_read(
            32'h0000_057C,
            32'd0,
            1'b1
        );

        csr_write(
            32'h0000_057C,
            32'd0,
            4'b1111,
            1'b1
        );

        // Full clear from either control register clears all local context.
        csr_write(
            ADDR_GEMM_CONTROL,
            32'd2,
            4'b1111,
            1'b0
        );

        check_condition(
            tensor_clear_o === 1'b1,
            "Tensor subsystem clear pulse was not emitted"
        );

        csr_read(
            ADDR_GEMM_ERROR,
            32'd0,
            1'b0
        );

        csr_read(
            ADDR_OUTPUT_READ_DATA,
            32'd0,
            1'b0
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor-compute CSR passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tensor-compute CSR errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
