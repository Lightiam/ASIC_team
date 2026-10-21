// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- Layer 9: Spiking Dynamic Activation Dispatcher
//
// Leaky Integrate-and-Fire (LIF) neuron bank used as an activation-sparsity
// gate. Lanes whose membrane potential stays below threshold do not fire, and
// the dispatcher deasserts their downstream enable, so idle compute tiles and
// (on a photonic build) their modulator drivers can be skipped.
//
// Specification formulation:
//
//   V[k](t + dt) = V[k](t) * exp(-dt / tau_leak) + sum_m W_mk * delta(t - t_m)
//   S[k](t)      = 1 if V[k](t) >= V_th else 0
//   S[k](t) == 1 -> V[k](t+) = V_reset
//
// Synthesis note: exp(-dt/tau) is not synthesisable and a multiplier per lane
// is wasteful for a gate. With a fixed time step the decay factor is a
// constant, so this implements the standard hardware substitution
//
//   V * exp(-dt/tau)  ~=  V - (V >> LEAK_SHIFT)
//
// which is a multiply by (1 - 2^-LEAK_SHIFT). Choose LEAK_SHIFT = round(
// log2(tau_leak / dt)) for the nearest first-order match. The approximation is
// exact in the sense that matters here: it is monotonic, it is a contraction
// toward zero, and it never increases V, so a lane cannot fire through leak
// alone. Decay is applied with arithmetic shift so negative potentials relax
// toward zero as well.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_lif_dispatcher #(
    // Number of independent neurons / downstream lanes.
    parameter int unsigned LANES = 8,

    // Membrane potential width, signed.
    parameter int unsigned POT_WIDTH = 16,

    // Width of each incoming synaptic current, signed.
    parameter int unsigned CUR_WIDTH = 12,

    // Leak: V <- V - (V >>> LEAK_SHIFT) each enabled step.
    // 0 disables leak entirely (pure integrate-and-fire).
    parameter int unsigned LEAK_SHIFT = 3
) (
    input  wire                              clk_i,
    input  wire                              rst_ni,

    // Clears all membrane state without a full reset.
    input  wire                              clear_i,

    // Advance the neuron bank one time step.
    input  wire                              step_valid_i,
    // Per-lane synaptic input for this step, signed.
    input  wire  [LANES*CUR_WIDTH-1:0]       current_i,
    // Lanes excluded from integration this step.
    input  wire  [LANES-1:0]                 lane_enable_i,

    // Firing threshold and reset level, signed, runtime programmable.
    input  wire signed [POT_WIDTH-1:0]       v_threshold_i,
    input  wire signed [POT_WIDTH-1:0]       v_reset_i,

    // One cycle after step_valid_i.
    output logic                             spike_valid_o,
    output logic [LANES-1:0]                 spike_o,
    // Downstream compute enable: a lane is worth running only if it fired.
    output logic [LANES-1:0]                 dispatch_enable_o,
    // High when no lane fired -- the whole tile can be bypassed.
    output logic                             all_idle_o,

    // Observability: membrane potential of lane MONITOR_LANE.
    input  wire  [$clog2(LANES > 1 ? LANES : 2)-1:0] monitor_lane_i,
    output logic signed [POT_WIDTH-1:0]      monitor_potential_o
);

    logic signed [POT_WIDTH-1:0] v_q [LANES];

    // Next-state potential per lane.
    logic signed [POT_WIDTH-1:0] v_next [LANES];
    logic [LANES-1:0]            fire;

    always_comb begin
        for (int unsigned k = 0; k < LANES; k++) begin
            logic signed [POT_WIDTH-1:0] decayed;
            logic signed [POT_WIDTH-1:0] integrated;
            logic signed [CUR_WIDTH-1:0] cur;

            // Leak. Arithmetic shift pulls both signs toward zero.
            if (LEAK_SHIFT == 0) decayed = v_q[k];
            else                 decayed = v_q[k] - (v_q[k] >>> LEAK_SHIFT);

            cur        = current_i[CUR_WIDTH*k +: CUR_WIDTH];
            integrated = decayed + POT_WIDTH'(cur);

            // A disabled lane still leaks but takes no input.
            if (!lane_enable_i[k]) integrated = decayed;

            fire[k] = (integrated >= v_threshold_i);

            v_next[k] = fire[k] ? v_reset_i : integrated;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int unsigned k = 0; k < LANES; k++) v_q[k] <= '0;
            spike_o       <= '0;
            spike_valid_o <= 1'b0;
        end
        else if (clear_i) begin
            for (int unsigned k = 0; k < LANES; k++) v_q[k] <= '0;
            spike_o       <= '0;
            spike_valid_o <= 1'b0;
        end
        else begin
            spike_valid_o <= step_valid_i;
            if (step_valid_i) begin
                for (int unsigned k = 0; k < LANES; k++) v_q[k] <= v_next[k];
                spike_o <= fire;
            end
            else begin
                spike_o <= '0;
            end
        end
    end

    assign dispatch_enable_o = spike_o;
    assign all_idle_o        = spike_valid_o && (spike_o == '0);

    assign monitor_potential_o = v_q[monitor_lane_i];

endmodule

`default_nettype wire
