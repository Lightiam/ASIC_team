// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN_AI_NODE_X2
//
// NCE core RTL: Original RTL Architect and Digital Designer: Talha Alam
// X2 node integration: dual-die node for the TFLN HDI flip-chip substrate.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Dual-NCE-die AI node.
//
// Mirrors the TFLN_AI_NODE_X2 substrate: two identical NCE dies placed
// symmetrically about a central thin-film lithium niobate photonic IC, with the
// host interface fanning in from the substrate edge.
//
//        edge fanout        DIE A        TFLN PIC        DIE B        edge fanout
//        ===========   [ NCE core ] <-- optical --> [ NCE core ]   ===========
//                        initiator                     target
//
// Both dies are the same physical part (the same GDS, placed twice). Die A is
// the one the host is bonded to; die B is reached only across the photonic
// link. That asymmetry lives in the substrate, not in the die.
//
// Address map:
//   Bit DIE_SELECT_BIT of the transaction address chooses the die.
//     0 -> die A, served locally
//     1 -> die B, tunnelled across the TFLN link
//   Below that bit, both dies present the identical NCE register map, so
//   software written for a single NCE works unchanged against either die.
//
// Photonic ports:
//   The PIC is a separate die on the substrate, so the four optical lanes are
//   brought to the node boundary. PIC_LOOPBACK connects them internally, which
//   models an ideal lossless waveguide pair and lets the node simulate and
//   synthesise standalone. Set it to zero when the real PIC is attached.
//
// Ordering:
//   A single AXI4-Lite frontend serialises the host interface, so exactly one
//   transaction is in flight across the node at a time. A transaction to die B
//   therefore cannot overtake one to die A, and the link needs no reordering.
// -----------------------------------------------------------------------------

