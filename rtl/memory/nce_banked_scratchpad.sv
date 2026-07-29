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
// Parameterized multi-bank tensor scratchpad.
//
// Default configuration:
//
//   4 banks × 256 words/bank × 32 bits/word = 4096 bytes
//
// Each packed interface lane corresponds to one independent physical bank.
// Addresses are local row addresses; flat tensor-address interleaving will be
// implemented by a separate adapter.
// -----------------------------------------------------------------------------

module nce_banked_scratchpad #(
    parameter int unsigned BANK_COUNT = 4,
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH = 32,

    parameter int unsigned BANK_ADDR_WIDTH =
        (WORDS_PER_BANK <= 1)
        ? 1
        : $clog2(WORDS_PER_BANK),

    parameter int unsigned BYTE_COUNT =
        DATA_WIDTH / 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    input  logic [BANK_COUNT-1:0] read_enable_i,

    input  logic [
        (BANK_COUNT * BANK_ADDR_WIDTH)-1:0
    ] read_addr_i,

    output logic [
        (BANK_COUNT * DATA_WIDTH)-1:0
    ] read_data_o,

    output logic [BANK_COUNT-1:0] read_valid_o,

    input  logic [BANK_COUNT-1:0] write_enable_i,

    input  logic [
        (BANK_COUNT * BANK_ADDR_WIDTH)-1:0
    ] write_addr_i,

    input  logic [
        (BANK_COUNT * DATA_WIDTH)-1:0
    ] write_data_i,

    input  logic [
        (BANK_COUNT * BYTE_COUNT)-1:0
    ] write_strb_i
);

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

                .read_enable_i  (
                    read_enable_i[bank_index]
                ),
                .read_addr_i    (
                    read_addr_i[
                        (bank_index * BANK_ADDR_WIDTH) +:
                        BANK_ADDR_WIDTH
                    ]
                ),
                .read_data_o    (
                    read_data_o[
                        (bank_index * DATA_WIDTH) +:
                        DATA_WIDTH
                    ]
                ),
                .read_valid_o   (
                    read_valid_o[bank_index]
                ),

                .write_enable_i (
                    write_enable_i[bank_index]
                ),
                .write_addr_i   (
                    write_addr_i[
                        (bank_index * BANK_ADDR_WIDTH) +:
                        BANK_ADDR_WIDTH
                    ]
                ),
                .write_data_i   (
                    write_data_i[
                        (bank_index * DATA_WIDTH) +:
                        DATA_WIDTH
                    ]
                ),
                .write_strb_i   (
                    write_strb_i[
                        (bank_index * BYTE_COUNT) +:
                        BYTE_COUNT
                    ]
                )
            );

        end
    endgenerate

endmodule

`default_nettype wire
