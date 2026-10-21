# Stackup: Megtron-7, 0.09 mm lines, 0.110 mm dielectric, 4.54 mm

All numbers here are produced by `pcb/prelayout_check.py`. Re-run it rather
than trusting this file.

## The stackup is pinned, not chosen

The obvious move for a lossy channel is to widen the trace: conductor loss
goes as `1/w`, so a wider lane reaches further. The width sweep says so:

| w (mm) | dielectric each side | board thickness | 200G reach | via aspect |
|---|---|---|---|---|
| 0.09 | 0.110 mm | 4.54 mm | 77.5 mm | 15.1:1 advanced |
| 0.12 | 0.139 mm | 5.43 mm | 99.1 mm | 18.1:1 **not buildable** |
| 0.15 | 0.168 mm | 6.32 mm | 119.0 mm | 21.1:1 **not buildable** |
| 0.20 | 0.216 mm | 7.81 mm | 148.9 mm | 26.1:1 **not buildable** |

Holding 50 ohm at a wider trace needs a taller dielectric, 31 gaps of it, and
the board grows faster than the reach does. A 0.30 mm through-via tops out
around 16:1, so every width above the minimum breaks the drill before the loss
budget is even reached.

So 0.09 mm is not the best width. It is the **only** width, and the reason to
record that is to stop a future reviewer from "improving" the loss by widening
the lanes.

## Does the minimum width actually close?

Yes, with margin, which is the only reason the design is viable at all.

| lane | Nyquist | Megtron-7 reach | required | margin |
|---|---|---|---|---|
| 112G PAM4 | 28 GHz | 107.0 mm | 60 mm | 78% |
| 200G PAM4 | 50 GHz | 77.5 mm | 60 mm | 29% |

"Required" is the 60 mm die-to-die gap from `pcb/build_board.py`, which is a
floor: it counts no escape routing, no detour, and no via stubs. The 29% on
the 200G lane is the number to watch during placement, because every
millimetre of routing detour spends it.

## Conductor loss dominates, and that has a consequence

At 50 GHz on Megtron-7 the split is 16.5 dB/m dielectric against 112.5 dB/m
conductor. The channel is **copper-limited, not resin-limited**. Two things
follow:

- Copper roughness matters more than the Df on the datasheet. Specify
  VLP or HVLP foil; standard foil roughness can add tens of percent at
  50 GHz and this model does not include it.
- A better laminate than Megtron-7 buys very little. The remaining
  dielectric term is 13% of the total, so even a perfect dielectric
  improves reach by about 15%.

## Why FR-4 is a functional blocker, not a cost question

JLCPCB does not stock Megtron-7. Substituting their FR-4 is not a downgrade
in margin, it removes the margin:

| lane | FR-4 reach | required | verdict |
|---|---|---|---|
| 112G PAM4 | 52.7 mm | 60 mm | short, but see caveat |
| 200G PAM4 | 33.2 mm | 60 mm | short by 1.8x |

**Caveat, stated because it changes one conclusion.** The conductor-loss term
uses `R = 2 Rs / w`, which overestimates: published 3.5 mil stripline data
runs roughly 40% below this form because it ignores how current actually
distributes across the trace. Scaling the conductor term from 1.0 down to 0.6
moves FR-4 at 112G from 52.7 mm to 64.0 mm, which crosses the 60 mm line. So:

- **200G on FR-4 fails robustly** -- 33 to 39 mm across the whole range,
  never within 1.5x of the requirement.
- **112G on FR-4 is indeterminate** at this fidelity. It straddles the
  requirement and needs a field solver or a measured coupon to call.

The 200G result is enough to settle the material choice on its own.

## Stated stackup

- Material: Megtron-7, Dk 3.3, Df 0.002 at 20 GHz
- Copper: 1 oz (35 um), VLP or HVLP foil required
- 32 copper layers, 31 dielectric gaps at 0.110 mm
- Finished thickness 4.54 mm
- Through-via 0.30 mm drill, 15.1:1 -- advanced process
- Target 50 ohm single-ended symmetric stripline

## Open option: hybrid stackup

A plane pair has no impedance target and can sit on 0.075 mm thin core, so
only the layers actually carrying PAM4 need the 0.110 mm gap, two gaps each.
That recovers thickness and aspect ratio:

| PAM4 layers | thickness | aspect ratio |
|---|---|---|
| 2 | 3.59 mm | 12.0:1 |
| 4 | 3.73 mm | 12.4:1 |
| 8 | 4.01 mm | 13.4:1 |
| 15 (all signal layers) | 4.51 mm | 15.0:1 |

This is worth taking: at 4 PAM4 layers it buys 0.8 mm and drops the aspect
ratio from 15.1:1 to 12.4:1, well clear of the 16:1 ceiling. It cannot be
committed yet because the lane count per die is not fixed -- that comes from
the schematic, which does not exist. Recorded as the first stackup revision
to make once it does.

---

# CORRECTION: the die-to-die requirement above is wrong

Everything above measured the copper reach against a **60 mm die-to-die run**.
There is no such run. The die-to-die datapath is optical.

Two independent sources say so, and both predate this analysis:

- The blueprint labels the bridge "1.6T/3.2T TFLN Interconnect Photonic
  Bridge (**Zero-copper datapath**)".
- `rtl/link/nce_tfln_pkg.sv` is titled "TFLN **optical** die-to-die link" and
  states: "The optical portion is outside this RTL: each endpoint drives one
  modulator lane and samples one photodetector lane."

I read the geometry out of `build_board.py` and treated the die gap as a
copper trace. It is the span the light crosses.

## The real copper requirement

The copper runs from the die BGA to the PIC's electrical transition only:
5.0 mm by geometry (60 mm gap minus the 50 mm PIC, halved), plus BGA escape.
15 mm is a generous allowance for that.

| material | lane | reach | vs 15 mm | vs 60 mm (as claimed) |
|---|---|---|---|---|
| Megtron-7 | 112G PAM4 | 107.0 mm | fits 7.1x | fits |
| Megtron-7 | 200G PAM4 | 77.5 mm | fits 5.2x | fits |
| FR-4 | 112G PAM4 | 52.7 mm | fits 3.5x | **claimed fail** |
| FR-4 | 200G PAM4 | 33.2 mm | fits 2.2x | **claimed fail** |

Every combination clears the real requirement, FR-4 included, with at least
2.2x margin.

## What this retracts

- "FR-4 does not carry the link" -- **retracted**. It carries the copper
  portion comfortably. The link it fails to carry is not made of copper.
- "Megtron-7 is a functional requirement, not a preference" -- **retracted
  as stated**. The insertion-loss budget does not select the laminate.
- The 29% margin on the 200G lane, described as "the number to watch during
  placement" -- that margin was against the wrong distance. The real margin
  is 5.2x.

## What survives

The physics is unchanged; only the distance it was applied to was wrong.

- The stackup is still pinned by the drill. Aspect ratio does not depend on
  trace length, so the finding that only 0.09 mm lines keep a 0.30 mm via
  buildable stands exactly as written.
- The channel is still conductor-limited (112 dB/m vs 16 dB/m at 50 GHz),
  so VLP/HVLP foil still matters more than the laminate's Df.
- The 112G FR-4 sensitivity caveat is now moot rather than resolved: it
  straddled a requirement that does not exist.

## What actually selects the laminate

Not loss. The open candidates are thermal expansion match to the CVD diamond
substrate, dimensional stability across 32 layers at 420 x 350 mm, and
lamination behaviour at 4.54 mm. None of those is computed yet, so the
material choice is currently **open**, not settled -- which is a weaker and
more honest position than either of my previous two.
