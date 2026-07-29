# NCE MVP Compute Architecture

## 1. Scope

This repository implements the production RTL for the Neural Compute Engine
digital ASIC.

The final ASIC will contain:

1. NCE compute subsystem
2. Control and register subsystem
3. Internal memory subsystem
4. Host-interface subsystem
5. PCIe Root Complex and physical interface

Milestone 1 covers the NCE compute subsystem. PCIe integration will follow
after the compute core is functionally verified.

## 2. SIMD Organization

- Number of SIMD lanes: 8
- Operand width per lane: 32 bits
- Vector operand width: 256 bits
- Accumulator width per lane: 32-bit IEEE-754 single precision
- Vector accumulator width: 256 bits
- Per-lane execution mask: 8 bits

Each active lane receives:

- One 32-bit operand A slice
- One 32-bit operand B slice
- One 32-bit FP32 accumulator value
- Operation code
- Precision mode

## 3. Supported Precision Modes

### INT8X4

Each 32-bit lane contains four signed two's-complement INT8 elements:

- Element 0: bits 7:0
- Element 1: bits 15:8
- Element 2: bits 23:16
- Element 3: bits 31:24

The lane calculates a four-element dot product. The exact signed dot-product
result is converted to FP32 before FP32 accumulation.

### BF16X2

Each 32-bit lane contains two standard bfloat16 values:

- Element 0: bits 15:0
- Element 1: bits 31:16

Each bfloat16 value uses:

- 1 sign bit
- 8 exponent bits
- 7 fraction bits
- Exponent bias 127

Packed element-wise operations produce two packed BF16 values. BF16 MAC mode
forms a two-element dot product and accumulates the result in FP32.

### BF24

One BF24 value occupies bits 23:0 of each 32-bit lane.

- Sign: bit 23
- Exponent: bits 22:15
- Fraction: bits 14:0
- Exponent bias: 127
- Bits 31:24 are reserved and must be zero

BF24 arithmetic results are converted to FP32 before accumulation.

### FP32

The complete 32-bit lane contains one IEEE-754 binary32 value:

- 1 sign bit
- 8 exponent bits
- 23 fraction bits
- Exponent bias 127

## 4. Operations

- NOP
- ADD
- MUL
- MAC
- INT8 DOT4 MAC
- ReLU
- SCALE

## 5. Floating-Point Behaviour

The floating-point datapath shall support:

- Positive and negative zero
- Normal values
- Subnormal values
- Positive and negative infinity
- Quiet NaN propagation
- Round-to-nearest, ties-to-even
- Overflow indication
- Underflow indication
- Invalid-operation indication
- Inexact-result indication

No integer addition of floating-point bit patterns is permitted.

## 6. Transaction Interface

The compute cluster will use a valid/ready transaction interface.

Input transaction:

- request valid
- request ready
- opcode
- precision
- lane mask
- operand A
- operand B
- accumulator input

Output transaction:

- response valid
- response ready
- arithmetic result
- accumulator result
- status flags

Operation latency may differ between precision modes. Valid/ready control
prevents software from depending on a fixed arithmetic latency.

## 7. Reset

- Active-low reset
- All architectural state resets to zero
- No stale response may appear after reset
- An interrupted transaction is discarded during reset

## 8. Verification Requirement

Every arithmetic block requires:

- Directed corner-case tests
- Randomized testing
- Independent software reference model
- Verilator lint
- Yosys synthesis check
- Integration testing before use in the eight-lane cluster
