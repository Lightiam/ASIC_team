# Lightrail NCE — specification pack for a design-services partner

Written for an external ASIC design house. Everything marked MEASURED was
produced by a tool in this repository and can be reproduced by running the
command named beside it. Everything marked TARGET is a design goal with no
silicon behind it. The distinction is kept rigidly, because the fastest way
to lose a partner's trust is to hand them a roadmap number formatted as a
result.

---

## 1. What exists today

| item | status | evidence |
|---|---|---|
| RTL, 74 modules | MEASURED | `scripts/run_nce_complete_design_regression.sh`, 74 suites |
| Hardened block to GDS | MEASURED | `nce_core_cluster`, sky130A, DRC/LVS/antenna all 0 |
| Tiny Tapeout chip in CI | MEASURED | green `gds` run, 11.4 MB `tt_submission` |
| Photonic device models | MEASURED | `photonics/`, 6 suites |
| 200G PHY | **ABSENT** | no analog IP anywhere in the repository |
| SerDes | **ABSENT** | `rtl/link/` is digital framing only |

### Hardened block, measured post-place-and-route

`nce_core_cluster` — Layers 8, 9, 12 and the token-generation loop.

```
core area            147,839 um2      (0.148 mm2)
die area             161,700 um2      (0.162 mm2)
magic DRC                     0
klayout DRC                   0
LVS errors                    0
antenna violations            0
hold WNS, 9 corners       0.000 ns
setup WNS, max_ss        -2.286 ns    DOES NOT CLOSE
```

Setup does not close at the 33.33 MHz target. Best achieved is roughly
31 MHz. This is stated up front because a partner will find it in the
first hour and should hear it from us first.

### Area, for die sizing

| block | area | source |
|---|---|---|
| one SIMD8 MAC tile | 0.196 mm2 | synthesis, `scripts/area_estimate.ys` |
| Core 16 (16 tiles, at 40% utilisation) | 7.84 mm2 | derived |
| Core 16 + stack cluster | **8.00 mm2** | derived |

Synthesis area excludes routing, fill and the I/O ring, so 8.00 mm2 is a
FLOOR. The utilisation figure, 40%, is what the cluster actually ran at
rather than an optimistic assumption.

---

## 2. The rate decision, and why it is the whole conversation

The blueprint says "1.6T/3.2T". Those are not two ways of saying the same
thing — they are different processes, different partners and different
money. The arithmetic:

| config | per lane | baud | Nyquist | 16 channels |
|---|---|---|---|---|
| 25G NRZ | 25 G | 25.0 GBd | 12.5 GHz | 0.40 T |
| 56G NRZ | 56 G | 56.0 GBd | 28.0 GHz | 0.90 T |
| **100G PAM4** | 100 G | **50.0 GBd** | **25.0 GHz** | **1.60 T** |
| 112G PAM4 | 112 G | 56.0 GBd | 28.0 GHz | 1.79 T |
| 200G PAM4 | 200 G | 100.0 GBd | 50.0 GHz | 3.20 T |

**1.6T is exactly 16 lanes of 100G PAM4, which is 50 GBd.** That sits
inside what 130nm SiGe HBTs do. 3.2T needs 100 GBd and does not.

So the blueprint's own lower number is the reachable one, and the upper
number is the roadmap. That is a far better position to negotiate from
than a single aspirational figure.

### A correction worth carrying into the conversation

56G NRZ and 112G PAM4 are **the same 56 GBd and the same 28 GHz Nyquist**.
PAM4 does not cost bandwidth; it costs SNR — three eyes instead of one is
a 9.54 dB penalty, plus driver linearity and FEC.

Anyone who says a process "will do 56G NRZ but not 112G PAM4" is making a
claim about linearity and SNR, not about fT. Worth being precise, because
the two lead to different vendors and different prices.

---

## 3. PHY specification

Derived in `phy/phy_requirements.py` from the device models, not assumed.
Shown for both rate points.

