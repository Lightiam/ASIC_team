<!---
Tiny Tapeout Project Documentation
-->

# NCE: Neural Compute Engine (Tiny Tapeout Edition)

## Authors & Credits

- **Original RTL Architect and Digital Designer:** Talha Alam
- **Co-Designer:** Bola Olatunji

## How it works

The **Neural Compute Engine (NCE)** is a single-lane INT8 dot-product
accelerator with a 32-bit integer accumulator and a shared IEEE-754 FP32
readout path. It occupies a 3x2 tile.

The datapath is one **INT8 DOT4 MAC lane**. Each execute step unpacks two
32-bit operand registers into four signed 8-bit pairs, multiplies them,
sums the four products exactly in 18 bits, and adds that sum into a
persistent signed 32-bit accumulator:

```
acc <- acc + (a0*b0 + a1*b1 + a2*b2 + a3*b3)
```

The accumulator is sticky across execute steps, so a longer dot product is
built by loading successive operand pairs and executing repeatedly. An
overflow flag latches if the 33-bit intermediate sum ever leaves signed
32-bit range.

Alongside the raw INT32 result, a combinational **INT32 to FP32 converter**
presents the same accumulator as an IEEE-754 binary32 word. The converter
normalises via a priority encoder and **truncates** the fraction rather than
rounding to nearest, so results are bit-exact for magnitudes below 2^24 and
truncated toward zero above it.

All host traffic goes through a **direct-strobed 8-bit register port**. There
is no serialised address phase and no handshake: the host loads an 8-bit
address pointer in one cycle, then transfers data bytes in subsequent
cycles. The pointer auto-increments on every data transfer, so a 32-bit word
is one address load followed by four byte transfers.

## Register map

The address space is 8 bits wide and byte-addressed. Multi-byte registers
are little-endian: the lowest address holds the least-significant byte.

| Address | Name | Type | Description |
|---|---|---|---|
| `0x00`–`0x03` | `HW_ID` | RO | Returns `0x4E434531` (`"NCE1"` in ASCII) |
| `0x04`–`0x07` | `CAPABILITIES` | RO | Returns `0x0000000F` |
| `0x10`–`0x13` | `R0` | RW | Vector register 0 — four packed signed INT8 lanes |
| `0x14`–`0x17` | `R1` | RW | Vector register 1 |
| `0x18`–`0x1B` | `R2` | RW | Vector register 2 |
| `0x1C`–`0x1F` | `R3` | RW | Vector register 3 |
| `0x20`–`0x23` | `ACC_INT32` | RO | Signed 32-bit accumulator |
| `0x24`–`0x27` | `ACC_FP32` | RO | Accumulator converted to IEEE-754 binary32 |
| `0x30` | `STATUS` | RO | Bit 0 `busy`, bit 1 `done`, bit 2 `acc_valid`, bit 3 `overflow` |
| `0x30` | `CONTROL` | WO | Bit 0 clears the accumulator, bit 1 clears `R0`–`R3` |
| `0x31` | `CONFIG` | RW | Bits `[1:0]` select Src A register, bits `[3:2]` select Src B. Resets to `0x04` (Src A = `R0`, Src B = `R1`) |

`0x30` is a split register: reading it returns `STATUS`, writing it acts on
`CONTROL`.

## How to test

Apply `clk` at 33.33 MHz, hold `ena = 1`, and release `rst_n`.

**Load the address pointer** — drive the address on `ui_in`, raise
`strobe` and `addr_load` together for one clock. `addr_load` takes priority
over `is_write`, so an address load and a data transfer must occupy separate
cycles.

**Write a byte** — drive the data on `ui_in`, raise `strobe` and `is_write`
for one clock. The pointer auto-increments.

**Read a byte** — `uo_out` is a combinational mux off the pointer, so the
data is already valid once the address is loaded. Sample `uo_out`, then
raise `strobe` alone (with `is_write` low) for one clock to advance to the
next byte.

**Execute one MAC step** — raise `start_exec` for exactly one clock. It is
level-sensitive, so a longer pulse issues one accumulate per clock. The
accumulator updates on the following clock edge; `done` pulses high for one
cycle.

A worked sequence — dot product of `R0 = 0x01020304` and `R1 = 0x0A0B0C0D`:

1. Write `0x01020304` to `R0`: address-load `0x10`, then write `0x04`,
   `0x03`, `0x02`, `0x01`.
2. Write `0x0A0B0C0D` to `R1`: address-load `0x14`, then write `0x0D`,
   `0x0C`, `0x0B`, `0x0A`.
3. Clear the accumulator: address-load `0x30`, write `0x01`.
4. Pulse `start_exec` for one clock and wait two clocks.
5. Read `ACC_INT32`: address-load `0x20`, then read four bytes.

The result is `4*13 + 3*12 + 2*11 + 1*10 = 120`. Pulsing `start_exec` again
accumulates to `240`. Reading `0x24` instead returns the same value as
`0x42F00000`, the binary32 encoding of `120.0`.

The cocotb suite in `test/test.py` exercises exactly these sequences,
including signed operands, register and accumulator clears, `CONFIG`
operand selection, and the FP32 readout.

## IO Pinout

| Pin | Direction | Description |
|---|---|---|
| `ui_in[7:0]` | Input | Address byte or write-data byte |
| `uo_out[7:0]` | Output | Read-data byte at the current address pointer |
| `uio[0]` | Input | `strobe` — commit one transfer |
| `uio[1]` | Input | `is_write` — 1 = write, 0 = read |
| `uio[2]` | Input | `addr_load` — 1 = load `ui_in` into the address pointer |
| `uio[3]` | Input | `start_exec` — run one INT8 DOT4 accumulate |
| `uio[4]` | Output | `ready` — tied high, the port accepts a transfer every clock |
| `uio[5]` | Output | `valid` — high while a read is addressed |
| `uio[6]` | Output | `busy` — compute active |
| `uio[7]` | Output | `done` — one-cycle pulse on compute completion |

`uio_oe` is `0xF0`: `uio[3:0]` are inputs, `uio[7:4]` are outputs.

## External hardware

None. The design needs only the Tiny Tapeout carrier board; drive the
register port from the RP2040 or any GPIO host.
