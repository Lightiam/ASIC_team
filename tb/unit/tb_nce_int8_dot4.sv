`timescale 1ns/1ps
`default_nettype none

module tb_nce_int8_dot4;

    logic [31:0] lhs_i;
    logic [31:0] rhs_i;

    logic signed [17:0] dot_o;

    integer test_number;
    integer error_count;

    nce_int8_dot4 dut (
        .lhs_i (lhs_i),
        .rhs_i (rhs_i),
        .dot_o (dot_o)
    );

    function automatic signed [17:0] calculate_reference (
        input logic [31:0] lhs,
        input logic [31:0] rhs
    );
        integer element_index;

        logic signed [7:0]  lhs_element_ref;
        logic signed [7:0]  rhs_element_ref;
        logic signed [15:0] product_ref;
        logic signed [17:0] sum_ref;

        begin
            lhs_element_ref = '0;
            rhs_element_ref = '0;
            product_ref     = '0;
            sum_ref         = '0;

            for (
                element_index = 0;
                element_index < 4;
                element_index = element_index + 1
            ) begin
                lhs_element_ref =
                    $signed(lhs[(element_index * 8) +: 8]);

                rhs_element_ref =
                    $signed(rhs[(element_index * 8) +: 8]);

                product_ref = lhs_element_ref * rhs_element_ref;

                sum_ref =
                    sum_ref + {{2{product_ref[15]}}, product_ref};
            end

            calculate_reference = sum_ref;
        end
    endfunction

    task automatic check_result (
        input logic [31:0] lhs_value,
        input logic [31:0] rhs_value
    );
        logic signed [17:0] expected_result;

        begin
            lhs_i = lhs_value;
            rhs_i = rhs_value;

            #1;

            expected_result =
                calculate_reference(lhs_value, rhs_value);

            test_number = test_number + 1;

            if (dot_o !== expected_result) begin
                error_count = error_count + 1;

                $display(
                    "ERROR test=%0d lhs=%h rhs=%h expected=%0d actual=%0d",
                    test_number,
                    lhs_value,
                    rhs_value,
                    expected_result,
                    dot_o
                );
            end
        end
    endtask

    initial begin
        lhs_i       = '0;
        rhs_i       = '0;
        test_number = 0;
        error_count = 0;

        // Zero cases
        check_result(32'h00000000, 32'h00000000);
        check_result(32'h00000000, 32'h7F7F7F7F);
        check_result(32'h80808080, 32'h00000000);

        // Maximum positive products
        check_result(32'h7F7F7F7F, 32'h7F7F7F7F);

        // -128 multiplied by -128 in every packed position.
        // Expected total: 4 * 16384 = 65536.
        check_result(32'h80808080, 32'h80808080);

        // Negative products
        check_result(32'h80808080, 32'h7F7F7F7F);
        check_result(32'h7F7F7F7F, 32'h80808080);

        // Mixed signed values
        check_result(32'h01FF7F80, 32'hFF017F80);
        check_result(32'h04030201, 32'hFCFDFEFF);
        check_result(32'h80FF017F, 32'h7F01FF80);

        // Deterministic patterns
        check_result(32'h01010101, 32'h01010101);
        check_result(32'hFFFFFFFF, 32'hFFFFFFFF);
        check_result(32'hAAAAAAAA, 32'h55555555);
        check_result(32'h12345678, 32'h87654321);

        // Random regression
        repeat (10000) begin
            check_result($urandom, $urandom);
        end

        if (error_count == 0) begin
            $display(
                "PASS: nce_int8_dot4 completed %0d tests with no errors.",
                test_number
            );
        end
        else begin
            $fatal(
                1,
                "FAIL: nce_int8_dot4 detected %0d errors in %0d tests.",
                error_count,
                test_number
            );
        end

        $finish;
    end

endmodule

`default_nettype wire
