// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
//
// RECONSTRUCTED LEAF MODULE
// -------------------------
// This module is instantiated three times by
// rtl/memory/nce_tensor_memory_subsystem.sv but was not present in any
// published branch of the repository. It has been reconstructed to satisfy
// every directed case asserted by tb/unit/tb_nce_tensor_scratchpad.sv.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Multi-port banked tensor scratchpad.
//
// PORT_COUNT logical ports share BANK_COUNT physical 1R1W banks. Each port
// presents a flat word address which is decoded low-bits-first:
//
//   bank index = flat_addr[BANK_INDEX_WIDTH-1:0]
//   bank row   = flat_addr[FLAT_ADDR_WIDTH-1:BANK_INDEX_WIDTH]
//
// Interleaving on the low bits means consecutive flat addresses land in
// different banks, so a sequential stride-one sweep across PORT_COUNT ports is
// conflict-free.
//
// Arbitration:
//   Read and write arbitration are independent, because each bank is 1R1W and
//   can serve one read and one write in the same cycle. Within each direction,
//   the lowest-numbered requesting port wins its bank; every other port
//   targeting that bank is refused for this cycle.
//
//     ready_o[p]    = request accepted this cycle
//     conflict_o[p] = request refused because a lower port won the bank
//
//   Both are combinational, so a caller can retry on the next cycle.
//
// Collision:
//   A read and a write that resolve to the same bank and row in the same cycle
//   are handled write-first by the underlying bank: the read returns the
//   post-merge value.
//
// Response:
//   Read responses are registered and return one cycle after acceptance. The
//   grant is pipelined alongside so that each bank's response is steered back
//   to the port that won it. A refused or invalid read returns zero with
//   read_valid_o deasserted.
//
// clear_i:
//   Invalidates every word in every bank and refuses all requests for that
//   cycle.
// -----------------------------------------------------------------------------

