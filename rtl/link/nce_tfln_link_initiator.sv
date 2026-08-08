// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) -- TFLN optical die-to-die link
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Link initiator: near-side endpoint.
//
// Presents an AXI4-Lite slave to the host, tunnels each transaction across the
// TFLN photonic link as a request frame, and completes the AXI transaction when
// the matching response frame returns.
//
// The link is single-outstanding by construction: the AXI4-Lite frontend it
// reuses issues one backend request at a time, and the initiator holds that
// request until a response arrives.
//
// Loss recovery:
//   An optical dropout would otherwise strand the AXI transaction forever, so a
//   response timeout retires the transaction with SLVERR and pulses
//   link_timeout_o. The bus therefore always makes progress, and software sees
//   an error rather than a hang.
// -----------------------------------------------------------------------------

module nce_tfln_link_initiator
    import nce_tfln_pkg::*;
#(
    parameter int unsigned RESPONSE_TIMEOUT = 4096
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Backend write request (from the node AXI4-Lite frontend)
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

    // Optical lanes (to and from the TFLN PIC)
    output logic         tfln_tx_o,
    input  logic         tfln_rx_i,

    // Status
    output logic         link_busy_o,
    output logic         link_timeout_o,
    output logic         link_crc_error_o
);

    localparam int unsigned TIMEOUT_WIDTH = $clog2(RESPONSE_TIMEOUT + 1);

    logic        backend_write_valid;
    logic        backend_write_ready;
    logic [31:0] backend_write_addr;
    logic [31:0] backend_write_data;
    logic [3:0]  backend_write_strb;
    logic        backend_write_error;

    logic        backend_read_valid;
    logic        backend_read_ready;
    logic [31:0] backend_read_addr;
    logic [31:0] backend_read_data;
    logic        backend_read_error;

    assign backend_write_valid = write_valid_i;
    assign backend_write_addr  = write_addr_i;
    assign backend_write_data  = write_data_i;
    assign backend_write_strb  = write_strb_i;
    assign write_ready_o       = backend_write_ready;
    assign write_error_o       = backend_write_error;

    assign backend_read_valid  = read_valid_i;
    assign backend_read_addr   = read_addr_i;
    assign read_ready_o        = backend_read_ready;
    assign read_data_o         = backend_read_data;
    assign read_error_o        = backend_read_error;

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
    // Request/response sequencing
    // -------------------------------------------------------------------------

    typedef enum logic [1:0] {
        STATE_IDLE   = 2'd0,
        STATE_SEND   = 2'd1,
        STATE_WAIT   = 2'd2
    } state_e;

    state_e                 state_q;
    logic                   pending_is_write_q;
    logic [TIMEOUT_WIDTH-1:0] timeout_q;

    logic        response_is_response;
    logic        response_error;
    logic [31:0] response_data;

    assign response_is_response =
        rx_frame[TFLN_CTRL_LSB + TFLN_CTRL_RESPONSE];

    assign response_error =
        rx_frame[TFLN_CTRL_LSB + TFLN_CTRL_ERROR];

    assign response_data =
        rx_frame[TFLN_DATA_LSB +: 32];

    assign link_busy_o = (state_q != STATE_IDLE);

    // Backend completion is a single-cycle acknowledgement.
    assign backend_write_ready =
        (state_q == STATE_WAIT) &&
        pending_is_write_q &&
        ((rx_frame_valid && response_is_response) ||
         (timeout_q == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT)));

    assign backend_read_ready =
        (state_q == STATE_WAIT) &&
        !pending_is_write_q &&
        ((rx_frame_valid && response_is_response) ||
         (timeout_q == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT)));

    // A timeout is reported to the bus as SLVERR.
    assign backend_write_error =
        (timeout_q == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT)) ||
        response_error;

    assign backend_read_error =
        (timeout_q == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT)) ||
        response_error;

    assign backend_read_data =
        (timeout_q == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT))
        ? 32'h0000_0000
        : response_data;

    assign tx_frame_valid = (state_q == STATE_SEND);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q            <= STATE_IDLE;
            pending_is_write_q <= 1'b0;
            timeout_q          <= {TIMEOUT_WIDTH{1'b0}};
            tx_frame           <= {TFLN_FRAME_BITS{1'b0}};
            link_timeout_o     <= 1'b0;
        end
        else begin
            link_timeout_o <= 1'b0;

            unique case (state_q)
                STATE_IDLE: begin
                    timeout_q <= {TIMEOUT_WIDTH{1'b0}};

                    // Writes are offered before reads so a posted write cannot
                    // be starved by a stream of reads.
                    if (backend_write_valid) begin
                        pending_is_write_q <= 1'b1;

                        tx_frame <= tfln_pack(
                            1'b0,
                            1'b1,
                            1'b0,
                            backend_write_strb,
                            backend_write_addr,
                            backend_write_data
                        );

                        state_q <= STATE_SEND;
                    end
                    else if (backend_read_valid) begin
                        pending_is_write_q <= 1'b0;

                        tx_frame <= tfln_pack(
                            1'b0,
                            1'b0,
                            1'b0,
                            4'h0,
                            backend_read_addr,
                            32'h0000_0000
                        );

                        state_q <= STATE_SEND;
                    end
                end

                STATE_SEND: begin
                    if (tx_frame_ready) begin
                        state_q   <= STATE_WAIT;
                        timeout_q <= {TIMEOUT_WIDTH{1'b0}};
                    end
                end

                STATE_WAIT: begin
                    if (rx_frame_valid && response_is_response) begin
                        state_q <= STATE_IDLE;
                    end
                    else if (
                        timeout_q == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT)
                    ) begin
                        state_q        <= STATE_IDLE;
                        link_timeout_o <= 1'b1;
                    end
                    else begin
                        timeout_q <= timeout_q + TIMEOUT_WIDTH'(1);
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
