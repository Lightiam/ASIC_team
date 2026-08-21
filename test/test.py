import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

async def tt_write_word(dut, addr: int, data: int):
    # Send 4 bytes of address
    for i in range(4):
        await RisingEdge(dut.clk)
        dut.ui_in.value = (addr >> (i * 8)) & 0xFF
        dut.uio_in.value = 0x03 # cmd_valid=1, is_write=1
        await RisingEdge(dut.clk)
        dut.uio_in.value = 0x00

    # Send 4 bytes of data
    for i in range(4):
        await RisingEdge(dut.clk)
        dut.ui_in.value = (data >> (i * 8)) & 0xFF
        dut.uio_in.value = 0x03
        await RisingEdge(dut.clk)
        dut.uio_in.value = 0x00

    # Wait for resp_valid (uio_out[5] / uio_out[1])
    while (int(dut.uio_out.value) & 0x22) == 0:
        await RisingEdge(dut.clk)

    # Acknowledge response
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0x04 # resp_ack=1
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0x00

async def tt_read_word(dut, addr: int) -> int:
    # Send 4 bytes of address
    for i in range(4):
        await RisingEdge(dut.clk)
        dut.ui_in.value = (addr >> (i * 8)) & 0xFF
        dut.uio_in.value = 0x01 # cmd_valid=1, is_write=0
        await RisingEdge(dut.clk)
        dut.uio_in.value = 0x00

    rbytes = []
    for _ in range(4):
        while (int(dut.uio_out.value) & 0x22) == 0:
            await RisingEdge(dut.clk)
        rbytes.append(int(dut.uo_out.value))
        await RisingEdge(dut.clk)
        dut.uio_in.value = 0x04 # resp_ack=1
        await RisingEdge(dut.clk)
        dut.uio_in.value = 0x00

    # Consume status byte
    while (int(dut.uio_out.value) & 0x22) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0x04
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0x00

    return (rbytes[3] << 24) | (rbytes[2] << 16) | (rbytes[1] << 8) | rbytes[0]

@cocotb.test()
async def test_nce_top(dut):
    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)

    # 1. Test VERSION register readback
    version = await tt_read_word(dut, 0x00000000)
    assert version == 0x4E434531, f"Expected 0x4E434531, got 0x{version:08X}"

    # 2. Test CAPABILITIES register
    caps = await tt_read_word(dut, 0x00000004)
    assert (caps & 0x0F) == 0x0F, f"Expected capabilities 0x0F, got 0x{caps:08X}"

    # 3. Test Staging Vector Word Write & Readback
    await tt_write_word(dut, 0x00000060, 0xAABBCCDD)
    val = await tt_read_word(dut, 0x00000060)
    assert val == 0xAABBCCDD, f"Expected 0xAABBCCDD, got 0x{val:08X}"

    dut._log.info("All Tiny Tapeout NCE tests passed successfully!")
