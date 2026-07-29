`timescale 1ns/1ps
`default_nettype none

module tb_nce_tensor_scratchpad;

    localparam int unsigned BANK_COUNT       = 4;
    localparam int unsigned WORDS_PER_BANK   = 256;
    localparam int unsigned DATA_WIDTH       = 32;
    localparam int unsigned PORT_COUNT       = 4;
    localparam int unsigned FLAT_ADDR_WIDTH  = 10;
    localparam int unsigned BYTE_COUNT       = 4;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic [PORT_COUNT-1:0] read_enable_i;
    logic [(PORT_COUNT*FLAT_ADDR_WIDTH)-1:0] read_addr_i;
    logic [PORT_COUNT-1:0] read_ready_o;
    logic [PORT_COUNT-1:0] read_conflict_o;
    logic [(PORT_COUNT*DATA_WIDTH)-1:0] read_data_o;
    logic [PORT_COUNT-1:0] read_valid_o;

    logic [PORT_COUNT-1:0] write_enable_i;
    logic [(PORT_COUNT*FLAT_ADDR_WIDTH)-1:0] write_addr_i;
    logic [(PORT_COUNT*DATA_WIDTH)-1:0] write_data_i;
    logic [(PORT_COUNT*BYTE_COUNT)-1:0] write_strb_i;
    logic [PORT_COUNT-1:0] write_ready_o;
    logic [PORT_COUNT-1:0] write_conflict_o;

    integer check_count;
    integer error_count;

    nce_tensor_scratchpad dut (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),

        .read_enable_i     (read_enable_i),
        .read_addr_i       (read_addr_i),
        .read_ready_o      (read_ready_o),
        .read_conflict_o   (read_conflict_o),
        .read_data_o       (read_data_o),
        .read_valid_o      (read_valid_o),

        .write_enable_i    (write_enable_i),
        .write_addr_i      (write_addr_i),
        .write_data_i      (write_data_i),
        .write_strb_i      (write_strb_i),
        .write_ready_o     (write_ready_o),
        .write_conflict_o  (write_conflict_o)
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

    task automatic check_read_response (
        input logic [3:0] expected_valid,
        input logic [127:0] expected_data,
        input string phase
    );
        integer port_index;
        begin
            for (
                port_index = 0;
                port_index < PORT_COUNT;
                port_index = port_index + 1
            ) begin
                check_condition(
                    read_valid_o[port_index] ===
                    expected_valid[port_index],
                    $sformatf(
                        "%s port %0d valid mismatch",
                        phase,
                        port_index
                    )
                );

                check_condition(
                    read_data_o[
                        (port_index * 32) +: 32
                    ] === expected_data[
                        (port_index * 32) +: 32
                    ],
                    $sformatf(
                        "%s port %0d data mismatch",
                        phase,
                        port_index
                    )
                );
            end
        end
    endtask

    task automatic issue_write (
        input logic [3:0] enable,
        input logic [39:0] address,
        input logic [127:0] data,
        input logic [15:0] strobe,
        input logic [3:0] expected_ready,
        input logic [3:0] expected_conflict
    );
        begin
            @(negedge clk_i);

            write_enable_i = enable;
            write_addr_i   = address;
            write_data_i   = data;
            write_strb_i   = strobe;

            #1;

            check_condition(
                write_ready_o === expected_ready,
                "write-ready vector mismatch"
            );

            check_condition(
                write_conflict_o === expected_conflict,
                "write-conflict vector mismatch"
            );

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
        input logic [3:0] enable,
        input logic [39:0] address,
        input logic [3:0] expected_ready,
        input logic [3:0] expected_conflict,
        input logic [3:0] expected_valid,
        input logic [127:0] expected_data,
        input string phase
    );
        begin
            @(negedge clk_i);

            read_enable_i = enable;
            read_addr_i   = address;

            #1;

            check_condition(
                read_ready_o === expected_ready,
                $sformatf("%s ready mismatch", phase)
            );

            check_condition(
                read_conflict_o === expected_conflict,
                $sformatf("%s conflict mismatch", phase)
            );

            @(posedge clk_i);
            #1;

            check_read_response(
                expected_valid,
                expected_data,
                phase
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

        repeat (5) @(posedge clk_i);

        @(negedge clk_i);
        rst_ni = 1'b1;

        @(posedge clk_i);
        #1;

        check_read_response(
            4'b0000,
            128'd0,
            "post-reset"
        );

        // Four consecutive words map to four independent banks, row zero.
        issue_write(
            4'b1111,
            {10'd3, 10'd2, 10'd1, 10'd0},
            {
                32'h4444_4444,
                32'h3333_3333,
                32'h2222_2222,
                32'h1111_1111
            },
            16'hFFFF,
            4'b1111,
            4'b0000
        );

        issue_read(
            4'b1111,
            {10'd3, 10'd2, 10'd1, 10'd0},
            4'b1111,
            4'b0000,
            4'b1111,
            {
                32'h4444_4444,
                32'h3333_3333,
                32'h2222_2222,
                32'h1111_1111
            },
            "row-zero interleaving"
        );

        // Addresses 4..7 map to row one of banks 0..3.
        issue_write(
            4'b1111,
            {10'd7, 10'd6, 10'd5, 10'd4},
            {
                32'h8888_8888,
                32'h7777_7777,
                32'h6666_6666,
                32'h5555_5555
            },
            16'hFFFF,
            4'b1111,
            4'b0000
        );

        issue_read(
            4'b1111,
            {10'd7, 10'd6, 10'd5, 10'd4},
            4'b1111,
            4'b0000,
            4'b1111,
            {
                32'h8888_8888,
                32'h7777_7777,
                32'h6666_6666,
                32'h5555_5555
            },
            "row-one interleaving"
        );

        // All addresses target bank zero. Port zero must win.
        issue_write(
            4'b1111,
            {10'd20, 10'd16, 10'd12, 10'd8},
            {
                32'hDDDD_DDDD,
                32'hCCCC_CCCC,
                32'hBBBB_BBBB,
                32'hAAAA_AAAA
            },
            16'hFFFF,
            4'b0001,
            4'b1110
        );

        issue_read(
            4'b1111,
            {10'd12, 10'd8, 10'd4, 10'd0},
            4'b0001,
            4'b1110,
            4'b0001,
            {
                32'd0,
                32'd0,
                32'd0,
                32'h1111_1111
            },
            "same-bank read conflict"
        );

        // Mixed bank conflicts: ports 0 and 2 win banks 1 and 2.
        issue_read(
            4'b1111,
            {10'd6, 10'd2, 10'd5, 10'd1},
            4'b0101,
            4'b1010,
            4'b0101,
            {
                32'd0,
                32'h3333_3333,
                32'd0,
                32'h2222_2222
            },
            "mixed bank conflicts"
        );

        // Read and write the same address concurrently through different
        // logical lanes. The physical bank must return write-first data.
        @(negedge clk_i);

        read_enable_i = 4'b0001;
        read_addr_i   = {10'd0, 10'd0, 10'd0, 10'd3};

        write_enable_i = 4'b0010;
        write_addr_i   = {10'd0, 10'd0, 10'd3, 10'd0};
        write_data_i   = {
            32'd0,
            32'd0,
            32'hABCD_EF01,
            32'd0
        };
        write_strb_i = {
            4'h0,
            4'h0,
            4'hF,
            4'h0
        };

        #1;

        check_condition(
            read_ready_o === 4'b0001,
            "same-address concurrent read was not accepted"
        );

        check_condition(
            write_ready_o === 4'b0010,
            "same-address concurrent write was not accepted"
        );

        @(posedge clk_i);
        #1;

        check_read_response(
            4'b0001,
            {
                32'd0,
                32'd0,
                32'd0,
                32'hABCD_EF01
            },
            "concurrent write-first access"
        );

        @(negedge clk_i);

        read_enable_i  = '0;
        read_addr_i    = '0;
        write_enable_i = '0;
        write_addr_i   = '0;
        write_data_i   = '0;
        write_strb_i   = '0;

        // Maximum flat address: bank three, row 255.
        issue_write(
            4'b0100,
            {10'd0, 10'd1023, 10'd0, 10'd0},
            {
                32'd0,
                32'hDEAD_BEEF,
                32'd0,
                32'd0
            },
            {
                4'h0,
                4'b0011,
                4'h0,
                4'h0
            },
            4'b0100,
            4'b0000
        );

        issue_read(
            4'b0100,
            {10'd0, 10'd1023, 10'd0, 10'd0},
            4'b0100,
            4'b0000,
            4'b0100,
            {
                32'd0,
                32'h0000_BEEF,
                32'd0,
                32'd0
            },
            "maximum-address partial write"
        );

        // Clear invalidates every bank and blocks requests while asserted.
        @(negedge clk_i);

        clear_i       = 1'b1;
        read_enable_i = 4'b1111;
        read_addr_i   = {10'd3, 10'd2, 10'd1, 10'd0};

        #1;

        check_condition(
            read_ready_o === 4'b0000,
            "read accepted during clear"
        );

        @(posedge clk_i);
        #1;

        check_read_response(
            4'b0000,
            128'd0,
            "clear response"
        );

        @(negedge clk_i);

        clear_i       = 1'b0;
        read_enable_i = '0;
        read_addr_i   = '0;

        issue_read(
            4'b1111,
            {10'd3, 10'd2, 10'd1, 10'd0},
            4'b1111,
            4'b0000,
            4'b0000,
            128'd0,
            "post-clear invalidation"
        );

        // Asynchronous reset also clears response and validity state.
        rst_ni = 1'b0;
        #1;

        check_read_response(
            4'b0000,
            128'd0,
            "asynchronous reset"
        );

        if (error_count == 0) begin
            $display(
                "PASS: tensor scratchpad passed all %0d checks.",
                check_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d tensor-scratchpad errors in %0d checks.",
                error_count,
                check_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
