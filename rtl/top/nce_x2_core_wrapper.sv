// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN_AI_NODE_X2
//
// NCE core RTL: Original RTL Architect and Digital Designer: Talha Alam
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Per-die NCE core wrapper.
//
// Selects which NCE variant occupies a die site on the X2 node. Both variants
// expose the identical AXI4-Lite slave port list, so the choice is invisible
// above this wrapper and the node integration does not change.
//
//   USE_INT8_CORE = 1  nce_axi_int8_top             INT8 dot-product engine
//   USE_INT8_CORE = 0  nce_axi_mixed_precision_top  INT8 + BF16 + BF24 + FP32
//
// The INT8 variant exists so the complete two-die node can be placed and routed
// on modest hardware: the mixed-precision core carries the full tensor memory
// subsystem and is far too large to harden two of. Selecting the variant here
// rather than editing the node keeps one node description for both builds.
// -----------------------------------------------------------------------------

module nce_x2_core_wrapper #(
    parameter bit USE_INT8_CORE = 1'b1
) (
    input  logic         clk_i,
    input  logic         rst_ni,

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
    input  logic         s_axi_rready_i
);

    generate
        if (USE_INT8_CORE) begin : g_int8_core

            nce_axi_int8_top u_core (
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
                .s_axi_rready_i  (s_axi_rready_i)
            );

        end : g_int8_core
        else begin : g_mixed_precision_core

            nce_axi_mixed_precision_top u_core (
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
                .s_axi_rready_i  (s_axi_rready_i)
            );

        end : g_mixed_precision_core
    endgenerate

endmodule

`default_nettype wire
