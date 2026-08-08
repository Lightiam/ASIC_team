// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
//
// RECONSTRUCTED LEAF MODULE
// -------------------------
// This module is instantiated per bank by rtl/memory/nce_banked_scratchpad.sv
// but was not present in any published branch of the repository. It has been
// reconstructed to satisfy every directed case asserted by the parent unit
// testbench tb/unit/tb_nce_banked_scratchpad.sv, including the write-first
// same-address collision, the merge-against-zero rule for partial writes to an
// invalid word, the zero-strobe no-op, and clear dominance.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Single-bank 1R1W scratchpad with byte strobes and per-word validity.
//
// Storage:
//   WORDS_PER_BANK words of DATA_WIDTH bits. Every word carries a valid bit so
//   that a partial (byte-strobed) write to a word that has never been written
//   merges against zero rather than against undefined storage.
//
// Write:
//   A write commits only when it is enabled and its byte strobe is non-zero.
//   A zero-strobe write is a no-op and does not validate the word. clear_i
//   outranks the write port entirely.
//
// Read:
//   The read port is registered: read_data_o and read_valid_o present the
//   result one clock after the address is applied. An unenabled or invalid read
//   returns zero with read_valid_o deasserted.
//
// Collision:
//   A read and a write to the same address in the same cycle are resolved
//   write-first: the read returns the post-merge value, which is also what the
//   storage holds afterwards.
//
// clear_i:
//   Invalidates every word in a single cycle. The storage itself is not erased,
//   which is unobservable: reads are gated by the valid bits, and the next write
//   to a word merges against zero because that word reads back as invalid.
// -----------------------------------------------------------------------------

module nce_scratchpad_bank_1r1w #(
    parameter int unsigned WORDS_PER_BANK = 256,
    parameter int unsigned DATA_WIDTH     = 32,

    parameter int unsigned ADDR_WIDTH =
        (WORDS_PER_BANK <= 1)
        ? 1
        : $clog2(WORDS_PER_BANK),

    parameter int unsigned BYTE_COUNT =
        DATA_WIDTH / 8
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  clear_i,

    // Read port (registered)
    input  logic                  read_enable_i,
    input  logic [ADDR_WIDTH-1:0] read_addr_i,
    output logic [DATA_WIDTH-1:0] read_data_o,
    output logic                  read_valid_o,

    // Write port
    input  logic                  write_enable_i,
    input  logic [ADDR_WIDTH-1:0] write_addr_i,
    input  logic [DATA_WIDTH-1:0] write_data_i,
    input  logic [BYTE_COUNT-1:0] write_strb_i
);

    localparam int unsigned BYTE_WIDTH = 8;

    logic [DATA_WIDTH-1:0]     memory_q [WORDS_PER_BANK-1:0];
    logic [WORDS_PER_BANK-1:0] valid_q;

    logic write_commit;

    logic [DATA_WIDTH-1:0] write_old_data;
    logic [DATA_WIDTH-1:0] write_merged_data;

    logic read_write_collision;
    logic read_word_valid;
    logic read_hit;

    // A zero-strobe write is not a write, and clear outranks it entirely.
    assign write_commit =
        !clear_i &&
        write_enable_i &&
        (write_strb_i != {BYTE_COUNT{1'b0}});

    // A partial write to a word that has never been written must merge against
    // zero, never against whatever the storage happens to hold.
    assign write_old_data =
        valid_q[write_addr_i]
        ? memory_q[write_addr_i]
        : {DATA_WIDTH{1'b0}};

    always_comb begin
        write_merged_data = write_old_data;

        for (
            int unsigned byte_index = 0;
            byte_index < BYTE_COUNT;
            byte_index = byte_index + 1
        ) begin
            if (write_strb_i[byte_index]) begin
                write_merged_data[
                    (byte_index * BYTE_WIDTH) +: BYTE_WIDTH
                ] = write_data_i[
                    (byte_index * BYTE_WIDTH) +: BYTE_WIDTH
                ];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read path
    //
    // Resolved write-first: a same-address collision reads the merged result.
    // -------------------------------------------------------------------------

    assign read_write_collision =
        write_commit &&
        (read_addr_i == write_addr_i);

    assign read_word_valid =
        !clear_i &&
        (valid_q[read_addr_i] || read_write_collision);

    assign read_hit =
        read_enable_i &&
        read_word_valid;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_data_o  <= {DATA_WIDTH{1'b0}};
            read_valid_o <= 1'b0;
        end
        else begin
            read_valid_o <= read_hit;

            read_data_o <=
                !read_hit
                ? {DATA_WIDTH{1'b0}}
                : read_write_collision
                  ? write_merged_data
                  : memory_q[read_addr_i];
        end
    end

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_q <= {WORDS_PER_BANK{1'b0}};
        end
        else if (clear_i) begin
            valid_q <= {WORDS_PER_BANK{1'b0}};
        end
        else if (write_commit) begin
            valid_q[write_addr_i] <= 1'b1;
        end
    end

    always_ff @(posedge clk_i) begin
        if (write_commit) begin
            memory_q[write_addr_i] <= write_merged_data;
        end
    end

endmodule

`default_nettype wire
