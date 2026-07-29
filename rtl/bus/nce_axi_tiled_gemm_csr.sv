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
// AXI-backend-style CSR extension for the autonomous 8x8 tiled systolic GEMM.
//
// Address map:
//
//   0x200 TILED_CONFIG
//         bits 1:0 precision
//         bits 7:4 packed K-token count, 1..8
//
//   0x204 TILED_CONTROL
//         bit 0 start
//         bit 1 clear engine, buffers and results
//         bit 2 clear sticky done/error status
//
//   0x208 TILED_STATUS
//         bit 0     start ready
//         bit 1     busy
//         bit 2     done sticky
//         bit 3     error sticky
//         bits 6:4  error code
//         bit 8     current M tile
//         bit 9     current N tile
//         bit 10    current K tile
//         bit 11    all 64 results valid
//
//   0x20C A address
//   0x210 A data
//   0x214 B address
//   0x218 B data
//
//   0x220/0x224 A-valid low/high
//   0x228/0x22C B-valid low/high
//   0x230/0x234 result-valid low/high
//
//   0x238/0x23C invalid low/high
//   0x240/0x244 overflow low/high
//   0x248/0x24C underflow low/high
//   0x250/0x254 inexact low/high
//
//   0x300-0x3FC 64 row-major FP32 results
// -----------------------------------------------------------------------------

