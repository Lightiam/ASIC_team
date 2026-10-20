// -----------------------------------------------------------------------------
// Testbench: Layer 9 spiking (LIF) activation dispatcher.
//
// The behavioural claims made in the module header are the ones tested here:
//
//   1. Integration: repeated sub-threshold input eventually crosses threshold.
//   2. Reset: a lane that fires drops to v_reset, not to zero-by-accident.
//   3. Leak is CONTRACTIVE and MONOTONIC -- a lane can never fire from leak
//      alone. This is the property that justifies replacing exp(-dt/tau) with
//      a shift, so it is checked directly rather than assumed.
//   4. Sparsity gating: dispatch_enable follows spikes, and all_idle asserts
//      when no lane fires, which is what lets downstream tiles be skipped.
//   5. Lane isolation and lane_enable masking.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_nce_lif_dispatcher;

    localparam int unsigned LANES      = 8;
    localparam int unsigned POT_WIDTH  = 16;
    localparam int unsigned CUR_WIDTH  = 12;
    localparam int unsigned LEAK_SHIFT = 3;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic                          clear_i;
    logic                          step_valid_i;
    logic [LANES*CUR_WIDTH-1:0]    current_i;
    logic [LANES-1:0]              lane_enable_i;
    logic signed [POT_WIDTH-1:0]   v_threshold_i;
    logic signed [POT_WIDTH-1:0]   v_reset_i;
    logic                          spike_valid_o;
    logic [LANES-1:0]              spike_o;
    logic [LANES-1:0]              dispatch_enable_o;
    logic                          all_idle_o;
    logic [2:0]                    monitor_lane_i;
    logic signed [POT_WIDTH-1:0]   monitor_potential_o;

    nce_lif_dispatcher #(
        .LANES (LANES), .POT_WIDTH (POT_WIDTH),
        .CUR_WIDTH (CUR_WIDTH), .LEAK_SHIFT (LEAK_SHIFT)
    ) dut (
        .clk_i (clk), .rst_ni (rst_n),
        .clear_i (clear_i),
        .step_valid_i (step_valid_i), .current_i (current_i),
        .lane_enable_i (lane_enable_i),
        .v_threshold_i (v_threshold_i), .v_reset_i (v_reset_i),
        .spike_valid_o (spike_valid_o), .spike_o (spike_o),
        .dispatch_enable_o (dispatch_enable_o), .all_idle_o (all_idle_o),
        .monitor_lane_i (monitor_lane_i),
        .monitor_potential_o (monitor_potential_o)
    );

    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic set_current (input int unsigned lane,
                                input logic signed [CUR_WIDTH-1:0] v);
        begin
            current_i[CUR_WIDTH*lane +: CUR_WIDTH] = v;
        end
    endtask

    task automatic step;
        begin
            @(negedge clk);
            step_valid_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            step_valid_i = 1'b0;
        end
    endtask

    task automatic do_clear;
        begin
            @(negedge clk);
            clear_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            clear_i = 1'b0;
        end
    endtask

    initial begin
        logic signed [POT_WIDTH-1:0] prev, now;
        int unsigned steps_to_fire;
        bit fired;

        clear_i       = 1'b0;
        step_valid_i  = 1'b0;
        current_i     = '0;
        lane_enable_i = {LANES{1'b1}};
        v_threshold_i = 16'sd1000;
        v_reset_i     = 16'sd0;
        monitor_lane_i = 3'd0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1. integration to threshold -------------------------------------
        do_clear();
        for (int unsigned l = 0; l < LANES; l++) set_current(l, 0);
        set_current(0, 300);

        fired = 0;
        steps_to_fire = 0;
        for (int unsigned s = 0; s < 40 && !fired; s++) begin
            step();
            steps_to_fire++;
            if (spike_o[0]) fired = 1;
        end
        checks++;
        if (!fired) begin
            errors++;
            $display("FAIL [integrate]: lane 0 never reached threshold");
        end
        else $display("  lane 0 integrated to threshold in %0d steps", steps_to_fire);

        // ---- 2. firing resets the membrane to v_reset ------------------------
        checks++;
        if (monitor_potential_o !== v_reset_i) begin
            errors++;
            $display("FAIL [reset]: potential=%0d expected v_reset=%0d",
                     monitor_potential_o, v_reset_i);
        end

        // ---- 3. leak is contractive: NO firing from leak alone ---------------
        // Charge a lane just under threshold, then remove input entirely. The
        // potential must decay monotonically toward zero and never spike.
        do_clear();
        set_current(0, 900);
        step();                       // potential ~900, below 1000
        set_current(0, 0);

        prev  = monitor_potential_o;
        fired = 0;
        for (int unsigned s = 0; s < 60; s++) begin
            step();
            now = monitor_potential_o;
            if (spike_o[0]) fired = 1;
            if (now > prev) begin
                errors++;
                $display("FAIL [leak-monotonic]: potential rose %0d -> %0d", prev, now);
            end
            prev = now;
        end
        checks++;
        if (fired) begin
            errors++;
            $display("FAIL [leak-no-fire]: lane fired from leak alone");
        end
        else $display("  leak monotonic and never fires alone; decayed to %0d", prev);

        checks++;
        if (prev < 0) begin
            errors++;
            $display("FAIL [leak-sign]: decayed past zero to %0d", prev);
        end

        // ---- 4. negative potential relaxes toward zero too --------------------
        do_clear();
        set_current(0, -900);
        step();
        set_current(0, 0);
        prev = monitor_potential_o;
        checks++;
        if (prev >= 0) begin
            errors++;
            $display("FAIL [neg-charge]: expected negative potential, got %0d", prev);
        end
        for (int unsigned s = 0; s < 60; s++) begin
            step();
            now = monitor_potential_o;
            if (now < prev) begin
                errors++;
                $display("FAIL [neg-leak]: potential fell %0d -> %0d", prev, now);
            end
            prev = now;
        end
        checks++;
        if (prev > 0) begin
            errors++;
            $display("FAIL [neg-leak-overshoot]: relaxed past zero to %0d", prev);
        end
        else $display("  negative potential relaxed toward zero: %0d", prev);

        // ---- 5. sparsity gating ----------------------------------------------
        do_clear();
        for (int unsigned l = 0; l < LANES; l++) set_current(l, 0);
        step();
        checks++;
        if (!all_idle_o || spike_o !== '0) begin
            errors++;
            $display("FAIL [idle]: all_idle=%b spikes=%b", all_idle_o, spike_o);
        end
        else $display("  no input -> all_idle asserted, zero spikes");

        checks++;
        if (dispatch_enable_o !== spike_o) begin
            errors++;
            $display("FAIL [dispatch]: enable=%b spikes=%b", dispatch_enable_o, spike_o);
        end

        // ---- 6. lane isolation: only the driven lane fires -------------------
        do_clear();
        for (int unsigned l = 0; l < LANES; l++) set_current(l, 0);
        set_current(3, 2000);          // above threshold in one step
        step();
        checks++;
        if (spike_o !== (1 << 3)) begin
            errors++;
            $display("FAIL [isolation]: spikes=%b expected only lane 3", spike_o);
        end
        else $display("  lane isolation holds: spikes=%b", spike_o);

        checks++;
        if (all_idle_o) begin
            errors++;
            $display("FAIL [idle-wrong]: all_idle asserted while lane 3 fired");
        end

        // ---- 7. lane_enable masks integration --------------------------------
        do_clear();
        for (int unsigned l = 0; l < LANES; l++) set_current(l, 2000);
        lane_enable_i = 8'b0000_0001;  // only lane 0 may integrate
        step();
        checks++;
        if (spike_o !== 8'b0000_0001) begin
            errors++;
            $display("FAIL [lane-enable]: spikes=%b expected 00000001", spike_o);
        end
        else $display("  lane_enable masking works: spikes=%b", spike_o);
        lane_enable_i = {LANES{1'b1}};

        // ---- 8. clear wipes state --------------------------------------------
        do_clear();
        checks++;
        if (monitor_potential_o !== '0 || spike_o !== '0) begin
            errors++;
            $display("FAIL [clear]: potential=%0d spikes=%b",
                     monitor_potential_o, spike_o);
        end

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("PASS: LIF dispatcher passed all %0d checks.", checks);
        else
            $display("FAIL: LIF dispatcher had %0d errors in %0d checks.", errors, checks);
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1, "lif mismatch");
        $finish;
    end

endmodule

`default_nettype wire
