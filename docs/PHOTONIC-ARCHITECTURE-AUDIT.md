# Audit: does the repository implement a photonic architecture?

Audited against the 22-Layer Intelligence Stack and the Dual-NCE Motherboard
Blueprint. Every claim below cites a file, a command, or a number.

---

## Headline

**The repository is a CMOS digital implementation plus a set of standalone
analytic photonic models. No executable path in it touches, drives, or is
driven by optical hardware.**

That is not the same as "it is fake". The photonic models are real physics,
they compute correct results, and their tests pass. But they *model* devices;
they do not *control* them. The distinction is the whole substance of this
audit, and the code is honest about it in its own docstrings -- the gap is
between the code and the **deck**, not between the code and its comments.

### Four facts that settle it

1. **No hardware I/O exists anywhere in the repository.** The photonic
   modules import exactly: `math`, `numpy`, `cmath`, `dataclasses`,
   `subprocess` (to invoke ngspice), and lazily `photonforge`. There is no
   serial, USB, VISA, GPIB, SPI, I2C, ioctl or device-file access in
   `photonics/`, `rtl/` or `sw/`.

2. **Nothing imports the photonic models.** Grepping `sw/`, `src/` and
   `rtl/` for any reference to `photonics`, `l02_tfln`, `l04_wdm` or
   `l05_mzi` returns nothing. The optical layers are entirely decoupled from
   the compute stack: they consume nothing and nothing consumes them.

3. **The HAL opens no device, and says so.** `sw/hal/include/lightrail/
   nce_hal.hpp:63` reads: *"it is why there is no /dev/mem in this header."*
   `MmioBackend` takes a base pointer the caller must already have. The only
   concrete backend in the repository is `sw/emu/`, which deliberately
   identifies as `EMU0` so the HAL's probe rejects it.

4. **The RTL states that the optics are outside it.**
   `rtl/link/nce_tfln_pkg.sv:17` -- *"The optical portion is outside this
   RTL: each endpoint drives one modulator lane and samples one
   photodetector lane, both presented here as single-bit serial ports."*

---

## Bandwidth: the largest discrepancy in the project

> **Resolved by restatement.** The claim is now stated as a target with the
> current framing rate given separately, in `docs/BANDWIDTH-STATEMENT.md`
> and at every call site. The analysis below is what prompted that.


The blueprint claims a **1.6T/3.2T** photonic bridge. The RTL that drives it
is a one-bit serial port.

| | |
|---|---|
| port | `output logic serial_o` -- `rtl/link/nce_tfln_serializer.sv:31` |
| width | **1 bit per clock** |
| clock | 30.0 ns target (`CLOCK_PERIOD` in the flow configs) = 33.33 MHz |
| per lane | **33.3 Mbps** |
| 16 WDM channels | **533 Mbps** |
| blueprint claim | **3,200,000 Mbps** |
| **shortfall** | **6,000x** |

The factor is 6,000x whichever way it is taken: per lane (200 Gbps claimed
against 33.3 Mbps achievable) and in aggregate (3.2T against 533 Mbps).

This is not a tuning problem. Reaching 200 Gbps per lane requires an analog
SerDes and a modulator driver running at 50 GHz Nyquist. Neither exists in
this repository as RTL, as a hard macro, or as a vendor IP reference, and
neither is the kind of thing a synthesized digital core can do -- the
measured F_max of the hardened cluster was 30.3 MHz, which is *below* even
the 33.33 MHz target.

**What the RTL actually is:** correct, verified digital framing -- a 96-bit
frame with an 8-bit sync marker, CRC-8 over 80 bits, and framing re-acquisition
on CRC failure. It is the link layer that *would* ride on an optical PHY.
It is not the PHY.

---

## Layer-by-layer status

Legend:
**MODEL** = analytic/numerical model, drives no hardware ·
**RTL** = synthesizable Verilog ·
**SW** = working software ·
**ABSENT** = not implemented

### Base: Physical Fabric (1-5)

