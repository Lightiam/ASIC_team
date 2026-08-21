<!---
Tiny Tapeout Project Documentation
-->

# NCE: Neural Compute Engine (Tiny Tapeout Edition)

## Authors & Credits

- **Original RTL Architect and Digital Designer:** Talha Alam
- **Co-Designer:** Bola Olatunji

## How it works

The **Neural Compute Engine (NCE)** is an 8-lane SIMD neural accelerator featuring:
- **Eight Parallel Execution Lanes:** 256-bit wide vector datapath.
- **Precision Datapath:** INT8 DOT4 integer dot products converted to normalized IEEE-754 FP32 format.
- **IEEE-754 Accumulation:** 8 individual FP32 accumulators per lane.
- **Byte Serialization Bridge:** Decouples the 8-bit Tiny Tapeout physical pins to an internal 32-bit AXI4-Lite CSR backend.

## Register Map & Commands

| Address Offset | Name | Type | Description |
|---|---|---|---|
| `0x000` | `VERSION` | RO | Returns `0x4E434531` (`"NCE1"` in ASCII) |
| `0x004` | `CAPABILITIES` | RO | Returns `0x0000000F` (INT8, BF16, BF24, FP32 flags) |
| `0x008` | `CONTROL` | WO | Bit 0: Clear Regs, Bit 1: Clear Accumulators, Bit 3: Clear Stats |
| `0x010` | `COMMAND` | WO | Bits [3:0]=Opcode (0=ADD, 1=MUL, 2=MAC, 3=DOT4), [5:4]=Precision |
| `0x018` | `STATUS` | RO | Bit 0: Busy, Bit 1: Done, Bit 2: Acc Valid |
| `0x060`–`0x07C`| `VECTOR_STAGING[0..7]` | RW | Staging 8 words (256 bits) for vector registers |
| `0x080` | `VECTOR_COMMIT` | WO | Commit strobe transferring staged vector to target register |
| `0x100`–`0x11C`| `ACC_READBACK[0..7]` | RO | Direct readback of the 8 FP32 lane accumulators |

## How to test

1. Apply `clk` (up to 50 MHz) and release `rst_n` with `ena = 1`.
2. To issue a 32-bit AXI read (e.g. read `VERSION` at `0x000`):
   - Stream 4 address bytes on `ui_in` with `uio_in[0] = 1` (valid) and `uio_in[1] = 0` (read).
   - Sample `uo_out` across 4 clock handshakes using `uio_in[2]` (resp_ack) when `uio_out[5]` (resp_valid) is high.
3. To stage a 256-bit vector:
   - Write 8 consecutive words to addresses `0x060` through `0x07C`.
   - Write `0x00000001` to `0x080` (`VECTOR_COMMIT`).
4. To execute a DOT4 computation:
   - Write opcode `0x03` to `COMMAND` (`0x010`).
   - Poll `STATUS` (`0x018`) until `done` (`Bit 1`) is asserted.
   - Read accumulated results from `ACC_READBACK` registers (`0x100`–`0x11C`).

## IO Pinout

| Pin | Direction | Description |
|---|---|---|
| `ui_in[7:0]` | Input | Multiplexed Address / Write Data byte stream |
| `uo_out[7:0]` | Output | Multiplexed Read Data / Status byte stream |
| `uio_in[0]` | Input | `cmd_valid` strobe |
| `uio_in[1]` | Input | `is_write` selector (1=Write, 0=Read) |
| `uio_in[2]` | Input | `resp_ack` strobe from master |
| `uio_out[4]` | Output | `cmd_ready` |
| `uio_out[5]` | Output | `resp_valid` |
| `uio_out[6]` | Output | `engine_busy` |
| `uio_out[7]` | Output | `engine_done` |
