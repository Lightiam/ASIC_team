`timescale 1ns/1ps
`default_nettype none

module tb_nce_axi_csr_backend;

    localparam logic [31:0] ADDR_DEVICE_ID           = 32'h0000_0000;
    localparam logic [31:0] ADDR_VERSION             = 32'h0000_0004;
    localparam logic [31:0] ADDR_CONTROL             = 32'h0000_0008;
    localparam logic [31:0] ADDR_STATUS              = 32'h0000_000C;
    localparam logic [31:0] ADDR_COMMAND             = 32'h0000_0010;
    localparam logic [31:0] ADDR_COMMAND_COUNT       = 32'h0000_0014;
    localparam logic [31:0] ADDR_COMMAND_ERROR_COUNT = 32'h0000_0018;
    localparam logic [31:0] ADDR_EXECUTE_COUNT       = 32'h0000_001C;
    localparam logic [31:0] ADDR_LAST_COMMAND        = 32'h0000_0020;
    localparam logic [31:0] ADDR_LAST_ERROR          = 32'h0000_0024;

    localparam logic [31:0] ADDR_VECTOR_CONFIG       = 32'h0000_0040;
    localparam logic [31:0] ADDR_VECTOR_STAGE_VALID  = 32'h0000_0044;
    localparam logic [31:0] ADDR_VECTOR_DATA0        = 32'h0000_0060;
    localparam logic [31:0] ADDR_VECTOR_COMMIT       = 32'h0000_0080;

    localparam logic [31:0] ADDR_MATRIX_CONFIG       = 32'h0000_00A0;
    localparam logic [31:0] ADDR_MATRIX_STAGE_VALID  = 32'h0000_00A4;
    localparam logic [31:0] ADDR_MATRIX_DATA0        = 32'h0000_00C0;
    localparam logic [31:0] ADDR_MATRIX_COMMIT       = 32'h0000_00E0;

    localparam logic [31:0] ADDR_ACCUMULATOR0        = 32'h0000_0100;
    localparam logic [31:0] ADDR_VECTOR_VALID_MASK   = 32'h0000_0120;
    localparam logic [31:0] ADDR_MATRIX_VALID_MASK   = 32'h0000_0124;
    localparam logic [31:0] ADDR_LANE_INVALID        = 32'h0000_0128;
    localparam logic [31:0] ADDR_LANE_OVERFLOW       = 32'h0000_012C;
    localparam logic [31:0] ADDR_LANE_UNDERFLOW      = 32'h0000_0130;
    localparam logic [31:0] ADDR_LANE_INEXACT        = 32'h0000_0134;
    localparam logic [31:0] ADDR_GLOBAL_FLAGS        = 32'h0000_0138;

    logic clk_i;
    logic rst_ni;

    logic        write_valid_i;
    logic        write_ready_o;
    logic [31:0] write_addr_i;
    logic [31:0] write_data_i;
    logic [3:0]  write_strb_i;
    logic        write_error_o;

    logic        read_valid_i;
    logic        read_ready_o;
    logic [31:0] read_addr_i;
    logic [31:0] read_data_o;
    logic        read_error_o;

    logic register_clear_o;
    logic accumulator_clear_o;

    logic         vector_write_enable_o;
    logic [3:0]   vector_write_addr_o;
    logic [7:0]   vector_write_lane_enable_o;
    logic [255:0] vector_write_data_o;

    logic         matrix_write_enable_o;
    logic [3:0]   matrix_write_addr_o;
    logic [7:0]   matrix_write_lane_enable_o;
    logic [255:0] matrix_write_data_o;

    logic       cmd_valid_o;
    logic       cmd_ready_i;
    logic [3:0] cmd_opcode_o;
    logic [1:0] cmd_precision_o;
    logic [3:0] cmd_vector_source_addr_o;
    logic [3:0] cmd_matrix_source_addr_o;

    logic       cmd_accept_i;
    logic       cmd_error_i;
    logic [1:0] cmd_error_code_i;
    logic       execute_issue_i;
    logic       operand_valid_i;

    logic [255:0] accumulator_i;
    logic         accumulator_valid_i;
    logic         accumulator_update_i;

    logic [7:0] lane_invalid_i;
    logic [7:0] lane_overflow_i;
    logic [7:0] lane_underflow_i;
    logic [7:0] lane_inexact_i;

    logic invalid_i;
    logic overflow_i;
    logic underflow_i;
    logic inexact_i;

    logic [15:0] vector_valid_mask_i;
    logic [15:0] matrix_valid_mask_i;

    integer test_count;
    integer error_count;
    integer lane_index;

    nce_axi_csr_backend dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),

        .write_valid_i               (write_valid_i),
        .write_ready_o               (write_ready_o),
        .write_addr_i                (write_addr_i),
        .write_data_i                (write_data_i),
        .write_strb_i                (write_strb_i),
        .write_error_o               (write_error_o),

        .read_valid_i                (read_valid_i),
        .read_ready_o                (read_ready_o),
        .read_addr_i                 (read_addr_i),
        .read_data_o                 (read_data_o),
        .read_error_o                (read_error_o),

        .register_clear_o            (register_clear_o),
        .accumulator_clear_o         (accumulator_clear_o),

        .vector_write_enable_o       (vector_write_enable_o),
        .vector_write_addr_o         (vector_write_addr_o),
        .vector_write_lane_enable_o  (vector_write_lane_enable_o),
        .vector_write_data_o         (vector_write_data_o),

        .matrix_write_enable_o       (matrix_write_enable_o),
        .matrix_write_addr_o         (matrix_write_addr_o),
        .matrix_write_lane_enable_o  (matrix_write_lane_enable_o),
        .matrix_write_data_o         (matrix_write_data_o),

        .cmd_valid_o                 (cmd_valid_o),
        .cmd_ready_i                 (cmd_ready_i),
        .cmd_opcode_o                (cmd_opcode_o),
        .cmd_precision_o             (cmd_precision_o),
        .cmd_vector_source_addr_o    (cmd_vector_source_addr_o),
        .cmd_matrix_source_addr_o    (cmd_matrix_source_addr_o),

        .cmd_accept_i                (cmd_accept_i),
        .cmd_error_i                 (cmd_error_i),
        .cmd_error_code_i            (cmd_error_code_i),
        .execute_issue_i             (execute_issue_i),
        .operand_valid_i             (operand_valid_i),

        .accumulator_i               (accumulator_i),
        .accumulator_valid_i         (accumulator_valid_i),
        .accumulator_update_i        (accumulator_update_i),

        .lane_invalid_i              (lane_invalid_i),
        .lane_overflow_i             (lane_overflow_i),
        .lane_underflow_i            (lane_underflow_i),
        .lane_inexact_i              (lane_inexact_i),

        .invalid_i                   (invalid_i),
        .overflow_i                  (overflow_i),
        .underflow_i                 (underflow_i),
        .inexact_i                   (inexact_i),

        .vector_valid_mask_i         (vector_valid_mask_i),
        .matrix_valid_mask_i         (matrix_valid_mask_i)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    always_comb begin
        cmd_accept_i =
            cmd_valid_o &&
            cmd_ready_i;

        cmd_error_i =
            cmd_accept_i &&
            (
                cmd_opcode_o != 4'h4 ||
                cmd_precision_o != 2'b00 ||
                !operand_valid_i
            );

        if (!cmd_error_i) begin
            cmd_error_code_i = 2'b00;
        end
        else if (cmd_opcode_o != 4'h4) begin
            cmd_error_code_i = 2'b01;
        end
        else if (cmd_precision_o != 2'b00) begin
            cmd_error_code_i = 2'b10;
        end
        else begin
            cmd_error_code_i = 2'b11;
        end

        execute_issue_i =
            cmd_accept_i &&
            !cmd_error_i;
    end

    task automatic report_error (
        input string message
    );
        begin
            error_count = error_count + 1;

            if (error_count <= 20) begin
                $display(
                    "ERROR test=%0d: %s",
                    test_count,
                    message
                );
            end
        end
    endtask

    task automatic csr_write (
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [3:0]  strobes,
        input logic        expected_error
    );
        begin
            test_count = test_count + 1;

            @(negedge clk_i);

            write_valid_i = 1'b1;
            write_addr_i  = address;
            write_data_i  = data;
            write_strb_i  = strobes;

            #1;

            if (write_ready_o !== 1'b1) begin
                report_error("Write request was not ready");
            end

            if (write_error_o !== expected_error) begin
                report_error("Write error response mismatch");
            end

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            write_valid_i = 1'b0;
            write_addr_i  = 32'd0;
            write_data_i  = 32'd0;
            write_strb_i  = 4'd0;
        end
    endtask

    task automatic csr_read (
        input logic [31:0] address,
        input logic [31:0] expected_data,
        input logic        expected_error
    );
        begin
            test_count = test_count + 1;

            @(negedge clk_i);

            read_valid_i = 1'b1;
            read_addr_i  = address;

            #1;

            if (read_ready_o !== 1'b1) begin
                report_error("Read request was not ready");
            end

            if (read_error_o !== expected_error) begin
                report_error("Read error response mismatch");
            end

            if (read_data_o !== expected_data) begin
                report_error("Read data mismatch");

                if (error_count <= 20) begin
                    $display(
                        "  address=%08h data=%08h expected=%08h",
                        address,
                        read_data_o,
                        expected_data
                    );
                end
            end

            @(posedge clk_i);

            @(negedge clk_i);

            read_valid_i = 1'b0;
            read_addr_i  = 32'd0;
        end
    endtask

    initial begin
        rst_ni = 1'b0;

        write_valid_i = 1'b0;
        write_addr_i  = 32'd0;
        write_data_i  = 32'd0;
        write_strb_i  = 4'd0;

        read_valid_i = 1'b0;
        read_addr_i  = 32'd0;

        cmd_ready_i     = 1'b1;
        operand_valid_i = 1'b1;

        accumulator_i = {
            32'h4780_0000,
            32'h4700_0000,
            32'h4680_0000,
            32'h4600_0000,
            32'h4580_0000,
            32'h4500_0000,
            32'h4480_0000,
            32'h4400_0000
        };

        accumulator_valid_i  = 1'b1;
        accumulator_update_i = 1'b0;

        lane_invalid_i   = 8'h01;
        lane_overflow_i  = 8'h02;
        lane_underflow_i = 8'h04;
        lane_inexact_i   = 8'h08;

        invalid_i   = 1'b1;
        overflow_i  = 1'b0;
        underflow_i = 1'b1;
        inexact_i   = 1'b1;

        vector_valid_mask_i = 16'h00F3;
        matrix_valid_mask_i = 16'h0C3C;

        test_count  = 0;
        error_count = 0;

        repeat (4) begin
            @(posedge clk_i);
        end

        #1;

        if (
            write_ready_o !== 1'b0 ||
            read_ready_o !== 1'b0
        ) begin
            $fatal(
                1,
                "CSR backend reset readiness is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        csr_read(
            ADDR_DEVICE_ID,
            32'h4E43_4530,
            1'b0
        );

        csr_read(
            ADDR_VERSION,
            32'h0001_0000,
            1'b0
        );

        csr_read(
            32'h0000_0002,
            32'd0,
            1'b1
        );

        csr_read(
            32'h0000_F000,
            32'd0,
            1'b1
        );

        // Vector staging configuration.
        csr_write(
            ADDR_VECTOR_CONFIG,
            32'h0000_FF05,
            4'b0011,
            1'b0
        );

        csr_read(
            ADDR_VECTOR_CONFIG,
            32'h0000_FF05,
            1'b0
        );

        // Stage all eight vector lanes.
        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            csr_write(
                ADDR_VECTOR_DATA0 +
                    (lane_index * 4),
                32'h1111_0000 + lane_index,
                4'b1111,
                1'b0
            );
        end

        csr_read(
            ADDR_VECTOR_STAGE_VALID,
            32'h0000_00FF,
            1'b0
        );

        // Check atomic vector commit before the clock edge.
        test_count = test_count + 1;

        @(negedge clk_i);

        write_valid_i = 1'b1;
        write_addr_i  = ADDR_VECTOR_COMMIT;
        write_data_i  = 32'h0000_0001;
        write_strb_i  = 4'b1111;

        #1;

        if (
            write_ready_o !== 1'b1 ||
            write_error_o !== 1'b0
        ) begin
            report_error(
                "Vector commit write was not accepted"
            );
        end

        @(posedge clk_i);
        #1;

        if (
            vector_write_enable_o !== 1'b1 ||
            vector_write_addr_o !== 4'h5 ||
            vector_write_lane_enable_o !== 8'hFF
        ) begin
            report_error(
                "Registered vector commit control mismatch"
            );
        end

        for (
            lane_index = 0;
            lane_index < 8;
            lane_index = lane_index + 1
        ) begin
            if (
                vector_write_data_o[
                    (lane_index * 32) +: 32
                ]
                !==
                (32'h1111_0000 + lane_index)
            ) begin
                report_error(
                    "Registered vector commit data mismatch"
                );
            end
        end

        @(negedge clk_i);
        write_valid_i = 1'b0;

        csr_read(
            ADDR_VECTOR_STAGE_VALID,
            32'h0000_0000,
            1'b0
        );

        // Commit without staged data must fail.
        csr_write(
            ADDR_VECTOR_COMMIT,
            32'h0000_0001,
            4'b1111,
            1'b1
        );

        // Matrix staging.
        csr_write(
            ADDR_MATRIX_CONFIG,
            32'h0000_0F09,
            4'b0011,
            1'b0
        );

        for (
            lane_index = 0;
            lane_index < 4;
            lane_index = lane_index + 1
        ) begin
            csr_write(
                ADDR_MATRIX_DATA0 +
                    (lane_index * 4),
                32'h2222_0000 + lane_index,
                4'b1111,
                1'b0
            );
        end

        csr_read(
            ADDR_MATRIX_STAGE_VALID,
            32'h0000_000F,
            1'b0
        );

        test_count = test_count + 1;

        @(negedge clk_i);

        write_valid_i = 1'b1;
        write_addr_i  = ADDR_MATRIX_COMMIT;
        write_data_i  = 32'h0000_0001;
        write_strb_i  = 4'b1111;

        #1;

        if (
            write_ready_o !== 1'b1 ||
            write_error_o !== 1'b0
        ) begin
            report_error(
                "Matrix commit write was not accepted"
            );
        end

        @(posedge clk_i);
        #1;

        if (
            matrix_write_enable_o !== 1'b1 ||
            matrix_write_addr_o !== 4'h9 ||
            matrix_write_lane_enable_o !== 8'h0F
        ) begin
            report_error(
                "Registered matrix commit control mismatch"
            );
        end

        for (
            lane_index = 0;
            lane_index < 4;
            lane_index = lane_index + 1
        ) begin
            if (
                matrix_write_data_o[
                    (lane_index * 32) +: 32
                ]
                !==
                (32'h2222_0000 + lane_index)
            ) begin
                report_error(
                    "Registered matrix commit data mismatch"
                );
            end
        end

        @(negedge clk_i);
        write_valid_i = 1'b0;

        csr_read(
            ADDR_MATRIX_STAGE_VALID,
            32'h0000_0000,
            1'b0
        );

        // Supported command.
        csr_write(
            ADDR_COMMAND,
            32'h0000_9104,
            4'b1111,
            1'b0
        );

        // Unsupported opcode.
        csr_write(
            ADDR_COMMAND,
            32'h0000_9101,
            4'b1111,
            1'b1
        );

        // Invalid operands.
        operand_valid_i = 1'b0;

        csr_write(
            ADDR_COMMAND,
            32'h0000_9104,
            4'b1111,
            1'b1
        );

        operand_valid_i = 1'b1;

        csr_read(
            ADDR_COMMAND_COUNT,
            32'd3,
            1'b0
        );

        csr_read(
            ADDR_COMMAND_ERROR_COUNT,
            32'd2,
            1'b0
        );

        csr_read(
            ADDR_EXECUTE_COUNT,
            32'd1,
            1'b0
        );

        csr_read(
            ADDR_LAST_COMMAND,
            32'h0000_9104,
            1'b0
        );

        csr_read(
            ADDR_LAST_ERROR,
            32'h0000_0007,
            1'b0
        );

        // Clear pulses.
        test_count = test_count + 1;

        @(negedge clk_i);

        write_valid_i = 1'b1;
        write_addr_i  = ADDR_CONTROL;
        write_data_i  = 32'h0000_000F;
        write_strb_i  = 4'b0001;

        #1;

        if (
            write_ready_o !== 1'b1 ||
            write_error_o !== 1'b0
        ) begin
            report_error(
                "Control write was not accepted"
            );
        end

        @(posedge clk_i);
        #1;

        if (
            register_clear_o !== 1'b1 ||
            accumulator_clear_o !== 1'b1
        ) begin
            report_error(
                "Registered control clear pulses were not asserted"
            );
        end

        @(negedge clk_i);
        write_valid_i = 1'b0;

        @(posedge clk_i);
        #1;

        if (
            register_clear_o !== 1'b0 ||
            accumulator_clear_o !== 1'b0
        ) begin
            report_error(
                "Control clear pulses lasted longer than one cycle"
            );
        end

        csr_read(
            ADDR_COMMAND_COUNT,
            32'd0,
            1'b0
        );

        csr_read(
            ADDR_COMMAND_ERROR_COUNT,
            32'd0,
            1'b0
        );

        csr_read(
            ADDR_EXECUTE_COUNT,
            32'd0,
            1'b0
        );

        // Read execution results.
        csr_read(
            ADDR_ACCUMULATOR0,
            32'h4400_0000,
            1'b0
        );

        csr_read(
            ADDR_ACCUMULATOR0 + 32'h1C,
            32'h4780_0000,
            1'b0
        );

        csr_read(
            ADDR_VECTOR_VALID_MASK,
            32'h0000_00F3,
            1'b0
        );

        csr_read(
            ADDR_MATRIX_VALID_MASK,
            32'h0000_0C3C,
            1'b0
        );

        csr_read(
            ADDR_LANE_INVALID,
            32'h0000_0001,
            1'b0
        );

        csr_read(
            ADDR_LANE_OVERFLOW,
            32'h0000_0002,
            1'b0
        );

        csr_read(
            ADDR_LANE_UNDERFLOW,
            32'h0000_0004,
            1'b0
        );

        csr_read(
            ADDR_LANE_INEXACT,
            32'h0000_0008,
            1'b0
        );

        csr_read(
            ADDR_GLOBAL_FLAGS,
            32'h0000_000D,
            1'b0
        );

        // Read-only register writes must fail.
        csr_write(
            ADDR_DEVICE_ID,
            32'hDEAD_BEEF,
            4'b1111,
            1'b1
        );

        if (error_count == 0) begin
            $display(
                "PASS: nce_axi_csr_backend passed all %0d CSR checks.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d CSR errors detected in %0d checks.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