| # | Layer | Status | Implementation | Note |
|---|---|---|---|---|
| 1 | Physical Fabric | **MODEL + real PCB** | `photonics/l01_pdn.py`, `pcb/` | KiCad board is genuine: 32 layers, 15 poured planes, 5,368 pads, **0 DRC errors**. PDN model finds the 24 uohm target missed by **296x** |
| 2 | TFLN Interconnects | **MODEL** | `photonics/l02_tfln_mzm.py` | Closed-form electro-optic MZM: Vpi, extinction ratio, link budget. Velocity-mismatch limit 66.8 GHz at 1 cm. Computes; drives nothing |
| 3 | Remote Laser Arrays | **MODEL** | `photonics/l03_laser_array.py` | Finds the array is **Class 4, not Class 1M**, and 4,500 pm thermal drift. No laser is controlled |
| 4 | Multi-Spectral WDM | **MODEL** | `photonics/l04_wdm.py` | 16 ITU channels, 0.7982-0.8099 nm spacing, 51 pm grid error. `channels=16 x 200 Gbps = 3.2T` is **arithmetic**, not a measurement |
| 5 | Analog Wave Compute | **MODEL** | `photonics/l05_mzi_mesh.py` | Clements MZI decomposition, exact to 4.6e-16. A numerical linear-algebra routine -- no interference is physically computed |

**Answer to "are layers 1-5 natively driven or stubbed over electrical
primitives?"** Neither. They are not stubbed over electrical primitives --
there is no electrical stand-in pretending to be optical. They are *physics
calculators that sit beside the stack*, connected to nothing.

### Core: Logic & Kernel (6-12)

| # | Layer | Status | Implementation | Note |
|---|---|---|---|---|
| 6 | Memristive Synaptic Grid | **MODEL (SPICE)** | `photonics/l06_memristor_crossbar.py` | Generates an ngspice netlist and runs the simulator. Finds **3.3 ENOB at 32x32**. A circuit simulation, not a device |
| 7 | Analog Signal Restoration | **MODEL** | `photonics/l07_receiver.py` | SOA + TIA chain; TIA worth +0.01 dB, PAM4 penalty 9.45 dB |
| 8 | Ternary Logic Encoder | **RTL** | `rtl/ternary/` | Genuinely synthesizable and hardened. Multiplier-free negate-and-add. **8,329 um2** vs INT8 dot4's 12,117 um2 = **5.82x per lane** (deck claimed 6.8x) |
| 9 | Spiking Logic Dispatcher | **RTL** | `rtl/spiking/nce_lif_dispatcher.sv` | LIF with shift-based leak. **16,502 um2** |
| 10 | Logic Core | **RTL** | `rtl/core/` | The bulk of the 74 RTL modules: INT8/BF16/BF24/FP32 MAC lanes, systolic arrays |
| 11 | Fine-Grained Control | **RTL** | `rtl/control/` | Command decoders, GEMM controller |
| 12 | Communication Primitives | **RTL** | `rtl/collective/` | ABFP alignment + INT32 collective ALU. **23,992 um2** |

Layers 8-12 are the strongest part of the repository. This is real hardware
description that synthesizes, places, routes and passes DRC/LVS.

### Control Plane: Fabric OS (13-18)

| # | Layer | Status | Implementation | Note |
|---|---|---|---|---|
| 13 | Deterministic Kernel | **SW** | `sw/fabric/l13_repro_sum.hpp/.cpp` | 512-bit Kulisch super-accumulator, exact FP32 summation |
| 14 | Optimization Engine | **SW** | `sw/fabric/l14_collective_opt.py` | Min-max congestion LP via scipy/HiGHS |
| 15 | Fabric OS | **SW** | `sw/fabric/l15_fabric_os.py` | Hysteresis over 3 samples; degraded links de-rated 400->40 Gbps, not deleted |
| 16 | Provable Algorithms | **SW** | `sw/fabric/l16_l18_l21_l22.py` | `schedule_guarantee`, `reconfiguration_penalty` |
| 17 | Topology-Aware Routing | **SW** | `sw/fabric/l17_bvn_scheduler.hpp/.cpp` | Birkhoff-von Neumann via Kuhn's matching; validates doubly-stochastic input |
| 18 | Global Scheduler | **SW** | `sw/fabric/l16_l18_l21_l22.py` | |

### Summit: AI Workloads (19-22)

