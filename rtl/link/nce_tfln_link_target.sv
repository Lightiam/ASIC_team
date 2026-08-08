// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN optical die-to-die link
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Link target: far-side endpoint.
//
// Recovers request frames arriving over the TFLN photonic link, replays each
// one as an AXI4-Lite transaction on the far die, and returns the outcome as a
// response frame.
//
// Only one request is serviced at a time, matching the single-outstanding
// behaviour of the initiator. Frames that arrive while a transaction is in
// flight are dropped rather than queued: the initiator cannot produce them, so
// their presence means the link has desynchronised, and dropping keeps the
// endpoint from replaying a corrupted address onto the far die.
// -----------------------------------------------------------------------------

module nce_tfln_link_target
    import nce_tfln_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,

    // Optical lanes (to and from the TFLN PIC)
    input  logic         tfln_rx_i,
    output logic         tfln_tx_o,

    // AXI4-Lite master (far die)
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
    output logic         m_axi_rready_o,

    // Status
    output logic         link_busy_o,
    output logic         link_crc_error_o,
    output logic         link_dropped_o
);

    // -------------------------------------------------------------------------
    // Serial transport
    // -------------------------------------------------------------------------

    logic                       tx_frame_valid;
    logic                       tx_frame_ready;
    logic [TFLN_FRAME_BITS-1:0] tx_frame;
    logic                       tx_busy;

    logic                       rx_frame_valid;
    logic [TFLN_FRAME_BITS-1:0] rx_frame;
    logic                       rx_crc_error;

    nce_tfln_serializer u_serializer (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .frame_valid_i (tx_frame_valid),
        .frame_ready_o (tx_frame_ready),
        .frame_i       (tx_frame),
        .serial_o      (tfln_tx_o),
        .busy_o        (tx_busy)
    );

    nce_tfln_deserializer u_deserializer (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .serial_i      (tfln_rx_i),
        .frame_valid_o (rx_frame_valid),
        .frame_o       (rx_frame),
        .crc_error_o   (rx_crc_error)
    );

    assign link_crc_error_o = rx_crc_error;

    // -------------------------------------------------------------------------
    // Request field extraction
    // -------------------------------------------------------------------------

    logic        request_is_response;
    logic        request_is_write;
    logic [3:0]  request_strb;
    logic [31:0] request_addr;
    logic [31:0] request_data;

    assign request_is_response = rx_frame[TFLN_CTRL_LSB + TFLN_CTRL_RESPONSE];
    assign request_is_write    = rx_frame[TFLN_CTRL_LSB + TFLN_CTRL_WRITE];
    assign request_strb        = rx_frame[TFLN_STRB_LSB +: 4];
    assign request_addr        = rx_frame[TFLN_ADDR_LSB +: 32];
    assign request_data        = rx_frame[TFLN_DATA_LSB +: 32];

    // -------------------------------------------------------------------------
    // Transaction sequencing
    // -------------------------------------------------------------------------

    typedef enum logic [2:0] {
        STATE_IDLE     = 3'd0,
        STATE_WRITE    = 3'd1,
        STATE_WRITE_B  = 3'd2,
        STATE_READ     = 3'd3,
        STATE_READ_R   = 3'd4,
        STATE_RESPOND  = 3'd5
    } state_e;

    state_e      state_q;
    logic [31:0] addr_q;
    logic [31:0] data_q;
    logic [3:0]  strb_q;
    logic [31:0] result_q;
    logic        error_q;
    logic        is_write_q;

    logic        aw_done_q;
    logic        w_done_q;

    assign link_busy_o = (state_q != STATE_IDLE);

    assign m_axi_awaddr_o  = addr_q;
    assign m_axi_awprot_o  = 3'b000;
    assign m_axi_awvalid_o = (state_q == STATE_WRITE) && !aw_done_q;

    assign m_axi_wdata_o   = data_q;
    assign m_axi_wstrb_o   = strb_q;
    assign m_axi_wvalid_o  = (state_q == STATE_WRITE) && !w_done_q;

    assign m_axi_bready_o  = (state_q == STATE_WRITE_B);

    assign m_axi_araddr_o  = addr_q;
    assign m_axi_arprot_o  = 3'b000;
    assign m_axi_arvalid_o = (state_q == STATE_READ);

    assign m_axi_rready_o  = (state_q == STATE_READ_R);

    assign tx_frame_valid  = (state_q == STATE_RESPOND);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q        <= STATE_IDLE;
            addr_q         <= 32'h0000_0000;
            data_q         <= 32'h0000_0000;
            strb_q         <= 4'h0;
            result_q       <= 32'h0000_0000;
            error_q        <= 1'b0;
            is_write_q     <= 1'b0;
            aw_done_q      <= 1'b0;
            w_done_q       <= 1'b0;
            tx_frame       <= {TFLN_FRAME_BITS{1'b0}};
            link_dropped_o <= 1'b0;
        end
        else begin
            link_dropped_o <= 1'b0;

            unique case (state_q)
                STATE_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                    error_q   <= 1'b0;
                    result_q  <= 32'h0000_0000;

                    if (rx_frame_valid && !request_is_response) begin
                        addr_q     <= request_addr;
                        data_q     <= request_data;
                        strb_q     <= request_strb;
                        is_write_q <= request_is_write;

                        if (request_is_write) begin
                            state_q <= STATE_WRITE;
                        end
                        else begin
                            state_q <= STATE_READ;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (m_axi_awvalid_o && m_axi_awready_i) begin
                        aw_done_q <= 1'b1;
                    end

                    if (m_axi_wvalid_o && m_axi_wready_i) begin
                        w_done_q <= 1'b1;
                    end

                    // Both channels accepted, counting acceptances that land
                    // in this same cycle.
                    if (
                        (aw_done_q || (m_axi_awvalid_o && m_axi_awready_i)) &&
                        (w_done_q  || (m_axi_wvalid_o  && m_axi_wready_i))
                    ) begin
                        state_q <= STATE_WRITE_B;
                    end
                end

                STATE_WRITE_B: begin
                    if (m_axi_bvalid_i) begin
                        error_q <= m_axi_bresp_i[1];

                        // Built on the transition so the frame is already
                        // stable when STATE_RESPOND raises frame_valid.
                        tx_frame <= tfln_pack(
                            1'b1,
                            is_write_q,
                            m_axi_bresp_i[1],
                            4'h0,
                            32'h0000_0000,
                            32'h0000_0000
                        );

                        state_q <= STATE_RESPOND;
                    end
                end

                STATE_READ: begin
                    if (m_axi_arready_i) begin
                        state_q <= STATE_READ_R;
                    end
                end

                STATE_READ_R: begin
                    if (m_axi_rvalid_i) begin
                        result_q <= m_axi_rdata_i;
                        error_q  <= m_axi_rresp_i[1];

                        tx_frame <= tfln_pack(
                            1'b1,
                            is_write_q,
                            m_axi_rresp_i[1],
                            4'h0,
                            32'h0000_0000,
                            m_axi_rdata_i
                        );

                        state_q <= STATE_RESPOND;
                    end
                end

                STATE_RESPOND: begin
                    if (tx_frame_ready) begin
                        state_q <= STATE_IDLE;
                    end
                end
            endcase

            // A request arriving mid-transaction means the link has lost
            // framing; drop it rather than replay a suspect address.
            if (
                (state_q != STATE_IDLE) &&
                rx_frame_valid &&
                !request_is_response
            ) begin
                link_dropped_o <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
