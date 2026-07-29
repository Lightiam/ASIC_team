`timescale 1ns/1ps
`default_nettype none

module tb_nce_tiled_gemm_client_mux;

    logic clk_i;
    logic rst_ni;

    logic software_clear_i;
    logic software_a_write_enable_i;
    logic [5:0] software_a_write_addr_i;
    logic [31:0] software_a_write_data_i;
    logic software_b_write_enable_i;
    logic [5:0] software_b_write_addr_i;
    logic [31:0] software_b_write_data_i;
    logic software_start_i;
    logic software_start_ready_o;
    logic [1:0] software_precision_i;
    logic [3:0] software_k_token_count_i;
    logic software_busy_o;
    logic software_done_o;
    logic software_error_o;
    logic [2:0] software_error_code_o;
    logic software_m_tile_o;
    logic software_n_tile_o;
    logic software_k_tile_o;
    logic [63:0] software_a_valid_mask_o;
    logic [63:0] software_b_valid_mask_o;
    logic [2047:0] software_accumulator_o;
    logic [63:0] software_accumulator_valid_o;
    logic [63:0] software_invalid_o;
    logic [63:0] software_overflow_o;
    logic [63:0] software_underflow_o;
    logic [63:0] software_inexact_o;

    logic convolution_claim_i;
    logic convolution_release_i;
    logic convolution_available_o;
    logic convolution_clear_i;
    logic convolution_a_write_enable_i;
    logic [5:0] convolution_a_write_addr_i;
    logic [31:0] convolution_a_write_data_i;
    logic convolution_b_write_enable_i;
    logic [5:0] convolution_b_write_addr_i;
    logic [31:0] convolution_b_write_data_i;
    logic convolution_start_i;
    logic convolution_start_ready_o;
    logic [1:0] convolution_precision_i;
    logic [3:0] convolution_k_token_count_i;
    logic convolution_busy_o;
    logic convolution_done_o;
    logic convolution_error_o;
    logic [2:0] convolution_error_code_o;
    logic [2047:0] convolution_accumulator_o;
    logic [63:0] convolution_accumulator_valid_o;
    logic [63:0] convolution_invalid_o;
    logic [63:0] convolution_overflow_o;
    logic [63:0] convolution_underflow_o;
    logic [63:0] convolution_inexact_o;

    logic tensor_claim_i;
    logic tensor_release_i;
    logic tensor_available_o;
    logic tensor_clear_i;
    logic tensor_a_write_enable_i;
    logic [5:0] tensor_a_write_addr_i;
    logic [31:0] tensor_a_write_data_i;
    logic tensor_b_write_enable_i;
    logic [5:0] tensor_b_write_addr_i;
    logic [31:0] tensor_b_write_data_i;
    logic tensor_start_i;
    logic tensor_start_ready_o;
    logic [1:0] tensor_precision_i;
    logic [3:0] tensor_k_token_count_i;
    logic tensor_busy_o;
    logic tensor_done_o;
    logic tensor_error_o;
    logic [2:0] tensor_error_code_o;
    logic [2047:0] tensor_accumulator_o;
    logic [63:0] tensor_accumulator_valid_o;
    logic [63:0] tensor_invalid_o;
    logic [63:0] tensor_overflow_o;
    logic [63:0] tensor_underflow_o;
    logic [63:0] tensor_inexact_o;

    logic shared_clear_o;
    logic shared_a_write_enable_o;
    logic [5:0] shared_a_write_addr_o;
    logic [31:0] shared_a_write_data_o;
    logic shared_b_write_enable_o;
    logic [5:0] shared_b_write_addr_o;
    logic [31:0] shared_b_write_data_o;
    logic shared_start_o;
    logic shared_start_ready_i;
    logic [1:0] shared_precision_o;
    logic [3:0] shared_k_token_count_o;

    logic shared_busy_i;
    logic shared_done_i;
    logic shared_error_i;
    logic [2:0] shared_error_code_i;
    logic shared_m_tile_i;
    logic shared_n_tile_i;
    logic shared_k_tile_i;
    logic [63:0] shared_a_valid_mask_i;
    logic [63:0] shared_b_valid_mask_i;
    logic [2047:0] shared_accumulator_i;
    logic [63:0] shared_accumulator_valid_i;
    logic [63:0] shared_invalid_i;
    logic [63:0] shared_overflow_i;
    logic [63:0] shared_underflow_i;
    logic [63:0] shared_inexact_i;

    logic [1:0] owner_o;

    integer check_count;
    integer error_count;

    nce_tiled_gemm_client_mux dut (
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

    task automatic release_convolution;
        begin
            @(negedge clk_i);

            convolution_clear_i =
                1'b1;

            convolution_release_i =
                1'b1;

            #1;

            check_condition(
                shared_clear_o === 1'b1,
                "Convolution clear was not routed"
            );

            @(posedge clk_i);
            #1;

            convolution_clear_i =
                1'b0;

            convolution_release_i =
                1'b0;

            check_condition(
                owner_o === 2'd0,
                "Convolution did not release ownership"
            );
        end
    endtask

    task automatic release_tensor;
        begin
            @(negedge clk_i);

            tensor_clear_i =
                1'b1;

            tensor_release_i =
                1'b1;

            #1;

            check_condition(
                shared_clear_o === 1'b1,
                "Tensor clear was not routed"
            );

            @(posedge clk_i);
            #1;

            tensor_clear_i =
                1'b0;

            tensor_release_i =
                1'b0;

            check_condition(
                owner_o === 2'd0,
                "Tensor did not release ownership"
            );
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        software_clear_i = 1'b0;
        software_a_write_enable_i = 1'b0;
        software_a_write_addr_i = 6'd0;
        software_a_write_data_i = 32'd0;
        software_b_write_enable_i = 1'b0;
        software_b_write_addr_i = 6'd0;
        software_b_write_data_i = 32'd0;
        software_start_i = 1'b0;
        software_precision_i = 2'b01;
        software_k_token_count_i = 4'd4;

        convolution_claim_i = 1'b0;
        convolution_release_i = 1'b0;
        convolution_clear_i = 1'b0;
        convolution_a_write_enable_i = 1'b0;
        convolution_a_write_addr_i = 6'd0;
        convolution_a_write_data_i = 32'd0;
        convolution_b_write_enable_i = 1'b0;
        convolution_b_write_addr_i = 6'd0;
        convolution_b_write_data_i = 32'd0;
        convolution_start_i = 1'b0;
        convolution_precision_i = 2'b00;
        convolution_k_token_count_i = 4'd3;

        tensor_claim_i = 1'b0;
        tensor_release_i = 1'b0;
        tensor_clear_i = 1'b0;
        tensor_a_write_enable_i = 1'b0;
        tensor_a_write_addr_i = 6'd0;
        tensor_a_write_data_i = 32'd0;
        tensor_b_write_enable_i = 1'b0;
        tensor_b_write_addr_i = 6'd0;
        tensor_b_write_data_i = 32'd0;
        tensor_start_i = 1'b0;
        tensor_precision_i = 2'b10;
        tensor_k_token_count_i = 4'd6;

        shared_start_ready_i = 1'b1;
        shared_busy_i = 1'b0;
        shared_done_i = 1'b0;
        shared_error_i = 1'b0;
        shared_error_code_i = 3'd5;

        shared_m_tile_i = 1'b1;
        shared_n_tile_i = 1'b0;
        shared_k_tile_i = 1'b1;

        shared_a_valid_mask_i =
            64'hAAAA_AAAA_AAAA_AAAA;

        shared_b_valid_mask_i =
            64'h5555_5555_5555_5555;

        shared_accumulator_i =
            2048'd0;

        shared_accumulator_i[31:0] =
            32'h4120_0000;

        shared_accumulator_valid_i =
            64'h1;

        shared_invalid_i =
            64'h1;

        shared_overflow_i =
            64'h2;

        shared_underflow_i =
            64'h4;

        shared_inexact_i =
            64'h8;

        check_count = 0;
        error_count = 0;

        repeat (4) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            owner_o === 2'd0 &&
            software_start_ready_o === 1'b1 &&
            convolution_available_o === 1'b1 &&
            tensor_available_o === 1'b1,
            "Idle ownership availability mismatch"
        );

        // ---------------------------------------------------------------------
        // Software ownership and context isolation
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        software_a_write_enable_i =
            1'b1;

        software_a_write_addr_i =
            6'd17;

        software_a_write_data_i =
            32'h1234_5678;

        #1;

        check_condition(
            shared_a_write_enable_o === 1'b1 &&
            shared_a_write_addr_o === 6'd17 &&
            shared_a_write_data_o === 32'h1234_5678,
            "Software A request was not routed"
        );

        @(posedge clk_i);
        #1;

        software_a_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd1 &&
            convolution_available_o === 1'b0 &&
            tensor_available_o === 1'b0,
            "Software did not acquire exclusive ownership"
        );

        shared_done_i = 1'b1;
        #1;

        check_condition(
            software_done_o === 1'b1 &&
            convolution_done_o === 1'b0 &&
            tensor_done_o === 1'b0,
            "Software completion response was not isolated"
        );

        check_condition(
            software_accumulator_o[31:0] === 32'h4120_0000 &&
            convolution_accumulator_o === 2048'd0 &&
            tensor_accumulator_o === 2048'd0,
            "Software accumulator context was not isolated"
        );

        shared_done_i = 1'b0;

        @(negedge clk_i);

        software_clear_i =
            1'b1;

        #1;

        check_condition(
            shared_clear_o === 1'b1,
            "Software clear was not routed"
        );

        @(posedge clk_i);
        #1;

        software_clear_i =
            1'b0;

        check_condition(
            owner_o === 2'd0,
            "Software clear did not release ownership"
        );

        // ---------------------------------------------------------------------
        // Tensor ownership, request routing and response isolation
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        tensor_claim_i =
            1'b1;

        #1;

        check_condition(
            software_start_ready_o === 1'b0 &&
            software_busy_o === 1'b1,
            "Software was not blocked during tensor claim"
        );

        @(posedge clk_i);
        #1;

        tensor_claim_i =
            1'b0;

        check_condition(
            owner_o === 2'd3 &&
            tensor_start_ready_o === 1'b1 &&
            convolution_available_o === 1'b0,
            "Tensor did not acquire ownership"
        );

        @(negedge clk_i);

        tensor_a_write_enable_i =
            1'b1;

        tensor_a_write_addr_i =
            6'd21;

        tensor_a_write_data_i =
            32'hA1A2_A3A4;

        tensor_b_write_enable_i =
            1'b1;

        tensor_b_write_addr_i =
            6'd22;

        tensor_b_write_data_i =
            32'hB1B2_B3B4;

        #1;

        check_condition(
            shared_a_write_enable_o === 1'b1 &&
            shared_a_write_addr_o === 6'd21 &&
            shared_a_write_data_o === 32'hA1A2_A3A4,
            "Tensor A request was not routed"
        );

        check_condition(
            shared_b_write_enable_o === 1'b1 &&
            shared_b_write_addr_o === 6'd22 &&
            shared_b_write_data_o === 32'hB1B2_B3B4,
            "Tensor B request was not routed"
        );

        tensor_a_write_enable_i =
            1'b0;

        tensor_b_write_enable_i =
            1'b0;

        tensor_start_i =
            1'b1;

        #1;

        check_condition(
            shared_start_o === 1'b1 &&
            shared_precision_o === 2'b10 &&
            shared_k_token_count_o === 4'd6,
            "Tensor start/configuration was not routed"
        );

        tensor_start_i =
            1'b0;

        shared_done_i =
            1'b1;

        #1;

        check_condition(
            tensor_done_o === 1'b1 &&
            software_done_o === 1'b0 &&
            convolution_done_o === 1'b0,
            "Tensor completion response was not isolated"
        );

        check_condition(
            tensor_accumulator_o[31:0] === 32'h4120_0000 &&
            tensor_accumulator_valid_o === 64'h1 &&
            software_accumulator_o === 2048'd0 &&
            convolution_accumulator_o === 2048'd0,
            "Tensor result context was not isolated"
        );

        check_condition(
            tensor_invalid_o === 64'h1 &&
            tensor_overflow_o === 64'h2 &&
            tensor_underflow_o === 64'h4 &&
            tensor_inexact_o === 64'h8,
            "Tensor arithmetic flags were not routed"
        );

        shared_done_i =
            1'b0;

        release_tensor();

        // ---------------------------------------------------------------------
        // Tensor must outrank simultaneous software staging
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        software_a_write_enable_i =
            1'b1;

        software_a_write_addr_i =
            6'd1;

        software_a_write_data_i =
            32'h1111_1111;

        tensor_claim_i =
            1'b1;

        tensor_a_write_enable_i =
            1'b1;

        tensor_a_write_addr_i =
            6'd2;

        tensor_a_write_data_i =
            32'h2222_2222;

        #1;

        check_condition(
            shared_a_write_enable_o === 1'b1 &&
            shared_a_write_addr_o === 6'd2 &&
            shared_a_write_data_o === 32'h2222_2222,
            "Tensor did not outrank simultaneous software staging"
        );

        @(posedge clk_i);
        #1;

        software_a_write_enable_i =
            1'b0;

        tensor_claim_i =
            1'b0;

        tensor_a_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd3,
            "Tensor did not win software/tensor claim"
        );

        release_tensor();

        // ---------------------------------------------------------------------
        // Convolution must outrank both tensor and software
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        software_a_write_enable_i =
            1'b1;

        software_a_write_addr_i =
            6'd3;

        software_a_write_data_i =
            32'h3333_3333;

        tensor_claim_i =
            1'b1;

        tensor_a_write_enable_i =
            1'b1;

        tensor_a_write_addr_i =
            6'd4;

        tensor_a_write_data_i =
            32'h4444_4444;

        convolution_claim_i =
            1'b1;

        convolution_a_write_enable_i =
            1'b1;

        convolution_a_write_addr_i =
            6'd5;

        convolution_a_write_data_i =
            32'h5555_5555;

        #1;

        check_condition(
            shared_a_write_enable_o === 1'b1 &&
            shared_a_write_addr_o === 6'd5 &&
            shared_a_write_data_o === 32'h5555_5555,
            "Convolution did not receive highest claim priority"
        );

        check_condition(
            tensor_available_o === 1'b0 &&
            software_start_ready_o === 1'b0,
            "Lower-priority clients were not blocked"
        );

        @(posedge clk_i);
        #1;

        software_a_write_enable_i =
            1'b0;

        tensor_claim_i =
            1'b0;

        tensor_a_write_enable_i =
            1'b0;

        convolution_claim_i =
            1'b0;

        convolution_a_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd2,
            "Convolution did not win three-way claim"
        );

        shared_error_i =
            1'b1;

        #1;

        check_condition(
            convolution_error_o === 1'b1 &&
            convolution_error_code_o === 3'd5 &&
            software_error_o === 1'b0 &&
            tensor_error_o === 1'b0,
            "Convolution error response was not isolated"
        );

        check_condition(
            convolution_accumulator_o[31:0] === 32'h4120_0000 &&
            software_accumulator_o === 2048'd0 &&
            tensor_accumulator_o === 2048'd0,
            "Convolution result context was not isolated"
        );

        shared_error_i =
            1'b0;

        release_convolution();

        check_condition(
            software_start_ready_o === 1'b1 &&
            convolution_available_o === 1'b1 &&
            tensor_available_o === 1'b1,
            "Mux did not return to fully available idle state"
        );


        // ---------------------------------------------------------------------
        // Simultaneous software A/B staging must claim software ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        software_a_write_enable_i =
            1'b1;

        software_a_write_addr_i =
            6'd11;

        software_a_write_data_i =
            32'hAAAA_0011;

        software_b_write_enable_i =
            1'b1;

        software_b_write_addr_i =
            6'd12;

        software_b_write_data_i =
            32'hBBBB_0012;

        #1;

        check_condition(
            shared_a_write_enable_o === 1'b1 &&
            shared_a_write_addr_o === 6'd11 &&
            shared_a_write_data_o === 32'hAAAA_0011 &&
            shared_b_write_enable_o === 1'b1 &&
            shared_b_write_addr_o === 6'd12 &&
            shared_b_write_data_o === 32'hBBBB_0012,
            "Simultaneous software A/B writes were not routed"
        );

        @(posedge clk_i);
        #1;

        software_a_write_enable_i =
            1'b0;

        software_b_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd1,
            "Simultaneous software writes did not claim ownership"
        );

        // ---------------------------------------------------------------------
        // Autonomous claims and non-owner releases must not steal software
        // ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        tensor_claim_i =
            1'b1;

        tensor_a_write_enable_i =
            1'b1;

        tensor_a_write_addr_i =
            6'd19;

        tensor_a_write_data_i =
            32'hDEAD_0019;

        #1;

        check_condition(
            owner_o === 2'd1 &&
            shared_a_write_enable_o === 1'b0 &&
            tensor_available_o === 1'b0,
            "Tensor request leaked through software ownership"
        );

        @(posedge clk_i);
        #1;

        tensor_claim_i =
            1'b0;

        tensor_a_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd1,
            "Tensor claim stole active software ownership"
        );

        @(negedge clk_i);

        tensor_release_i =
            1'b1;

        convolution_release_i =
            1'b1;

        @(posedge clk_i);
        #1;

        tensor_release_i =
            1'b0;

        convolution_release_i =
            1'b0;

        check_condition(
            owner_o === 2'd1,
            "Non-owner release changed software ownership"
        );

        @(negedge clk_i);

        software_clear_i =
            1'b1;

        #1;

        check_condition(
            shared_clear_o === 1'b1,
            "Software clear was not routed during hardening test"
        );

        @(posedge clk_i);
        #1;

        software_clear_i =
            1'b0;

        check_condition(
            owner_o === 2'd0,
            "Software hardening context did not release"
        );

        // ---------------------------------------------------------------------
        // Convolution claim and unrelated releases must not steal tensor
        // ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        tensor_claim_i =
            1'b1;

        @(posedge clk_i);
        #1;

        tensor_claim_i =
            1'b0;

        check_condition(
            owner_o === 2'd3,
            "Tensor hardening context did not acquire ownership"
        );

        @(negedge clk_i);

        convolution_claim_i =
            1'b1;

        convolution_a_write_enable_i =
            1'b1;

        convolution_a_write_addr_i =
            6'd23;

        convolution_a_write_data_i =
            32'hC0DE_0023;

        #1;

        check_condition(
            owner_o === 2'd3 &&
            shared_a_write_enable_o === 1'b0 &&
            convolution_available_o === 1'b0,
            "Convolution request leaked through tensor ownership"
        );

        @(posedge clk_i);
        #1;

        convolution_claim_i =
            1'b0;

        convolution_a_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd3,
            "Convolution claim stole active tensor ownership"
        );

        @(negedge clk_i);

        software_clear_i =
            1'b1;

        convolution_release_i =
            1'b1;

        #1;

        check_condition(
            shared_clear_o === 1'b0,
            "Non-owner clear leaked into tensor context"
        );

        @(posedge clk_i);
        #1;

        software_clear_i =
            1'b0;

        convolution_release_i =
            1'b0;

        check_condition(
            owner_o === 2'd3,
            "Non-owner controls changed tensor ownership"
        );

        release_tensor();

        // ---------------------------------------------------------------------
        // Active release and competing claim in the same cycle must return to
        // OWNER_NONE first. It must not perform an implicit immediate handoff.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        tensor_claim_i =
            1'b1;

        @(posedge clk_i);
        #1;

        tensor_claim_i =
            1'b0;

        check_condition(
            owner_o === 2'd3,
            "Tensor did not acquire release-collision context"
        );

        @(negedge clk_i);

        tensor_clear_i =
            1'b1;

        tensor_release_i =
            1'b1;

        convolution_claim_i =
            1'b1;

        convolution_a_write_enable_i =
            1'b1;

        convolution_a_write_addr_i =
            6'd31;

        convolution_a_write_data_i =
            32'hCAFE_0031;

        #1;

        check_condition(
            shared_clear_o === 1'b1 &&
            shared_a_write_enable_o === 1'b0,
            "Competing claimant overrode releasing tensor context"
        );

        @(posedge clk_i);
        #1;

        check_condition(
            owner_o === 2'd0,
            "Release collision performed an immediate ownership handoff"
        );

        tensor_clear_i =
            1'b0;

        tensor_release_i =
            1'b0;

        convolution_claim_i =
            1'b0;

        convolution_a_write_enable_i =
            1'b0;

        @(posedge clk_i);
        #1;

        check_condition(
            owner_o === 2'd0,
            "Released owner was unexpectedly reacquired"
        );

        // ---------------------------------------------------------------------
        // Shared completion/error activity while idle must not leak into any
        // client-visible response or result context.
        // ---------------------------------------------------------------------

        shared_done_i =
            1'b1;

        shared_error_i =
            1'b1;

        #1;

        check_condition(
            software_done_o === 1'b0 &&
            convolution_done_o === 1'b0 &&
            tensor_done_o === 1'b0 &&
            software_error_o === 1'b0 &&
            convolution_error_o === 1'b0 &&
            tensor_error_o === 1'b0,
            "Shared idle response leaked to a client"
        );

        check_condition(
            software_error_code_o === 3'd0 &&
            convolution_error_code_o === 3'd0 &&
            tensor_error_code_o === 3'd0,
            "Shared idle error code leaked to a client"
        );

        check_condition(
            software_accumulator_o === 2048'd0 &&
            convolution_accumulator_o === 2048'd0 &&
            tensor_accumulator_o === 2048'd0,
            "Shared idle accumulator leaked to a client"
        );

        shared_done_i =
            1'b0;

        shared_error_i =
            1'b0;

        // ---------------------------------------------------------------------
        // Asynchronous reset from software ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        software_a_write_enable_i =
            1'b1;

        software_a_write_addr_i =
            6'd41;

        software_a_write_data_i =
            32'h1111_0041;

        @(posedge clk_i);
        #1;

        software_a_write_enable_i =
            1'b0;

        check_condition(
            owner_o === 2'd1,
            "Software reset context was not acquired"
        );

        @(negedge clk_i);
        #1;

        rst_ni =
            1'b0;

        #1;

        check_condition(
            owner_o === 2'd0 &&
            software_start_ready_o === 1'b0 &&
            convolution_available_o === 1'b0 &&
            tensor_available_o === 1'b0,
            "Asynchronous reset did not clear software ownership"
        );

        #1;

        rst_ni =
            1'b1;

        #1;

        check_condition(
            owner_o === 2'd0 &&
            software_start_ready_o === 1'b1 &&
            convolution_available_o === 1'b1 &&
            tensor_available_o === 1'b1,
            "Mux did not recover after software-owner reset"
        );

        // ---------------------------------------------------------------------
        // Asynchronous reset from tensor ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        tensor_claim_i =
            1'b1;

        @(posedge clk_i);
        #1;

        tensor_claim_i =
            1'b0;

        check_condition(
            owner_o === 2'd3,
            "Tensor reset context was not acquired"
        );

        @(negedge clk_i);
        #1;

        rst_ni =
            1'b0;

        #1;

        check_condition(
            owner_o === 2'd0 &&
            tensor_start_ready_o === 1'b0 &&
            tensor_busy_o === 1'b0 &&
            tensor_done_o === 1'b0 &&
            tensor_error_o === 1'b0,
            "Asynchronous reset did not isolate tensor context"
        );

        #1;

        rst_ni =
            1'b1;

        #1;

        check_condition(
            owner_o === 2'd0 &&
            software_start_ready_o === 1'b1 &&
            convolution_available_o === 1'b1 &&
            tensor_available_o === 1'b1,
            "Mux did not recover after tensor-owner reset"
        );

        // ---------------------------------------------------------------------
        // Asynchronous reset from convolution ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        convolution_claim_i =
            1'b1;

        @(posedge clk_i);
        #1;

        convolution_claim_i =
            1'b0;

        check_condition(
            owner_o === 2'd2,
            "Convolution reset context was not acquired"
        );

        @(negedge clk_i);
        #1;

        rst_ni =
            1'b0;

        #1;

        check_condition(
            owner_o === 2'd0 &&
            convolution_start_ready_o === 1'b0 &&
            convolution_busy_o === 1'b0 &&
            convolution_done_o === 1'b0 &&
            convolution_error_o === 1'b0,
            "Asynchronous reset did not isolate convolution context"
        );

        #1;

        rst_ni =
            1'b1;

        #1;

        check_condition(
            owner_o === 2'd0 &&
            software_start_ready_o === 1'b1 &&
            convolution_available_o === 1'b1 &&
            tensor_available_o === 1'b1,
            "Mux did not recover after convolution-owner reset"
        );

        if (error_count == 0) begin
            $display(
                "PASS: three-client tiled-GEMM mux passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tiled-client-mux errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
