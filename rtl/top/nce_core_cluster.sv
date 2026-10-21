// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- core cluster integration
//
// Brings the stack-layer blocks together behind one control/status interface:
//
//   Layer 8   nce_ternary_dot16      ternary GEMM datapath
//   Layer 9   nce_lif_dispatcher     activation-sparsity gate
//   Layer 12  nce_abfp_align         float -> shared-exponent integers
//   Layer 12  nce_collective_alu     in-network reduction
//   (gen)     nce_neural_gen_loop    on-chip token selection
//
// Control is a single CTRL word and a single STATUS word, laid out to match
// the CSR bit assignments used by software.
//
// ORDERING NOTE. The ABFP stage sits in FRONT of the collective ALU, not
// behind it. The ALU reduces integers precisely so a ring can combine
// contributions in any order; feeding it floats directly would reintroduce
// the order dependence that Layer 13 exists to remove. The wiring here
// enforces that: there is no path from a float input to the ALU that does
// not pass through alignment first.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module nce_core_cluster #(
    parameter int unsigned TERNARY_ACT_W = 8,
    parameter int unsigned LIF_LANES     = 8,
    parameter int unsigned COLL_SLOTS    = 16,
    parameter int unsigned GEN_WINDOW    = 8,
    parameter int unsigned GEN_LOGIT_W   = 16,
    parameter int unsigned GEN_TOKEN_W   = 16
) (
    input  wire                          clk_i,
    input  wire                          rst_ni,

    // ---- control word ---------------------------------------------------
    //  [0] CORE_EN        cluster enable
    //  [1] SW_RST         soft reset of block state
    //  [2] TERNARY_MODE   route the GEMM datapath through the trit unit
    //  [3] ABFP_BYPASS    feed the ALU directly (see ordering note above)
    //  [4] SPIKE_GATE_EN  let the LIF dispatcher gate downstream compute
    input  wire [31:0]                   ctrl_i,

    // ---- Layer 8: ternary datapath --------------------------------------
    input  wire                          tern_valid_i,
    input  wire [31:0]                   tern_weights_i,
    input  wire [16*TERNARY_ACT_W-1:0]   tern_acts_i,
    output logic                         tern_valid_o,
    output logic signed [TERNARY_ACT_W+4:0] tern_result_o,
    output logic [15:0]                  tern_trap_o,

    // ---- Layer 9: spiking dispatcher ------------------------------------
    input  wire                          lif_step_i,
    input  wire [LIF_LANES*12-1:0]       lif_current_i,
    input  wire signed [15:0]            lif_threshold_i,
    input  wire signed [15:0]            lif_reset_i,
    output logic [LIF_LANES-1:0]         lif_dispatch_o,
    output logic                         lif_idle_o,

    // ---- Layer 12: ABFP + collective ------------------------------------
    input  wire                          abfp_valid_i,
    input  wire [8*32-1:0]               abfp_block_i,
    input  wire [1:0]                    coll_op_i,
    input  wire [$clog2(COLL_SLOTS)-1:0] coll_slot_i,
    input  wire                          coll_last_i,
    input  wire                          coll_out_ready_i,
    output logic                         coll_out_valid_o,
    output logic signed [31:0]           coll_out_payload_o,
    output logic [COLL_SLOTS-1:0]        coll_complete_o,
    output logic [7:0]                   abfp_block_exp_o,

    // ---- token generation ------------------------------------------------
    input  wire                          gen_start_i,
    input  wire                          gen_valid_i,
    input  wire [GEN_WINDOW*GEN_LOGIT_W-1:0] gen_logits_i,
    input  wire [GEN_TOKEN_W-1:0]        gen_base_token_i,
    input  wire                          gen_last_i,
    output logic                         gen_done_o,
    output logic [GEN_TOKEN_W-1:0]       gen_token_o,

    // ---- status word ----------------------------------------------------
    //  [4] TERNARY_EN_STAT
    //  [5] LIF_SPIKE_EVENT_LATCH
    //  [6] COLLECTIVE_ALU_BUSY
    //  [7] GEN_BUSY
    //  [8] TERNARY_TRAP      sticky: a reserved trit code was seen
    //  [9] ABFP_INF_NAN      sticky: a non-finite lane reached alignment
    output logic [31:0]                  status_o
);

    localparam int unsigned CTRL_CORE_EN       = 0;
    localparam int unsigned CTRL_SW_RST        = 1;
    localparam int unsigned CTRL_TERNARY_MODE  = 2;
    localparam int unsigned CTRL_ABFP_BYPASS   = 3;
    localparam int unsigned CTRL_SPIKE_GATE_EN = 4;

    wire core_en  = ctrl_i[CTRL_CORE_EN];
    wire soft_rst = ctrl_i[CTRL_SW_RST];

    // ---- Layer 8 ----------------------------------------------------------
    wire tern_enable = core_en && ctrl_i[CTRL_TERNARY_MODE];

    nce_ternary_dot16 #(
        .ACT_WIDTH  (TERNARY_ACT_W),
        .REGISTERED (1'b1)
    ) u_ternary (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni && !soft_rst),
        .valid_i       (tern_valid_i && tern_enable),
        .weights_i     (tern_weights_i),
        .activations_i (tern_acts_i),
        .valid_o       (tern_valid_o),
        .result_o      (tern_result_o),
        .trap_o        (tern_trap_o)
    );

    // ---- Layer 9 ----------------------------------------------------------
    wire [LIF_LANES-1:0] lif_spike;
    wire                 lif_spike_valid;

    nce_lif_dispatcher #(
        .LANES      (LIF_LANES),
        .POT_WIDTH  (16),
        .CUR_WIDTH  (12),
        .LEAK_SHIFT (3)
    ) u_lif (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .clear_i             (soft_rst),
        .step_valid_i        (lif_step_i && core_en),
        .current_i           (lif_current_i),
        .lane_enable_i       ({LIF_LANES{1'b1}}),
        .v_threshold_i       (lif_threshold_i),
        .v_reset_i           (lif_reset_i),
        .spike_valid_o       (lif_spike_valid),
        .spike_o             (lif_spike),
        .dispatch_enable_o   (),
        .all_idle_o          (lif_idle_o),
        .monitor_lane_i      ('0),
        .monitor_potential_o ()
    );

    // The gate only masks downstream work when software asks for it; with it
    // disabled every lane is dispatched, which is the safe default.
    assign lif_dispatch_o = ctrl_i[CTRL_SPIKE_GATE_EN] ? lif_spike
                                                      : {LIF_LANES{1'b1}};

    // ---- Layer 12: alignment then reduction -------------------------------
    wire                abfp_valid;
    wire [8*28-1:0]     abfp_mant;
    wire [7:0]          abfp_infnan;

    nce_abfp_align u_abfp (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni && !soft_rst),
        .valid_i     (abfp_valid_i && core_en),
        .block_i     (abfp_block_i),
        .valid_o     (abfp_valid),
        .block_exp_o (abfp_block_exp_o),
        .mantissa_o  (abfp_mant),
        .subnormal_o (),
        .inf_nan_o   (abfp_infnan)
    );

    // Lane 0's aligned mantissa is the ALU payload. ABFP_BYPASS takes the raw
    // word instead, which is only valid for data that is already integer --
    // it does NOT make float reduction order-independent.
    wire signed [31:0] coll_payload =
        ctrl_i[CTRL_ABFP_BYPASS] ? $signed(abfp_block_i[31:0])
                                 : $signed({{4{abfp_mant[27]}}, abfp_mant[27:0]});

    wire coll_in_valid = ctrl_i[CTRL_ABFP_BYPASS] ? (abfp_valid_i && core_en)
                                                  : abfp_valid;

    nce_collective_alu #(.SLOTS (COLL_SLOTS)) u_coll (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni && !soft_rst),
        .clear_i         (soft_rst),
        .clear_op_i      (coll_op_i),
        .in_valid_i      (coll_in_valid),
        .in_ready_o      (),
        .op_i            (coll_op_i),
        .slot_i          (coll_slot_i),
        .payload_i       (coll_payload),
        .last_i          (coll_last_i),
        .out_valid_o     (coll_out_valid_o),
        .out_ready_i     (coll_out_ready_i),
        .out_payload_o   (coll_out_payload_o),
        .out_slot_o      (),
        .out_last_o      (),
        .slot_complete_o (coll_complete_o)
    );

    // ---- token generation --------------------------------------------------
    wire gen_busy;

    nce_neural_gen_loop #(
        .WINDOW  (GEN_WINDOW),
        .LOGIT_W (GEN_LOGIT_W),
        .TOKEN_W (GEN_TOKEN_W)
    ) u_gen (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni && !soft_rst),
        .start_i        (gen_start_i && core_en),
        .valid_i        (gen_valid_i && core_en),
        .logits_i       (gen_logits_i),
        .base_token_i   (gen_base_token_i),
        .last_i         (gen_last_i),
        .noise_enable_i (1'b0),
        .temperature_i  ('0),
        .seed_i         ('0),
        .seed_load_i    (1'b0),
        .done_o         (gen_done_o),
        .token_o        (gen_token_o),
        .logit_o        (),
        .busy_o         (gen_busy)
    );

    // ---- status ------------------------------------------------------------
    // Sticky error bits: cleared only by a soft reset, so a transient fault
    // cannot be missed by software polling at the wrong moment.
    logic tern_trap_q;
    logic abfp_infnan_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tern_trap_q   <= 1'b0;
            abfp_infnan_q <= 1'b0;
        end
        else if (soft_rst) begin
            tern_trap_q   <= 1'b0;
            abfp_infnan_q <= 1'b0;
        end
        else begin
            if (tern_valid_o && (tern_trap_o != 16'd0)) tern_trap_q <= 1'b1;
            if (abfp_valid  && (abfp_infnan != 8'd0))   abfp_infnan_q <= 1'b1;
        end
    end

    always_comb begin
        status_o    = 32'd0;
        status_o[4] = tern_enable;
        status_o[5] = lif_spike_valid && (lif_spike != '0);
        status_o[6] = coll_out_valid_o;
        status_o[7] = gen_busy;
        status_o[8] = tern_trap_q;
        status_o[9] = abfp_infnan_q;
    end

endmodule

`default_nettype wire