| parameter | 1.6T product | 3.2T roadmap |
|---|---|---|
| modulation | PAM4 | PAM4 |
| per lane | 100 Gbps | 200 Gbps |
| line rate with KP4 | 105.8 Gbps | 211.7 Gbps |
| symbol rate | 52.9 GBd | 105.8 GBd |
| Nyquist | 26.5 GHz | 52.9 GHz |
| lanes | 16 | 16 |
| FEC | KP4 RS(544,514) | KP4 RS(544,514) |
| pre-FEC BER | 2.4e-4 | 2.4e-4 |

From the device models, both MEASURED:

- **Modulator drive 1.80 Vpp** differential. Vpi is 1.80 V at a 1 cm
  electrode (`photonics/l02_tfln_mzm.py`).
- **Electrode bandwidth 66.80 GHz** at 1 cm, from velocity mismatch. This
  supports the 3.2T symbol rate, so the electrode length does not have to
  change between the two rate points.
- **Required OMA -10.83 dBm** at the receiver, from TIA noise and
  responsivity (`photonics/l07_receiver.py`).
- **TIA bandwidth is marginal at 3.2T**: the Layer 7 spec is 56 GHz
  against 52.9 GHz needed. At 1.6T it is comfortable.

---

## 4. The host-side interface, which is where the real work is

The gap between what the die does today and what a 200G lane needs is most
usefully stated as a **bus width**, because in that form it has an answer:

| core clock | bits per clock, one lane | verdict |
|---|---|---|
| 33.33 MHz (today) | 6,350 | not routable |
| 400 MHz | 529 | wide, normal for 100G-class |
| 800 MHz | 265 | wide, normal for 100G-class |

The current RTL moves **1 bit per clock at 33 MHz**. That is 33.3 Mbps per
lane and 533 Mbps across 16 channels, against a 3.2T target — a factor of
6,000, asserted as a test in `photonics/test_l02_l04.py` so it cannot
quietly drift.

**No PHY purchase fixes this.** At 33 MHz the die cannot source the bits.
Raising the core clock is a prerequisite, not an optimisation, and it is
work a design-services partner is well suited to.

What is already built: `rtl/link/nce_pcs_gearbox.sv`, the width conversion
between core and PHY, verified bit-exact across 64->32, 32->64 and the
non-integer 48->32, each under backpressure.

What is not built: KP4 FEC, alignment markers, lane deskew. A gearbox is
not a PCS.

---

## 5. Division of work

| | |
|---|---|
| **BUY or LICENSE** | Analog front end: driver, CDR, PLL, CTLE/DFE, serialiser. Not writable in open tools. |
| **BUILD** | PCS: KP4 FEC, gearbox, alignment, deskew. Ordinary synthesisable digital. |
| **FIX FIRST** | Core clock. Gates everything above regardless of what is bought. |
| **HAVE** | 74 RTL modules, one block hardened to clean DRC/LVS, device models for layers 1-7. |

---

## 6. Questions to settle before any scope is agreed

1. **Node and foundry.** Which, and is the PDK one we can hold a copy of?
2. **NRE, and what it covers.** Mask set, shuttle slot, engineering hours,
   how many respins.
3. **IP ownership.** Who owns RTL, layout and test collateral generated
   under the engagement. Our existing work is open; what we generate
   jointly should be settled in writing, not assumed.
4. **SerDes source.** Licensed, and from whom, or expected from us. This is
   usually the largest single line in a programme of this type, and the
   answer changes the budget more than the node does.
5. **Which rate.** 1.6T at 50 GBd, or 3.2T at 100 GBd. See section 2. The
   honest answer decides the process.

---

## 7. What we will not claim

- No silicon has been fabricated. There is a GDS and a submission package.
- Layers 1-7 are **physics models**, not hardware. They compute correct
  device behaviour and drive nothing.
- There is no SerDes, no PHY and no optical hardware in the repository.
- The 3.2T figure is a target. The implemented link runs at 533 Mbps
  across 16 channels, and the repository asserts that gap in a test rather
  than hiding it.
