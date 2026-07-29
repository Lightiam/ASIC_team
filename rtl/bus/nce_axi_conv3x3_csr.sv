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
// AXI-backend-style CSR extension for the fixed reference convolution engine.
//
// Address map:
//
//   0x400 CONV_CONTROL
//         bit 0 start
//         bit 1 clear convolution buffers, results, and sticky status
//         bit 2 clear sticky done/error status only
//
//   0x404 CONV_STATUS
//         bit 0     start ready
//         bit 1     busy
//         bit 2     done sticky
//         bit 3     error sticky
//         bits 6:4  error code
//         bit 8     all 16 input pixels valid
//         bit 9     all 9 kernel values valid
//         bit 10    all 4 output results valid
//
//   0x408 PIXEL_ADDRESS
//   0x40C PIXEL_DATA
//   0x410 KERNEL_ADDRESS
//   0x414 KERNEL_DATA
//
//   0x418 PIXEL_VALID_MASK
//   0x41C KERNEL_VALID_MASK
//   0x420 RESULT_VALID_MASK
//   0x424 ARITHMETIC_FLAGS
//         bits 3:0    invalid
//         bits 7:4    overflow
//         bits 11:8   underflow
//         bits 15:12  inexact
//
//   0x440 RESULT_0
//   0x444 RESULT_1
//   0x448 RESULT_2
//   0x44C RESULT_3
// -----------------------------------------------------------------------------

