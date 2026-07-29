`timescale 1ns/1ps
`default_nettype none

module tb_nce_int8_command_decoder;

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

    logic       vector_flush;
    logic       vector_cmd_valid;
    logic [3:0] vector_opcode;
    logic [1:0] vector_precision;
    logic       vector_operand_valid;
    logic       vector_execute_ready;

    logic       expected_cmd_ready;
    logic       expected_execute_valid;
    logic       expected_cmd_accept;
    logic       expected_cmd_error;
    logic [1:0] expected_error_code;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_int8_command_decoder dut (
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

    initial begin
        flush_i                = 1'b0;
        cmd_valid_i            = 1'b0;
        cmd_opcode_i           = 4'd0;
        cmd_precision_i        = 2'd0;
        operand_valid_i        = 1'b0;
        execute_ready_i        = 1'b0;

        vector_flush           = 1'b0;
        vector_cmd_valid       = 1'b0;
        vector_opcode          = 4'd0;
        vector_precision       = 2'd0;
        vector_operand_valid   = 1'b0;
        vector_execute_ready   = 1'b0;

        expected_cmd_ready     = 1'b0;
        expected_execute_valid = 1'b0;
        expected_cmd_accept    = 1'b0;
        expected_cmd_error     = 1'b0;
        expected_error_code    = 2'd0;

        test_count             = 0;
        error_count            = 0;

        vector_file = $fopen(
            "build/int8_command_decoder_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open command-decoder vectors."
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h %h\n",
                vector_flush,
                vector_cmd_valid,
                vector_opcode,
                vector_precision,
                vector_operand_valid,
                vector_execute_ready,
                expected_cmd_ready,
                expected_execute_valid,
                expected_cmd_accept,
                expected_cmd_error,
                expected_error_code
            );

            if (scan_result == 11) begin
                flush_i         = vector_flush;
                cmd_valid_i     = vector_cmd_valid;
                cmd_opcode_i    = vector_opcode;
                cmd_precision_i = vector_precision;
                operand_valid_i = vector_operand_valid;
                execute_ready_i = vector_execute_ready;

                #1;

                test_count = test_count + 1;

                if (
                    cmd_ready_o !== expected_cmd_ready ||
                    execute_valid_o !== expected_execute_valid ||
                    cmd_accept_o !== expected_cmd_accept ||
                    cmd_error_o !== expected_cmd_error ||
                    cmd_error_code_o !== expected_error_code
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR test=%0d flush=%h valid=%h opcode=%h precision=%h operands=%h exec_ready=%h ready=%h/%h exec_valid=%h/%h accept=%h/%h error=%h/%h code=%h/%h",
                            test_count,
                            vector_flush,
                            vector_cmd_valid,
                            vector_opcode,
                            vector_precision,
                            vector_operand_valid,
                            vector_execute_ready,
                            cmd_ready_o,
                            expected_cmd_ready,
                            execute_valid_o,
                            expected_execute_valid,
                            cmd_accept_o,
                            expected_cmd_accept,
                            cmd_error_o,
                            expected_cmd_error,
                            cmd_error_code_o,
                            expected_error_code
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_int8_command_decoder passed all %0d exhaustive vectors.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d tests.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
