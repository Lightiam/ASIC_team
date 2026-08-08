// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
//
// RECONSTRUCTED LEAF MODULE
// -------------------------
// This module is instantiated twice by rtl/memory/nce_register_banks.sv but was
// not present in any published branch of the repository. It has been
// reconstructed to match the reference model in
// scripts/gen_regfile_16x256_vectors.py, which the unit testbench
// tb/unit/tb_nce_regfile_16x256.sv replays over 10 directed and 50000 random
// cycles, checking outputs both before and after each clock edge.
//
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// 16-entry x 256-bit register file, two combinational read ports, one
// lane-maskable write port.
//
// Each 256-bit register is addressed as eight 32-bit lanes. A write updates
// only the lanes selected by write_lane_enable_i; unselected lanes retain their
// previous contents.
//
// Validity tracking:
//   Each register carries a valid bit. A register reads back as zero with
//   read_valid deasserted until it has been written. The first write to an
//   invalid register merges against zero rather than against stale contents, so
//   a lane-masked first write leaves the unwritten lanes at zero.
//
//   clear_i invalidates every register in a single cycle. It does not need to
//   erase the storage: reads are gated by the valid bits, and the next write to
//   a register merges against zero because that register reads as invalid.
//
// Timing:
//   Both read ports are combinational and bypass the write port, so a read of
//   the register being written in the same cycle returns the merged result.
//   valid_mask_o likewise reflects the write taking place this cycle. The
//   outputs are therefore identical immediately before and immediately after
//   the clock edge that commits the write, provided the inputs are held.
//
// Priority:
//   clear_i outranks write_enable_i. A write with an all-zero lane mask is not
//   a write: it commits nothing and does not set the valid bit.
// -----------------------------------------------------------------------------

module nce_regfile_16x256 #(
    parameter int unsigned REGISTER_COUNT = 16,
    parameter int unsigned LANE_COUNT     = 8,
    parameter int unsigned LANE_WIDTH     = 32,

    parameter int unsigned REGISTER_WIDTH =
        LANE_COUNT * LANE_WIDTH,

    parameter int unsigned ADDR_WIDTH =
        (REGISTER_COUNT <= 1)
        ? 1
        : $clog2(REGISTER_COUNT)
) (
    input  logic                      clk_i,
    input  logic                      rst_ni,
    input  logic                      clear_i,

    // Read port A
    input  logic [ADDR_WIDTH-1:0]     read_addr_a_i,
    output logic [REGISTER_WIDTH-1:0] read_data_a_o,
    output logic                      read_valid_a_o,

    // Read port B
    input  logic [ADDR_WIDTH-1:0]     read_addr_b_i,
    output logic [REGISTER_WIDTH-1:0] read_data_b_o,
    output logic                      read_valid_b_o,

    // Write port
    input  logic                      write_enable_i,
    input  logic [ADDR_WIDTH-1:0]     write_addr_i,
    input  logic [LANE_COUNT-1:0]     write_lane_enable_i,
    input  logic [REGISTER_WIDTH-1:0] write_data_i,

    output logic [REGISTER_COUNT-1:0] valid_mask_o
);

    logic [REGISTER_WIDTH-1:0] registers_q [REGISTER_COUNT-1:0];
    logic [REGISTER_COUNT-1:0] valid_q;

    logic write_commit;

    logic [REGISTER_WIDTH-1:0] write_old_data;
    logic [REGISTER_WIDTH-1:0] write_merged_data;

    logic [REGISTER_COUNT-1:0] effective_valid;

    // A masked-off write is not a write, and clear outranks it entirely.
    assign write_commit =
        !clear_i &&
        write_enable_i &&
        (write_lane_enable_i != {LANE_COUNT{1'b0}});

    // The first write to an invalid register merges against zero so that stale
    // storage can never re-emerge through the unwritten lanes.
    assign write_old_data =
        valid_q[write_addr_i]
        ? registers_q[write_addr_i]
        : {REGISTER_WIDTH{1'b0}};

    // Lane-wise merge of the incoming data over the current contents.
    always_comb begin
        write_merged_data = write_old_data;

        for (
            int unsigned lane_index = 0;
            lane_index < LANE_COUNT;
            lane_index = lane_index + 1
        ) begin
            if (write_lane_enable_i[lane_index]) begin
                write_merged_data[
                    (lane_index * LANE_WIDTH) +: LANE_WIDTH
                ] = write_data_i[
                    (lane_index * LANE_WIDTH) +: LANE_WIDTH
                ];
            end
        end
    end

    // Validity as observed this cycle, including the write in flight.
    always_comb begin
        if (clear_i) begin
            effective_valid = {REGISTER_COUNT{1'b0}};
        end
        else begin
            effective_valid = valid_q;

            if (write_commit) begin
                effective_valid[write_addr_i] = 1'b1;
            end
        end
    end

    assign valid_mask_o = effective_valid;

    // -------------------------------------------------------------------------
    // Read ports (combinational, write-bypassing)
    // -------------------------------------------------------------------------

    logic bypass_a;
    logic bypass_b;

    assign bypass_a =
        write_commit &&
        (read_addr_a_i == write_addr_i);

    assign bypass_b =
        write_commit &&
        (read_addr_b_i == write_addr_i);

    assign read_valid_a_o = effective_valid[read_addr_a_i];
    assign read_valid_b_o = effective_valid[read_addr_b_i];

    assign read_data_a_o =
        !read_valid_a_o
        ? {REGISTER_WIDTH{1'b0}}
        : bypass_a
          ? write_merged_data
          : registers_q[read_addr_a_i];

    assign read_data_b_o =
        !read_valid_b_o
        ? {REGISTER_WIDTH{1'b0}}
        : bypass_b
          ? write_merged_data
          : registers_q[read_addr_b_i];

    // -------------------------------------------------------------------------
    // Sequential state
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_q <= {REGISTER_COUNT{1'b0}};

            for (
                int unsigned register_index = 0;
                register_index < REGISTER_COUNT;
                register_index = register_index + 1
            ) begin
                registers_q[register_index] <=
                    {REGISTER_WIDTH{1'b0}};
            end
        end
        else if (clear_i) begin
            valid_q <= {REGISTER_COUNT{1'b0}};
        end
        else if (write_commit) begin
            registers_q[write_addr_i] <= write_merged_data;
            valid_q[write_addr_i]     <= 1'b1;
        end
    end

endmodule

`default_nettype wire