module nce_axi_tiled_gemm_csr (
    input  logic          clk_i,
    input  logic          rst_ni,

    input  logic          write_valid_i,
    output logic          write_ready_o,
    input  logic [31:0]   write_addr_i,
    input  logic [31:0]   write_data_i,
    input  logic [3:0]    write_strb_i,
    output logic          write_error_o,

    input  logic          read_valid_i,
    output logic          read_ready_o,
    input  logic [31:0]   read_addr_i,
    output logic [31:0]   read_data_o,
    output logic          read_error_o,

    output logic          tiled_clear_o,

    output logic          tiled_a_write_enable_o,
    output logic [5:0]    tiled_a_write_addr_o,
    output logic [31:0]   tiled_a_write_data_o,

    output logic          tiled_b_write_enable_o,
    output logic [5:0]    tiled_b_write_addr_o,
    output logic [31:0]   tiled_b_write_data_o,

    output logic          tiled_start_o,
    input  logic          tiled_start_ready_i,

    output logic [1:0]    tiled_precision_o,
    output logic [3:0]    tiled_k_token_count_o,

    input  logic          tiled_busy_i,
    input  logic          tiled_done_i,
    input  logic          tiled_error_i,
    input  logic [2:0]    tiled_error_code_i,

    input  logic          tiled_m_tile_i,
    input  logic          tiled_n_tile_i,
    input  logic          tiled_k_tile_i,

    input  logic [63:0]   tiled_a_valid_mask_i,
    input  logic [63:0]   tiled_b_valid_mask_i,

    input  logic [2047:0] tiled_accumulator_i,
    input  logic [63:0]   tiled_accumulator_valid_i,

    input  logic [63:0]   tiled_invalid_i,
    input  logic [63:0]   tiled_overflow_i,
    input  logic [63:0]   tiled_underflow_i,
    input  logic [63:0]   tiled_inexact_i
);

    localparam logic [31:0] ADDR_CONFIG          = 32'h0000_0200;
    localparam logic [31:0] ADDR_CONTROL         = 32'h0000_0204;
    localparam logic [31:0] ADDR_STATUS          = 32'h0000_0208;

    localparam logic [31:0] ADDR_A_ADDR          = 32'h0000_020C;
    localparam logic [31:0] ADDR_A_DATA          = 32'h0000_0210;
    localparam logic [31:0] ADDR_B_ADDR          = 32'h0000_0214;
    localparam logic [31:0] ADDR_B_DATA          = 32'h0000_0218;

    localparam logic [31:0] ADDR_A_VALID_LO      = 32'h0000_0220;
    localparam logic [31:0] ADDR_A_VALID_HI      = 32'h0000_0224;
    localparam logic [31:0] ADDR_B_VALID_LO      = 32'h0000_0228;
    localparam logic [31:0] ADDR_B_VALID_HI      = 32'h0000_022C;

    localparam logic [31:0] ADDR_RESULT_VALID_LO = 32'h0000_0230;
    localparam logic [31:0] ADDR_RESULT_VALID_HI = 32'h0000_0234;

    localparam logic [31:0] ADDR_INVALID_LO      = 32'h0000_0238;
    localparam logic [31:0] ADDR_INVALID_HI      = 32'h0000_023C;
    localparam logic [31:0] ADDR_OVERFLOW_LO     = 32'h0000_0240;
    localparam logic [31:0] ADDR_OVERFLOW_HI     = 32'h0000_0244;
    localparam logic [31:0] ADDR_UNDERFLOW_LO    = 32'h0000_0248;
    localparam logic [31:0] ADDR_UNDERFLOW_HI    = 32'h0000_024C;
    localparam logic [31:0] ADDR_INEXACT_LO      = 32'h0000_0250;
    localparam logic [31:0] ADDR_INEXACT_HI      = 32'h0000_0254;

    localparam logic [31:0] ADDR_RESULT_FIRST    = 32'h0000_0300;
    localparam logic [31:0] ADDR_RESULT_LAST     = 32'h0000_03FC;

    logic [1:0] precision_q;
    logic [3:0] k_token_count_q;

    logic [5:0] a_addr_q;
    logic [5:0] b_addr_q;

    logic       done_sticky_q;
    logic       error_sticky_q;
    logic [2:0] error_code_q;

    logic write_fire;
    logic full_write_strobe;
    logic valid_control_action;

    assign write_fire =
        write_valid_i &&
        write_ready_o;

    assign full_write_strobe =
        (write_strb_i == 4'b1111);

    assign valid_control_action =
        (write_data_i[2:0] == 3'b001) ||
        (write_data_i[2:0] == 3'b010) ||
        (write_data_i[2:0] == 3'b100);

    assign write_ready_o =
        rst_ni;

    assign read_ready_o =
        rst_ni;

    assign tiled_precision_o =
        precision_q;

    assign tiled_k_token_count_o =
        k_token_count_q;

    assign tiled_a_write_addr_o =
        a_addr_q;

    assign tiled_b_write_addr_o =
        b_addr_q;

    // -------------------------------------------------------------------------
    // Write validation
    // -------------------------------------------------------------------------

    always @* begin
        write_error_o = 1'b0;

        if (write_addr_i[1:0] != 2'b00) begin
            write_error_o = 1'b1;
        end
        else begin
            case (write_addr_i)
                ADDR_CONFIG,
                ADDR_A_ADDR,
                ADDR_A_DATA,
                ADDR_B_ADDR,
                ADDR_B_DATA: begin
                    write_error_o =
                        !full_write_strobe ||
                        tiled_busy_i;
                end

                ADDR_CONTROL: begin
                    if (
                        !full_write_strobe ||
                        !valid_control_action
                    ) begin
                        write_error_o = 1'b1;
                    end
                    else if (
                        write_data_i[0] &&
                        !tiled_start_ready_i
                    ) begin
                        write_error_o = 1'b1;
                    end
                end

                default: begin
                    write_error_o = 1'b1;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Configuration, write pulses and sticky status
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            precision_q     <= 2'b00;
            k_token_count_q <= 4'd8;

            a_addr_q <= 6'd0;
            b_addr_q <= 6'd0;

            tiled_clear_o <= 1'b0;

            tiled_a_write_enable_o <= 1'b0;
            tiled_a_write_data_o   <= 32'd0;

            tiled_b_write_enable_o <= 1'b0;
            tiled_b_write_data_o   <= 32'd0;

            tiled_start_o <= 1'b0;

            done_sticky_q  <= 1'b0;
            error_sticky_q <= 1'b0;
            error_code_q   <= 3'd0;
        end
        else begin
            tiled_clear_o <= 1'b0;

            tiled_a_write_enable_o <= 1'b0;
            tiled_b_write_enable_o <= 1'b0;

            tiled_start_o <= 1'b0;

            if (tiled_done_i) begin
                done_sticky_q <= 1'b1;
            end

            if (tiled_error_i) begin
                error_sticky_q <= 1'b1;
                error_code_q   <= tiled_error_code_i;
            end

            if (
                write_fire &&
                !write_error_o
            ) begin
                case (write_addr_i)
                    ADDR_CONFIG: begin
                        precision_q <=
                            write_data_i[1:0];

                        k_token_count_q <=
                            write_data_i[7:4];
                    end

                    ADDR_A_ADDR: begin
                        a_addr_q <=
                            write_data_i[5:0];
                    end

                    ADDR_A_DATA: begin
                        tiled_a_write_enable_o <= 1'b1;
                        tiled_a_write_data_o   <= write_data_i;
                    end

                    ADDR_B_ADDR: begin
                        b_addr_q <=
                            write_data_i[5:0];
                    end

                    ADDR_B_DATA: begin
                        tiled_b_write_enable_o <= 1'b1;
                        tiled_b_write_data_o   <= write_data_i;
                    end

                    ADDR_CONTROL: begin
                        if (write_data_i[0]) begin
                            tiled_start_o <= 1'b1;

                            done_sticky_q  <= 1'b0;
                            error_sticky_q <= 1'b0;
                            error_code_q   <= 3'd0;
                        end
                        else if (write_data_i[1]) begin
                            tiled_clear_o <= 1'b1;

                            done_sticky_q  <= 1'b0;
                            error_sticky_q <= 1'b0;
                            error_code_q   <= 3'd0;
                        end
                        else if (write_data_i[2]) begin
                            done_sticky_q  <= 1'b0;
                            error_sticky_q <= 1'b0;
                            error_code_q   <= 3'd0;
                        end
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read decode
    // -------------------------------------------------------------------------

    always @* begin
        read_data_o  = 32'd0;
        read_error_o = 1'b0;

        if (read_addr_i[1:0] != 2'b00) begin
            read_error_o = 1'b1;
        end
        else if (
            read_addr_i >= ADDR_RESULT_FIRST &&
            read_addr_i <= ADDR_RESULT_LAST
        ) begin
            // For 0x300-0x3FC, bits [7:2] directly encode result 0-63.
            read_data_o =
                tiled_accumulator_i[
                    {
                        read_addr_i[7:2],
                        5'b00000
                    } +: 32
                ];
        end
        else begin
            case (read_addr_i)
                ADDR_CONFIG: begin
                    read_data_o[1:0] =
                        precision_q;

                    read_data_o[7:4] =
                        k_token_count_q;
                end

                ADDR_CONTROL: begin
                    read_data_o = 32'd0;
                end

                ADDR_STATUS: begin
                    read_data_o[0] =
                        tiled_start_ready_i;

                    read_data_o[1] =
                        tiled_busy_i;

                    read_data_o[2] =
                        done_sticky_q;

                    read_data_o[3] =
                        error_sticky_q;

                    read_data_o[6:4] =
                        error_code_q;

                    read_data_o[8] =
                        tiled_m_tile_i;

                    read_data_o[9] =
                        tiled_n_tile_i;

                    read_data_o[10] =
                        tiled_k_tile_i;

                    read_data_o[11] =
                        &tiled_accumulator_valid_i;
                end

                ADDR_A_ADDR: begin
                    read_data_o[5:0] =
                        a_addr_q;
                end

                ADDR_B_ADDR: begin
                    read_data_o[5:0] =
                        b_addr_q;
                end

                ADDR_A_VALID_LO:
                    read_data_o = tiled_a_valid_mask_i[31:0];

                ADDR_A_VALID_HI:
                    read_data_o = tiled_a_valid_mask_i[63:32];

                ADDR_B_VALID_LO:
                    read_data_o = tiled_b_valid_mask_i[31:0];

                ADDR_B_VALID_HI:
                    read_data_o = tiled_b_valid_mask_i[63:32];

                ADDR_RESULT_VALID_LO:
                    read_data_o = tiled_accumulator_valid_i[31:0];

                ADDR_RESULT_VALID_HI:
                    read_data_o = tiled_accumulator_valid_i[63:32];

                ADDR_INVALID_LO:
                    read_data_o = tiled_invalid_i[31:0];

                ADDR_INVALID_HI:
                    read_data_o = tiled_invalid_i[63:32];

                ADDR_OVERFLOW_LO:
                    read_data_o = tiled_overflow_i[31:0];

                ADDR_OVERFLOW_HI:
                    read_data_o = tiled_overflow_i[63:32];

                ADDR_UNDERFLOW_LO:
                    read_data_o = tiled_underflow_i[31:0];

                ADDR_UNDERFLOW_HI:
                    read_data_o = tiled_underflow_i[63:32];

                ADDR_INEXACT_LO:
                    read_data_o = tiled_inexact_i[31:0];

                ADDR_INEXACT_HI:
                    read_data_o = tiled_inexact_i[63:32];

                default: begin
                    read_data_o  = 32'd0;
                    read_error_o = 1'b1;
                end
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic read_valid_unused;

    assign read_valid_unused =
        read_valid_i;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