module nce_x2_tfln_node #(
    // Address bit selecting between the two dies.
    parameter int unsigned DIE_SELECT_BIT = 22,

    // Cycles the initiator waits for a response before retiring the
    // transaction with SLVERR.
    parameter int unsigned RESPONSE_TIMEOUT = 4096,

    // Connect the optical lanes internally (ideal PIC) when set.
    parameter bit PIC_LOOPBACK = 1'b1,

    // Which NCE variant occupies each die site. The INT8 core is small enough
    // that both dies can be placed and routed together; see
    // rtl/top/nce_x2_core_wrapper.sv.
    parameter bit USE_INT8_CORE = 1'b1
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Host AXI4-Lite slave, arriving from the substrate edge fanout
    input  logic [31:0]  s_axi_awaddr_i,
    input  logic [2:0]   s_axi_awprot_i,
    input  logic         s_axi_awvalid_i,
    output logic         s_axi_awready_o,

    input  logic [31:0]  s_axi_wdata_i,
    input  logic [3:0]   s_axi_wstrb_i,
    input  logic         s_axi_wvalid_i,
    output logic         s_axi_wready_o,

    output logic [1:0]   s_axi_bresp_o,
    output logic         s_axi_bvalid_o,
    input  logic         s_axi_bready_i,

    input  logic [31:0]  s_axi_araddr_i,
    input  logic [2:0]   s_axi_arprot_i,
    input  logic         s_axi_arvalid_i,
    output logic         s_axi_arready_o,

    output logic [31:0]  s_axi_rdata_o,
    output logic [1:0]   s_axi_rresp_o,
    output logic         s_axi_rvalid_o,
    input  logic         s_axi_rready_i,

    // Optical lanes crossing the TFLN PIC
    output logic         pic_a_tx_o,
    input  logic         pic_a_rx_i,
    output logic         pic_b_tx_o,
    input  logic         pic_b_rx_i,

    // Link status
    output logic         link_busy_o,
    output logic         link_timeout_o,
    output logic         link_crc_error_o,
    output logic         link_dropped_o
);

    // -------------------------------------------------------------------------
    // Host AXI4-Lite frontend
    // -------------------------------------------------------------------------

    logic        host_write_valid;
    logic        host_write_ready;
    logic [31:0] host_write_addr;
    logic [2:0]  host_write_prot;
    logic [31:0] host_write_data;
    logic [3:0]  host_write_strb;
    logic        host_write_error;

    logic        host_read_valid;
    logic        host_read_ready;
    logic [31:0] host_read_addr;
    logic [2:0]  host_read_prot;
    logic [31:0] host_read_data;
    logic        host_read_error;

    nce_axi4lite_frontend #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32)
    ) u_host_frontend (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        .s_axi_awaddr_i  (s_axi_awaddr_i),
        .s_axi_awprot_i  (s_axi_awprot_i),
        .s_axi_awvalid_i (s_axi_awvalid_i),
        .s_axi_awready_o (s_axi_awready_o),

        .s_axi_wdata_i   (s_axi_wdata_i),
        .s_axi_wstrb_i   (s_axi_wstrb_i),
        .s_axi_wvalid_i  (s_axi_wvalid_i),
        .s_axi_wready_o  (s_axi_wready_o),

        .s_axi_bresp_o   (s_axi_bresp_o),
        .s_axi_bvalid_o  (s_axi_bvalid_o),
        .s_axi_bready_i  (s_axi_bready_i),

        .s_axi_araddr_i  (s_axi_araddr_i),
        .s_axi_arprot_i  (s_axi_arprot_i),
        .s_axi_arvalid_i (s_axi_arvalid_i),
        .s_axi_arready_o (s_axi_arready_o),

        .s_axi_rdata_o   (s_axi_rdata_o),
        .s_axi_rresp_o   (s_axi_rresp_o),
        .s_axi_rvalid_o  (s_axi_rvalid_o),
        .s_axi_rready_i  (s_axi_rready_i),

        .write_valid_o   (host_write_valid),
        .write_ready_i   (host_write_ready),
        .write_addr_o    (host_write_addr),
        .write_prot_o    (host_write_prot),
        .write_data_o    (host_write_data),
        .write_strb_o    (host_write_strb),
        .write_error_i   (host_write_error),

        .read_valid_o    (host_read_valid),
        .read_ready_i    (host_read_ready),
        .read_addr_o     (host_read_addr),
        .read_prot_o     (host_read_prot),
        .read_data_i     (host_read_data),
        .read_error_i    (host_read_error)
    );

    // -------------------------------------------------------------------------
    // Die selection
    // -------------------------------------------------------------------------

    logic write_targets_die_b;
    logic read_targets_die_b;

    assign write_targets_die_b = host_write_addr[DIE_SELECT_BIT];
    assign read_targets_die_b  = host_read_addr[DIE_SELECT_BIT];

    // Die A path
    logic        die_a_write_valid;
    logic        die_a_write_ready;
    logic        die_a_write_error;
    logic        die_a_read_valid;
    logic        die_a_read_ready;
    logic [31:0] die_a_read_data;
    logic        die_a_read_error;

    // Die B path (across the photonic link)
    logic        die_b_write_valid;
    logic        die_b_write_ready;
    logic        die_b_write_error;
    logic        die_b_read_valid;
    logic        die_b_read_ready;
    logic [31:0] die_b_read_data;
    logic        die_b_read_error;

    assign die_a_write_valid = host_write_valid && !write_targets_die_b;
    assign die_b_write_valid = host_write_valid &&  write_targets_die_b;

    assign die_a_read_valid  = host_read_valid  && !read_targets_die_b;
    assign die_b_read_valid  = host_read_valid  &&  read_targets_die_b;

    assign host_write_ready =
        write_targets_die_b
        ? die_b_write_ready
        : die_a_write_ready;

    assign host_write_error =
        write_targets_die_b
        ? die_b_write_error
        : die_a_write_error;

    assign host_read_ready =
        read_targets_die_b
        ? die_b_read_ready
        : die_a_read_ready;

    assign host_read_data =
        read_targets_die_b
        ? die_b_read_data
        : die_a_read_data;

    assign host_read_error =
        read_targets_die_b
        ? die_b_read_error
        : die_a_read_error;

    // -------------------------------------------------------------------------
    // Die A: local NCE
    // -------------------------------------------------------------------------

    logic [31:0] a_awaddr;
    logic [2:0]  a_awprot;
    logic        a_awvalid;
    logic        a_awready;
    logic [31:0] a_wdata;
    logic [3:0]  a_wstrb;
    logic        a_wvalid;
    logic        a_wready;
    logic [1:0]  a_bresp;
    logic        a_bvalid;
    logic        a_bready;
    logic [31:0] a_araddr;
    logic [2:0]  a_arprot;
    logic        a_arvalid;
    logic        a_arready;
    logic [31:0] a_rdata;
    logic [1:0]  a_rresp;
    logic        a_rvalid;
    logic        a_rready;

    nce_axi4lite_master_adapter u_die_a_adapter (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        .write_valid_i   (die_a_write_valid),
        .write_ready_o   (die_a_write_ready),
        .write_addr_i    (host_write_addr),
        .write_data_i    (host_write_data),
        .write_strb_i    (host_write_strb),
        .write_error_o   (die_a_write_error),

        .read_valid_i    (die_a_read_valid),
        .read_ready_o    (die_a_read_ready),
        .read_addr_i     (host_read_addr),
        .read_data_o     (die_a_read_data),
        .read_error_o    (die_a_read_error),

        .m_axi_awaddr_o  (a_awaddr),
        .m_axi_awprot_o  (a_awprot),
        .m_axi_awvalid_o (a_awvalid),
        .m_axi_awready_i (a_awready),

        .m_axi_wdata_o   (a_wdata),
        .m_axi_wstrb_o   (a_wstrb),
        .m_axi_wvalid_o  (a_wvalid),
        .m_axi_wready_i  (a_wready),

        .m_axi_bresp_i   (a_bresp),
        .m_axi_bvalid_i  (a_bvalid),
        .m_axi_bready_o  (a_bready),

        .m_axi_araddr_o  (a_araddr),
        .m_axi_arprot_o  (a_arprot),
        .m_axi_arvalid_o (a_arvalid),
        .m_axi_arready_i (a_arready),

        .m_axi_rdata_i   (a_rdata),
        .m_axi_rresp_i   (a_rresp),
        .m_axi_rvalid_i  (a_rvalid),
        .m_axi_rready_o  (a_rready)
    );

    nce_x2_core_wrapper #(
        .USE_INT8_CORE (USE_INT8_CORE)
    ) u_die_a (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        .s_axi_awaddr_i  (a_awaddr),
        .s_axi_awprot_i  (a_awprot),
        .s_axi_awvalid_i (a_awvalid),
        .s_axi_awready_o (a_awready),

        .s_axi_wdata_i   (a_wdata),
        .s_axi_wstrb_i   (a_wstrb),
        .s_axi_wvalid_i  (a_wvalid),
        .s_axi_wready_o  (a_wready),

        .s_axi_bresp_o   (a_bresp),
        .s_axi_bvalid_o  (a_bvalid),
        .s_axi_bready_i  (a_bready),

        .s_axi_araddr_i  (a_araddr),
        .s_axi_arprot_i  (a_arprot),
        .s_axi_arvalid_i (a_arvalid),
        .s_axi_arready_o (a_arready),

        .s_axi_rdata_o   (a_rdata),
        .s_axi_rresp_o   (a_rresp),
        .s_axi_rvalid_o  (a_rvalid),
        .s_axi_rready_i  (a_rready)
    );

    // -------------------------------------------------------------------------
    // Photonic link
    // -------------------------------------------------------------------------

    logic a_tx;
    logic a_rx;
    logic b_tx;
    logic b_rx;

    assign pic_a_tx_o = a_tx;
    assign pic_b_tx_o = b_tx;

    // An ideal PIC is a pair of crossed waveguides. When the real PIC is
    // attached the lanes come in from the node boundary instead.
    assign a_rx = PIC_LOOPBACK ? b_tx : pic_a_rx_i;
    assign b_rx = PIC_LOOPBACK ? a_tx : pic_b_rx_i;

    nce_tfln_link_initiator #(
        .RESPONSE_TIMEOUT (RESPONSE_TIMEOUT)
    ) u_link_initiator (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),

        .write_valid_i    (die_b_write_valid),
        .write_ready_o    (die_b_write_ready),
        .write_addr_i     (host_write_addr),
        .write_data_i     (host_write_data),
        .write_strb_i     (host_write_strb),
        .write_error_o    (die_b_write_error),

        .read_valid_i     (die_b_read_valid),
        .read_ready_o     (die_b_read_ready),
        .read_addr_i      (host_read_addr),
        .read_data_o      (die_b_read_data),
        .read_error_o     (die_b_read_error),

        .tfln_tx_o        (a_tx),
        .tfln_rx_i        (a_rx),

        .link_busy_o      (link_busy_o),
        .link_timeout_o   (link_timeout_o),
        .link_crc_error_o (link_crc_error_o)
    );

    // -------------------------------------------------------------------------
    // Die B: remote NCE, reached only across the photonic link
    // -------------------------------------------------------------------------

    logic [31:0] b_awaddr;
    logic [2:0]  b_awprot;
    logic        b_awvalid;
    logic        b_awready;
    logic [31:0] b_wdata;
    logic [3:0]  b_wstrb;
    logic        b_wvalid;
    logic        b_wready;
    logic [1:0]  b_bresp;
    logic        b_bvalid;
    logic        b_bready;
    logic [31:0] b_araddr;
    logic [2:0]  b_arprot;
    logic        b_arvalid;
    logic        b_arready;
    logic [31:0] b_rdata;
    logic [1:0]  b_rresp;
    logic        b_rvalid;
    logic        b_rready;

    logic        target_busy;
    logic        target_crc_error;

    nce_tfln_link_target u_link_target (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),

        .tfln_rx_i        (b_rx),
        .tfln_tx_o        (b_tx),

        .m_axi_awaddr_o   (b_awaddr),
        .m_axi_awprot_o   (b_awprot),
        .m_axi_awvalid_o  (b_awvalid),
        .m_axi_awready_i  (b_awready),

        .m_axi_wdata_o    (b_wdata),
        .m_axi_wstrb_o    (b_wstrb),
        .m_axi_wvalid_o   (b_wvalid),
        .m_axi_wready_i   (b_wready),

        .m_axi_bresp_i    (b_bresp),
        .m_axi_bvalid_i   (b_bvalid),
        .m_axi_bready_o   (b_bready),

        .m_axi_araddr_o   (b_araddr),
        .m_axi_arprot_o   (b_arprot),
        .m_axi_arvalid_o  (b_arvalid),
        .m_axi_arready_i  (b_arready),

        .m_axi_rdata_i    (b_rdata),
        .m_axi_rresp_i    (b_rresp),
        .m_axi_rvalid_i   (b_rvalid),
        .m_axi_rready_o   (b_rready),

        .link_busy_o      (target_busy),
        .link_crc_error_o (target_crc_error),
        .link_dropped_o   (link_dropped_o)
    );

    nce_x2_core_wrapper #(
        .USE_INT8_CORE (USE_INT8_CORE)
    ) u_die_b (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        .s_axi_awaddr_i  (b_awaddr),
        .s_axi_awprot_i  (b_awprot),
        .s_axi_awvalid_i (b_awvalid),
        .s_axi_awready_o (b_awready),

        .s_axi_wdata_i   (b_wdata),
        .s_axi_wstrb_i   (b_wstrb),
        .s_axi_wvalid_i  (b_wvalid),
        .s_axi_wready_o  (b_wready),

        .s_axi_bresp_o   (b_bresp),
        .s_axi_bvalid_o  (b_bvalid),
        .s_axi_bready_i  (b_bready),

        .s_axi_araddr_i  (b_araddr),
        .s_axi_arprot_i  (b_arprot),
        .s_axi_arvalid_i (b_arvalid),
        .s_axi_arready_o (b_arready),

        .s_axi_rdata_o   (b_rdata),
        .s_axi_rresp_o   (b_rresp),
        .s_axi_rvalid_o  (b_rvalid),
        .s_axi_rready_i  (b_rready)
    );

endmodule

`default_nettype wire
