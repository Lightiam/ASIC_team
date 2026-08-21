// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// Co-Designer: Bola Olatunji
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// Signed 32-bit integer to IEEE-754 binary32 converter for shared readout.
module nce_int32_to_fp32 (
    input  wire        [31:0] int_i,
    output wire        [31:0] fp32_o
);

    wire        sign;
    wire [31:0] magnitude;
    reg  [4:0]  msb_index;
    wire [7:0]  exponent;
    reg  [22:0] fraction;

    assign sign = int_i[31];
    assign magnitude = sign ? ((~int_i[31:0]) + 32'd1) : int_i[31:0];

    // Priority encoder for leading one
    always @(*) begin
        if      (magnitude[31]) msb_index = 5'd31;
        else if (magnitude[30]) msb_index = 5'd30;
        else if (magnitude[29]) msb_index = 5'd29;
        else if (magnitude[28]) msb_index = 5'd28;
        else if (magnitude[27]) msb_index = 5'd27;
        else if (magnitude[26]) msb_index = 5'd26;
        else if (magnitude[25]) msb_index = 5'd25;
        else if (magnitude[24]) msb_index = 5'd24;
        else if (magnitude[23]) msb_index = 5'd23;
        else if (magnitude[22]) msb_index = 5'd22;
        else if (magnitude[21]) msb_index = 5'd21;
        else if (magnitude[20]) msb_index = 5'd20;
        else if (magnitude[19]) msb_index = 5'd19;
        else if (magnitude[18]) msb_index = 5'd18;
        else if (magnitude[17]) msb_index = 5'd17;
        else if (magnitude[16]) msb_index = 5'd16;
        else if (magnitude[15]) msb_index = 5'd15;
        else if (magnitude[14]) msb_index = 5'd14;
        else if (magnitude[13]) msb_index = 5'd13;
        else if (magnitude[12]) msb_index = 5'd12;
        else if (magnitude[11]) msb_index = 5'd11;
        else if (magnitude[10]) msb_index = 5'd10;
        else if (magnitude[9])  msb_index = 5'd9;
        else if (magnitude[8])  msb_index = 5'd8;
        else if (magnitude[7])  msb_index = 5'd7;
        else if (magnitude[6])  msb_index = 5'd6;
        else if (magnitude[5])  msb_index = 5'd5;
        else if (magnitude[4])  msb_index = 5'd4;
        else if (magnitude[3])  msb_index = 5'd3;
        else if (magnitude[2])  msb_index = 5'd2;
        else if (magnitude[1])  msb_index = 5'd1;
        else                    msb_index = 5'd0;
    end

    assign exponent = 8'd127 + {3'd0, msb_index};

    always @(*) begin
        if (msb_index >= 5'd23) begin
            fraction = magnitude[30:0] >> (msb_index - 5'd23);
        end else begin
            fraction = magnitude[22:0] << (5'd23 - msb_index);
        end
    end

    assign fp32_o = (magnitude == 32'd0) ? 32'h0000_0000 : {sign, exponent, fraction};

endmodule

`default_nettype wire