module nce_axi_conv3x3_csr (
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

    output logic         conv_clear_o,

    output logic         pixel_write_enable_o,
    output logic [3:0]   pixel_write_addr_o,
    output logic [7:0]   pixel_write_data_o,

    output logic         kernel_write_enable_o,
    output logic [3:0]   kernel_write_addr_o,
    output logic [7:0]   kernel_write_data_o,

    output logic         conv_start_o,
    input  logic         conv_start_ready_i,

    input  logic         conv_busy_i,
    input  logic         conv_done_i,
    input  logic         conv_error_i,
    input  logic [2:0]   conv_error_code_i,

    input  logic [15:0]  pixel_valid_mask_i,
    input  logic [8:0]   kernel_valid_mask_i,

    input  logic [127:0] result_i,
    input  logic [3:0]   result_valid_i,

    input  logic [3:0]   invalid_i,
    input  logic [3:0]   overflow_i,
    input  logic [3:0]   underflow_i,
    input  logic [3:0]   inexact_i
);

    localparam logic [31:0] ADDR_CONTROL      = 32'h0000_0400;
    localparam logic [31:0] ADDR_STATUS       = 32'h0000_0404;

    localparam logic [31:0] ADDR_PIXEL_ADDR   = 32'h0000_0408;
    localparam logic [31:0] ADDR_PIXEL_DATA   = 32'h0000_040C;
    localparam logic [31:0] ADDR_KERNEL_ADDR  = 32'h0000_0410;
    localparam logic [31:0] ADDR_KERNEL_DATA  = 32'h0000_0414;

    localparam logic [31:0] ADDR_PIXEL_VALID  = 32'h0000_0418;
    localparam logic [31:0] ADDR_KERNEL_VALID = 32'h0000_041C;
    localparam logic [31:0] ADDR_RESULT_VALID = 32'h0000_0420;
    localparam logic [31:0] ADDR_FLAGS        = 32'h0000_0424;

    localparam logic [31:0] ADDR_RESULT_0     = 32'h0000_0440;
    localparam logic [31:0] ADDR_RESULT_1     = 32'h0000_0444;
    localparam logic [31:0] ADDR_RESULT_2     = 32'h0000_0448;
    localparam logic [31:0] ADDR_RESULT_3     = 32'h0000_044C;

    logic [3:0] pixel_addr_q;
    logic [3:0] kernel_addr_q;

    logic       done_sticky_q;
    logic       error_sticky_q;
    logic [2:0] error_code_q;

    logic write_fire;
    logic full_write_strobe;
    logic valid_control_action;

    assign write_ready_o =
        rst_ni;

    assign read_ready_o =
        rst_ni;

    assign write_fire =
        write_valid_i &&
        write_ready_o;

    assign full_write_strobe =
        (write_strb_i == 4'b1111);

    assign valid_control_action =
        (write_data_i[31:3] == 29'd0) &&
        (
            (write_data_i[2:0] == 3'b001) ||
            (write_data_i[2:0] == 3'b010) ||
            (write_data_i[2:0] == 3'b100)
        );

    assign pixel_write_addr_o =
        pixel_addr_q;

    assign kernel_write_addr_o =
        kernel_addr_q;

    // -------------------------------------------------------------------------
    // Write validation
    // -------------------------------------------------------------------------

    always @* begin
        write_error_o = 1'b0;

        if (write_addr_i[1:0] != 2'b00) begin
            write_error_o = 1'b1;
        end
        else if (!full_write_strobe) begin
            write_error_o = 1'b1;
        end
        else begin
            case (write_addr_i)
                ADDR_CONTROL: begin
                    if (!valid_control_action) begin
                        write_error_o = 1'b1;
                    end
                    else if (
                        write_data_i[0] &&
                        !conv_start_ready_i
                    ) begin
                        write_error_o = 1'b1;
                    end
                end

                ADDR_PIXEL_ADDR: begin
                    if (
                        conv_busy_i ||
                        write_data_i[31:4] != 28'd0
                    ) begin
                        write_error_o = 1'b1;
                    end
                end

                ADDR_PIXEL_DATA: begin
                    if (conv_busy_i) begin
                        write_error_o = 1'b1;
                    end
                end

                ADDR_KERNEL_ADDR: begin
                    if (
                        conv_busy_i ||
                        write_data_i > 32'd8
                    ) begin
                        write_error_o = 1'b1;
                    end
                end

                ADDR_KERNEL_DATA: begin
                    if (
                        conv_busy_i ||
                        kernel_addr_q > 4'd8
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
    // CSR state and command pulses
    // -------------------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pixel_addr_q  <= 4'd0;
            kernel_addr_q <= 4'd0;

            done_sticky_q  <= 1'b0;
            error_sticky_q <= 1'b0;
            error_code_q   <= 3'd0;

            conv_clear_o <= 1'b0;
            conv_start_o <= 1'b0;

            pixel_write_enable_o <= 1'b0;
            pixel_write_data_o   <= 8'd0;

            kernel_write_enable_o <= 1'b0;
            kernel_write_data_o   <= 8'd0;
        end
        else begin
            conv_clear_o <= 1'b0;
            conv_start_o <= 1'b0;

            pixel_write_enable_o  <= 1'b0;
            kernel_write_enable_o <= 1'b0;

            if (conv_done_i) begin
                done_sticky_q <= 1'b1;
            end

            if (conv_error_i) begin
                error_sticky_q <= 1'b1;
                error_code_q   <= conv_error_code_i;
            end

            if (
                write_fire &&
                !write_error_o
            ) begin
                case (write_addr_i)
                    ADDR_CONTROL: begin
                        case (write_data_i[2:0])
                            3'b001: begin
                                conv_start_o <= 1'b1;
                            end

                            3'b010: begin
                                conv_clear_o <= 1'b1;

                                done_sticky_q  <= 1'b0;
                                error_sticky_q <= 1'b0;
                                error_code_q   <= 3'd0;
                            end

                            3'b100: begin
                                done_sticky_q  <= 1'b0;
                                error_sticky_q <= 1'b0;
                                error_code_q   <= 3'd0;
                            end

                            default: begin
                            end
                        endcase
                    end

                    ADDR_PIXEL_ADDR: begin
                        pixel_addr_q <=
                            write_data_i[3:0];
                    end

                    ADDR_PIXEL_DATA: begin
                        pixel_write_enable_o <= 1'b1;
                        pixel_write_data_o   <=
                            write_data_i[7:0];
                    end

                    ADDR_KERNEL_ADDR: begin
                        kernel_addr_q <=
                            write_data_i[3:0];
                    end

                    ADDR_KERNEL_DATA: begin
                        kernel_write_enable_o <= 1'b1;
                        kernel_write_data_o   <=
                            write_data_i[7:0];
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Readback
    // -------------------------------------------------------------------------

    always @* begin
        read_data_o  = 32'd0;
        read_error_o = 1'b0;

        if (
            read_valid_i &&
            read_addr_i[1:0] != 2'b00
        ) begin
            read_error_o = 1'b1;
        end
        else if (read_valid_i) begin
            case (read_addr_i)
                ADDR_CONTROL: begin
                    read_data_o = 32'd0;
                end

                ADDR_STATUS: begin
                    read_data_o[0]   = conv_start_ready_i;
                    read_data_o[1]   = conv_busy_i;
                    read_data_o[2]   = done_sticky_q;
                    read_data_o[3]   = error_sticky_q;
                    read_data_o[6:4] = error_code_q;
                    read_data_o[8]   = &pixel_valid_mask_i;
                    read_data_o[9]   = &kernel_valid_mask_i;
                    read_data_o[10]  = &result_valid_i;
                end

                ADDR_PIXEL_ADDR: begin
                    read_data_o = {
                        28'd0,
                        pixel_addr_q
                    };
                end

                ADDR_KERNEL_ADDR: begin
                    read_data_o = {
                        28'd0,
                        kernel_addr_q
                    };
                end

                ADDR_PIXEL_VALID: begin
                    read_data_o = {
                        16'd0,
                        pixel_valid_mask_i
                    };
                end

                ADDR_KERNEL_VALID: begin
                    read_data_o = {
                        23'd0,
                        kernel_valid_mask_i
                    };
                end

                ADDR_RESULT_VALID: begin
                    read_data_o = {
                        28'd0,
                        result_valid_i
                    };
                end

                ADDR_FLAGS: begin
                    read_data_o = {
                        16'd0,
                        inexact_i,
                        underflow_i,
                        overflow_i,
                        invalid_i
                    };
                end

                ADDR_RESULT_0: begin
                    read_data_o = result_i[31:0];
                end

                ADDR_RESULT_1: begin
                    read_data_o = result_i[63:32];
                end

                ADDR_RESULT_2: begin
                    read_data_o = result_i[95:64];
                end

                ADDR_RESULT_3: begin
                    read_data_o = result_i[127:96];
                end

                default: begin
                    read_error_o = 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
