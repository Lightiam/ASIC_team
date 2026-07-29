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
// Signed 18-bit integer to IEEE-754 binary32 converter.
//
// Every signed 18-bit integer is exactly representable in FP32 because
// binary32 contains 24 bits of significand precision, including the hidden bit.
// Therefore, this converter requires no rounding or inexact-result handling.
// -----------------------------------------------------------------------------

module nce_int18_to_fp32 (
    input  logic signed [17:0] int_i,
    output logic        [31:0] fp32_o
);

    logic        sign;
    logic [17:0] magnitude;
    logic [4:0]  msb_index;
    logic [7:0]  exponent;
    logic [22:0] fraction;

    // Priority encoder returning the highest asserted bit.
    function automatic logic [4:0] find_msb_index (
        input logic [17:1] value
    );
        begin
            if      (value[17]) find_msb_index = 5'd17;
            else if (value[16]) find_msb_index = 5'd16;
            else if (value[15]) find_msb_index = 5'd15;
            else if (value[14]) find_msb_index = 5'd14;
            else if (value[13]) find_msb_index = 5'd13;
            else if (value[12]) find_msb_index = 5'd12;
            else if (value[11]) find_msb_index = 5'd11;
            else if (value[10]) find_msb_index = 5'd10;
            else if (value[9])  find_msb_index = 5'd9;
            else if (value[8])  find_msb_index = 5'd8;
            else if (value[7])  find_msb_index = 5'd7;
            else if (value[6])  find_msb_index = 5'd6;
            else if (value[5])  find_msb_index = 5'd5;
            else if (value[4])  find_msb_index = 5'd4;
            else if (value[3])  find_msb_index = 5'd3;
            else if (value[2])  find_msb_index = 5'd2;
            else if (value[1])  find_msb_index = 5'd1;
            else               find_msb_index = 5'd0;
        end
    endfunction

    assign sign = int_i[17];

    // Two's-complement absolute value. This also correctly handles -131072.
    assign magnitude = sign
                     ? ((~int_i[17:0]) + 18'd1)
                     : int_i[17:0];

    assign msb_index = find_msb_index(magnitude[17:1]);

    // FP32 exponent bias is 127.
    assign exponent = 8'd127 + {3'd0, msb_index};

    // The leading one shifts beyond bit 22 and becomes the implicit hidden bit.
    // The remaining lower bits form the stored FP32 fraction.
    assign fraction =
        {5'd0, magnitude} << (5'd23 - msb_index);

    assign fp32_o = (magnitude == 18'd0)
                  ? 32'h0000_0000
                  : {sign, exponent, fraction};

endmodule

`default_nettype wire
