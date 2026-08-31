# SPDX-FileCopyrightText: (c) 2026 ASIC Team
# SPDX-License-Identifier: CC0-1.0
#
# Cocotb testbench for tt_um_nce_neural_engine.
#
# Protocol under test: the direct-strobed 8-bit register port.
#
#   uio_in[0] strobe      pulse high for one clock to commit a transfer
#   uio_in[1] is_write    1 = write byte at pointer, 0 = read (advance pointer)
#   uio_in[2] addr_load   1 = load ui_in into the 8-bit address pointer
#   uio_in[3] start_exec  1 = run one INT8 DOT4 multiply-accumulate
#
#   uio_out[4] ready   uio_out[5] valid   uio_out[6] busy   uio_out[7] done
#
# addr_load takes priority over is_write, so an address load and a data
# transfer must occupy separate clock cycles. Reads and writes both
# auto-increment the pointer, so a 32-bit word is one address load followed
# by four byte transfers, least-significant byte first.

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

# 33.333 MHz, matching clock_hz in info.yaml
CLK_PERIOD_NS = 30

# Every transfer is followed by one idle clock, and outputs are sampled
# SETTLE_NS into that idle clock. At RTL this is only cosmetic, but the
# gate-level netlist is compiled with UNIT_DELAY=#1, so the combinational
# read mux from the address pointer to uo_out takes many nanoseconds to
# resolve. Sampling immediately after the clock edge would latch a value
# that is still propagating.
SETTLE_NS = 5

# uio_in control bits
STROBE = 1 << 0
IS_WRITE = 1 << 1
ADDR_LOAD = 1 << 2
START_EXEC = 1 << 3

# uio_out status bits
READY = 1 << 4
VALID = 1 << 5
BUSY = 1 << 6
DONE = 1 << 7

# Register map
ADDR_HW_ID = 0x00
ADDR_CAPS = 0x04
ADDR_R0 = 0x10
ADDR_R1 = 0x14
ADDR_R2 = 0x18
ADDR_R3 = 0x1C
ADDR_ACC_INT32 = 0x20
ADDR_ACC_FP32 = 0x24
ADDR_ACC2_INT32 = 0x28
ADDR_ACC2_FP32 = 0x2C
ADDR_STATUS = 0x30
ADDR_CONTROL = 0x30
ADDR_CONFIG = 0x31
ADDR_CONFIG2 = 0x32

HW_ID = 0x4E434531  # "NCE1"
CAPABILITIES = 0x0000000F

# CONTROL (write to 0x30) bits
CTRL_CLEAR_ACC = 1 << 0
CTRL_CLEAR_REGS = 1 << 1

# STATUS (read from 0x30) bits
ST_BUSY = 1 << 0
ST_DONE = 1 << 1
ST_ACC_VALID = 1 << 2
ST_OVERFLOW = 1 << 3
ST_OVERFLOW2 = 1 << 4


# ---------------------------------------------------------------------------
# Bus helpers
# ---------------------------------------------------------------------------

def resolved(signal, name):
    """Read a signal as an integer, failing loudly if it still holds x/z.

    Gate-level runs can leave outputs unresolved if the testbench samples
    too early or reset was too short; this turns an opaque conversion
    error into a readable assertion.
    """
    value = signal.value
    try:
        return int(value)
    except Exception:
        raise AssertionError(f"{name} is not fully resolved: {value!r}")


