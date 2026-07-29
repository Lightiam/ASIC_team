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
// AXI-backend-style CSR extension for the autonomous native 4x4 systolic GEMM.
//
// This module does not implement AXI protocol channels directly. It accepts
// the same single-request backend interface used behind nce_axi4lite_frontend.
//
// GEMM start errors caused by invalid precision, K, or missing tile entries are
// reported asynchronously through GEMM_STATUS after the accepted start write.
// -----------------------------------------------------------------------------

module nce_axi_systolic_gemm_csr (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         write_valid_i,
    output logic         write_ready_o,
    input  logic [31:0]  write_addr_i,
    input  logic [31:0]  write_data_i,
    input  logic [3:0]   write_strb_i,
    output logic         write_error_o,

    input  logic         read_valid_i,
    output logic         read_ready_o,
    input  logic [31:0]  read_addr_i,
    output logic [31:0]  read_data_o,
    output logic         read_error_o,

    // GEMM tile/configuration interface
    output logic         gemm_clear_o,

    output logic         gemm_a_write_enable_o,
    output logic [3:0]   gemm_a_write_addr_o,
    output logic [31:0]  gemm_a_write_data_o,

    output logic         gemm_b_write_enable_o,
    output logic [3:0]   gemm_b_write_addr_o,
    output logic [31:0]  gemm_b_write_data_o,

    output logic         gemm_start_o,
    input  logic         gemm_start_ready_i,

    output logic [1:0]   gemm_precision_o,
    output logic [2:0]   gemm_k_count_o,
    output logic         gemm_accumulate_o,

    // GEMM execution status
    input  logic         gemm_busy_i,
    input  logic         gemm_done_i,
    input  logic         gemm_error_i,
    input  logic [2:0]   gemm_error_code_i,

    input  logic [3:0]   gemm_wavefront_cycle_i,

    input  logic [15:0]  gemm_a_valid_mask_i,
    input  logic [15:0]  gemm_b_valid_mask_i,

    input  logic [511:0] gemm_accumulator_i,
    input  logic [15:0]  gemm_accumulator_valid_i,
    input  logic [15:0]  gemm_accumulator_update_i,

    input  logic [15:0]  gemm_mac_fire_mask_i,

    input  logic [15:0]  gemm_invalid_i,
    input  logic [15:0]  gemm_overflow_i,
    input  logic [15:0]  gemm_underflow_i,
    input  logic [15:0]  gemm_inexact_i
);

    localparam logic [31:0] ADDR_GEMM_CONFIG       = 32'h0000_0140;
    localparam logic [31:0] ADDR_GEMM_CONTROL      = 32'h0000_0144;
    localparam logic [31:0] ADDR_GEMM_STATUS       = 32'h0000_0148;

    localparam logic [31:0] ADDR_GEMM_A_ADDR       = 32'h0000_014C;
    localparam logic [31:0] ADDR_GEMM_A_DATA       = 32'h0000_0150;
    localparam logic [31:0] ADDR_GEMM_B_ADDR       = 32'h0000_0154;
    localparam logic [31:0] ADDR_GEMM_B_DATA       = 32'h0000_0158;

    localparam logic [31:0] ADDR_GEMM_A_VALID      = 32'h0000_015C;
    localparam logic [31:0] ADDR_GEMM_B_VALID      = 32'h0000_0160;

    localparam logic [31:0] ADDR_GEMM_RESULT0      = 32'h0000_0180;
    localparam logic [31:0] ADDR_GEMM_RESULT1      = 32'h0000_0184;
    localparam logic [31:0] ADDR_GEMM_RESULT2      = 32'h0000_0188;
    localparam logic [31:0] ADDR_GEMM_RESULT3      = 32'h0000_018C;
    localparam logic [31:0] ADDR_GEMM_RESULT4      = 32'h0000_0190;
    localparam logic [31:0] ADDR_GEMM_RESULT5      = 32'h0000_0194;
    localparam logic [31:0] ADDR_GEMM_RESULT6      = 32'h0000_0198;
    localparam logic [31:0] ADDR_GEMM_RESULT7      = 32'h0000_019C;
    localparam logic [31:0] ADDR_GEMM_RESULT8      = 32'h0000_01A0;
    localparam logic [31:0] ADDR_GEMM_RESULT9      = 32'h0000_01A4;
    localparam logic [31:0] ADDR_GEMM_RESULT10     = 32'h0000_01A8;
    localparam logic [31:0] ADDR_GEMM_RESULT11     = 32'h0000_01AC;
    localparam logic [31:0] ADDR_GEMM_RESULT12     = 32'h0000_01B0;
    localparam logic [31:0] ADDR_GEMM_RESULT13     = 32'h0000_01B4;
    localparam logic [31:0] ADDR_GEMM_RESULT14     = 32'h0000_01B8;
    localparam logic [31:0] ADDR_GEMM_RESULT15     = 32'h0000_01BC;

    localparam logic [31:0] ADDR_GEMM_RESULT_VALID = 32'h0000_01C0;
    localparam logic [31:0] ADDR_GEMM_MAC_FIRE     = 32'h0000_01C4;
    localparam logic [31:0] ADDR_GEMM_INVALID      = 32'h0000_01C8;
    localparam logic [31:0] ADDR_GEMM_OVERFLOW     = 32'h0000_01CC;
    localparam logic [31:0] ADDR_GEMM_UNDERFLOW    = 32'h0000_01D0;
    localparam logic [31:0] ADDR_GEMM_INEXACT      = 32'h0000_01D4;

    logic [1:0] precision_q;
    logic [2:0] k_count_q;
    logic       accumulate_q;

    logic [3:0] a_addr_q;
    logic [3:0] b_addr_q;

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

    assign gemm_precision_o =
        precision_q;

    assign gemm_k_count_o =
        k_count_q;

    assign gemm_accumulate_o =
        accumulate_q;

    assign gemm_a_write_addr_o =
        a_addr_q;

    assign gemm_b_write_addr_o =
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
                ADDR_GEMM_CONFIG,
                ADDR_GEMM_A_ADDR,
                ADDR_GEMM_A_DATA,
                ADDR_GEMM_B_ADDR,
                ADDR_GEMM_B_DATA: begin
                    write_error_o =
                        !full_write_strobe ||
                        gemm_busy_i;
                end

                ADDR_GEMM_CONTROL: begin
                    if (
                        !full_write_strobe ||
                        !valid_control_action
                    ) begin
                        write_error_o = 1'b1;
                    end
                    else if (
                        write_data_i[0] &&
                        !gemm_start_ready_i
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
    // Configuration, tile writes and sticky status
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            precision_q  <= 2'b00;
            k_count_q    <= 3'd4;
            accumulate_q <= 1'b0;

            a_addr_q <= 4'd0;
            b_addr_q <= 4'd0;

            gemm_clear_o <= 1'b0;

            gemm_a_write_enable_o <= 1'b0;
            gemm_a_write_data_o   <= 32'd0;

            gemm_b_write_enable_o <= 1'b0;
            gemm_b_write_data_o   <= 32'd0;

            gemm_start_o <= 1'b0;

            done_sticky_q  <= 1'b0;
            error_sticky_q <= 1'b0;
            error_code_q   <= 3'd0;
        end
        else begin
            gemm_clear_o <= 1'b0;

            gemm_a_write_enable_o <= 1'b0;
            gemm_b_write_enable_o <= 1'b0;

            gemm_start_o <= 1'b0;

            if (gemm_done_i) begin
                done_sticky_q <= 1'b1;
            end

            if (gemm_error_i) begin
                error_sticky_q <= 1'b1;
                error_code_q   <= gemm_error_code_i;
            end

            if (
                write_fire &&
                !write_error_o
            ) begin
                case (write_addr_i)
                    ADDR_GEMM_CONFIG: begin
                        precision_q <=
                            write_data_i[1:0];

                        k_count_q <=
                            write_data_i[6:4];

                        accumulate_q <=
                            write_data_i[8];
                    end

                    ADDR_GEMM_A_ADDR: begin
                        a_addr_q <=
                            write_data_i[3:0];
                    end

                    ADDR_GEMM_A_DATA: begin
                        gemm_a_write_enable_o <= 1'b1;
                        gemm_a_write_data_o   <= write_data_i;
                    end

                    ADDR_GEMM_B_ADDR: begin
                        b_addr_q <=
                            write_data_i[3:0];
                    end

                    ADDR_GEMM_B_DATA: begin
                        gemm_b_write_enable_o <= 1'b1;
                        gemm_b_write_data_o   <= write_data_i;
                    end

                    ADDR_GEMM_CONTROL: begin
                        if (write_data_i[0]) begin
                            gemm_start_o <= 1'b1;

                            done_sticky_q  <= 1'b0;
                            error_sticky_q <= 1'b0;
                            error_code_q   <= 3'd0;
                        end
                        else if (write_data_i[1]) begin
                            gemm_clear_o <= 1'b1;

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
    // Read path
    // -------------------------------------------------------------------------

    always @* begin
        read_data_o  = 32'd0;
        read_error_o = 1'b0;

        if (read_addr_i[1:0] != 2'b00) begin
            read_error_o = 1'b1;
        end
        else begin
            case (read_addr_i)
                ADDR_GEMM_CONFIG: begin
                    read_data_o[1:0] =
                        precision_q;

                    read_data_o[6:4] =
                        k_count_q;

                    read_data_o[8] =
                        accumulate_q;
                end

                ADDR_GEMM_CONTROL: begin
                    read_data_o = 32'd0;
                end

                ADDR_GEMM_STATUS: begin
                    read_data_o[0] =
                        gemm_start_ready_i;

                    read_data_o[1] =
                        gemm_busy_i;

                    read_data_o[2] =
                        done_sticky_q;

                    read_data_o[3] =
                        error_sticky_q;

                    read_data_o[6:4] =
                        error_code_q;

                    read_data_o[11:8] =
                        gemm_wavefront_cycle_i;

                    read_data_o[12] =
                        |gemm_accumulator_update_i;

                    read_data_o[13] =
                        &gemm_accumulator_valid_i;
                end

                ADDR_GEMM_A_ADDR: begin
                    read_data_o[3:0] =
                        a_addr_q;
                end

                ADDR_GEMM_B_ADDR: begin
                    read_data_o[3:0] =
                        b_addr_q;
                end

                ADDR_GEMM_A_VALID: begin
                    read_data_o[15:0] =
                        gemm_a_valid_mask_i;
                end

                ADDR_GEMM_B_VALID: begin
                    read_data_o[15:0] =
                        gemm_b_valid_mask_i;
                end

                ADDR_GEMM_RESULT0:
                    read_data_o = gemm_accumulator_i[31:0];

                ADDR_GEMM_RESULT1:
                    read_data_o = gemm_accumulator_i[63:32];

                ADDR_GEMM_RESULT2:
                    read_data_o = gemm_accumulator_i[95:64];

                ADDR_GEMM_RESULT3:
                    read_data_o = gemm_accumulator_i[127:96];

                ADDR_GEMM_RESULT4:
                    read_data_o = gemm_accumulator_i[159:128];

                ADDR_GEMM_RESULT5:
                    read_data_o = gemm_accumulator_i[191:160];

                ADDR_GEMM_RESULT6:
                    read_data_o = gemm_accumulator_i[223:192];

                ADDR_GEMM_RESULT7:
                    read_data_o = gemm_accumulator_i[255:224];

                ADDR_GEMM_RESULT8:
                    read_data_o = gemm_accumulator_i[287:256];

                ADDR_GEMM_RESULT9:
                    read_data_o = gemm_accumulator_i[319:288];

                ADDR_GEMM_RESULT10:
                    read_data_o = gemm_accumulator_i[351:320];

                ADDR_GEMM_RESULT11:
                    read_data_o = gemm_accumulator_i[383:352];

                ADDR_GEMM_RESULT12:
                    read_data_o = gemm_accumulator_i[415:384];

                ADDR_GEMM_RESULT13:
                    read_data_o = gemm_accumulator_i[447:416];

                ADDR_GEMM_RESULT14:
                    read_data_o = gemm_accumulator_i[479:448];

                ADDR_GEMM_RESULT15:
                    read_data_o = gemm_accumulator_i[511:480];

                ADDR_GEMM_RESULT_VALID: begin
                    read_data_o[15:0] =
                        gemm_accumulator_valid_i;
                end

                ADDR_GEMM_MAC_FIRE: begin
                    read_data_o[15:0] =
                        gemm_mac_fire_mask_i;
                end

                ADDR_GEMM_INVALID: begin
                    read_data_o[15:0] =
                        gemm_invalid_i;
                end

                ADDR_GEMM_OVERFLOW: begin
                    read_data_o[15:0] =
                        gemm_overflow_i;
                end

                ADDR_GEMM_UNDERFLOW: begin
                    read_data_o[15:0] =
                        gemm_underflow_i;
                end

                ADDR_GEMM_INEXACT: begin
                    read_data_o[15:0] =
                        gemm_inexact_i;
                end

                default: begin
                    read_data_o  = 32'd0;
                    read_error_o = 1'b1;
                end
            endcase
        end
    end

    // read_valid_i is consumed by the frontend handshake and does not alter
    // combinational register selection.
    /* verilator lint_off UNUSEDSIGNAL */
    logic read_valid_unused;

    assign read_valid_unused =
        read_valid_i;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
