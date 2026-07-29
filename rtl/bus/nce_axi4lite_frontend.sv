// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Single-outstanding AXI4-Lite slave frontend.
//
// Converts AXI4-Lite transactions into independent backend valid/ready
// interfaces.
//
// Features:
//   - Independent AW and W channel buffering
//   - AW-before-W, W-before-AW and simultaneous arrival support
//   - Stable B and R responses under backpressure
//   - Independent read and write paths
//   - OKAY and SLVERR response generation
//
// Responses:
//   2'b00 = OKAY
//   2'b10 = SLVERR
// -----------------------------------------------------------------------------

module nce_axi4lite_frontend #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  logic                      clk_i,
    input  logic                      rst_ni,

    // AXI write-address channel
    input  logic [ADDR_WIDTH-1:0]     s_axi_awaddr_i,
    input  logic [2:0]                s_axi_awprot_i,
    input  logic                      s_axi_awvalid_i,
    output logic                      s_axi_awready_o,

    // AXI write-data channel
    input  logic [DATA_WIDTH-1:0]     s_axi_wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0] s_axi_wstrb_i,
    input  logic                      s_axi_wvalid_i,
    output logic                      s_axi_wready_o,

    // AXI write-response channel
    output logic [1:0]                s_axi_bresp_o,
    output logic                      s_axi_bvalid_o,
    input  logic                      s_axi_bready_i,

    // AXI read-address channel
    input  logic [ADDR_WIDTH-1:0]     s_axi_araddr_i,
    input  logic [2:0]                s_axi_arprot_i,
    input  logic                      s_axi_arvalid_i,
    output logic                      s_axi_arready_o,

    // AXI read-data channel
    output logic [DATA_WIDTH-1:0]     s_axi_rdata_o,
    output logic [1:0]                s_axi_rresp_o,
    output logic                      s_axi_rvalid_o,
    input  logic                      s_axi_rready_i,

    // Backend write request
    output logic                      write_valid_o,
    input  logic                      write_ready_i,
    output logic [ADDR_WIDTH-1:0]     write_addr_o,
    output logic [2:0]                write_prot_o,
    output logic [DATA_WIDTH-1:0]     write_data_o,
    output logic [(DATA_WIDTH/8)-1:0] write_strb_o,
    input  logic                      write_error_i,

    // Backend read request
    output logic                      read_valid_o,
    input  logic                      read_ready_i,
    output logic [ADDR_WIDTH-1:0]     read_addr_o,
    output logic [2:0]                read_prot_o,
    input  logic [DATA_WIDTH-1:0]     read_data_i,
    input  logic                      read_error_i
);

    localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;

    logic                      aw_buffer_valid_q;
    logic [ADDR_WIDTH-1:0]     awaddr_q;
    logic [2:0]                awprot_q;

    logic                      w_buffer_valid_q;
    logic [DATA_WIDTH-1:0]     wdata_q;
    logic [(DATA_WIDTH/8)-1:0] wstrb_q;

    logic                      ar_buffer_valid_q;
    logic [ADDR_WIDTH-1:0]     araddr_q;
    logic [2:0]                arprot_q;

    logic write_fire;
    logic read_fire;

    assign s_axi_awready_o =
        rst_ni &&
        !aw_buffer_valid_q &&
        !s_axi_bvalid_o;

    assign s_axi_wready_o =
        rst_ni &&
        !w_buffer_valid_q &&
        !s_axi_bvalid_o;

    assign write_valid_o =
        aw_buffer_valid_q &&
        w_buffer_valid_q &&
        !s_axi_bvalid_o;

    assign write_addr_o = awaddr_q;
    assign write_prot_o = awprot_q;
    assign write_data_o = wdata_q;
    assign write_strb_o = wstrb_q;

    assign write_fire =
        write_valid_o &&
        write_ready_i;

    assign s_axi_arready_o =
        rst_ni &&
        !ar_buffer_valid_q &&
        !s_axi_rvalid_o;

    assign read_valid_o =
        ar_buffer_valid_q &&
        !s_axi_rvalid_o;

    assign read_addr_o = araddr_q;
    assign read_prot_o = arprot_q;

    assign read_fire =
        read_valid_o &&
        read_ready_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_buffer_valid_q <= 1'b0;
            awaddr_q          <= '0;
            awprot_q          <= '0;

            w_buffer_valid_q  <= 1'b0;
            wdata_q           <= '0;
            wstrb_q           <= '0;

            s_axi_bvalid_o    <= 1'b0;
            s_axi_bresp_o     <= AXI_RESP_OKAY;
        end
        else begin
            if (
                s_axi_awvalid_i &&
                s_axi_awready_o
            ) begin
                aw_buffer_valid_q <= 1'b1;
                awaddr_q          <= s_axi_awaddr_i;
                awprot_q          <= s_axi_awprot_i;
            end

            if (
                s_axi_wvalid_i &&
                s_axi_wready_o
            ) begin
                w_buffer_valid_q <= 1'b1;
                wdata_q          <= s_axi_wdata_i;
                wstrb_q          <= s_axi_wstrb_i;
            end

            if (write_fire) begin
                aw_buffer_valid_q <= 1'b0;
                w_buffer_valid_q  <= 1'b0;

                s_axi_bvalid_o <= 1'b1;

                s_axi_bresp_o <=
                    write_error_i
                    ? AXI_RESP_SLVERR
                    : AXI_RESP_OKAY;
            end
            else if (
                s_axi_bvalid_o &&
                s_axi_bready_i
            ) begin
                s_axi_bvalid_o <= 1'b0;
                s_axi_bresp_o  <= AXI_RESP_OKAY;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ar_buffer_valid_q <= 1'b0;
            araddr_q          <= '0;
            arprot_q          <= '0;

            s_axi_rdata_o     <= '0;
            s_axi_rresp_o     <= AXI_RESP_OKAY;
            s_axi_rvalid_o    <= 1'b0;
        end
        else begin
            if (
                s_axi_arvalid_i &&
                s_axi_arready_o
            ) begin
                ar_buffer_valid_q <= 1'b1;
                araddr_q          <= s_axi_araddr_i;
                arprot_q          <= s_axi_arprot_i;
            end

            if (read_fire) begin
                ar_buffer_valid_q <= 1'b0;

                s_axi_rdata_o  <= read_data_i;
                s_axi_rvalid_o <= 1'b1;

                s_axi_rresp_o <=
                    read_error_i
                    ? AXI_RESP_SLVERR
                    : AXI_RESP_OKAY;
            end
            else if (
                s_axi_rvalid_o &&
                s_axi_rready_i
            ) begin
                s_axi_rdata_o  <= '0;
                s_axi_rresp_o  <= AXI_RESP_OKAY;
                s_axi_rvalid_o <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
