# Dual-NCE blueprint vs. the board as built

Written to settle whether the KiCad board actually implements the Dual-NCE
Motherboard Schematic Blueprint, feature by feature. Three of these were
divergences and one was an error in my own analysis.

## Matches

| blueprint | board | evidence |
|---|---|---|
| Dual AI Compute Units (BGA-2500) | U1, U2 | 50 x 50 at 1.1 mm pitch = 2500 balls each, 55 mm package |
| 1.6T/3.2T TFLN Photonic Bridge | PIC1 | 16 WDM channels x 200G PAM4 = 3.2T, from `photonics/l04_wdm.py` |
| Zero-copper datapath | no die-to-die bus | the only high-speed copper is die -> PIC; see the correction below |
| VRM Arrays, 48 DrMOS phases | U100..U147 | 48 placed, two banks of 24 |
| 1000 A+ delivery | checked, consistent | see the arithmetic below |

### 1000 A is consistent with the ball count and the phase count

Both independently check out, which is worth stating because the PDN fails
elsewhere and it would be easy to assume it fails here too.

- 1042 VDD balls per die at 1000 A is **0.96 A per ball**. A 0.6 mm ball
  waist is 0.283 mm2, so **3.4 A/mm2** -- comfortably under the 10-20 A/mm2
  where electromigration becomes life-limiting.
- 48 phases at 1000 A is **20.8 A per phase**. Typical DrMOS parts are rated
  50-70 A, so the phase count is not marginal.

The PDN problem is the 24 uohm impedance target (`photonics/l01_pdn.py`,
296x over), not current capacity. Those are different failures and only the
second one is ruled out here.

## Divergences found and fixed

**VRM phase count was half.** `build_board.py` set `VRM_PHASES = 24` and
placed 24 markers. The blueprint annotates 48 DrMOS phases. The code comment
said "24 phases dual rail (48 DrMOS in the blueprint)", which reads like a
reconciliation but is not one -- 24 markers were drawn, not 48. Now 48.

**Placeholder silkscreen outlived its purpose.** `build_board.py` drew
rectangles and text to mark where the dies and VRM phases would go. Once real
footprints occupied those positions the markers became duplicate artwork
sitting on copper, worth 294 DRC violations. Deleted.

## Correction to my own analysis

**The die-to-die path is optical, and I analysed it as copper.**

I measured insertion-loss reach against the 60 mm die-to-die gap and
concluded that FR-4 "does not carry the link" and that Megtron-7 is a
functional requirement. Both claims are withdrawn.

The blueprint labels the bridge a **zero-copper datapath**, and
`rtl/link/nce_tfln_pkg.sv` is titled "TFLN **optical** die-to-die link",
stating that each endpoint drives one modulator lane and samples one
photodetector lane. The 60 mm span is crossed by light.

The real copper requirement is die BGA to PIC transition: 5.0 mm by geometry,
15 mm with escape allowance. Against that every material clears, FR-4
included, by at least 2.2x. `STACKUP-DECISION.md` carries the full retraction
and what survives it -- the drill-aspect finding is unaffected, because
aspect ratio does not depend on trace length.

## Not implemented

**CVD diamond liquid cooling overlay.** Present in the blueprint, absent from
the board. It is not a PCB layer -- it is a substrate and cooling structure
over the dies -- so it would not appear in the stackup. It matters anyway:
CVD diamond conducts at roughly 2000 W/m.K against copper's 400, so it is the
reason a die dissipating at this scale is coolable at all. Modelling it needs
a per-die power number, which is still the open gate.

**Edge I/O.** The blueprint shows cage connectors along the left edge and
connector banks around the periphery. None are placed. They do not block
die-to-PIC routing, so they are deferred rather than missing.

## Open question: board aspect ratio

The blueprint's board reads as roughly 1.7:1. The board is 420 x 350 mm,
which is 1.2:1. `build_board.py` attributes those dimensions to "the
specification", but no file in `docs/spec/` states them, so the attribution
is unverified and the mismatch is unresolved.

This is not cosmetic. Aspect ratio sets how far the VRM banks sit from the
dies, which is the dominant term in plane spreading resistance -- the one
PDN term currently inside budget. Flagged rather than changed, because
guessing a board outline to match a rendering would be the wrong way to
settle it.
