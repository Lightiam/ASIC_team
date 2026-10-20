// -----------------------------------------------------------------------------
// Testbench: Layer 8 ternary dot-product unit.
//
// Checks the RTL against the independent reference function in
// nce_ternary_pkg, over directed corner cases and constrained-random vectors.
// Prints a machine-greppable verdict line.
//
// Activations are carried in two forms: ACT_WIDTH-bit lanes for the DUT, and
// REF_ACT_WIDTH-bit sign-extended lanes for the reference function. Packed
// vectors throughout, so this elaborates under Icarus as well as Verilator.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_ternary_dot16;

    import nce_ternary_pkg::*;

    localparam int unsigned ACT_WIDTH = 8;
    localparam int unsigned ACC_WIDTH = ACT_WIDTH + 5;
    localparam int unsigned LANES     = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic                        valid_i;
    logic [31:0]                 weights_i;
    logic [LANES*ACT_WIDTH-1:0]  activations_i;
    logic                        valid_o;
    logic signed [ACC_WIDTH-1:0] result_o;
    logic [15:0]                 trap_o;

    nce_ternary_dot16 #(
        .ACT_WIDTH  (ACT_WIDTH),
        .REGISTERED (1'b1)
    ) dut (
        .clk_i         (clk),
        .rst_ni        (rst_n),
        .valid_i       (valid_i),
        .weights_i     (weights_i),
        .activations_i (activations_i),
        .valid_o       (valid_o),
        .result_o      (result_o),
        .trap_o        (trap_o)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    // Activation scratch: one signed value per lane, held wide then narrowed.
    logic signed [REF_ACT_WIDTH-1:0]       act_wide  [LANES];
    logic [REF_ACT_WIDTH*LANES-1:0]        act_ref_packed;

    // Pack the scratch into both representations.
    task automatic pack_acts;
        begin
            for (int unsigned i = 0; i < LANES; i++) begin
                activations_i[ACT_WIDTH*i +: ACT_WIDTH] =
                    act_wide[i][ACT_WIDTH-1:0];
                act_ref_packed[REF_ACT_WIDTH*i +: REF_ACT_WIDTH] =
                    act_wide[i];
            end
        end
    endtask

    task automatic set_all_acts (input logic signed [REF_ACT_WIDTH-1:0] v);
        begin
            for (int unsigned i = 0; i < LANES; i++) act_wide[i] = v;
        end
    endtask

    // Drive one vector and check the registered result against the reference.
    task automatic run_case (
        input logic [31:0] weights,
        input string       label
    );
        logic signed [31:0] expected;
        logic [15:0]        expected_trap;
        begin
            pack_acts();

            expected      = trit_dot_ref(weights, act_ref_packed);
            expected_trap = trit_trap_mask(weights);

            // Drive on the falling edge, away from the edge the DUT samples
            // on. Driving at the posedge races the DUT's always_ff and makes
            // every result appear one case late.
            @(negedge clk);
            weights_i = weights;
            valid_i   = 1'b1;

            @(posedge clk);         // DUT captures here
            @(negedge clk);         // non-blocking updates have settled
            valid_i   = 1'b0;

            checks++;
            if (result_o !== expected[ACC_WIDTH-1:0]) begin
                errors++;
                $display("FAIL [%0s]: result=%0d expected=%0d weights=%h",
                         label, result_o, expected, weights);
            end
            if (trap_o !== expected_trap) begin
                errors++;
                $display("FAIL [%0s]: trap=%b expected=%b",
                         label, trap_o, expected_trap);
            end
        end
    endtask

    initial begin
        valid_i       = 1'b0;
        weights_i     = '0;
        activations_i = '0;
        set_all_acts(0);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- directed: all zero trits, non-zero activations -> 0 -------------
        set_all_acts(50);
        run_case ({16{TRIT_ZERO}}, "all-zero-trits");

        // ---- directed: all +1 -> sum of activations --------------------------
        set_all_acts(7);
        run_case ({16{TRIT_POS}}, "all-pos");

        // ---- directed: all -1 -> negated sum ---------------------------------
        set_all_acts(7);
        run_case ({16{TRIT_NEG}}, "all-neg");

        // ---- directed: most-negative activation, all +1 ----------------------
        // -128 * 16 = -2048, needs the full 12-bit accumulator.
        set_all_acts(-128);
        run_case ({16{TRIT_POS}}, "min-act-all-pos");

        // ---- directed: most-negative activation, all -1 ----------------------
        // Negating -128 must not wrap: +2048 requires the widened accumulator.
        set_all_acts(-128);
        run_case ({16{TRIT_NEG}}, "min-act-all-neg");

        // ---- directed: max positive activation, all +1 -----------------------
        set_all_acts(127);
        run_case ({16{TRIT_POS}}, "max-act-all-pos");

        // ---- directed: reserved code raises trap and contributes zero --------
        set_all_acts(100);
        run_case ({{15{TRIT_ZERO}}, TRIT_RESERVED}, "reserved-lane0");

        // ---- directed: every lane reserved -> result 0, trap all ones --------
        set_all_acts(-99);
        run_case ({16{TRIT_RESERVED}}, "all-reserved");

        // ---- directed: alternating +1/-1 over equal activations cancels ------
        set_all_acts(33);
        run_case ({8{TRIT_NEG, TRIT_POS}}, "alternating-cancels");

        // ---- randomised ------------------------------------------------------
        begin
            logic [31:0] w;
            for (int unsigned n = 0; n < 500; n++) begin
                for (int unsigned i = 0; i < LANES; i++)
                    act_wide[i] =
                        REF_ACT_WIDTH'($signed($urandom_range(0, 255)) - 128);
                for (int unsigned i = 0; i < LANES; i++)
                    w[2*i +: 2] = 2'($urandom_range(0, 3));   // includes reserved
                run_case (w, "random");
            end
        end

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: ternary dot16 passed all %0d checks.", checks);
        else
            $display("FAIL: ternary dot16 had %0d errors in %0d checks.",
                     errors, checks);
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1, "ternary dot16 mismatch");
        $finish;
    end

endmodule

`default_nettype wire
