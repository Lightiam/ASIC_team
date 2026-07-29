`timescale 1ns/1ps
`default_nettype none

module tb_nce_int18_to_fp32;

    logic signed [17:0] int_i;
    logic        [31:0] fp32_o;

    logic [17:0] vector_input;
    logic [31:0] expected_output;

    integer vector_file;
    integer scan_result;
    integer test_count;
    integer error_count;

    nce_int18_to_fp32 dut (
        .int_i  (int_i),
        .fp32_o (fp32_o)
    );

    initial begin
        int_i         = '0;
        vector_input  = '0;
        expected_output = '0;
        test_count    = 0;
        error_count   = 0;

        vector_file =
            $fopen("build/int18_to_fp32_vectors.txt", "r");

        if (vector_file == 0) begin
            $fatal(
                1,
                "Could not open build/int18_to_fp32_vectors.txt"
            );
        end

        while (!$feof(vector_file)) begin
            scan_result = $fscanf(
                vector_file,
                "%h %h\n",
                vector_input,
                expected_output
            );

            if (scan_result == 2) begin
                int_i = $signed(vector_input);
                #1;

                test_count = test_count + 1;

                if (fp32_o !== expected_output) begin
                    error_count = error_count + 1;

                    if (error_count <= 20) begin
                        $display(
                            "ERROR input=%0d raw=%05h expected=%08h actual=%08h",
                            int_i,
                            vector_input,
                            expected_output,
                            fp32_o
                        );
                    end
                end
            end
        end

        $fclose(vector_file);

        if (error_count == 0) begin
            $display(
                "PASS: nce_int18_to_fp32 passed all %0d exhaustive inputs.",
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
