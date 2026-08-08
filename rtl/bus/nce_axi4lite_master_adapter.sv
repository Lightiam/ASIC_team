// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Backend-request to AXI4-Lite master adapter.
//
// The inverse of nce_axi4lite_frontend: it turns the internal single-outstanding
// valid/ready request interface back into AXI4-Lite transactions, so a backend
// request can be routed to a slave that expects a full AXI4-Lite port.
//
// Reads and writes are served one at a time, writes first. A backend request is
// acknowledged for a single cycle when its AXI response arrives, carrying the
// SLVERR indication back on the corresponding error output.
// -----------------------------------------------------------------------------

module nce_axi4lite_master_adapter (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Backend write request
    input  logic         write_valid_i,
    output logic         write_ready_o,
    input  logic [31:0]  write_addr_i,
    input  logic [31:0]  write_data_i,
    input  logic [3:0]   write_strb_i,
    output logic         write_error_o,

    // Backend read request
    input  logic         read_valid_i,
    output logic         read_ready_o,
    input  logic [31:0]  read_addr_i,
    output logic [31:0]  read_data_o,
    output logic         read_error_o,

    // AXI4-Lite master
    output logic [31:0]  m_axi_awaddr_o,
    output logic [2:0]   m_axi_awprot_o,
    output logic         m_axi_awvalid_o,
    input  logic         m_axi_awready_i,

    output logic [31:0]  m_axi_wdata_o,
    output logic [3:0]   m_axi_wstrb_o,
    output logic         m_axi_wvalid_o,
    input  logic         m_axi_wready_i,

    input  logic [1:0]   m_axi_bresp_i,
    input  logic         m_axi_bvalid_i,
    output logic         m_axi_bready_o,

    output logic [31:0]  m_axi_araddr_o,
    output logic [2:0]   m_axi_arprot_o,
    output logic         m_axi_arvalid_o,
    input  logic         m_axi_arready_i,

    input  logic [31:0]  m_axi_rdata_i,
    input  logic [1:0]   m_axi_rresp_i,
    input  logic         m_axi_rvalid_i,
    output logic         m_axi_rready_o
);

    typedef enum logic [2:0] {
        STATE_IDLE    = 3'd0,
        STATE_WRITE   = 3'd1,
        STATE_WRITE_B = 3'd2,
        STATE_READ    = 3'd3,
        STATE_READ_R  = 3'd4
    } state_e;

    state_e state_q;

    logic aw_done_q;
    logic w_done_q;

    assign m_axi_awaddr_o  = write_addr_i;
    assign m_axi_awprot_o  = 3'b000;
    assign m_axi_awvalid_o = (state_q == STATE_WRITE) && !aw_done_q;

    assign m_axi_wdata_o   = write_data_i;
    assign m_axi_wstrb_o   = write_strb_i;
    assign m_axi_wvalid_o  = (state_q == STATE_WRITE) && !w_done_q;

    assign m_axi_bready_o  = (state_q == STATE_WRITE_B);

    assign m_axi_araddr_o  = read_addr_i;
    assign m_axi_arprot_o  = 3'b000;
    assign m_axi_arvalid_o = (state_q == STATE_READ);

    assign m_axi_rready_o  = (state_q == STATE_READ_R);

    // Single-cycle backend acknowledgement on response arrival.
    assign write_ready_o = (state_q == STATE_WRITE_B) && m_axi_bvalid_i;
    assign write_error_o = m_axi_bresp_i[1];

    assign read_ready_o  = (state_q == STATE_READ_R) && m_axi_rvalid_i;
    assign read_data_o   = m_axi_rdata_i;
    assign read_error_o  = m_axi_rresp_i[1];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q   <= STATE_IDLE;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end
        else begin
            unique case (state_q)
                STATE_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;

                    if (write_valid_i) begin
                        state_q <= STATE_WRITE;
                    end
                    else if (read_valid_i) begin
                        state_q <= STATE_READ;
                    end
                end

                STATE_WRITE: begin
                    if (m_axi_awvalid_o && m_axi_awready_i) begin
                        aw_done_q <= 1'b1;
                    end

                    if (m_axi_wvalid_o && m_axi_wready_i) begin
                        w_done_q <= 1'b1;
                    end

                    if (
                        (aw_done_q || (m_axi_awvalid_o && m_axi_awready_i)) &&
                        (w_done_q  || (m_axi_wvalid_o  && m_axi_wready_i))
                    ) begin
                        state_q <= STATE_WRITE_B;
                    end
                end

                STATE_WRITE_B: begin
                    if (m_axi_bvalid_i) begin
                        state_q <= STATE_IDLE;
                    end
                end

                STATE_READ: begin
                    if (m_axi_arready_i) begin
                        state_q <= STATE_READ_R;
                    end
                end

                STATE_READ_R: begin
                    if (m_axi_rvalid_i) begin
                        state_q <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