| # | Layer | Status | Implementation | Note |
|---|---|---|---|---|
| 19 | Direct Integration | **SW, interface only** | `sw/hal/` | 47 CSRs generated from the RTL. **Opens no device** -- see fact 3 |
| 20 | Framework Adapters (Shim) | **SW, refuses by design** | `sw/shim/nccl_net_lightrail.cpp` | Reports **zero devices**; every data-path call returns `ncclInternalError` while `kHaveTransport == false`. Deliberately cannot silently pretend to work |
| 21 | **Holographic Unified Memory Pooling** | **ABSENT as described** | `sw/fabric/l16_l18_l21_l22.py` (`MemoryMap`) | **The word "holographic" appears in zero files in the repository.** What exists is a conventional tenant memory-partition map. There is nothing holographic about it |
| 22 | AI Workloads | **SW** | `sw/fabric/l16_l18_l21_l22.py` | MoE `route_tokens`, `expert_load`, `load_imbalance`, prefill/decode split |

---

## Motherboard blueprint

| Blueprint item | Status | Evidence |
|---|---|---|
| Dual AI Compute Units (BGA-2500) | **present, provisional** | `U1`, `U2`: 50x50 @ 1.1 mm = 2500 balls each. Ball map generated **by rule**, not a released pinout |
| 48 DrMOS phases, 1000 A+ | **present, corrected** | Was **24**; fixed to 48 this session. 1000 A checks out: **3.4 A/mm2** per ball (limit 10-20) and **20.8 A/phase** (parts rated 50-70 A) |
| 1.6T/3.2T TFLN bridge, zero-copper | **footprint only** | `PIC1` is a package outline with 128 electrical pads. No photonic layout is streamed into the board. The *copper* claim holds -- there is no die-to-die copper bus -- but the *bandwidth* claim does not (see above) |
| CVD Diamond Liquid Cooling | **ABSENT** | No thermal model anywhere. Not a PCB layer, so it would not appear in the stackup, but nothing models it. Blocked on a per-die power number that does not exist |

---

## Verification gap

The regression runs **65 suites**. `scripts/run_stack_layers.sh` invokes
Icarus on five RTL blocks. Grepping all of `scripts/` for `test_l0`,
`l05_mzi` or `photonic` returns **nothing**.

> **Closed.** `scripts/run_photonics.sh` now runs all six photonic suites
> and is registered in the regression. `tb/unit/tb_nce_tfln_link.sv` gates
> the link layer, 16 checks, wired into `run_stack_layers.sh`.

**No photonic model was covered by the regression.** All five suites I ran
manually pass (`test_l01_pdn`, `test_l02_l04`, `test_l03_laser`,
`test_l05_mzi_mesh`, `test_l07_receiver` -- all exit 0), so the models work.
Nothing stops them from silently breaking.

---

## Comments versus functional logic

The user asked specifically whether these layers exist in code or only in
documentation. Measured:

| group | code lines | comment lines | comment share |
|---|---|---|---|
| photonics L1-L7 | 593 | 442 | 42.7% |
| rtl L8 ternary | 129 | 79 | 38.0% |
| rtl L9 spiking | 67 | 46 | 40.7% |
| rtl L12 collective | 159 | 75 | 32.1% |
| rtl TFLN link | 552 | 148 | 21.1% |
| sw L13-L22 | 658 | 319 | 32.7% |

**This is not a documentation-only repository.** Every layer with a file has
substantial executable logic behind it. The comment share is high but that
reflects a documented codebase, not hollow one. The gap this audit found is
not "comments pretending to be code" -- it is **code that models physics
being described in the deck as code that performs physics**.

---

## Recommendations

Ordered by how much each closes the gap between the deck and the repository.

### 1. Restate the bandwidth claim, or build the PHY (highest priority)

The 6,000x gap is the single largest discrepancy in the project and it is
load-bearing for the whole value proposition. Two honest options:

- **Restate**: describe 1.6T/3.2T as the *target* of the photonic bridge and
  state the current digital framing rate separately. Costs nothing, removes
  a claim no artifact supports.
- **Build**: specify the SerDes PHY as an explicit, named gap -- analog IP
  at 50 GHz Nyquist, which is not open-source-toolable and will need a
  vendor. Put it on the roadmap as procurement, not engineering.

Either is defensible. Leaving the deck as-is is not.

### 2. Rename Layer 21 or implement it -- DONE (both)

