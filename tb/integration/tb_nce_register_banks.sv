`timescale 1ns/1ps
`default_nettype none

module tb_nce_register_banks;

    logic clk_i;
    logic rst_ni;
    logic clear_i;

    logic [3:0]   vector_read_addr_a_i;
    logic [255:0] vector_read_data_a_o;
    logic         vector_read_valid_a_o;

    logic [3:0]   vector_read_addr_b_i;
    logic [255:0] vector_read_data_b_o;
    logic         vector_read_valid_b_o;

    logic         vector_write_enable_i;
    logic [3:0]   vector_write_addr_i;
    logic [7:0]   vector_write_lane_enable_i;
    logic [255:0] vector_write_data_i;

    logic [3:0]   matrix_read_addr_a_i;
    logic [255:0] matrix_read_data_a_o;
    logic         matrix_read_valid_a_o;

    logic [3:0]   matrix_read_addr_b_i;
    logic [255:0] matrix_read_data_b_o;
    logic         matrix_read_valid_b_o;

    logic         matrix_write_enable_i;
    logic [3:0]   matrix_write_addr_i;
    logic [7:0]   matrix_write_lane_enable_i;
    logic [255:0] matrix_write_data_i;

    logic [15:0] vector_valid_mask_o;
    logic [15:0] matrix_valid_mask_o;

    logic vector_clear;

    logic vector_write_enable;
    logic [3:0] vector_write_addr;
    logic [7:0] vector_lane_enable;
    logic [255:0] vector_write_data;
    logic [3:0] vector_read_addr_a;
    logic [3:0] vector_read_addr_b;

    logic matrix_write_enable;
    logic [3:0] matrix_write_addr;
    logic [7:0] matrix_lane_enable;
    logic [255:0] matrix_write_data;
    logic [3:0] matrix_read_addr_a;
    logic [3:0] matrix_read_addr_b;

    logic [255:0] expected_vector_data_a;
    logic expected_vector_valid_a;
    logic [255:0] expected_vector_data_b;
    logic expected_vector_valid_b;
    logic [15:0] expected_vector_mask;

    logic [255:0] expected_matrix_data_a;
    logic expected_matrix_valid_a;
    logic [255:0] expected_matrix_data_b;
    logic expected_matrix_valid_b;
    logic [15:0] expected_matrix_mask;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_register_banks dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .clear_i                     (clear_i),

        .vector_read_addr_a_i        (vector_read_addr_a_i),
        .vector_read_data_a_o        (vector_read_data_a_o),
        .vector_read_valid_a_o       (vector_read_valid_a_o),

        .vector_read_addr_b_i        (vector_read_addr_b_i),
        .vector_read_data_b_o        (vector_read_data_b_o),
        .vector_read_valid_b_o       (vector_read_valid_b_o),

        .vector_write_enable_i       (vector_write_enable_i),
        .vector_write_addr_i         (vector_write_addr_i),
        .vector_write_lane_enable_i  (vector_write_lane_enable_i),
        .vector_write_data_i         (vector_write_data_i),

        .matrix_read_addr_a_i        (matrix_read_addr_a_i),
        .matrix_read_data_a_o        (matrix_read_data_a_o),
        .matrix_read_valid_a_o       (matrix_read_valid_a_o),

        .matrix_read_addr_b_i        (matrix_read_addr_b_i),
        .matrix_read_data_b_o        (matrix_read_data_b_o),
        .matrix_read_valid_b_o       (matrix_read_valid_b_o),

        .matrix_write_enable_i       (matrix_write_enable_i),
        .matrix_write_addr_i         (matrix_write_addr_i),
        .matrix_write_lane_enable_i  (matrix_write_lane_enable_i),
        .matrix_write_data_i         (matrix_write_data_i),

        .vector_valid_mask_o         (vector_valid_mask_o),
        .matrix_valid_mask_o         (matrix_valid_mask_o)
    );

    initial begin
        clk_i = 1'b0;

        forever begin
            #5 clk_i = ~clk_i;
        end
    end

    initial begin
        rst_ni = 1'b0;
        clear_i = 1'b0;

        vector_read_addr_a_i = '0;
        vector_read_addr_b_i = '0;
        vector_write_enable_i = '0;
        vector_write_addr_i = '0;
        vector_write_lane_enable_i = '0;
        vector_write_data_i = '0;

        matrix_read_addr_a_i = '0;
        matrix_read_addr_b_i = '0;
        matrix_write_enable_i = '0;
        matrix_write_addr_i = '0;
        matrix_write_lane_enable_i = '0;
        matrix_write_data_i = '0;

        test_count = 0;
        error_count = 0;

        repeat (3) @(posedge clk_i);
        @(negedge clk_i);
        rst_ni = 1'b1;

        vector_file = $fopen(
            "build/register_banks_vectors.txt",
            "r"
        );

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open register-bank vectors."
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",

                vector_clear,

                vector_write_enable,
                vector_write_addr,
                vector_lane_enable,
                vector_write_data,
                vector_read_addr_a,
                vector_read_addr_b,

                matrix_write_enable,
                matrix_write_addr,
                matrix_lane_enable,
                matrix_write_data,
                matrix_read_addr_a,
                matrix_read_addr_b,

                expected_vector_data_a,
                expected_vector_valid_a,
                expected_vector_data_b,
                expected_vector_valid_b,
                expected_vector_mask,

                expected_matrix_data_a,
                expected_matrix_valid_a,
                expected_matrix_data_b,
                expected_matrix_valid_b,
                expected_matrix_mask
            );

            if (scan_result == 23) begin
                @(negedge clk_i);

                clear_i = vector_clear;

                vector_write_enable_i =
                    vector_write_enable;

                vector_write_addr_i =
                    vector_write_addr;

                vector_write_lane_enable_i =
                    vector_lane_enable;

                vector_write_data_i =
                    vector_write_data;

                vector_read_addr_a_i =
                    vector_read_addr_a;

                vector_read_addr_b_i =
                    vector_read_addr_b;

                matrix_write_enable_i =
                    matrix_write_enable;

                matrix_write_addr_i =
                    matrix_write_addr;

                matrix_write_lane_enable_i =
                    matrix_lane_enable;

                matrix_write_data_i =
                    matrix_write_data;

                matrix_read_addr_a_i =
                    matrix_read_addr_a;

                matrix_read_addr_b_i =
                    matrix_read_addr_b;

                @(posedge clk_i);
                #1;

                test_count = test_count + 1;

                if (
                    vector_read_data_a_o !==
                        expected_vector_data_a ||
                    vector_read_valid_a_o !==
                        expected_vector_valid_a ||
                    vector_read_data_b_o !==
                        expected_vector_data_b ||
                    vector_read_valid_b_o !==
                        expected_vector_valid_b ||
                    vector_valid_mask_o !==
                        expected_vector_mask ||

                    matrix_read_data_a_o !==
                        expected_matrix_data_a ||
                    matrix_read_valid_a_o !==
                        expected_matrix_valid_a ||
                    matrix_read_data_b_o !==
                        expected_matrix_data_b ||
                    matrix_read_valid_b_o !==
                        expected_matrix_valid_b ||
                    matrix_valid_mask_o !==
                        expected_matrix_mask
                ) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR test=%0d vector_mask=%04h/%04h matrix_mask=%04h/%04h vector_a=%064h/%064h matrix_a=%064h/%064h",
                            test_count,
                            vector_valid_mask_o,
                            expected_vector_mask,
                            matrix_valid_mask_o,
                            expected_matrix_mask,
                            vector_read_data_a_o,
                            expected_vector_data_a,
                            matrix_read_data_a_o,
                            expected_matrix_data_a
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_register_banks passed all %0d cycles.",
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
