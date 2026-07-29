`timescale 1ns/1ps
`default_nettype none

module tb_nce_shared_systolic_gemm_4x4;

    logic clk_i;
    logic rst_ni;

    logic direct_clear_i;

    logic        direct_a_write_enable_i;
    logic [3:0]  direct_a_write_addr_i;
    logic [31:0] direct_a_write_data_i;

    logic        direct_b_write_enable_i;
    logic [3:0]  direct_b_write_addr_i;
    logic [31:0] direct_b_write_data_i;

    logic       direct_start_i;
    logic       direct_start_ready_o;
    logic [1:0] direct_precision_i;
    logic [2:0] direct_k_count_i;
    logic       direct_accumulate_i;

    logic       direct_busy_o;
    logic       direct_done_o;
    logic       direct_error_o;
    logic [2:0] direct_error_code_o;

    logic tiled_claim_i;
    logic tiled_release_i;
    logic tiled_engine_available_o;

    logic tiled_engine_clear_i;

    logic        tiled_engine_a_write_enable_i;
    logic [3:0]  tiled_engine_a_write_addr_i;
    logic [31:0] tiled_engine_a_write_data_i;

    logic        tiled_engine_b_write_enable_i;
    logic [3:0]  tiled_engine_b_write_addr_i;
    logic [31:0] tiled_engine_b_write_data_i;

    logic       tiled_engine_start_i;
    logic       tiled_engine_start_ready_o;
    logic [1:0] tiled_engine_precision_i;
    logic [2:0] tiled_engine_k_count_i;
    logic       tiled_engine_accumulate_i;

    logic       tiled_engine_busy_o;
    logic       tiled_engine_done_o;
    logic       tiled_engine_error_o;
    logic [2:0] tiled_engine_error_code_o;

    integer check_count;
    integer error_count;
    integer wait_count;

    nce_shared_systolic_gemm_4x4 dut (
        .clk_i                         (clk_i),
        .rst_ni                        (rst_ni),

        .direct_clear_i                (direct_clear_i),

        .direct_a_write_enable_i       (direct_a_write_enable_i),
        .direct_a_write_addr_i         (direct_a_write_addr_i),
        .direct_a_write_data_i         (direct_a_write_data_i),

        .direct_b_write_enable_i       (direct_b_write_enable_i),
        .direct_b_write_addr_i         (direct_b_write_addr_i),
        .direct_b_write_data_i         (direct_b_write_data_i),

        .direct_start_i                (direct_start_i),
        .direct_start_ready_o          (direct_start_ready_o),
        .direct_precision_i            (direct_precision_i),
        .direct_k_count_i              (direct_k_count_i),
        .direct_accumulate_i           (direct_accumulate_i),

        .direct_busy_o                 (direct_busy_o),
        .direct_done_o                 (direct_done_o),
        .direct_error_o                (direct_error_o),
        .direct_error_code_o           (direct_error_code_o),

        .tiled_claim_i                 (tiled_claim_i),
        .tiled_release_i               (tiled_release_i),
        .tiled_engine_available_o      (tiled_engine_available_o),

        .tiled_engine_clear_i          (tiled_engine_clear_i),

        .tiled_engine_a_write_enable_i (tiled_engine_a_write_enable_i),
        .tiled_engine_a_write_addr_i   (tiled_engine_a_write_addr_i),
        .tiled_engine_a_write_data_i   (tiled_engine_a_write_data_i),

        .tiled_engine_b_write_enable_i (tiled_engine_b_write_enable_i),
        .tiled_engine_b_write_addr_i   (tiled_engine_b_write_addr_i),
        .tiled_engine_b_write_data_i   (tiled_engine_b_write_data_i),

        .tiled_engine_start_i          (tiled_engine_start_i),
        .tiled_engine_start_ready_o    (tiled_engine_start_ready_o),
        .tiled_engine_precision_i      (tiled_engine_precision_i),
        .tiled_engine_k_count_i        (tiled_engine_k_count_i),
        .tiled_engine_accumulate_i     (tiled_engine_accumulate_i),

        .tiled_engine_busy_o           (tiled_engine_busy_o),
        .tiled_engine_done_o           (tiled_engine_done_o),
        .tiled_engine_error_o          (tiled_engine_error_o),
        .tiled_engine_error_code_o     (tiled_engine_error_code_o)
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

    task automatic wait_for_direct_ready;
        begin
            wait_count = 0;

            while (
                direct_start_ready_o !== 1'b1 &&
                wait_count < 100
            ) begin
                @(posedge clk_i);
                #1;

                wait_count = wait_count + 1;
            end

            check_condition(
                direct_start_ready_o === 1'b1,
                "Direct physical engine did not become ready"
            );
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        direct_clear_i = 1'b0;

        direct_a_write_enable_i = 1'b0;
        direct_a_write_addr_i = 4'd0;
        direct_a_write_data_i = 32'd0;

        direct_b_write_enable_i = 1'b0;
        direct_b_write_addr_i = 4'd0;
        direct_b_write_data_i = 32'd0;

        direct_start_i = 1'b0;
        direct_precision_i = 2'b00;
        direct_k_count_i = 3'd1;
        direct_accumulate_i = 1'b0;

        tiled_claim_i = 1'b0;
        tiled_release_i = 1'b0;
        tiled_engine_clear_i = 1'b0;

        tiled_engine_a_write_enable_i = 1'b0;
        tiled_engine_a_write_addr_i = 4'd0;
        tiled_engine_a_write_data_i = 32'd0;

        tiled_engine_b_write_enable_i = 1'b0;
        tiled_engine_b_write_addr_i = 4'd0;
        tiled_engine_b_write_data_i = 32'd0;

        tiled_engine_start_i = 1'b0;
        tiled_engine_precision_i = 2'b01;
        tiled_engine_k_count_i = 3'd2;
        tiled_engine_accumulate_i = 1'b0;

        check_count = 0;
        error_count = 0;
        wait_count = 0;

        repeat (4) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            dut.owner_q === 2'd0 &&
            direct_start_ready_o === 1'b1 &&
            tiled_engine_available_o === 1'b1,
            "Shared physical engine did not enter idle state"
        );

        // Shared responses while idle must not leak to either client.
        force dut.shared_done = 1'b1;
        force dut.shared_error = 1'b1;
        force dut.shared_error_code = 3'd5;

        #1;

        check_condition(
            direct_done_o === 1'b0 &&
            direct_error_o === 1'b0 &&
            tiled_engine_done_o === 1'b0 &&
            tiled_engine_error_o === 1'b0,
            "Idle physical-engine response leaked to a client"
        );

        release dut.shared_done;
        release dut.shared_error;
        release dut.shared_error_code;

        // ---------------------------------------------------------------------
        // Tiled claim must outrank all simultaneous direct requests.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        tiled_claim_i = 1'b1;

        direct_clear_i = 1'b1;

        direct_a_write_enable_i = 1'b1;
        direct_a_write_addr_i = 4'd3;
        direct_a_write_data_i = 32'hAAAA_0003;

        direct_b_write_enable_i = 1'b1;
        direct_b_write_addr_i = 4'd4;
        direct_b_write_data_i = 32'hBBBB_0004;

        direct_start_i = 1'b1;

        #1;

        check_condition(
            direct_start_ready_o === 1'b0 &&
            direct_busy_o === 1'b1,
            "Direct client was not blocked during idle tiled claim"
        );

        check_condition(
            dut.shared_clear === 1'b0 &&
            dut.shared_a_write_enable === 1'b0 &&
            dut.shared_b_write_enable === 1'b0 &&
            dut.shared_start === 1'b0,
            "Direct request leaked during tiled ownership claim"
        );

        @(posedge clk_i);
        #1;

        tiled_claim_i = 1'b0;

        direct_clear_i = 1'b0;
        direct_a_write_enable_i = 1'b0;
        direct_b_write_enable_i = 1'b0;
        direct_start_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd2 &&
            tiled_engine_start_ready_o === 1'b1 &&
            direct_start_ready_o === 1'b0,
            "Tiled client did not acquire exclusive ownership"
        );

        // ---------------------------------------------------------------------
        // Tiled requests route while direct requests remain isolated.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        direct_clear_i = 1'b1;
        direct_a_write_enable_i = 1'b1;
        direct_a_write_addr_i = 4'd5;
        direct_a_write_data_i = 32'hDDDD_0005;

        tiled_engine_a_write_enable_i = 1'b1;
        tiled_engine_a_write_addr_i = 4'd7;
        tiled_engine_a_write_data_i = 32'h7777_0007;

        tiled_engine_b_write_enable_i = 1'b1;
        tiled_engine_b_write_addr_i = 4'd8;
        tiled_engine_b_write_data_i = 32'h8888_0008;

        #1;

        check_condition(
            dut.shared_clear === 1'b0,
            "Direct clear leaked during tiled ownership"
        );

        check_condition(
            dut.shared_a_write_enable === 1'b1 &&
            dut.shared_a_write_addr === 4'd7 &&
            dut.shared_a_write_data === 32'h7777_0007,
            "Tiled A request was not routed"
        );

        check_condition(
            dut.shared_b_write_enable === 1'b1 &&
            dut.shared_b_write_addr === 4'd8 &&
            dut.shared_b_write_data === 32'h8888_0008,
            "Tiled B request was not routed"
        );

        @(posedge clk_i);
        #1;

        direct_clear_i = 1'b0;
        direct_a_write_enable_i = 1'b0;

        tiled_engine_a_write_enable_i = 1'b0;
        tiled_engine_b_write_enable_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd2,
            "Non-owner direct controls changed tiled ownership"
        );

        force dut.shared_done = 1'b1;
        force dut.shared_error = 1'b1;
        force dut.shared_error_code = 3'd6;

        #1;

        check_condition(
            tiled_engine_done_o === 1'b1 &&
            tiled_engine_error_o === 1'b1 &&
            tiled_engine_error_code_o === 3'd6 &&
            direct_done_o === 1'b0 &&
            direct_error_o === 1'b0,
            "Tiled response was not isolated"
        );

        release dut.shared_done;
        release dut.shared_error;
        release dut.shared_error_code;

        // Releasing tiled ownership and requesting direct operation in the same
        // cycle must return to idle first.
        @(negedge clk_i);

        tiled_release_i = 1'b1;
        direct_start_i = 1'b1;

        #1;

        check_condition(
            direct_start_ready_o === 1'b0 &&
            dut.shared_start === 1'b0,
            "Direct start bypassed active tiled ownership"
        );

        @(posedge clk_i);
        #1;

        tiled_release_i = 1'b0;
        direct_start_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd0,
            "Tiled release caused an unintended immediate handoff"
        );

        // ---------------------------------------------------------------------
        // Direct ownership and persistent direct context.
        // ---------------------------------------------------------------------

        wait_for_direct_ready();

        @(negedge clk_i);

        direct_start_i = 1'b1;

        #1;

        check_condition(
            direct_start_ready_o === 1'b1 &&
            dut.shared_start === 1'b1,
            "Direct start was not accepted"
        );

        @(posedge clk_i);
        #1;

        direct_start_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd1,
            "Direct client did not acquire ownership"
        );

        force dut.shared_done = 1'b1;
        force dut.shared_error = 1'b1;
        force dut.shared_error_code = 3'd4;

        #1;

        check_condition(
            direct_done_o === 1'b1 &&
            direct_error_o === 1'b1 &&
            direct_error_code_o === 3'd4 &&
            tiled_engine_done_o === 1'b0 &&
            tiled_engine_error_o === 1'b0,
            "Direct response was not isolated"
        );

        release dut.shared_done;
        release dut.shared_error;
        release dut.shared_error_code;

        // A spurious tiled claim cannot steal or interfere with direct-owned
        // request routing.
        @(negedge clk_i);

        tiled_claim_i = 1'b1;

        direct_a_write_enable_i = 1'b1;
        direct_a_write_addr_i = 4'd9;
        direct_a_write_data_i = 32'h9999_0009;

        tiled_engine_a_write_enable_i = 1'b1;
        tiled_engine_a_write_addr_i = 4'd10;
        tiled_engine_a_write_data_i = 32'hAAAA_0010;

        #1;

        check_condition(
            dut.shared_a_write_enable === 1'b1 &&
            dut.shared_a_write_addr === 4'd9 &&
            dut.shared_a_write_data === 32'h9999_0009,
            "Tiled claim interfered with direct-owned routing"
        );

        @(posedge clk_i);
        #1;

        tiled_claim_i = 1'b0;
        direct_a_write_enable_i = 1'b0;
        tiled_engine_a_write_enable_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd1,
            "Spurious tiled claim stole direct ownership"
        );

        @(negedge clk_i);

        tiled_release_i = 1'b1;

        @(posedge clk_i);
        #1;

        tiled_release_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd1,
            "Non-owner tiled release changed direct ownership"
        );

        // Direct clear and a tiled claim in the same cycle return to idle. The
        // tiled claimant must retry after release.
        @(negedge clk_i);

        direct_clear_i = 1'b1;
        tiled_claim_i = 1'b1;

        #1;

        check_condition(
            dut.shared_clear === 1'b1,
            "Direct clear was not routed from direct ownership"
        );

        @(posedge clk_i);
        #1;

        direct_clear_i = 1'b0;
        tiled_claim_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd0,
            "Direct release collision caused immediate tiled handoff"
        );

        // ---------------------------------------------------------------------
        // Asynchronous reset from tiled ownership.
        // ---------------------------------------------------------------------

        @(negedge clk_i);
        tiled_claim_i = 1'b1;

        @(posedge clk_i);
        #1;

        tiled_claim_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd2,
            "Tiled reset context was not acquired"
        );

        @(negedge clk_i);
        #1;

        rst_ni = 1'b0;

        #1;

        check_condition(
            dut.owner_q === 2'd0 &&
            direct_start_ready_o === 1'b0 &&
            tiled_engine_available_o === 1'b0,
            "Asynchronous reset did not clear tiled ownership"
        );

        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            dut.owner_q === 2'd0 &&
            direct_start_ready_o === 1'b1 &&
            tiled_engine_available_o === 1'b1,
            "Physical engine did not recover after tiled-owner reset"
        );

        // ---------------------------------------------------------------------
        // Asynchronous reset from direct ownership.
        // ---------------------------------------------------------------------

        wait_for_direct_ready();

        @(negedge clk_i);
        direct_start_i = 1'b1;

        @(posedge clk_i);
        #1;

        direct_start_i = 1'b0;

        check_condition(
            dut.owner_q === 2'd1,
            "Direct reset context was not acquired"
        );

        @(negedge clk_i);
        #1;

        rst_ni = 1'b0;

        #1;

        check_condition(
            dut.owner_q === 2'd0 &&
            direct_start_ready_o === 1'b0 &&
            tiled_engine_available_o === 1'b0,
            "Asynchronous reset did not clear direct ownership"
        );

        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_condition(
            dut.owner_q === 2'd0 &&
            direct_start_ready_o === 1'b1 &&
            tiled_engine_available_o === 1'b1,
            "Physical engine did not recover after direct-owner reset"
        );

        if (error_count == 0) begin
            $display(
                "PASS: shared physical-engine arbitration passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d shared-engine errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