"Holographic Unified Memory Pooling" has **zero occurrences** in the
repository. `MemoryMap` is tenant partitioning. Either rename the layer to
what it is, or define what "holographic" means operationally so it can be
built and tested. As it stands the name cannot be defended in a technical
review.

### 3. Put the photonic models under CI -- DONE

`scripts/run_photonics.sh` runs all six suites (l01 PDN, l02/l04 MZM+WDM,
l03 laser, l05 MZI mesh, l06 crossbar, l07 receiver) and is registered in
`run_nce_complete_design_regression.sh`. A missing dependency is reported as
a FAILURE rather than skipped, because a skipped check and a passing check
look identical in a summary line -- which is how ungated code stays ungated.
All six pass in the container: 6 passed, 0 failed.

The TFLN link also had no testbench at all, which was the worst place in the
repository to have none: it is the digital half of the photonic bridge and
the half the 1.6T/3.2T target is measured against.
`tb/unit/tb_nce_tfln_link.sv` now tests the claims the package header makes
-- MSB-first ordering, field-intact round trip, CRC rejection of a corrupted
frame, idle quiescence, and re-acquisition after a payload containing the
SYNC marker. 16 checks, all passing.

### 4. Reclassify Layers 1-7 in the deck

Relabel them as **"modelled"** rather than implemented, with the measured
results attached -- several of which are genuinely valuable findings the
deck currently omits:

- PDN misses 24 uohm by **296x** (so the PDN must move on-die)
- Laser array is **Class 4, not Class 1M** (a safety-certification issue)
- Memristor crossbar achieves **3.3 ENOB at 32x32** (limits useful array size)
- MZM velocity mismatch caps at **66.8 GHz at 1 cm**

A deck that reports these reads as rigorous. One that omits them reads as
marketing, and they will surface in diligence anyway.

### 5. Model the CVD diamond thermal path

Needs a per-die power number first. Diamond conducts at roughly
2000 W/m.K against copper's 400, which is plausibly the reason the design
is coolable at all -- worth quantifying rather than asserting.

### 6. Close the HAL to a real device

`sw/hal` is a clean abstraction with no concrete production backend. The
emulator deliberately refuses to impersonate hardware. That is good design,
and it means Layer 19 "Direct Integration" is currently an interface, not an
integration. Label it accordingly until silicon exists.

---

## What this audit does not say

It does not say the work is weak. Layers 8-12 are real synthesizable RTL,
hardened through place-and-route with measured areas. Layers 13-22 are
working algorithms with tests that find their own errors. The PCB is a
genuine 32-layer board with zero DRC errors. The photonic models are correct
physics that produce findings a marketing deck would not have invented
against itself.

The finding is narrower and sharper: **the repository is an excellent
digital and analytical codebase describing a photonic machine that does not
yet exist in it.** Every optical claim in the deck is currently backed by a
calculation, not by a device or a driver.

---

# Update: four gaps closed

| layer | module | result |
|---|---|---|
| 1 | `models/l1_diamond_thermal.py` | silicon **115.86 C** vs diamond **78.84 C** peak junction; 10 physics checks |
| 2 | `rtl/link/nce_serdes_200g_stub.sv` | Gray PAM4 + CDR, 16 checks. **Carries no bandwidth** |
| 20 | `sw/shim/lrai_transport_loopback.py` | opt-in only, 28 checks |
| 21 | `sw/fabric/l21_memory_pool.py` | O(1) resolution, 15 checks |

Regression is now **73 suites**.

Three things these do NOT change:

**The 6000x bandwidth gap stands.** A behavioural SerDes stub exercises the
digital protocol; it is not a PHY and nothing synthesised from it carries
200 Gbps.

**Layer 20 still reports zero devices by default.** The C++ shim's
`kHaveTransport` is untouched. The loopback is inert unless
`LIGHTRAIL_EMULATE=1`, and identifies as `NCEE`.

**Layer 21 is not a coherence protocol.** It resolves where a page lives,
which is the easy half. It refuses a write from a non-owner rather than
pretending to the hard half.

The word "holographic" is still absent, deliberately. Nothing in the design
is holographic -- there is no volumetric storage, no interference encoding
and no optical medium holding state. The layer is built; the word is not
used.
