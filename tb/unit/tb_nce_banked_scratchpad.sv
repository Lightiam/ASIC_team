`timescale 1ns/1ps
`default_nettype none

module tb_nce_banked_scratchpad;

    localparam int unsigned BANK_COUNT       = 4;
    localparam int unsigned WORDS_PER_BANK   = 256;
    localparam int unsigned DATA_WIDTH       = 32;
    localparam int unsigned BANK_ADDR_WIDTH  = 8;
    localparam int unsigned BYTE_COUNT       = 4;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic [BANK_COUNT-1:0] read_enable_i;

    logic [
        (BANK_COUNT * BANK_ADDR_WIDTH)-1:0
    ] read_addr_i;

    logic [
        (BANK_COUNT * DATA_WIDTH)-1:0
    ] read_data_o;

    logic [BANK_COUNT-1:0] read_valid_o;

    logic [BANK_COUNT-1:0] write_enable_i;

    logic [
        (BANK_COUNT * BANK_ADDR_WIDTH)-1:0
    ] write_addr_i;

    logic [
        (BANK_COUNT * DATA_WIDTH)-1:0
    ] write_data_i;

    logic [
        (BANK_COUNT * BYTE_COUNT)-1:0
    ] write_strb_i;

    integer check_count;
    integer error_count;

    nce_banked_scratchpad #(
        .BANK_COUNT        (BANK_COUNT),
        .WORDS_PER_BANK    (WORDS_PER_BANK),
        .DATA_WIDTH        (DATA_WIDTH),
        .BANK_ADDR_WIDTH   (BANK_ADDR_WIDTH),
        .BYTE_COUNT        (BYTE_COUNT)
    ) dut (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),

        .read_enable_i     (read_enable_i),
        .read_addr_i       (read_addr_i),
        .read_data_o       (read_data_o),
        .read_valid_o      (read_valid_o),

        .write_enable_i    (write_enable_i),
        .write_addr_i      (write_addr_i),
        .write_data_i      (write_data_i),
        .write_strb_i      (write_strb_i)
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

    task automatic check_read_vector (
        input logic [BANK_COUNT-1:0] expected_valid,
        input logic [
            (BANK_COUNT * DATA_WIDTH)-1:0
        ] expected_data,
        input string phase_name
    );

        integer bank_index;

        begin
            for (
                bank_index = 0;
                bank_index < BANK_COUNT;
                bank_index = bank_index + 1
            ) begin
                check_condition(
                    read_valid_o[bank_index] ===
                    expected_valid[bank_index],
                    $sformatf(
                        "%s: bank %0d valid mismatch",
                        phase_name,
                        bank_index
                    )
                );

                check_condition(
                    read_data_o[
                        (bank_index * DATA_WIDTH) +:
                        DATA_WIDTH
                    ] === expected_data[
                        (bank_index * DATA_WIDTH) +:
                        DATA_WIDTH
                    ],
                    $sformatf(
                        "%s: bank %0d data mismatch",
                        phase_name,
                        bank_index
                    )
                );

                if (
                    read_data_o[
                        (bank_index * DATA_WIDTH) +:
                        DATA_WIDTH
                    ] !== expected_data[
                        (bank_index * DATA_WIDTH) +:
                        DATA_WIDTH
                    ]
                ) begin
                    $display(
                        "  bank=%0d data=%08h expected=%08h",
                        bank_index,
                        read_data_o[
                            (bank_index * DATA_WIDTH) +:
                            DATA_WIDTH
                        ],
                        expected_data[
                            (bank_index * DATA_WIDTH) +:
                            DATA_WIDTH
                        ]
                    );
                end
            end
        end
    endtask

    task automatic issue_write (
        input logic [BANK_COUNT-1:0] bank_enable,
        input logic [
            (BANK_COUNT * BANK_ADDR_WIDTH)-1:0
        ] bank_addr,
        input logic [
            (BANK_COUNT * DATA_WIDTH)-1:0
        ] bank_data,
        input logic [
            (BANK_COUNT * BYTE_COUNT)-1:0
        ] bank_strb
    );
        begin
            @(negedge clk_i);

            write_enable_i = bank_enable;
            write_addr_i   = bank_addr;
            write_data_i   = bank_data;
            write_strb_i   = bank_strb;

            @(posedge clk_i);
            #1;

            @(negedge clk_i);

            write_enable_i = '0;
            write_addr_i   = '0;
            write_data_i   = '0;
            write_strb_i   = '0;
        end
    endtask

    task automatic issue_read (
        input logic [BANK_COUNT-1:0] bank_enable,
        input logic [
            (BANK_COUNT * BANK_ADDR_WIDTH)-1:0
        ] bank_addr,
        input logic [BANK_COUNT-1:0] expected_valid,
        input logic [
            (BANK_COUNT * DATA_WIDTH)-1:0
        ] expected_data,
        input string phase_name
    );
        begin
            @(negedge clk_i);

            read_enable_i = bank_enable;
            read_addr_i   = bank_addr;

            @(posedge clk_i);
            #1;

            check_read_vector(
                expected_valid,
                expected_data,
                phase_name
            );

            @(negedge clk_i);

            read_enable_i = '0;
            read_addr_i   = '0;
        end
    endtask

    initial begin
        rst_ni  = 1'b0;
        clear_i = 1'b0;

        read_enable_i = '0;
        read_addr_i   = '0;

        write_enable_i = '0;
        write_addr_i   = '0;
        write_data_i   = '0;
        write_strb_i   = '0;

        check_count = 0;
        error_count = 0;

        repeat (5) begin
            @(posedge clk_i);
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b0000,
            128'd0,
            "post-reset outputs"
        );

        // ---------------------------------------------------------------------
        // Four-bank parallel full-word write.
        //
        // The same local row exists independently in every bank.
        // ---------------------------------------------------------------------

        issue_write(
            4'b1111,
            {
                8'd7,
                8'd7,
                8'd7,
                8'd7
            },
            {
                32'h0D0E_0F10,
                32'h090A_0B0C,
                32'h0506_0708,
                32'h0102_0304
            },
            {
                4'hF,
                4'hF,
                4'hF,
                4'hF
            }
        );

        // Explicitly prove that the response does not change before the
        // synchronous read clock edge.
        @(negedge clk_i);

        read_enable_i = 4'b1111;
        read_addr_i = {
            8'd7,
            8'd7,
            8'd7,
            8'd7
        };

        #1;

        check_read_vector(
            4'b0000,
            128'd0,
            "read latency before response edge"
        );

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b1111,
            {
                32'h0D0E_0F10,
                32'h090A_0B0C,
                32'h0506_0708,
                32'h0102_0304
            },
            "parallel bank read"
        );

        @(negedge clk_i);
        read_enable_i = '0;
        read_addr_i   = '0;

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b0000,
            128'd0,
            "disabled read response"
        );

        // ---------------------------------------------------------------------
        // Partial byte write to an already valid word.
        //
        // Old bank-0 word: 01 02 03 04
        // New data:        AA BB CC DD
        // Strobe:          0  1  0  1
        // Result:          01 BB 03 DD
        // ---------------------------------------------------------------------

        issue_write(
            4'b0001,
            {
                8'd0,
                8'd0,
                8'd0,
                8'd7
            },
            {
                32'd0,
                32'd0,
                32'd0,
                32'hAABB_CCDD
            },
            {
                4'h0,
                4'h0,
                4'h0,
                4'b0101
            }
        );

        issue_read(
            4'b1111,
            {
                8'd7,
                8'd7,
                8'd7,
                8'd7
            },
            4'b1111,
            {
                32'h0D0E_0F10,
                32'h090A_0B0C,
                32'h0506_0708,
                32'h01BB_03DD
            },
            "partial valid-word update"
        );

        // ---------------------------------------------------------------------
        // Partial write to an invalid word.
        //
        // Only bytes 1 and 0 are enabled, so upper bytes must become zero.
        // ---------------------------------------------------------------------

        issue_write(
            4'b0010,
            {
                8'd0,
                8'd0,
                8'd9,
                8'd0
            },
            {
                32'd0,
                32'd0,
                32'hA1B2_C3D4,
                32'd0
            },
            {
                4'h0,
                4'h0,
                4'b0011,
                4'h0
            }
        );

        issue_read(
            4'b0010,
            {
                8'd0,
                8'd0,
                8'd9,
                8'd0
            },
            4'b0010,
            {
                32'd0,
                32'd0,
                32'h0000_C3D4,
                32'd0
            },
            "partial invalid-word update"
        );

        // ---------------------------------------------------------------------
        // A zero byte-strobe mask must not create a valid word.
        // ---------------------------------------------------------------------

        issue_write(
            4'b0100,
            {
                8'd0,
                8'd10,
                8'd0,
                8'd0
            },
            {
                32'd0,
                32'hDEAD_BEEF,
                32'd0,
                32'd0
            },
            {
                4'h0,
                4'h0,
                4'h0,
                4'h0
            }
        );

        issue_read(
            4'b0100,
            {
                8'd0,
                8'd10,
                8'd0,
                8'd0
            },
            4'b0000,
            128'd0,
            "zero-strobe write rejection"
        );

        // ---------------------------------------------------------------------
        // Same-cycle same-address read/write collision.
        //
        // Bank 3 old value: 0D 0E 0F 10
        // New data:         FF EE DD CC
        // Strobe:           1  1  0  0
        // Forwarded result: FF EE 0F 10
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        read_enable_i  = 4'b1000;
        read_addr_i    = {
            8'd7,
            8'd0,
            8'd0,
            8'd0
        };

        write_enable_i = 4'b1000;
        write_addr_i   = {
            8'd7,
            8'd0,
            8'd0,
            8'd0
        };

        write_data_i = {
            32'hFFEE_DDCC,
            32'd0,
            32'd0,
            32'd0
        };

        write_strb_i = {
            4'b1100,
            4'h0,
            4'h0,
            4'h0
        };

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b1000,
            {
                32'hFFEE_0F10,
                32'd0,
                32'd0,
                32'd0
            },
            "write-first collision"
        );

        @(negedge clk_i);

        read_enable_i  = '0;
        read_addr_i    = '0;
        write_enable_i = '0;
        write_addr_i   = '0;
        write_data_i   = '0;
        write_strb_i   = '0;

        issue_read(
            4'b1000,
            {
                8'd7,
                8'd0,
                8'd0,
                8'd0
            },
            4'b1000,
            {
                32'hFFEE_0F10,
                32'd0,
                32'd0,
                32'd0
            },
            "stored write-first result"
        );

        // ---------------------------------------------------------------------
        // One bank can read one row while writing another row.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        read_enable_i = 4'b0001;
        read_addr_i = {
            8'd0,
            8'd0,
            8'd0,
            8'd7
        };

        write_enable_i = 4'b0001;
        write_addr_i = {
            8'd0,
            8'd0,
            8'd0,
            8'd11
        };

        write_data_i = {
            32'd0,
            32'd0,
            32'd0,
            32'hCAFE_BABE
        };

        write_strb_i = {
            4'h0,
            4'h0,
            4'h0,
            4'hF
        };

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b0001,
            {
                32'd0,
                32'd0,
                32'd0,
                32'h01BB_03DD
            },
            "simultaneous different-address read/write"
        );

        @(negedge clk_i);

        read_enable_i  = '0;
        read_addr_i    = '0;
        write_enable_i = '0;
        write_addr_i   = '0;
        write_data_i   = '0;
        write_strb_i   = '0;

        issue_read(
            4'b0001,
            {
                8'd0,
                8'd0,
                8'd0,
                8'd11
            },
            4'b0001,
            {
                32'd0,
                32'd0,
                32'd0,
                32'hCAFE_BABE
            },
            "simultaneous write storage"
        );

        // ---------------------------------------------------------------------
        // Clear must dominate writes and invalidate every bank.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        clear_i = 1'b1;

        write_enable_i = 4'b1111;
        write_addr_i = {
            8'd7,
            8'd7,
            8'd7,
            8'd7
        };

        write_data_i = {
            32'hFFFF_FFFF,
            32'hFFFF_FFFF,
            32'hFFFF_FFFF,
            32'hFFFF_FFFF
        };

        write_strb_i = {
            4'hF,
            4'hF,
            4'hF,
            4'hF
        };

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b0000,
            128'd0,
            "clear response"
        );

        @(negedge clk_i);

        clear_i        = 1'b0;
        write_enable_i = '0;
        write_addr_i   = '0;
        write_data_i   = '0;
        write_strb_i   = '0;

        issue_read(
            4'b1111,
            {
                8'd7,
                8'd7,
                8'd7,
                8'd7
            },
            4'b0000,
            128'd0,
            "clear invalidation"
        );

        // A partial write after clear must use zero rather than stale data.
        issue_write(
            4'b0001,
            {
                8'd0,
                8'd0,
                8'd0,
                8'd7
            },
            {
                32'd0,
                32'd0,
                32'd0,
                32'hFFFF_FFAA
            },
            {
                4'h0,
                4'h0,
                4'h0,
                4'b0001
            }
        );

        issue_read(
            4'b0001,
            {
                8'd0,
                8'd0,
                8'd0,
                8'd7
            },
            4'b0001,
            {
                32'd0,
                32'd0,
                32'd0,
                32'h0000_00AA
            },
            "post-clear partial write"
        );

        // ---------------------------------------------------------------------
        // Asynchronous reset clears output and validity state.
        // ---------------------------------------------------------------------

        @(negedge clk_i);

        read_enable_i = 4'b0001;
        read_addr_i = {
            8'd0,
            8'd0,
            8'd0,
            8'd7
        };

        @(posedge clk_i);
        #1;

        check_read_vector(
            4'b0001,
            {
                32'd0,
                32'd0,
                32'd0,
                32'h0000_00AA
            },
            "pre-reset read"
        );

        rst_ni = 1'b0;
        #1;

        check_read_vector(
            4'b0000,
            128'd0,
            "asynchronous reset response"
        );

        @(negedge clk_i);

        read_enable_i = '0;
        read_addr_i   = '0;
        rst_ni        = 1'b1;

        issue_read(
            4'b0001,
            {
                8'd0,
                8'd0,
                8'd0,
                8'd7
            },
            4'b0000,
            128'd0,
            "post-reset invalidation"
        );

        if (error_count == 0) begin
            $display(
                "PASS: banked scratchpad passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d scratchpad errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
