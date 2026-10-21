# Fab package notes -- lightrail_dual_nce

Generated with `build_board.py` (KiCad 10 pcbnew), exported with `kicad-cli`.

## Verified

| Check | Result |
|---|---|
| Edge.Cuts closed | yes -- confirmed by parsing the Gerber, not the export dialog |
| Copper layers | 32/32, no inner layer missing |
| DRC | 0 violations, 0 unconnected |
| Board size | 420 x 350 mm (JLCPCB limit 656 x 586 mm) |
| Layer count | 32 (JLCPCB supports 1-32) |
| Drill | PTH + NPTH, Excellon, mm, with maps |

## Design rules

DRC constraints live in the **project** file (`.kicad_pro`), not the board.
Assigning `BOARD_DESIGN_SETTINGS` members through pcbnew and calling
`SaveBoard` does **not** persist them -- the values read back unchanged.
`apply_project_rules()` writes them where KiCad actually keeps them.

Set to the standard process: 0.15 mm clearance and track, 0.30 mm through
hole, 0.60 mm via, 0.13 mm annular ring, 0.15 mm silk clearance.

## Blockers before this can be ordered

1. **Megtron-7 is not offered by JLCPCB.** Their materials are FR-4 and
   Rogers/PTFE. The specification picks Megtron-7 for er ~3.3 and
   tand <= 0.002 at 20 GHz; FR-4 is roughly er 4.3 and tand 0.02, about ten
   times the loss. That changes the signal-integrity design, so this needs a
   fab that stocks Panasonic laminates.

2. **No components.** 0 footprints, 0 tracks, 0 holes. BOM and CPL are empty
   by construction. The board is a stackup, outline, die-site and VRM-phase
   skeleton -- there is nothing to assemble yet.

3. **Rotation table not needed yet**, but will be: JLCPCB library rotations
   disagree with KiCad footprint rotations per part, not as a global offset.
   Keep a correction table in this directory once parts are placed, and check
   every polarised and multi-pin part against the LCSC preview.

4. **32 layers at this size is not a standard-process quote.** Within
   capability, but expect a DFM review rather than an instant price.

5. **24 uohm PDN is not achievable on the board.** `photonics/l01_pdn.py`
   measures 296x over target across DC-100 MHz with 3320 decoupling
   capacitors. It has to be met on-die and in-package; this board carries the
   low-frequency envelope only.

## Megtron-7 is a functional requirement, not a preference

Recorded after `prelayout_check.py` quantified it. The earlier note said only
that JLCPCB does not stock Megtron-7 and that FR-4 is roughly 10x the loss.
That understated the problem: FR-4 does not carry the link at all.

At the 60 mm die-to-die gap, with 0.09 mm lines and a 10 dB trace budget:

| lane | Megtron-7 | FR-4 | required |
|---|---|---|---|
| 112G PAM4 (28 GHz) | 107.0 mm | 52.7 mm | 60 mm |
| 200G PAM4 (50 GHz) | 77.5 mm | 33.2 mm | 60 mm |

200G on FR-4 is short by 1.8x and stays short across the whole plausible
range of the loss model, so the material choice is settled by that row alone.
112G on FR-4 is genuinely indeterminate at this fidelity -- it moves to
64.0 mm under the optimistic bound of the conductor-loss term, crossing the
requirement. Do not quote the 112G row as a failure without a field solver.

Consequence for ordering: this board does not go to JLCPCB. It needs a
specialist HDI fab that stocks Megtron-7 or equivalent low-Df laminate and
runs a 16:1 through-via aspect ratio. The fab package in `fab/` is still
correct output and still worth keeping -- the Gerber and drill checks it
passed are fab-independent -- but the quote does not come from JLCPCB.