async def start_and_reset(dut):
    """Start the clock and bring the DUT out of reset."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)
    await Timer(SETTLE_NS, unit="ns")


async def _pulse(dut, ui, ctrl):
    """Drive one transfer, then idle for a clock so outputs settle.

    Inputs are driven a full clock ahead of the edge that samples them, and
    the idle clock afterwards gives the combinational read path time to
    resolve before the caller looks at uo_out.
    """
    dut.ui_in.value = ui & 0xFF
    dut.uio_in.value = ctrl
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 1)
    await Timer(SETTLE_NS, unit="ns")


async def load_addr(dut, addr):
    """Point the address pointer at `addr`."""
    await _pulse(dut, addr, STROBE | ADDR_LOAD)


async def write_byte(dut, data):
    """Write one byte at the pointer. The pointer auto-increments."""
    await _pulse(dut, data, STROBE | IS_WRITE)


async def read_byte(dut):
    """Read the byte at the pointer, then auto-increment.

    uo_out is a combinational mux off the address pointer, so the data is
    already present before the strobe; the strobe only advances the pointer.
    """
    value = resolved(dut.uo_out, "uo_out")
    await _pulse(dut, 0, STROBE)
    return value


async def write_word(dut, addr, value):
    """Write a 32-bit word, least-significant byte first."""
    await load_addr(dut, addr)
    for i in range(4):
        await write_byte(dut, (value >> (8 * i)) & 0xFF)


async def read_word(dut, addr):
    """Read a 32-bit word, least-significant byte first."""
    await load_addr(dut, addr)
    word = 0
    for i in range(4):
        word |= (await read_byte(dut)) << (8 * i)
    return word


async def read_reg8(dut, addr):
    """Read a single byte-wide register."""
    await load_addr(dut, addr)
    return resolved(dut.uo_out, "uo_out")


async def clear_accumulator(dut):
    await load_addr(dut, ADDR_CONTROL)
    await write_byte(dut, CTRL_CLEAR_ACC)
    await ClockCycles(dut.clk, 2)
    await Timer(SETTLE_NS, unit="ns")


async def execute(dut):
    """Pulse start_exec for exactly one clock and let the MAC settle.

    start_exec is level-sensitive and registers mac_en_req, so the
    accumulator updates on the following clock edge.
    """
    await _pulse(dut, 0, START_EXEC)
    await ClockCycles(dut.clk, 3)
    await Timer(SETTLE_NS, unit="ns")


# ---------------------------------------------------------------------------
# Reference model
# ---------------------------------------------------------------------------

def as_int8(byte):
    return byte - 256 if byte >= 128 else byte


def dot4(word_a, word_b):
    """Signed INT8 4-element dot product of two packed 32-bit words."""
    total = 0
    for i in range(4):
        a = as_int8((word_a >> (8 * i)) & 0xFF)
        b = as_int8((word_b >> (8 * i)) & 0xFF)
        total += a * b
    return total


def to_int32(value):
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def int32_to_fp32_bits(value):
    """IEEE-754 binary32 bit pattern for a signed 32-bit integer.

    The RTL converter truncates rather than rounding, so this reference is
    only exact for magnitudes representable in 24 bits. Every value used in
    these tests is well inside that range.
    """
    assert abs(value) < (1 << 24), "reference model is exact only below 2**24"
    return struct.unpack("<I", struct.pack("<f", float(value)))[0]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_identification(dut):
    """Hardware ID and capability words read back over the strobed port."""
    await start_and_reset(dut)

    hw_id = await read_word(dut, ADDR_HW_ID)
    assert hw_id == HW_ID, f"HW_ID: expected {HW_ID:#010x}, got {hw_id:#010x}"

    caps = await read_word(dut, ADDR_CAPS)
    assert caps == CAPABILITIES, f"CAPABILITIES: expected {CAPABILITIES:#010x}, got {caps:#010x}"

    status = resolved(dut.uio_out, "uio_out")
    assert status & READY, f"ready should be asserted, uio_out={status:#04x}"

    oe = resolved(dut.uio_oe, "uio_oe")
    assert oe == 0xF0, f"uio_oe: expected 0xf0 (upper nibble out), got {oe:#04x}"


@cocotb.test()
async def test_register_file(dut):
    """Each of the four vector registers holds and returns a 32-bit word."""
    await start_and_reset(dut)

    patterns = {
        ADDR_R0: 0x01020304,
        ADDR_R1: 0xDEADBEEF,
        ADDR_R2: 0x00000000,
        ADDR_R3: 0xFFFFFFFF,
    }

    for addr, value in patterns.items():
        await write_word(dut, addr, value)

    for addr, value in patterns.items():
        got = await read_word(dut, addr)
        assert got == value, f"R@{addr:#04x}: expected {value:#010x}, got {got:#010x}"


@cocotb.test()
async def test_register_clear(dut):
    """CONTROL bit 1 zeroes the whole register file."""
    await start_and_reset(dut)

    await write_word(dut, ADDR_R0, 0x11223344)
    await write_word(dut, ADDR_R1, 0x55667788)

    await load_addr(dut, ADDR_CONTROL)
    await write_byte(dut, CTRL_CLEAR_REGS)
    await ClockCycles(dut.clk, 2)

    for addr in (ADDR_R0, ADDR_R1, ADDR_R2, ADDR_R3):
        got = await read_word(dut, addr)
        assert got == 0, f"R@{addr:#04x} should be cleared, got {got:#010x}"


@cocotb.test()
async def test_dot4_accumulate(dut):
    """One execute step accumulates a signed INT8 DOT4 into the INT32 register."""
    await start_and_reset(dut)

    a = 0x01020304  # +4 +3 +2 +1
    b = 0x0A0B0C0D  # +13 +12 +11 +10

    await write_word(dut, ADDR_R0, a)
    await write_word(dut, ADDR_R1, b)
    await clear_accumulator(dut)

    expected = dot4(a, b)
    assert expected == 120, "sanity check on the reference model"

    await execute(dut)
    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    assert acc == expected, f"after 1 MAC: expected {expected}, got {acc}"

    # The accumulator is persistent: a second execute adds the same product.
    await execute(dut)
    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    assert acc == 2 * expected, f"after 2 MACs: expected {2 * expected}, got {acc}"

    status = await read_reg8(dut, ADDR_STATUS)
    assert status & ST_ACC_VALID, f"acc_valid should be set, status={status:#04x}"
    assert not (status & ST_OVERFLOW), f"no overflow expected, status={status:#04x}"


@cocotb.test()
async def test_dot4_signed_operands(dut):
    """Negative INT8 operands accumulate with the correct sign."""
    await start_and_reset(dut)

    a = 0xFFFFFFFF  # -1 -1 -1 -1
    b = 0x01010101  # +1 +1 +1 +1

    await write_word(dut, ADDR_R0, a)
    await write_word(dut, ADDR_R1, b)
    await clear_accumulator(dut)

    expected = dot4(a, b)
    assert expected == -4, "sanity check on the reference model"

    await execute(dut)
    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    assert acc == expected, f"expected {expected}, got {acc}"

    # Clearing returns the accumulator to zero.
    await clear_accumulator(dut)
    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    assert acc == 0, f"accumulator should clear to 0, got {acc}"


@cocotb.test()
async def test_config_operand_select(dut):
    """CONFIG selects which registers feed the two MAC operand ports."""
    await start_and_reset(dut)

    await write_word(dut, ADDR_R0, 0x00000000)
    await write_word(dut, ADDR_R1, 0x00000000)
    await write_word(dut, ADDR_R2, 0x02020202)  # +2 x4
    await write_word(dut, ADDR_R3, 0x03030303)  # +3 x4

    # Src A = R2 (bits [1:0] = 2), Src B = R3 (bits [3:2] = 3) -> 0b1110
    await load_addr(dut, ADDR_CONFIG)
    await write_byte(dut, 0x0E)
    await ClockCycles(dut.clk, 2)

    config = await read_reg8(dut, ADDR_CONFIG)
    assert config == 0x0E, f"CONFIG readback: expected 0x0e, got {config:#04x}"

    await clear_accumulator(dut)
    await execute(dut)

    expected = dot4(0x02020202, 0x03030303)
    assert expected == 24, "sanity check on the reference model"

    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    assert acc == expected, f"expected {expected}, got {acc}"


@cocotb.test()
async def test_fp32_readback(dut):
    """The shared INT32 to FP32 converter mirrors the accumulator."""
    await start_and_reset(dut)

    a = 0x01020304
    b = 0x0A0B0C0D

    await write_word(dut, ADDR_R0, a)
    await write_word(dut, ADDR_R1, b)
    await clear_accumulator(dut)

    # Zero converts to +0.0.
    fp = await read_word(dut, ADDR_ACC_FP32)
    assert fp == 0x00000000, f"fp32(0) should be 0x00000000, got {fp:#010x}"

    await execute(dut)

    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    fp = await read_word(dut, ADDR_ACC_FP32)
    expected = int32_to_fp32_bits(acc)
    assert fp == expected, (
        f"fp32({acc}): expected {expected:#010x}, got {fp:#010x}"
    )


@cocotb.test()
async def test_busy_done_handshake(dut):
    """busy asserts while the MAC computes, then done pulses when the result lands.

    This is a regression test for a real defect: busy_q was assigned 1 and
    then 0 inside the same sequential block, so the last assignment always
    won and uio_out[6] was tied low forever while info.yaml advertised it as
    a live status output. A dead status pin passes every functional test that
    does not look at it, which is exactly why this one exists.
    """
    await start_and_reset(dut)

    await write_word(dut, ADDR_R0, 0x01020304)
    await write_word(dut, ADDR_R1, 0x0A0B0C0D)
    await clear_accumulator(dut)

    # Drive start_exec for exactly one clock, then sample uio_out on every
    # subsequent edge. _pulse() idles a clock and would swallow the pulse.
    dut.ui_in.value = 0
    dut.uio_in.value = START_EXEC
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0

    busy_trace, done_trace = [], []
    for _ in range(6):
        await Timer(SETTLE_NS, unit="ns")
        status = resolved(dut.uio_out, "uio_out")
        busy_trace.append(1 if status & BUSY else 0)
        done_trace.append(1 if status & DONE else 0)
        await RisingEdge(dut.clk)

    assert sum(busy_trace) == 1, (
        f"busy should assert for exactly one cycle, got {busy_trace}"
    )
    assert sum(done_trace) == 1, (
        f"done should pulse for exactly one cycle, got {done_trace}"
    )
    assert busy_trace.index(1) < done_trace.index(1), (
        f"busy must precede done: busy={busy_trace} done={done_trace}"
    )

    # The accumulate still happened, so the fix did not change the datapath.
    acc = to_int32(await read_word(dut, ADDR_ACC_INT32))
    assert acc == dot4(0x01020304, 0x0A0B0C0D), f"accumulator wrong: {acc}"


@cocotb.test()
async def test_dual_lane_simd(dut):
    """One execute strobe drives both lanes with independent operands.

    Lane 0 defaults to R0 x R1 and lane 1 to R2 x R3, so a single start_exec
    produces two different dot products. This is the whole point of the second
    lane: 2x INT8 throughput for one issue.
    """
    await start_and_reset(dut)

    a0, b0 = 0x01020304, 0x0A0B0C0D   # lane 0 -> 120
    a1, b1 = 0x02020202, 0x03030303   # lane 1 -> 24
    await write_word(dut, ADDR_R0, a0)
    await write_word(dut, ADDR_R1, b0)
    await write_word(dut, ADDR_R2, a1)
    await write_word(dut, ADDR_R3, b1)
    await clear_accumulator(dut)

    # Defaults after reset: lane 0 = R0/R1 (0x04), lane 1 = R2/R3 (0x0e).
    assert await read_reg8(dut, ADDR_CONFIG) == 0x04
    assert await read_reg8(dut, ADDR_CONFIG2) == 0x0E

    await execute(dut)

    acc0 = to_int32(await read_word(dut, ADDR_ACC_INT32))
    acc1 = to_int32(await read_word(dut, ADDR_ACC2_INT32))
    assert acc0 == dot4(a0, b0) == 120, f"lane 0: expected 120, got {acc0}"
    assert acc1 == dot4(a1, b1) == 24, f"lane 1: expected 24, got {acc1}"

    # Both accumulate independently on a second issue.
    await execute(dut)
    assert to_int32(await read_word(dut, ADDR_ACC_INT32)) == 240
    assert to_int32(await read_word(dut, ADDR_ACC2_INT32)) == 48


@cocotb.test()
async def test_lane1_config_and_fp32(dut):
    """Lane 1 operand select is programmable and its FP32 readout tracks."""
    await start_and_reset(dut)

    await write_word(dut, ADDR_R0, 0xFFFFFFFF)  # -1 x4
    await write_word(dut, ADDR_R1, 0x01010101)  # +1 x4
    await write_word(dut, ADDR_R2, 0x00000000)
    await write_word(dut, ADDR_R3, 0x00000000)

    # Point lane 1 at R0/R1 as well, so both lanes must agree.
    await load_addr(dut, ADDR_CONFIG2)
    await write_byte(dut, 0x04)
    await ClockCycles(dut.clk, 2)
    assert await read_reg8(dut, ADDR_CONFIG2) == 0x04

    await clear_accumulator(dut)
    await execute(dut)

    acc0 = to_int32(await read_word(dut, ADDR_ACC_INT32))
    acc1 = to_int32(await read_word(dut, ADDR_ACC2_INT32))
    assert acc0 == acc1 == -4, f"lanes disagree: {acc0} vs {acc1}"

    # Lane 1 FP32 conversion mirrors its own accumulator.
    fp1 = await read_word(dut, ADDR_ACC2_FP32)
    assert fp1 == int32_to_fp32_bits(acc1), (
        f"lane1 fp32({acc1}): expected {int32_to_fp32_bits(acc1):#010x}, got {fp1:#010x}"
    )

    # Clearing zeroes both lanes.
    await clear_accumulator(dut)
    assert to_int32(await read_word(dut, ADDR_ACC_INT32)) == 0
    assert to_int32(await read_word(dut, ADDR_ACC2_INT32)) == 0
