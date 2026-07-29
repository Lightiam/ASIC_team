# NCE Compute Interface

## Clock and Reset

- clk_i: primary synchronous compute clock
- rst_ni: active-low reset

## Request Channel

- req_valid_i: request is valid
- req_ready_o: core can accept a request
- opcode_i[3:0]: requested arithmetic operation
- precision_i[1:0]: operand precision
- lane_mask_i[7:0]: enabled SIMD lanes
- operand_a_i[255:0]: eight 32-bit operand-A slices
- operand_b_i[255:0]: eight 32-bit operand-B slices
- accumulator_i[255:0]: eight FP32 accumulator values

A request is accepted only when:

    req_valid_i && req_ready_o

## Response Channel

- rsp_valid_o: response is valid
- rsp_ready_i: receiver can accept the response
- result_o[255:0]: arithmetic result
- accumulator_o[255:0]: updated FP32 accumulator values
- invalid_o[7:0]: invalid-operation flags
- overflow_o[7:0]: overflow flags
- underflow_o[7:0]: underflow flags
- inexact_o[7:0]: inexact-result flags
- saturation_o[7:0]: integer saturation flags

A response is transferred only when:

    rsp_valid_o && rsp_ready_i

The response must remain stable while rsp_valid_o is high and rsp_ready_i is
low.
