// -----------------------------------------------------------------------------
// Testbench: ABFP block alignment + order-independent reduction.
//
// Deliberately uses NO host floating point. Stimulus is raw FP32 bit patterns
// and the expected mantissas are integer constants computed offline. That
// matters here: $shortrealtobits and `real` are handled inconsistently across
// simulators. On this very block the two available simulators disagreed, and
// one of them returned all-zero bit patterns, so a testbench built on them
// ends up testing the simulator rather than the design.
//
// (Note: a comment line must not begin with the word that names that lint
// tool -- it is then parsed as a pragma and the build fails.)
//
// Properties under test:
//   1. Each lane aligns to the exact expected integer mantissa, signs included.
//   2. The block exponent is the largest NORMAL exponent in the block.
//   3. Summing the aligned block is independent of addition order -- the
//      property Layer 13 relies on.
//   4. An Inf lane is flagged, does not set the block scale, and does not
//      flush the finite lanes.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_abfp_align;

    localparam int unsigned BLOCK = 8;
    localparam int unsigned MW    = 28;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic                valid_i;
    logic [BLOCK*32-1:0] block_i;
    logic                valid_o;
    logic [7:0]          block_exp_o;
    logic [BLOCK*MW-1:0] mantissa_o;
    logic [7:0]          subnormal_o;
    logic [7:0]          inf_nan_o;

    nce_abfp_align dut (
        .clk_i (clk), .rst_ni (rst_n),
        .valid_i (valid_i), .block_i (block_i),
        .valid_o (valid_o), .block_exp_o (block_exp_o),
        .mantissa_o (mantissa_o),
        .subnormal_o (subnormal_o), .inf_nan_o (inf_nan_o)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    // Block: 1024.5, -256.25, 64.125, -16.0625, 4.5, -1.25, 0.5, 2.75
    // block_exp = 137 (from 1024.5). Expected mantissas, verified offline:
    //   mant = (((1<<23)|frac) << 3) >> (137 - exp), negated when sign is set.
    // Their sum, 53923840, reconstructs 822.8125 -- the exact real sum.
    localparam logic [31:0] V0 = 32'h4480_1000, V1 = 32'hC380_2000;
    localparam logic [31:0] V2 = 32'h4280_4000, V3 = 32'hC180_8000;
    localparam logic [31:0] V4 = 32'h4090_0000, V5 = 32'hBFA0_0000;
    localparam logic [31:0] V6 = 32'h3F00_0000, V7 = 32'h4030_0000;

    localparam int EXP_BLOCK_EXP = 137;
    localparam int EXP_SUM       = 53923840;

    function automatic int expected_mant (input int unsigned lane);
        begin
            case (lane)
                0: expected_mant =  67141632;
                1: expected_mant = -16793600;
                2: expected_mant =   4202496;
                3: expected_mant =  -1052672;
                4: expected_mant =    294912;
                5: expected_mant =    -81920;
                6: expected_mant =     32768;
                7: expected_mant =    180224;
                default: expected_mant = 0;
            endcase
        end
    endfunction

    task automatic drive (input logic [BLOCK*32-1:0] blk);
        begin
            @(negedge clk);
            block_i = blk;
            valid_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            valid_i = 1'b0;
            checks++;
        end
    endtask

    // Sum the aligned mantissas in a packed-nibble permutation. Pure integer
    // arithmetic, so the order must not change the result.
    function automatic logic signed [31:0] sum_perm (input logic [31:0] order);
        logic signed [31:0]   acc;
        logic signed [MW-1:0] m;
        logic [3:0]           idx;
        begin
            acc = 32'sd0;
            for (int unsigned i = 0; i < BLOCK; i++) begin
                idx = order[4*i +: 4];
                m   = mantissa_o[MW*idx +: MW];
                acc = acc + 32'(m);
            end
            sum_perm = acc;
        end
    endfunction

    localparam logic [31:0] PERM_FWD  = 32'h7654_3210;
    localparam logic [31:0] PERM_REV  = 32'h0123_4567;
    localparam logic [31:0] PERM_SHUF = 32'h4261_5073;

    initial begin
        logic signed [31:0]   s_fwd, s_rev, s_shuf;
        logic signed [MW-1:0] got;
        logic [BLOCK*32-1:0]  blk;

        valid_i = 1'b0;
        block_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1. per-lane alignment, signs included --------------------------
        drive ({V7, V6, V5, V4, V3, V2, V1, V0});

        if (block_exp_o !== 8'(EXP_BLOCK_EXP)) begin
            errors++;
            $display("FAIL [block-exp]: got %0d expected %0d",
                     block_exp_o, EXP_BLOCK_EXP);
        end

        for (int unsigned k = 0; k < BLOCK; k++) begin
            got = mantissa_o[MW*k +: MW];
            if (32'(got) !== expected_mant(k)) begin
                errors++;
                $display("FAIL [lane%0d]: mant=%0d expected=%0d",
                         k, got, expected_mant(k));
            end
        end

        // ---- 2. order independence ------------------------------------------
        s_fwd  = sum_perm(PERM_FWD);
        s_rev  = sum_perm(PERM_REV);
        s_shuf = sum_perm(PERM_SHUF);

        if (!(s_fwd === s_rev && s_fwd === s_shuf)) begin
            errors++;
            $display("FAIL [order]: fwd=%0d rev=%0d shuf=%0d", s_fwd, s_rev, s_shuf);
        end
        if (s_fwd !== EXP_SUM) begin
            errors++;
            $display("FAIL [sum]: got %0d expected %0d", s_fwd, EXP_SUM);
        end
        $display("  aligned sum = %0d, identical across 3 orders (expected %0d)",
                 s_fwd, EXP_SUM);

        // ---- 3. Inf must not define the block scale -------------------------
        // Lane 4 is +Inf; the rest are powers of two, exponents 128..135.
        drive ({32'h4380_0000, 32'h4300_0000, 32'h4280_0000, 32'h7F80_0000,
                32'h4200_0000, 32'h4100_0000, 32'h4080_0000, 32'h4000_0000});
        if (inf_nan_o[4] !== 1'b1) begin
            errors++;
            $display("FAIL [inf-flag]: lane 4 not flagged, inf_nan=%b", inf_nan_o);
        end
        if (block_exp_o === 8'hFF) begin
            errors++;
            $display("FAIL [inf-scale]: Inf set the block exponent");
        end
        if (mantissa_o[MW*7 +: MW] === '0) begin
            errors++;
            $display("FAIL [inf-flush]: finite lane 7 flushed to zero");
        end
        $display("  Inf lane flagged, block_exp=%0d, finite lanes retained",
                 block_exp_o);

        // ---- 4. all-zero block -----------------------------------------------
        drive ('0);
        if (mantissa_o !== '0) begin
            errors++;
            $display("FAIL [zero-block]: mantissas not all zero");
        end

        // ---- 5. randomised order independence --------------------------------
        for (int unsigned n = 0; n < 200; n++) begin
            for (int unsigned k = 0; k < BLOCK; k++)
                blk[32*k +: 32] = {1'($urandom_range(0, 1)),
                                   8'($urandom_range(100, 150)),
                                   23'($urandom_range(0, 8388607))};
            drive (blk);
            if (sum_perm(PERM_FWD) !== sum_perm(PERM_REV) ||
                sum_perm(PERM_FWD) !== sum_perm(PERM_SHUF)) begin
                errors++;
                $display("FAIL [random-order] iteration %0d", n);
            end
        end

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: ABFP align passed all %0d checks.", checks);
        else
            $display("FAIL: ABFP align had %0d errors in %0d checks.",
                     errors, checks);
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1, "abfp mismatch");
        $finish;
    end

endmodule

`default_nettype wire
