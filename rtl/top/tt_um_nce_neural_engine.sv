// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE) - Tiny Tapeout Top Wrapper
//
// Target Platform: Tiny Tapeout (LibreLane / OpenROAD on SkyWater SKY130)
// Original RTL Architect and Digital Designer: Talha Alam
// Co-Designer: Bola Olatunji
// -----------------------------------------------------------------------------
//
// Direct-Strobed Byte Register Port Interface:
//   ui_in[7:0]:   Address byte (when uio_in[2]=1) or Data byte (when uio_in[2]=0)
//   uio_in[0]:    strobe     (1 = active pulse for register write/read)
//   uio_in[1]:    is_write   (1 = Write transaction, 0 = Read transaction)
//   uio_in[2]:    addr_load  (1 = load ui_in into 8-bit auto-increment address counter)
//   uio_in[3]:    start_exec (1 = dispatch 1-cycle compute execute pulse)
//
//   uo_out[7:0]:  Read data byte from addressed register / accumulator
//   uio_out[4]:   ready      (1 = Ready for next transaction)
//   uio_out[5]:   valid      (1 = Valid read data on uo_out)
//   uio_out[6]:   busy       (1 = Compute execution active)
//   uio_out[7]:   done       (1 = Compute execution complete pulse)
//
//   uio_oe[7:0]:  Configured as 8'b1111_0000 (Pins 0..3 Inputs, Pins 4..7 Outputs)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tt_um_nce_neural_engine (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when powered
    input  wire       clk,      // clock (50 MHz)
    input  wire       rst_n     // reset_n - low to reset
);

    // Active-low system reset combined with chip enable
    wire sys_rst_n = rst_n & ena;

    // Direct strobed control inputs
    wire strobe     = uio_in[0];
    wire is_write   = uio_in[1];
    wire addr_load  = uio_in[2];
    wire start_exec = uio_in[3];

    // Hardware ID constant ("NCE1" = 0x4E434531)
    localparam [31:0] HARDWARE_ID   = 32'h4E434531;
    localparam [31:0] CAPABILITIES  = 32'h0000000F;

    // 8-bit auto-incrementing address counter
    reg [7:0] addr_q;

    // 4-entry x 32-bit Vector Register File (R0, R1, R2, R3)
    reg [31:0] regfile_q [0:3];

    // Control & Configuration Registers
    reg [7:0] config_src_q;  // [1:0] = Src A (0..3), [3:2] = Src B (0..3)
    reg       busy_q;
    reg       done_q;
    reg       acc_valid_q;

    // Compute datapath wires
    wire [31:0] op_a = regfile_q[config_src_q[1:0]];
    wire [31:0] op_b = regfile_q[config_src_q[3:2]];
    wire [31:0] acc_int32;
    wire        acc_overflow;
    wire [31:0] acc_fp32;

    reg  mac_clr_req;
    reg  mac_en_req;

    // Instantiate Native 1-Lane INT8/INT32 MAC Compute Engine
    nce_int8_int32_mac_lane u_mac_lane (
        .clk_i        (clk),
        .rst_ni       (sys_rst_n),
        .clr_i        (mac_clr_req),
        .en_i         (mac_en_req),
        .operand_a_i  (op_a),
        .operand_b_i  (op_b),
        .accumulator_o(acc_int32),
        .overflow_o   (acc_overflow)
    );

    // Instantiate Shared Output INT32 -> FP32 Converter for Readout
    nce_int32_to_fp32 u_int32_to_fp32 (
        .int_i (acc_int32),
        .fp32_o(acc_fp32)
    );

    // Read Multiplexer across 8-bit Address Space
    reg [7:0] read_byte_data;
    always @(*) begin
        case (addr_q)
            // Hardware Version ID ("NCE1" = 0x4E434531)
            8'h00: read_byte_data = HARDWARE_ID[7:0];
            8'h01: read_byte_data = HARDWARE_ID[15:8];
            8'h02: read_byte_data = HARDWARE_ID[23:16];
            8'h03: read_byte_data = HARDWARE_ID[31:24];

            // Capabilities (0x0000000F)
            8'h04: read_byte_data = CAPABILITIES[7:0];
            8'h05: read_byte_data = CAPABILITIES[15:8];
            8'h06: read_byte_data = CAPABILITIES[23:16];
            8'h07: read_byte_data = CAPABILITIES[31:24];

            // Register R0 (32 bits = 4 bytes)
            8'h10: read_byte_data = regfile_q[0][7:0];
            8'h11: read_byte_data = regfile_q[0][15:8];
            8'h12: read_byte_data = regfile_q[0][23:16];
            8'h13: read_byte_data = regfile_q[0][31:24];

            // Register R1 (32 bits = 4 bytes)
            8'h14: read_byte_data = regfile_q[1][7:0];
            8'h15: read_byte_data = regfile_q[1][15:8];
            8'h16: read_byte_data = regfile_q[1][23:16];
            8'h17: read_byte_data = regfile_q[1][31:24];

            // Register R2 (32 bits = 4 bytes)
            8'h18: read_byte_data = regfile_q[2][7:0];
            8'h19: read_byte_data = regfile_q[2][15:8];
            8'h1A: read_byte_data = regfile_q[2][23:16];
            8'h1B: read_byte_data = regfile_q[2][31:24];

            // Register R3 (32 bits = 4 bytes)
            8'h1C: read_byte_data = regfile_q[3][7:0];
            8'h1D: read_byte_data = regfile_q[3][15:8];
            8'h1E: read_byte_data = regfile_q[3][23:16];
            8'h1F: read_byte_data = regfile_q[3][31:24];

            // INT32 Accumulator Readback (0x20..0x23)
            8'h20: read_byte_data = acc_int32[7:0];
            8'h21: read_byte_data = acc_int32[15:8];
            8'h22: read_byte_data = acc_int32[23:16];
            8'h23: read_byte_data = acc_int32[31:24];

            // FP32 Converted Accumulator Readback (0x24..0x27)
            8'h24: read_byte_data = acc_fp32[7:0];
            8'h25: read_byte_data = acc_fp32[15:8];
            8'h26: read_byte_data = acc_fp32[23:16];
            8'h27: read_byte_data = acc_fp32[31:24];

            // Status Register (0x30)
            8'h30: read_byte_data = {4'b0000, acc_overflow, acc_valid_q, done_q, busy_q};

            // Config Register (0x31)
            8'h31: read_byte_data = config_src_q;

            default: read_byte_data = 8'h00;
        endcase
    end

    // Sequential Register Write & Execution FSM
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            addr_q        <= 8'h00;
            regfile_q[0]  <= 32'h00000000;
            regfile_q[1]  <= 32'h00000000;
            regfile_q[2]  <= 32'h00000000;
            regfile_q[3]  <= 32'h00000000;
            config_src_q  <= 8'h04; // Src A = R0 (0), Src B = R1 (1)
            busy_q        <= 1'b0;
            done_q        <= 1'b0;
            acc_valid_q   <= 1'b0;
            mac_clr_req   <= 1'b0;
            mac_en_req    <= 1'b0;
        end else begin
            // Default single-cycle strobes
            mac_clr_req <= 1'b0;
            mac_en_req  <= 1'b0;
            done_q      <= 1'b0;

            // Handle Compute Start Request
            if (start_exec) begin
                busy_q      <= 1'b1;
                mac_en_req  <= 1'b1;
                acc_valid_q <= 1'b1;
                done_q      <= 1'b1;
                busy_q      <= 1'b0;
            end

            // Handle Direct Strobed Address Load or Data Transfer
            if (strobe) begin
                if (addr_load) begin
                    // Direct 8-bit Address Load
                    addr_q <= ui_in;
                end else if (is_write) begin
                    // Write byte to addressed register
                    case (addr_q)
                        8'h10: regfile_q[0][7:0]   <= ui_in;
                        8'h11: regfile_q[0][15:8]  <= ui_in;
                        8'h12: regfile_q[0][23:16] <= ui_in;
                        8'h13: regfile_q[0][31:24] <= ui_in;

                        8'h14: regfile_q[1][7:0]   <= ui_in;
                        8'h15: regfile_q[1][15:8]  <= ui_in;
                        8'h16: regfile_q[1][23:16] <= ui_in;
                        8'h17: regfile_q[1][31:24] <= ui_in;

                        8'h18: regfile_q[2][7:0]   <= ui_in;
                        8'h19: regfile_q[2][15:8]  <= ui_in;
                        8'h1A: regfile_q[2][23:16] <= ui_in;
                        8'h1B: regfile_q[2][31:24] <= ui_in;

                        8'h1C: regfile_q[3][7:0]   <= ui_in;
                        8'h1D: regfile_q[3][15:8]  <= ui_in;
                        8'h1E: regfile_q[3][23:16] <= ui_in;
                        8'h1F: regfile_q[3][31:24] <= ui_in;

                        // Control Register (0x30): Bit 0 = clear acc, Bit 1 = clear regs
                        8'h30: begin
                            if (ui_in[0]) begin
                                mac_clr_req <= 1'b1;
                                acc_valid_q <= 1'b0;
                            end
                            if (ui_in[1]) begin
                                regfile_q[0] <= 32'h00000000;
                                regfile_q[1] <= 32'h00000000;
                                regfile_q[2] <= 32'h00000000;
                                regfile_q[3] <= 32'h00000000;
                            end
                        end

                        // Config Register (0x31): [1:0] Src A, [3:2] Src B
                        8'h31: config_src_q <= ui_in;

                        default: ;
                    endcase
                    // Auto-increment address pointer on data transfer
                    addr_q <= addr_q + 1'b1;
                end else begin
                    // Read auto-increment
                    addr_q <= addr_q + 1'b1;
                end
            end
        end
    end

    // Pin Assignments
    assign uo_out       = read_byte_data;
    assign uio_out[0]   = 1'b0;
    assign uio_out[1]   = 1'b0;
    assign uio_out[2]   = 1'b0;
    assign uio_out[3]   = 1'b0;
    assign uio_out[4]   = 1'b1;         // ready (always ready for transaction)
    assign uio_out[5]   = !is_write;    // valid (active on read)
    assign uio_out[6]   = busy_q;       // busy indicator
    assign uio_out[7]   = done_q;       // done pulse

    // Bidirectional pin directions: Lower 4 inputs, Upper 4 outputs
    assign uio_oe       = 8'b1111_0000;

endmodule

`default_nettype wire