module nce_tensor_scratchpad #(
    parameter int unsigned BANK_COUNT     = 4,
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH     = 32,
    parameter int unsigned PORT_COUNT     = 4,

    parameter int unsigned BANK_INDEX_WIDTH =
        (BANK_COUNT <= 1)
        ? 1
        : $clog2(BANK_COUNT),

    parameter int unsigned BANK_ADDR_WIDTH =
        (WORDS_PER_BANK <= 1)
        ? 1
        : $clog2(WORDS_PER_BANK),

    parameter int unsigned FLAT_ADDR_WIDTH =
        BANK_INDEX_WIDTH + BANK_ADDR_WIDTH,

    parameter int unsigned BYTE_COUNT =
        DATA_WIDTH / 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // Read ports
    input  logic [PORT_COUNT-1:0] read_enable_i,

    input  logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] read_addr_i,

    output logic [PORT_COUNT-1:0] read_ready_o,
    output logic [PORT_COUNT-1:0] read_conflict_o,

    output logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] read_data_o,

    output logic [PORT_COUNT-1:0] read_valid_o,

    // Write ports
    input  logic [PORT_COUNT-1:0] write_enable_i,

    input  logic [
        (PORT_COUNT * FLAT_ADDR_WIDTH)-1:0
    ] write_addr_i,

    input  logic [
        (PORT_COUNT * DATA_WIDTH)-1:0
    ] write_data_i,

    input  logic [
        (PORT_COUNT * BYTE_COUNT)-1:0
    ] write_strb_i,

    output logic [PORT_COUNT-1:0] write_ready_o,
    output logic [PORT_COUNT-1:0] write_conflict_o
);

    // -------------------------------------------------------------------------
    // Address decode
    // -------------------------------------------------------------------------

    logic [BANK_INDEX_WIDTH-1:0] read_bank  [PORT_COUNT-1:0];
    logic [BANK_ADDR_WIDTH-1:0]  read_row   [PORT_COUNT-1:0];
    logic [BANK_INDEX_WIDTH-1:0] write_bank [PORT_COUNT-1:0];
    logic [BANK_ADDR_WIDTH-1:0]  write_row  [PORT_COUNT-1:0];

    generate
        for (
            genvar port_index = 0;
            port_index < PORT_COUNT;
            port_index = port_index + 1
        ) begin : g_decode

            assign read_bank[port_index] =
                read_addr_i[
                    (port_index * FLAT_ADDR_WIDTH) +: BANK_INDEX_WIDTH
                ];

            assign read_row[port_index] =
                read_addr_i[
                    ((port_index * FLAT_ADDR_WIDTH) + BANK_INDEX_WIDTH) +:
                    BANK_ADDR_WIDTH
                ];

            assign write_bank[port_index] =
                write_addr_i[
                    (port_index * FLAT_ADDR_WIDTH) +: BANK_INDEX_WIDTH
                ];

            assign write_row[port_index] =
                write_addr_i[
                    ((port_index * FLAT_ADDR_WIDTH) + BANK_INDEX_WIDTH) +:
                    BANK_ADDR_WIDTH
                ];

        end : g_decode
    endgenerate

    // -------------------------------------------------------------------------
    // Per-bank arbitration: lowest requesting port wins.
    // -------------------------------------------------------------------------

    logic                        bank_read_grant       [BANK_COUNT-1:0];
    logic [PORT_COUNT-1:0]       bank_read_grant_port  [BANK_COUNT-1:0];
    logic                        bank_write_grant      [BANK_COUNT-1:0];
    logic [PORT_COUNT-1:0]       bank_write_grant_port [BANK_COUNT-1:0];

    always_comb begin
        read_ready_o     = {PORT_COUNT{1'b0}};
        read_conflict_o  = {PORT_COUNT{1'b0}};
        write_ready_o    = {PORT_COUNT{1'b0}};
        write_conflict_o = {PORT_COUNT{1'b0}};

        for (
            int unsigned bank_index = 0;
            bank_index < BANK_COUNT;
            bank_index = bank_index + 1
        ) begin
            bank_read_grant[bank_index]       = 1'b0;
            bank_read_grant_port[bank_index]  = {PORT_COUNT{1'b0}};
            bank_write_grant[bank_index]      = 1'b0;
            bank_write_grant_port[bank_index] = {PORT_COUNT{1'b0}};
        end

        if (!clear_i) begin
            for (
                int unsigned port_index = 0;
                port_index < PORT_COUNT;
                port_index = port_index + 1
            ) begin
                // Reads
                if (read_enable_i[port_index]) begin
                    if (!bank_read_grant[read_bank[port_index]]) begin
                        bank_read_grant[read_bank[port_index]] = 1'b1;

                        bank_read_grant_port[read_bank[port_index]]
                            [port_index] = 1'b1;

                        read_ready_o[port_index] = 1'b1;
                    end
                    else begin
                        read_conflict_o[port_index] = 1'b1;
                    end
                end

                // Writes
                if (write_enable_i[port_index]) begin
                    if (!bank_write_grant[write_bank[port_index]]) begin
                        bank_write_grant[write_bank[port_index]] = 1'b1;

                        bank_write_grant_port[write_bank[port_index]]
                            [port_index] = 1'b1;

                        write_ready_o[port_index] = 1'b1;
                    end
                    else begin
                        write_conflict_o[port_index] = 1'b1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Bank request muxing
    // -------------------------------------------------------------------------

    logic                       bank_read_enable [BANK_COUNT-1:0];
    logic [BANK_ADDR_WIDTH-1:0] bank_read_addr   [BANK_COUNT-1:0];
    logic [DATA_WIDTH-1:0]      bank_read_data   [BANK_COUNT-1:0];
    logic                       bank_read_valid  [BANK_COUNT-1:0];

    logic                       bank_write_enable [BANK_COUNT-1:0];
    logic [BANK_ADDR_WIDTH-1:0] bank_write_addr   [BANK_COUNT-1:0];
    logic [DATA_WIDTH-1:0]      bank_write_data   [BANK_COUNT-1:0];
    logic [BYTE_COUNT-1:0]      bank_write_strb   [BANK_COUNT-1:0];

    always_comb begin
        for (
            int unsigned bank_index = 0;
            bank_index < BANK_COUNT;
            bank_index = bank_index + 1
        ) begin
            bank_read_enable[bank_index]  = bank_read_grant[bank_index];
            bank_read_addr[bank_index]    = {BANK_ADDR_WIDTH{1'b0}};

            bank_write_enable[bank_index] = bank_write_grant[bank_index];
            bank_write_addr[bank_index]   = {BANK_ADDR_WIDTH{1'b0}};
            bank_write_data[bank_index]   = {DATA_WIDTH{1'b0}};
            bank_write_strb[bank_index]   = {BYTE_COUNT{1'b0}};

            for (
                int unsigned port_index = 0;
                port_index < PORT_COUNT;
                port_index = port_index + 1
            ) begin
                if (bank_read_grant_port[bank_index][port_index]) begin
                    bank_read_addr[bank_index] = read_row[port_index];
                end

                if (bank_write_grant_port[bank_index][port_index]) begin
                    bank_write_addr[bank_index] = write_row[port_index];

                    bank_write_data[bank_index] = write_data_i[
                        (port_index * DATA_WIDTH) +: DATA_WIDTH
                    ];

                    bank_write_strb[bank_index] = write_strb_i[
                        (port_index * BYTE_COUNT) +: BYTE_COUNT
                    ];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Banks
    // -------------------------------------------------------------------------

    generate
        for (
            genvar bank_index = 0;
            bank_index < BANK_COUNT;
            bank_index = bank_index + 1
        ) begin : g_bank

            nce_scratchpad_bank_1r1w #(
                .WORDS_PER_BANK (WORDS_PER_BANK),
                .DATA_WIDTH     (DATA_WIDTH),
                .ADDR_WIDTH     (BANK_ADDR_WIDTH),
                .BYTE_COUNT     (BYTE_COUNT)
            ) u_bank (
                .clk_i          (clk_i),
                .rst_ni         (rst_ni),
                .clear_i        (clear_i),

                .read_enable_i  (bank_read_enable[bank_index]),
                .read_addr_i    (bank_read_addr[bank_index]),
                .read_data_o    (bank_read_data[bank_index]),
                .read_valid_o   (bank_read_valid[bank_index]),

                .write_enable_i (bank_write_enable[bank_index]),
                .write_addr_i   (bank_write_addr[bank_index]),
                .write_data_i   (bank_write_data[bank_index]),
                .write_strb_i   (bank_write_strb[bank_index])
            );

        end : g_bank
    endgenerate

    // -------------------------------------------------------------------------
    // Response steering
    //
    // The grant is pipelined so each bank's registered response returns to the
    // port that won it.
    // -------------------------------------------------------------------------

    logic [PORT_COUNT-1:0] bank_read_grant_port_q [BANK_COUNT-1:0];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (
                int unsigned bank_index = 0;
                bank_index < BANK_COUNT;
                bank_index = bank_index + 1
            ) begin
                bank_read_grant_port_q[bank_index] <=
                    {PORT_COUNT{1'b0}};
            end
        end
        else begin
            for (
                int unsigned bank_index = 0;
                bank_index < BANK_COUNT;
                bank_index = bank_index + 1
            ) begin
                bank_read_grant_port_q[bank_index] <=
                    bank_read_grant_port[bank_index];
            end
        end
    end

    always_comb begin
        read_valid_o = {PORT_COUNT{1'b0}};
        read_data_o  = {(PORT_COUNT * DATA_WIDTH){1'b0}};

        for (
            int unsigned bank_index = 0;
            bank_index < BANK_COUNT;
            bank_index = bank_index + 1
        ) begin
            for (
                int unsigned port_index = 0;
                port_index < PORT_COUNT;
                port_index = port_index + 1
            ) begin
                if (bank_read_grant_port_q[bank_index][port_index]) begin
                    read_valid_o[port_index] =
                        bank_read_valid[bank_index];

                    read_data_o[
                        (port_index * DATA_WIDTH) +: DATA_WIDTH
                    ] = bank_read_data[bank_index];
                end
            end
        end
    end

endmodule

`default_nettype wire
