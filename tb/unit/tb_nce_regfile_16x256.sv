`timescale 1ns/1ps
`default_nettype none

module tb_nce_regfile_16x256;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic [3:0]   read_addr_a_i;
    logic [255:0] read_data_a_o;
    logic         read_valid_a_o;

    logic [3:0]   read_addr_b_i;
    logic [255:0] read_data_b_o;
    logic         read_valid_b_o;

    logic         write_enable_i;
    logic [3:0]   write_addr_i;
    logic [7:0]   write_lane_enable_i;
    logic [255:0] write_data_i;

    logic [15:0] valid_mask_o;

    logic         vector_clear;
    logic         vector_write_enable;
    logic [3:0]   vector_write_addr;
    logic [7:0]   vector_lane_enable;
    logic [255:0] vector_write_data;
    logic [3:0]   vector_read_addr_a;
    logic [3:0]   vector_read_addr_b;

    logic [255:0] expected_read_data_a;
    logic         expected_read_valid_a;
    logic [255:0] expected_read_data_b;
    logic         expected_read_valid_b;
    logic [15:0]  expected_valid_mask;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_regfile_16x256 dut (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .clear_i              (clear_i),

        .read_addr_a_i        (read_addr_a_i),
        .read_data_a_o        (read_data_a_o),
        .read_valid_a_o       (read_valid_a_o),

        .read_addr_b_i        (read_addr_b_i),
        .read_data_b_o        (read_data_b_o),
        .read_valid_b_o       (read_valid_b_o),

        .write_enable_i       (write_enable_i),
        .write_addr_i         (write_addr_i),
        .write_lane_enable_i  (write_lane_enable_i),
        .write_data_i         (write_data_i),

        .valid_mask_o         (valid_mask_o)
    );

    initial begin
        clk_i = 1'b0;

        forever begin
            #5 clk_i = ~clk_i;
        end
    end

    task automatic check_outputs (
        input string phase_name,
        input logic  check_valid_mask
    );
        begin
            if (
                read_data_a_o !== expected_read_data_a ||
                read_valid_a_o !== expected_read_valid_a ||
                read_data_b_o !== expected_read_data_b ||
                read_valid_b_o !== expected_read_valid_b ||
                (
                    check_valid_mask &&
                    valid_mask_o !== expected_valid_mask
                )
            ) begin
                error_count = error_count + 1;

                if (error_count <= 20) begin
                    $display(
                        "%s ERROR test=%0d read_a=%064h/%064h valid_a=%h/%h read_b=%064h/%064h valid_b=%h/%h mask=%04h/%04h check_mask=%h",
                        phase_name,
                        test_count + 1,
                        read_data_a_o,
                        expected_read_data_a,
                        read_valid_a_o,
                        expected_read_valid_a,
                        read_data_b_o,
                        expected_read_data_b,
                        read_valid_b_o,
                        expected_read_valid_b,
                        valid_mask_o,
                        expected_valid_mask,
                        check_valid_mask
                    );
                end
            end
        end
    endtask

    initial begin
        rst_ni                 = 1'b0;
        clear_i                = 1'b0;

        read_addr_a_i          = 4'd0;
        read_addr_b_i          = 4'd0;

        write_enable_i         = 1'b0;
        write_addr_i           = 4'd0;
        write_lane_enable_i    = 8'd0;
        write_data_i           = 256'd0;

        vector_clear           = 1'b0;
        vector_write_enable    = 1'b0;
        vector_write_addr      = 4'd0;
        vector_lane_enable     = 8'd0;
        vector_write_data      = 256'd0;
        vector_read_addr_a     = 4'd0;
        vector_read_addr_b     = 4'd0;

        expected_read_data_a   = 256'd0;
        expected_read_valid_a  = 1'b0;
        expected_read_data_b   = 256'd0;
        expected_read_valid_b  = 1'b0;
        expected_valid_mask    = 16'd0;

        test_count             = 0;
        error_count            = 0;

        repeat (3) begin
            @(posedge clk_i);
        end

        #1;

        if (
            read_data_a_o !== 256'd0 ||
            read_valid_a_o !== 1'b0 ||
            read_data_b_o !== 256'd0 ||
            read_valid_b_o !== 1'b0 ||
            valid_mask_o !== 16'd0
        ) begin
            $fatal(
                1,
                "Register-file reset state is incorrect."
            );
        end

        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/regfile_16x256_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open register-file vectors."
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h %h %h\n",
                vector_clear,
                vector_write_enable,
                vector_write_addr,
                vector_lane_enable,
                vector_write_data,
                vector_read_addr_a,
                vector_read_addr_b,
                expected_read_data_a,
                expected_read_valid_a,
                expected_read_data_b,
                expected_read_valid_b,
                expected_valid_mask
            );

            if (scan_result == 12) begin
                @(negedge clk_i);

                clear_i             = vector_clear;
                write_enable_i      = vector_write_enable;
                write_addr_i        = vector_write_addr;
                write_lane_enable_i = vector_lane_enable;
                write_data_i        = vector_write_data;
                read_addr_a_i       = vector_read_addr_a;
                read_addr_b_i       = vector_read_addr_b;

                #1;

                // Verify combinational write-through behavior.
                check_outputs("PRE-CLOCK", 1'b0);

                @(posedge clk_i);
                #1;

                // Verify the committed sequential state.
                check_outputs("POST-CLOCK", 1'b1);

                test_count = test_count + 1;
            end
        end

        $fclose(vector_file);

        clear_i             = 1'b0;
        write_enable_i      = 1'b0;
        write_lane_enable_i = 8'd0;
        write_data_i        = 256'd0;

        if (error_count == 0) begin
            $display(
                "PASS: nce_regfile_16x256 passed all %0d cycles.",
                test_count
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: %0d errors detected in %0d cycles.",
                error_count,
                test_count
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
