# SPDX-FileCopyrightText: 2026 Roberto Medina
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# uo_out flag bit positions (when bpm_sel = 0)
BREATH = 0
APNEA = 1
FAST = 2
SLOW = 3
IRREG = 4
HEART = 5
QUAL = 6
VALID = 7

CLKS_PER_SAMPLE = 1     # datapath runs one sample per clock
FRAME_PERIOD = 512      # clocks between UART frames


def bit(value, index):
    return (int(value) >> index) & 1


def uart_line(dut):
    return (int(dut.uio_out.value) >> 5) & 0x1


def set_ctrl(dut, demo=1, sens=0, bpm=0, pat=0):
    """uio_in: [0]=demo, [1]=sensitivity, [2]=bpm_sel, [4:3]=demo pattern."""
    dut.uio_in.value = (demo & 1) | ((sens & 1) << 1) | ((bpm & 1) << 2) | ((pat & 3) << 3)


async def do_reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


@cocotb.test()
async def test_demo_normal(dut):
    dut._log.info("Demo: normal breathing")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=0)
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=0)

    await ClockCycles(dut.clk, 400)

    assert bit(dut.uo_out.value, VALID) == 1
    assert bit(dut.uo_out.value, BREATH) == 1
    assert bit(dut.uo_out.value, APNEA) == 0
    assert bit(dut.uo_out.value, FAST) == 0
    assert bit(dut.uo_out.value, SLOW) == 0


@cocotb.test()
async def test_demo_fast(dut):
    dut._log.info("Demo: fast breathing")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=1)
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=1)

    await ClockCycles(dut.clk, 400)

    assert bit(dut.uo_out.value, BREATH) == 1
    assert bit(dut.uo_out.value, FAST) == 1
    assert bit(dut.uo_out.value, SLOW) == 0


@cocotb.test()
async def test_demo_slow(dut):
    dut._log.info("Demo: slow breathing")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=2)
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=2)

    await ClockCycles(dut.clk, 800)

    assert bit(dut.uo_out.value, BREATH) == 1
    assert bit(dut.uo_out.value, SLOW) == 1
    assert bit(dut.uo_out.value, FAST) == 0


@cocotb.test()
async def test_demo_apnea(dut):
    dut._log.info("Demo: apnea / no movement")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=3)
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=3)

    await ClockCycles(dut.clk, 400)   # > APNEA_THR (255) clocks

    assert bit(dut.uo_out.value, APNEA) == 1
    assert bit(dut.uo_out.value, BREATH) == 0
    assert bit(dut.uo_out.value, HEART) == 0, "no heartbeat during apnea"


@cocotb.test()
async def test_heartbeat(dut):
    dut._log.info("Heartbeat band detection (demo)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=0)
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=0)

    await ClockCycles(dut.clk, 200)

    assert bit(dut.uo_out.value, HEART) == 1, "heartbeat should be detected"


@cocotb.test()
async def test_bpm_readout(dut):
    dut._log.info("Breaths-per-minute readout (bpm_sel=1)")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=1)            # fast breathing, period ~24 clocks
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=1)

    await ClockCycles(dut.clk, 400)         # let several breaths complete
    set_ctrl(dut, demo=1, pat=1, bpm=1)     # switch output to BPM value
    await ClockCycles(dut.clk, 2)

    bpm = int(dut.uo_out.value)
    # BPM = 1000 / period; fast demo period ~24 -> ~41
    assert 25 <= bpm <= 60, f"fast-breathing BPM out of range: {bpm}"


@cocotb.test()
async def test_external_input(dut):
    dut._log.info("External 8-bit input mode")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=0, pat=0)
    await do_reset(dut)
    set_ctrl(dut, demo=0, pat=0)

    # square-ish breathing waveform, ~60-clock period
    for _ in range(8):
        dut.ui_in.value = 200
        await ClockCycles(dut.clk, 30)
        dut.ui_in.value = 50
        await ClockCycles(dut.clk, 30)

    assert bit(dut.uo_out.value, VALID) == 1
    assert bit(dut.uo_out.value, BREATH) == 1
    assert bit(dut.uo_out.value, APNEA) == 0


@cocotb.test()
async def test_uart_streaming(dut):
    dut._log.info("UART metric streaming")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    set_ctrl(dut, demo=1, pat=0)
    await do_reset(dut)
    set_ctrl(dut, demo=1, pat=0)

    # watch the TX line across a full frame period (spans a frame boundary)
    await ClockCycles(dut.clk, 30)
    seen_low = False
    for _ in range(FRAME_PERIOD + 200):
        if uart_line(dut) == 0:
            seen_low = True
            break
        await ClockCycles(dut.clk, 1)
    assert seen_low, "UART TX line never left idle - no frame transmitted"
