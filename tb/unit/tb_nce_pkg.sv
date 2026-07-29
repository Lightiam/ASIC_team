`timescale 1ns/1ps
`default_nettype none

module tb_nce_pkg;

    import nce_pkg::*;

    initial begin
        if (NCE_LANE_COUNT != 8)
            $fatal(1, "Incorrect lane count");

        if (NCE_LANE_WIDTH != 32)
            $fatal(1, "Incorrect lane width");

        if (NCE_VECTOR_WIDTH != 256)
            $fatal(1, "Incorrect vector width");

        if (NCE_BF16_FRAC_WIDTH != 7)
            $fatal(1, "Incorrect BF16 format");

        if (NCE_BF24_FRAC_WIDTH != 15)
            $fatal(1, "Incorrect BF24 format");

        if (NCE_FP32_FRAC_WIDTH != 23)
            $fatal(1, "Incorrect FP32 format");

        if (NCE_OP_DOT4_MAC != 4'h4)
            $fatal(1, "Incorrect DOT4 opcode");

        if (NCE_PREC_FP32 != 2'b11)
            $fatal(1, "Incorrect FP32 precision encoding");

        $display("PASS: NCE package constants and encodings verified.");
        $finish;
    end

endmodule

`default_nettype wire
