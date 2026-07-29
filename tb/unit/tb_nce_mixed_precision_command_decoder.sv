`timescale 1ns/1ps
`default_nettype none

module tb_nce_mixed_precision_command_decoder;

    logic       flush_i;

    logic       cmd_valid_i;
    logic       cmd_ready_o;

    logic [3:0] cmd_opcode_i;
    logic [1:0] cmd_precision_i;

    logic       operand_valid_i;
    logic       execute_ready_i;

    logic       execute_valid_o;
    logic       cmd_accept_o;
    logic       cmd_error_o;
    logic [1:0] cmd_error_code_o;

    integer check_count;
    integer error_count;

    localparam logic [1:0] ERROR_NONE                  = 2'b00;
    localparam logic [1:0] ERROR_UNSUPPORTED_OPCODE    = 2'b01;
    localparam logic [1:0] ERROR_UNSUPPORTED_PRECISION = 2'b10;
    localparam logic [1:0] ERROR_INVALID_OPERAND       = 2'b11;

    nce_mixed_precision_command_decoder dut (
        .flush_i          (flush_i),

        .cmd_valid_i      (cmd_valid_i),
        .cmd_ready_o      (cmd_ready_o),

        .cmd_opcode_i     (cmd_opcode_i),
        .cmd_precision_i  (cmd_precision_i),

        .operand_valid_i  (operand_valid_i),
        .execute_ready_i  (execute_ready_i),

        .execute_valid_o  (execute_valid_o),
        .cmd_accept_o     (cmd_accept_o),
        .cmd_error_o      (cmd_error_o),
        .cmd_error_code_o (cmd_error_code_o)
    );

    task automatic check_case (
        input string      case_name,

        input logic       expected_ready,
        input logic       expected_accept,
        input logic       expected_execute,
        input logic       expected_error,
        input logic [1:0] expected_error_code
    );
        begin
            #1;
            check_count = check_count + 1;

            if (
                cmd_ready_o !== expected_ready ||
                cmd_accept_o !== expected_accept ||
                execute_valid_o !== expected_execute ||
                cmd_error_o !== expected_error ||
                cmd_error_code_o !== expected_error_code
            ) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: %s",
                    case_name
                );

                $display(
                    "  ready/accept/execute/error/code = %b %b %b %b %b",
                    cmd_ready_o,
                    cmd_accept_o,
                    execute_valid_o,
                    cmd_error_o,
                    cmd_error_code_o
                );

                $display(
                    "  expected                        = %b %b %b %b %b",
                    expected_ready,
                    expected_accept,
                    expected_execute,
                    expected_error,
                    expected_error_code
                );
            end
        end
    endtask

    initial begin
        flush_i         = 1'b0;
        cmd_valid_i     = 1'b0;
        cmd_opcode_i    = 4'h0;
        cmd_precision_i = 2'b00;
        operand_valid_i = 1'b0;
        execute_ready_i = 1'b0;

        check_count = 0;
        error_count = 0;

        // Idle.
        check_case(
            "Idle",
            1'b1,
            1'b0,
            1'b0,
            1'b0,
            ERROR_NONE
        );

        // Valid INT8 command.
        cmd_valid_i     = 1'b1;
        cmd_opcode_i    = 4'h4;
        cmd_precision_i = 2'b00;
        operand_valid_i = 1'b1;
        execute_ready_i = 1'b1;

        check_case(
            "DOT4_MAC plus INT8X4",
            1'b1,
            1'b1,
            1'b1,
            1'b0,
            ERROR_NONE
        );

        // Valid BF16 command.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b01;

        check_case(
            "MAC plus BF16X2",
            1'b1,
            1'b1,
            1'b1,
            1'b0,
            ERROR_NONE
        );

        // Valid BF24 command.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b10;

        check_case(
            "MAC plus BF24",
            1'b1,
            1'b1,
            1'b1,
            1'b0,
            ERROR_NONE
        );

        // INT8 execution backpressure.
        cmd_opcode_i    = 4'h4;
        cmd_precision_i = 2'b00;
        execute_ready_i = 1'b0;

        check_case(
            "INT8 execution stall",
            1'b0,
            1'b0,
            1'b0,
            1'b0,
            ERROR_NONE
        );

        // BF16 execution backpressure.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b01;

        check_case(
            "BF16 execution stall",
            1'b0,
            1'b0,
            1'b0,
            1'b0,
            ERROR_NONE
        );

        // BF24 execution backpressure.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b10;

        check_case(
            "BF24 execution stall",
            1'b0,
            1'b0,
            1'b0,
            1'b0,
            ERROR_NONE
        );

        // Invalid operand for supported INT8 command.
        cmd_opcode_i    = 4'h4;
        cmd_precision_i = 2'b00;
        operand_valid_i = 1'b0;

        check_case(
            "INT8 invalid operand",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_INVALID_OPERAND
        );

        // Invalid operand for supported BF16 command.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b01;

        check_case(
            "BF16 invalid operand",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_INVALID_OPERAND
        );

        // Invalid operand for supported BF24 command.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b10;

        check_case(
            "BF24 invalid operand",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_INVALID_OPERAND
        );

        operand_valid_i = 1'b1;

        // Unknown opcode.
        cmd_opcode_i    = 4'hF;
        cmd_precision_i = 2'b00;

        check_case(
            "Unsupported opcode",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_UNSUPPORTED_OPCODE
        );

        // Native FP32 precision is not implemented.
        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b11;

        check_case(
            "Unsupported native FP32 precision",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_UNSUPPORTED_PRECISION
        );

        // Recognized precision with wrong opcode.
        cmd_opcode_i    = 4'h4;
        cmd_precision_i = 2'b01;

        check_case(
            "DOT4_MAC plus BF16X2 mismatch",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_UNSUPPORTED_PRECISION
        );

        // BF24 is recognized but cannot use the DOT4 opcode.
        cmd_opcode_i    = 4'h4;
        cmd_precision_i = 2'b10;

        check_case(
            "DOT4_MAC plus BF24 mismatch",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_UNSUPPORTED_PRECISION
        );

        cmd_opcode_i    = 4'h3;
        cmd_precision_i = 2'b00;

        check_case(
            "MAC plus INT8X4 mismatch",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_UNSUPPORTED_PRECISION
        );

        // Rejected commands ignore execution backpressure.
        cmd_opcode_i    = 4'hF;
        cmd_precision_i = 2'b11;
        execute_ready_i = 1'b0;

        check_case(
            "Rejected command consumed during backpressure",
            1'b1,
            1'b1,
            1'b0,
            1'b1,
            ERROR_UNSUPPORTED_OPCODE
        );

        // Invalid command while cmd_valid is low.
        cmd_valid_i = 1'b0;

        check_case(
            "Invalid command without valid",
            1'b1,
            1'b0,
            1'b0,
            1'b0,
            ERROR_NONE
        );

        // Flush blocks all acceptance.
        cmd_valid_i = 1'b1;
        flush_i     = 1'b1;

        check_case(
            "Flush",
            1'b0,
            1'b0,
            1'b0,
            1'b0,
            ERROR_NONE
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_mixed_precision_command_decoder passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d decoder errors detected in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
