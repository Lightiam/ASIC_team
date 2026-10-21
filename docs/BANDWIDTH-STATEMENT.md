# Bandwidth: target versus current

One authoritative statement of what the photonic bridge is designed to carry
and what the repository currently achieves. Both numbers are real; they
describe different things, and conflating them is the error this file exists
to prevent.

Anything in this repository quoting 1.6T or 3.2T should point here.

---

## Target — the photonic bridge

| | |
|---|---|
| channels | 16 (ITU grid, `photonics/l04_wdm.py`) |
| per lane | 200 Gbps PAM4 |
| **simplex aggregate** | **3.2 Tbps** |
| dual socket | 6.4 Tbps |
| half-populated (8 ch) | 1.6 Tbps |

This is the design target of the TFLN photonic bridge. It is arithmetic over
a channel plan, not a measurement: `aggregate_capacity_gbps()` multiplies
channel count by per-lane rate. The channel plan itself is checked against
the ITU grid and holds to a 51 pm error, so the *spectral* side of the claim
is modelled and verified. The *rate* side is an assumption about a PHY.

## Current — the digital framing layer

| | |
|---|---|
| port | `output logic serial_o`, `rtl/link/nce_tfln_serializer.sv` |
| width | 1 bit per clock |
| clock target | 33.33 MHz (`CLOCK_PERIOD` 30.0 ns) |
| clock measured | 30.3 MHz (hardened cluster, below target) |
| **per lane** | **33.3 Mbps** at target, 30.3 Mbps measured |
| **16 lanes** | **533 Mbps** at target |

This is what the repository actually drives today. It is correct, verified
digital framing: 96-bit frames, 8-bit sync marker, CRC-8 over 80 bits, and
framing re-acquisition when the CRC fails.

## The distance between them

**6,000x**, and the factor is the same from either direction:

- per lane: 200 Gbps / 33.3 Mbps = 6,000
- aggregate: 3.2 Tbps / 533 Mbps = 6,000

## What stands between target and current

A single missing component, and it is not a tuning problem:

**An analog SerDes PHY and modulator driver operating at 50 GHz Nyquist.**

It does not exist in this repository as RTL, as a hard macro, or as a vendor
IP reference. It cannot: a synthesized digital core in this process reaches
30.3 MHz, five orders of magnitude short. 200 Gbps PAM4 serialization is
analog mixed-signal design, procured from a vendor rather than written in
open tools.

Until that component exists, the correct way to describe the link is:

> A TFLN photonic bridge **targeting** 1.6T/3.2T, with the digital link
> layer implemented and verified, and the analog PHY outstanding.

## How to quote these numbers

**Correct:**
- "The photonic bridge targets 3.2T across 16 WDM channels."
- "The digital link layer frames at 33.3 Mbps per lane today."
- "Reaching the 3.2T target requires a 200G SerDes PHY, not yet sourced."

**Incorrect:**
- "The bridge delivers 3.2T." -- nothing in the repository delivers it.
- "16 x 200G = 3.2T" quoted without saying 200G is the target rate.
- Any throughput figure derived from 3.2T and presented as measured.

## Where the target legitimately appears

Some code uses 3.2T as an *input assumption* rather than a claim, which is
fine as long as it is labelled:

- `photonics/l04_wdm.py` -- `aggregate_capacity_gbps()` computes the target
  by construction. It is the definition of the target, not evidence for it.
- `sw/fabric/l16_l18_l21_l22.py` -- `local_gbps=3200.0` parameterises the
  scheduler against the target fabric. Scheduling policy has to be designed
  for the machine being built, so this is the right number to use; results
  from it are projections for the target fabric, not measurements.
- `pcb/build_schematic.py` -- 16 lanes per die per direction follows from
  the channel plan, and determines a real ball count. The lane *count* is
  solid; only the per-lane *rate* is a target.
