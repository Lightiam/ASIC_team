# Independent Area Audit — tt_um_nce_neural_engine

Verification of the Tiny Tapeout submission audit, using cell areas read directly from
`sky130_fd_sc_hd__tt_025C_1v80.lib` rather than quoted figures.

---

## Build fixes — verified, all three are real

Checked against the files on disk, not taken on trust:

| Claim | Status |
|---|---|
| `nce_int8_register_mac_core.sv` + `nce_register_banks.sv` added to `info.yaml` | ✅ lines 34–35 |
| Same two added to `config.json`, `test/Makefile`, `run_tt_um_nce_neural_engine.sh` | ✅ 2 matches in each |
| `.github/workflows/gds.yaml` using `tinytapeout/tt-gds-action@v2` | ✅ correct action |
| `.github/workflows/test.yaml` | ✅ present |
| `uio_out[4..7]` driven with cmd_ready / resp_valid / engine_busy / engine_done | ✅ lines 112–115 |

The elaboration blocker I found (`nce_int8_register_mac_core` not part of the design) is
genuinely fixed. The dependency chain now closes:

```
tt_um_nce_neural_engine -> nce_axi_int8_top -> nce_int8_command_core
   -> nce_int8_register_mac_core -> { nce_int8_simd8_mac, nce_register_banks }
      -> nce_regfile_16x256  (x2: vector + matrix)
```

**Minor:** the comment block at `tt_um_nce_neural_engine.sv:35–39` still describes the
old mapping (`uio_out[7:4]: Status / error flags`) and now contradicts both the code and
`info.yaml`. Cosmetic, but it will mislead the next reader.

---

## ⛔ Area — the submission cannot close at 3×2 tiles

### Corrected cell areas

Read from the liberty file:

| Cell | Area |
|---|---|
| `sky130_fd_sc_hd__dfxtp_1` (DFF, no reset) | **20.019 µm²** |
| `sky130_fd_sc_hd__dfrtp_1` (DFF, async reset) | **25.024 µm²** |
| `sky130_fd_sc_hd__mux2_1` | **11.261 µm²** |

### The report's flop area is optimistic

The audit states 9,414 flops ≈ **173,100 µm²**, citing `dfrtp_1`. That implies
**18.39 µm² per flop** — below the smallest flip-flop in the entire library.

Recomputed with real numbers:

| Basis | Area |
|---|---|
| 9,414 × 20.019 (no-reset flop) | **188,461 µm²** |
| 9,414 × 25.024 (reset flop, as cited) | **235,576 µm²** |

So the true flop area is **26–36 % larger** than reported.

### The register-file read muxing is missing entirely

Each `nce_regfile_16x256` has **two asynchronous read ports**, each selecting one of 16
entries, 256 bits wide. That is a 16:1 mux per bit:

```
256 bits × 2 ports × 15 mux2 × 2 banks = 15,360 mux2 cells
15,360 × 11.261 µm² = 172,966 µm²
```

**The read multiplexers alone are four times the entire tile budget**, and they do not
appear anywhere in the audit's table.

### Budget versus reality

| | Area |
|---|---|
| Die (3×2 tiles) | 114,858 µm² |
| Core | 107,612 µm² |
| **Usable at 40 % utilisation** | **43,045 µm²** |
| Flops | 188,000 – 236,000 µm² |
| Register-file read muxing | ~173,000 µm² |
| FP32 datapath, AXI, FSM | not yet counted |
| **Realistic total** | **≈ 380,000 – 430,000 µm²** |

**That is roughly 9–10× over budget, not 4×.**

### It does not fit in *any* Tiny Tapeout tile size

The largest standard TT allocation is 8×2 tiles — about 306,000 µm² of die,
≈ 116,000 µm² usable at the same utilisation. The design is still ~3–4× too large for
the biggest tile TT offers.

---

## What actually has to change

This is an architectural problem, not a settings problem. Raising `FP_CORE_UTIL` or
`PL_TARGET_DENSITY_PCT` cannot recover a 10× gap.

The register banks are the whole problem: **8,192 of the 9,414 flops (87 %)**, plus all
15,360 mux cells. To fit ~43,000 µm² the total flop budget is roughly **1,200–1,500**,
leaving room for logic.

Options, cheapest first:

1. **Drop to one register bank.** Vector only, no matrix. Halves flops and muxing at a
   stroke — 4,096 flops, ~82,000 µm². Still over, but a third of the way.
2. **Cut the register count.** 16 → 4 entries: 4 × 256 × 1 bank = **1,024 flops
   ≈ 20,500 µm²**, and the mux collapses from 16:1 to 4:1 (3 mux2/bit instead of 15),
   ~1,536 cells ≈ 17,300 µm². Together ≈ 38,000 µm² — **fits**.
3. **Narrow the datapath.** 8 lanes → 2 lanes gives a 64-bit register. 16 × 64 × 1 bank
   = 1,024 flops with the same mux reduction. Keeps the register count, cuts SIMD width.
4. **Register file as SRAM macro.** Only viable if the shuttle offers a user macro at
   this tile size; on small TT tiles it generally does not.

Option 2 or 3 keeps the architecture recognisable and demonstrable in silicon. The
8-lane × 16-entry × 256-bit configuration is a simulation-scale design, not a 3×2 tile
design.

---

## Recommendation

The build now elaborates and CI will run, so **the submission will attempt a GDS build**
— and it will fail in placement, not in synthesis. Fix the area first: pick a scaled
configuration, re-run synthesis, and confirm the cell area lands under ~43,000 µm²
before pushing.

Everything else about this submission — pinout, `uio_oe`, `ena` handling, single clock
domain, cocotb harness, docs, CC0 licence — is in good shape.
