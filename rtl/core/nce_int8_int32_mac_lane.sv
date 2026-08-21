// nce_int8_int32_mac_lane.sv
// High-efficiency INT8x4 Dot Product with 32-bit Integer Accumulation

`default_nettype none

module nce_int8_int32_mac_lane (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        clr_i,
    input  wire        en_i,
    input  wire [31:0] operand_a_i,
    input  wire [31:0] operand_b_i,
    output reg  [31:0] accumulator_o,
    output reg         overflow_o
);
    // Unpack 4 signed 8-bit integers
    wire signed [7:0] a0 = operand_a_i[7:0];
    wire signed [7:0] a1 = operand_a_i[15:8];
    wire signed [7:0] a2 = operand_a_i[23:16];
    wire signed [7:0] a3 = operand_a_i[31:24];

    wire signed [7:0] b0 = operand_b_i[7:0];
    wire signed [7:0] b1 = operand_b_i[15:8];
    wire signed [7:0] b2 = operand_b_i[23:16];
    wire signed [7:0] b3 = operand_b_i[31:24];

    // Four signed 8x8 multiplications
    wire signed [15:0] prod0 = a0 * b0;
    wire signed [15:0] prod1 = a1 * b1;
    wire signed [15:0] prod2 = a2 * b2;
    wire signed [15:0] prod3 = a3 * b3;

    // 18-bit exact dot-product sum
    wire signed [17:0] dot4_sum = (prod0 + prod1) + (prod2 + prod3);

    // 32-bit sign-extended addition with saturation/overflow check
    wire signed [32:0] next_acc = $signed(accumulator_o) + $signed({{14{dot4_sum[17]}}, dot4_sum});

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            accumulator_o <= 32'sd0;
            overflow_o    <= 1'b0;
        end else if (clr_i) begin
            accumulator_o <= 32'sd0;
            overflow_o    <= 1'b0;
        end else if (en_i) begin
            accumulator_o <= next_acc[31:0];
            if (next_acc[32] != next_acc[31]) begin
                overflow_o <= 1'b1;
            end
        end
    end

endmodule
`default_nettype wire
