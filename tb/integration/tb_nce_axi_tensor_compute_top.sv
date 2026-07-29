`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_tensor_compute_top;

    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;

    localparam logic [1:0] TARGET_ACTIVATION = 2'd0;
    localparam logic [1:0] TARGET_WEIGHT     = 2'd1;

    // Existing software-tiled client.
    localparam logic [31:0] ADDR_TILED_CONTROL =
        32'h0000_0204;

    localparam logic [31:0] ADDR_TILED_STATUS =
        32'h0000_0208;

    // Tensor loader.
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

    // Tensor GEMM.
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

    // Output scratchpad readback.
    localparam logic [31:0] ADDR_OUTPUT_READ_ADDRESS =
        32'h0000_0570;

    localparam logic [31:0] ADDR_OUTPUT_READ_CONTROL =
        32'h0000_0574;

    localparam logic [31:0] ADDR_OUTPUT_READ_DATA =
        32'h0000_0578;

    logic clk_i;
    logic rst_ni;

    logic [31:0] s_axi_awaddr_i;
    logic [2:0]  s_axi_awprot_i;
    logic        s_axi_awvalid_i;
    logic        s_axi_awready_o;

    logic [31:0] s_axi_wdata_i;
    logic [3:0]  s_axi_wstrb_i;
    logic        s_axi_wvalid_i;
    logic        s_axi_wready_o;

    logic [1:0] s_axi_bresp_o;
    logic       s_axi_bvalid_o;
    logic       s_axi_bready_i;

    logic [31:0] s_axi_araddr_i;
    logic [2:0]  s_axi_arprot_i;
    logic        s_axi_arvalid_i;
    logic        s_axi_arready_o;

    logic [31:0] s_axi_rdata_o;
    logic [1:0]  s_axi_rresp_o;
    logic        s_axi_rvalid_o;
    logic        s_axi_rready_i;

    integer check_count;
    integer error_count;

    nce_axi_mixed_precision_top dut (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .s_axi_awaddr_i     (s_axi_awaddr_i),
        .s_axi_awprot_i     (s_axi_awprot_i),
        .s_axi_awvalid_i    (s_axi_awvalid_i),
        .s_axi_awready_o    (s_axi_awready_o),

        .s_axi_wdata_i      (s_axi_wdata_i),
        .s_axi_wstrb_i      (s_axi_wstrb_i),
        .s_axi_wvalid_i     (s_axi_wvalid_i),
        .s_axi_wready_o     (s_axi_wready_o),

        .s_axi_bresp_o      (s_axi_bresp_o),
        .s_axi_bvalid_o     (s_axi_bvalid_o),
        .s_axi_bready_i     (s_axi_bready_i),

        .s_axi_araddr_i     (s_axi_araddr_i),
        .s_axi_arprot_i     (s_axi_arprot_i),
        .s_axi_arvalid_i    (s_axi_arvalid_i),
        .s_axi_arready_o    (s_axi_arready_o),

        .s_axi_rdata_o      (s_axi_rdata_o),
        .s_axi_rresp_o      (s_axi_rresp_o),
        .s_axi_rvalid_o     (s_axi_rvalid_o),
        .s_axi_rready_i     (s_axi_rready_i)
    );

    initial begin
        clk_i = 1'b0;

        forever begin
            #5 clk_i = ~clk_i;
        end
    end

    task automatic check_condition (
        input logic condition,
        input string message
    );
        begin
            check_count =
                check_count + 1;

            if (!condition) begin
                error_count =
                    error_count + 1;

                $display(
                    "ERROR check=%0d: %s",
                    check_count,
                    message
                );
            end
        end
    endtask

    task automatic axi_write (
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [1:0] expected_response
    );
        begin
            @(negedge clk_i);

            s_axi_awaddr_i =
                address;

            s_axi_awprot_i =
                3'b000;

            s_axi_awvalid_i =
                1'b1;

            s_axi_wdata_i =
                data;

            s_axi_wstrb_i =
                4'b1111;

            s_axi_wvalid_i =
                1'b1;

            fork
                begin
                    wait (
                        s_axi_awready_o === 1'b1
                    );

                    @(posedge clk_i);
                    #1;

                    s_axi_awvalid_i =
                        1'b0;
                end

                begin
                    wait (
                        s_axi_wready_o === 1'b1
                    );

                    @(posedge clk_i);
                    #1;

                    s_axi_wvalid_i =
                        1'b0;
                end
            join

            wait (
                s_axi_bvalid_o === 1'b1
            );

            #1;

            check_condition(
                s_axi_bresp_o === expected_response,
                "AXI write response mismatch"
            );

            if (
                s_axi_bresp_o !== expected_response
            ) begin
                $display(
                    "  address=%08h response=%h expected=%h",
                    address,
                    s_axi_bresp_o,
                    expected_response
                );
            end

            @(negedge clk_i);

            s_axi_bready_i =
                1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            s_axi_bready_i =
                1'b0;
        end
    endtask

    task automatic axi_read_capture (
        input logic [31:0] address,
        output logic [31:0] data,
        input logic [1:0] expected_response
    );
        begin
            @(negedge clk_i);

            s_axi_araddr_i =
                address;

            s_axi_arprot_i =
                3'b000;

            s_axi_arvalid_i =
                1'b1;

            wait (
                s_axi_arready_o === 1'b1
            );

            @(posedge clk_i);
            #1;

            s_axi_arvalid_i =
                1'b0;

            wait (
                s_axi_rvalid_o === 1'b1
            );

            #1;

            data =
                s_axi_rdata_o;

            check_condition(
                s_axi_rresp_o === expected_response,
                "AXI read response mismatch"
            );

            @(negedge clk_i);

            s_axi_rready_i =
                1'b1;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            s_axi_rready_i =
                1'b0;
        end
    endtask

    task automatic axi_read_expect (
        input logic [31:0] address,
        input logic [31:0] expected_data
    );
        logic [31:0] observed_data;

        begin
            axi_read_capture(
                address,
                observed_data,
                AXI_OKAY
            );

            check_condition(
                observed_data === expected_data,
                "AXI read data mismatch"
            );

            if (
                observed_data !== expected_data
            ) begin
                $display(
                    "  address=%08h data=%08h expected=%08h",
                    address,
                    observed_data,
                    expected_data
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
                    positive_integer_fp32 =
                        32'd0;
            endcase
        end
    endfunction

    task automatic tensor_full_clear;
        begin
            axi_write(
                ADDR_LOADER_CONTROL,
                32'h0000_0002,
                AXI_OKAY
            );

            repeat (4) begin
                @(posedge clk_i);
            end
        end
    endtask

    task automatic tensor_load_compact_matrix (
        input logic [1:0] target,
        input logic [9:0] base_addr,
        input integer k_count
    );
        integer total_words;
        integer accepted_words;
        integer stream_lane;
        integer stream_index;
        integer stream_row;
        integer stream_k;
        integer stream_column;
        integer word_value;
        integer timeout_count;

        logic [127:0] beat_data;
        logic [15:0] beat_strb;
        logic beat_last;

        logic [31:0] status;
        logic completed;

        begin
            total_words =
                8 * k_count;

            axi_write(
                ADDR_LOADER_CONFIG,
                {30'd0, target},
                AXI_OKAY
            );

            axi_write(
                ADDR_LOADER_BASE,
                32'(base_addr),
                AXI_OKAY
            );

            axi_write(
                ADDR_LOADER_WORD_COUNT,
                32'(total_words),
                AXI_OKAY
            );

            axi_write(
                ADDR_LOADER_CONTROL,
                32'h0000_0001,
                AXI_OKAY
            );

            completed =
                1'b0;

            for (
                timeout_count = 0;
                timeout_count < 50 &&
                !completed;
                timeout_count = timeout_count + 1
            ) begin
                axi_read_capture(
                    ADDR_LOADER_STATUS,
                    status,
                    AXI_OKAY
                );

                if (status[1]) begin
                    completed =
                        1'b1;
                end
            end

            check_condition(
                completed,
                "AXI tensor loader busy state was not observed"
            );

            // Tensor loading must block an autonomous tensor GEMM start.
            axi_write(
                ADDR_GEMM_CONTROL,
                32'h0000_0001,
                AXI_SLVERR
            );

            accepted_words =
                0;

            while (
                accepted_words < total_words
            ) begin
                beat_data =
                    128'd0;

                beat_strb =
                    16'd0;

                for (
                    stream_lane = 0;
                    stream_lane < 4;
                    stream_lane = stream_lane + 1
                ) begin
                    stream_index =
                        accepted_words +
                        stream_lane;

                    if (
                        stream_index < total_words
                    ) begin
                        if (
                            target == TARGET_ACTIVATION
                        ) begin
                            stream_row =
                                stream_index /
                                k_count;

                            stream_k =
                                stream_index %
                                k_count;

                            word_value =
                                (stream_row == stream_k)
                                ? 1
                                : 0;
                        end
                        else begin
                            stream_k =
                                stream_index / 8;

                            stream_column =
                                stream_index % 8;

                            word_value =
                                stream_k +
                                stream_column +
                                1;
                        end

                        beat_data[
                            (stream_lane * 32) +:
                            32
                        ] =
                            32'(word_value);

                        beat_strb[
                            (stream_lane * 4) +:
                            4
                        ] =
                            4'hF;
                    end
                end

                beat_last =
                    (
                        accepted_words + 4
                    ) >=
                    total_words;

                // Wait for the CSR stream interface to report ready.
                completed =
                    1'b0;

                for (
                    timeout_count = 0;
                    timeout_count < 50 &&
                    !completed;
                    timeout_count = timeout_count + 1
                ) begin
                    axi_read_capture(
                        ADDR_LOADER_STATUS,
                        status,
                        AXI_OKAY
                    );

                    if (status[8]) begin
                        completed =
                            1'b1;
                    end
                end

                check_condition(
                    completed,
                    "AXI tensor stream interface did not become ready"
                );

                axi_write(
                    ADDR_STREAM_DATA_0,
                    beat_data[31:0],
                    AXI_OKAY
                );

                axi_write(
                    ADDR_STREAM_DATA_1,
                    beat_data[63:32],
                    AXI_OKAY
                );

                axi_write(
                    ADDR_STREAM_DATA_2,
                    beat_data[95:64],
                    AXI_OKAY
                );

                axi_write(
                    ADDR_STREAM_DATA_3,
                    beat_data[127:96],
                    AXI_OKAY
                );

                axi_write(
                    ADDR_STREAM_STROBE,
                    {16'd0, beat_strb},
                    AXI_OKAY
                );

                axi_write(
                    ADDR_STREAM_CONTROL,
                    beat_last
                    ? 32'h0000_0003
                    : 32'h0000_0001,
                    AXI_OKAY
                );

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

            completed =
                1'b0;

            for (
                timeout_count = 0;
                timeout_count < 100 &&
                !completed;
                timeout_count = timeout_count + 1
            ) begin
                axi_read_capture(
                    ADDR_LOADER_STATUS,
                    status,
                    AXI_OKAY
                );

                if (
                    status[2] ||
                    status[3]
                ) begin
                    completed =
                        1'b1;
                end
            end

            check_condition(
                completed,
                "AXI tensor loader completion timed out"
            );

            check_condition(
                status[3] === 1'b0,
                "AXI tensor loader reported an error"
            );

            check_condition(
                status[2] === 1'b1 &&
                status[1] === 1'b0,
                "AXI tensor loader completion status mismatch"
            );

            check_condition(
                status[10:9] === target,
                "AXI tensor loader active-target mismatch"
            );

            axi_read_expect(
                ADDR_LOADER_WORDS_WRITTEN,
                32'(total_words)
            );

            // Preserve memory contents while clearing only sticky status.
            axi_write(
                ADDR_LOADER_CONTROL,
                32'h0000_0004,
                AXI_OKAY
            );
        end
    endtask

    task automatic execute_tensor_gemm (
        input logic [9:0] activation_base,
        input logic [9:0] weight_base,
        input logic [9:0] output_base,
        input integer k_count
    );
        integer timeout_count;

        logic [31:0] status;
        logic [31:0] tiled_status;
        logic completed;
        logic busy_seen;
        logic compute_seen;

        begin
            axi_write(
                ADDR_GEMM_ACTIVATION_BASE,
                32'(activation_base),
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_WEIGHT_BASE,
                32'(weight_base),
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_OUTPUT_BASE,
                32'(output_base),
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_CONFIG,
                32'(k_count << 4),
                AXI_OKAY
            );

            axi_write(
                ADDR_GEMM_CONTROL,
                32'h0000_0001,
                AXI_OKAY
            );

            busy_seen =
                1'b0;

            for (
                timeout_count = 0;
                timeout_count < 100 &&
                !busy_seen;
                timeout_count = timeout_count + 1
            ) begin
                axi_read_capture(
                    ADDR_GEMM_STATUS,
                    status,
                    AXI_OKAY
                );

                if (status[1]) begin
                    busy_seen =
                        1'b1;
                end
            end

            check_condition(
                busy_seen,
                "AXI tensor GEMM busy state was not observed"
            );

            // Tensor ownership must block the software tiled client.
            axi_write(
                ADDR_TILED_CONTROL,
                32'h0000_0001,
                AXI_SLVERR
            );

            axi_read_capture(
                ADDR_TILED_STATUS,
                tiled_status,
                AXI_OKAY
            );

            check_condition(
                tiled_status[0] === 1'b0,
                "Software tiled client remained ready during tensor ownership"
            );

            // Tensor execution must also block a new tensor-memory load.
            axi_write(
                ADDR_LOADER_CONTROL,
                32'h0000_0001,
                AXI_SLVERR
            );

            completed =
                1'b0;

            compute_seen =
                1'b0;

            for (
                timeout_count = 0;
                timeout_count < 5000 &&
                !completed;
                timeout_count = timeout_count + 1
            ) begin
                axi_read_capture(
                    ADDR_GEMM_STATUS,
                    status,
                    AXI_OKAY
                );

                if (status[2]) begin
                    compute_seen =
                        1'b1;
                end

                if (
                    status[3] ||
                    status[4]
                ) begin
                    completed =
                        1'b1;
                end
            end

            check_condition(
                completed,
                "AXI tensor GEMM completion timed out"
            );

            check_condition(
                status[4] === 1'b0,
                "AXI tensor GEMM reported an error"
            );

            check_condition(
                status[3] === 1'b1 &&
                status[1] === 1'b0,
                "AXI tensor GEMM final completion status mismatch"
            );

            check_condition(
                compute_seen &&
                status[2] === 1'b1,
                "AXI tensor GEMM compute completion was not recorded"
            );

            check_condition(
                status[8] === 1'b1,
                "AXI tensor GEMM result-valid summary mismatch"
            );

            check_condition(
                status[15:12] === 4'd0,
                "AXI tensor GEMM arithmetic-status summary mismatch"
            );

            axi_read_expect(
                ADDR_GEMM_ERROR,
                32'd0
            );

            axi_read_expect(
                ADDR_GEMM_WORDS_LOADED,
                32'(8 * k_count)
            );

            axi_read_expect(
                ADDR_GEMM_WORDS_WRITTEN,
                32'd64
            );

            axi_read_expect(
                ADDR_RESULT_VALID_LOW,
                32'hFFFF_FFFF
            );

            axi_read_expect(
                ADDR_RESULT_VALID_HIGH,
                32'hFFFF_FFFF
            );

            axi_read_expect(
                ADDR_ARITHMETIC_SUMMARY,
                32'd0
            );

            // Allow tensor and physical tiled ownership release to settle.
            repeat (4) begin
                @(posedge clk_i);
            end

            axi_read_capture(
                ADDR_TILED_STATUS,
                tiled_status,
                AXI_OKAY
            );

            check_condition(
                tiled_status[0] === 1'b1,
                "Software tiled client did not recover after tensor release"
            );
        end
    endtask

    task automatic read_output_word (
        input logic [9:0] word_addr,
        output logic [31:0] observed_word
    );
        integer timeout_count;

        logic [31:0] status;
        logic completed;

        begin
            axi_write(
                ADDR_OUTPUT_READ_ADDRESS,
                32'(word_addr),
                AXI_OKAY
            );

            axi_write(
                ADDR_OUTPUT_READ_CONTROL,
                32'h0000_0001,
                AXI_OKAY
            );

            completed =
                1'b0;

            for (
                timeout_count = 0;
                timeout_count < 50 &&
                !completed;
                timeout_count = timeout_count + 1
            ) begin
                axi_read_capture(
                    ADDR_OUTPUT_READ_CONTROL,
                    status,
                    AXI_OKAY
                );

                if (
                    status[2] ||
                    status[3]
                ) begin
                    completed =
                        1'b1;
                end
            end

            check_condition(
                completed,
                "AXI output-memory read timed out"
            );

            check_condition(
                status[3] === 1'b0,
                "AXI output-memory read reported a conflict"
            );

            check_condition(
                status[2] === 1'b1 &&
                status[1] === 1'b0,
                "AXI output-memory read-valid status mismatch"
            );

            axi_read_capture(
                ADDR_OUTPUT_READ_DATA,
                observed_word,
                AXI_OKAY
            );
        end
    endtask

    task automatic check_output_matrix (
        input logic [9:0] output_base,
        input integer k_count
    );
        integer result_index;
        integer result_row;
        integer result_column;

        logic [31:0] observed_word;
        logic [31:0] expected_word;

        begin
            for (
                result_index = 0;
                result_index < 64;
                result_index = result_index + 1
            ) begin
                result_row =
                    result_index / 8;

                result_column =
                    result_index % 8;

                expected_word =
                    positive_integer_fp32(
                        (result_row < k_count)
                        ? result_row +
                          result_column +
                          1
                        : 0
                    );

                read_output_word(
                    output_base +
                    10'(result_index),
                    observed_word
                );

                check_condition(
                    observed_word === expected_word,
                    "AXI tensor output numerical mismatch"
                );

                if (
                    observed_word !== expected_word
                ) begin
                    $display(
                        "  result=%0d row=%0d column=%0d data=%08h expected=%08h",
                        result_index,
                        result_row,
                        result_column,
                        observed_word,
                        expected_word
                    );
                end
            end

            axi_write(
                ADDR_OUTPUT_READ_CONTROL,
                32'h0000_0002,
                AXI_OKAY
            );
        end
    endtask

    initial begin
        rst_ni =
            1'b0;

        s_axi_awaddr_i =
            32'd0;

        s_axi_awprot_i =
            3'd0;

        s_axi_awvalid_i =
            1'b0;

        s_axi_wdata_i =
            32'd0;

        s_axi_wstrb_i =
            4'd0;

        s_axi_wvalid_i =
            1'b0;

        s_axi_bready_i =
            1'b0;

        s_axi_araddr_i =
            32'd0;

        s_axi_arprot_i =
            3'd0;

        s_axi_arvalid_i =
            1'b0;

        s_axi_rready_i =
            1'b0;

        check_count =
            0;

        error_count =
            0;

        repeat (8) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);

        rst_ni =
            1'b1;

        repeat (4) begin
            @(posedge clk_i);
        end

        tensor_full_clear();

        // ---------------------------------------------------------------------
        // K=8 identity-style activation matrix.
        // ---------------------------------------------------------------------

        $display(
            "INFO: Starting AXI tensor K=8 identity-style GEMM."
        );

        tensor_load_compact_matrix(
            TARGET_ACTIVATION,
            10'd100,
            8
        );

        tensor_load_compact_matrix(
            TARGET_WEIGHT,
            10'd300,
            8
        );

        execute_tensor_gemm(
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
        // Independent K=3 partial-K operation.
        // ---------------------------------------------------------------------

        tensor_full_clear();

        $display(
            "INFO: Starting AXI tensor K=3 partial-K GEMM."
        );

        tensor_load_compact_matrix(
            TARGET_ACTIVATION,
            10'd20,
            3
        );

        tensor_load_compact_matrix(
            TARGET_WEIGHT,
            10'd60,
            3
        );

        execute_tensor_gemm(
            10'd20,
            10'd60,
            10'd700,
            3
        );

        check_output_matrix(
            10'd700,
            3
        );

        tensor_full_clear();

        if (
            error_count == 0
        ) begin
            $display(
                "PASS: AXI tensor compute path passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d AXI tensor-compute errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
