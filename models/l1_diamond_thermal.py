"""Layer 1: CVD diamond heat spreader -- 2D steady-state thermal model.

WHAT THIS COMPUTES AND WHAT IT ASSUMES
--------------------------------------
Steady-state heat diffusion across a heat spreader bonded to an 800 W die,
solved on a finite-difference grid:

    k*t*(d2T/dx2 + d2T/dy2) + q(x,y) - h*(T - T_fluid) = 0

with q(x,y) the areal power density from the TDP map, and h the effective
convective coefficient of the cold plate, h = 1 / (R_conv * A).

It compares a silicon spreader (k = 149 W/m.K) against CVD synthetic
diamond (k = 2000 W/m.K). The point of a high-k spreader is LATERAL
SPREADING: it turns a concentrated hotspot into something the cold plate
can take across its whole face. That is what this measures.

NO RESULT IS ASSERTED IN ADVANCE. An earlier version of this analysis was
specified as "prove the hotspot drops from >38.5 C to <=4.2 C", then
reported 10.45 C to 4.52 C against a bound that had moved to 5.0 C. A model
written to reach a number cannot fail, so this one computes the number and
prints whatever it gets. The self-tests below check PHYSICS, not outcomes.

BOUNDARY CONDITIONS, AND WHY THE EARLIER ONES WERE WRONG
--------------------------------------------------------
A previous version implied a die-to-ambient resistance of 0.015 K/W, which
is 3-5x better than anything that exists; it was not counting the TIM, the
spreader or the cold plate. The convective resistance here is 0.04 K/W,
which is a real direct-die liquid cold plate. Sanity: no spreader, however
good, can beat P * R_conv = 800 * 0.04 = 32 K of rise above the fluid.
That floor is asserted as a test.

Run:  python l1_diamond_thermal.py
"""

from __future__ import annotations

import math
import sys

import numpy as np

# ---------------------------------------------------------------------------
# Geometry and materials
# ---------------------------------------------------------------------------
# Chiplet, not the whole accelerator. 8.00 mm2 is the measured size of
# Core 16 plus the stack cluster (scripts/area_estimate.ys), so the die is
# 2.83 mm square.
DIE_MM = 8.0 ** 0.5            # 2.828 mm -> 8.00 mm2
SPREADER_T_MM = 0.5            # heat spreader thickness
GRID = 192                     # cells per side

T_FLUID_C = 25.0               # cold plate fluid inlet

# Direct-to-chip microchannel cold plate, specified as a heat transfer
# COEFFICIENT. The model works in thermal resistance, so R = 1/(h*A). That
# conversion is the whole argument below, because h alone says nothing
# until it is multiplied by the area it acts over -- and this die is small.
H_CONV_W_M2K = 50_000.0
R_CONV_KW = 1.0 / (H_CONV_W_M2K * (DIE_MM * 1e-3) ** 2)

K_SILICON = 149.0              # W/(m.K)
K_DIAMOND = 2000.0             # W/(m.K) CVD synthetic

TDP_W = 25.0

# TDP map. Fractions of the die, as (name, power_W, x0, x1, y0, y1) in
# normalised die coordinates. The GEMM array is the hotspot that matters:
# 450 W into roughly a quarter of the die area.
POWER_MAP = [
    ("SIMD GEMM / ternary array", 14.0, 0.28, 0.72, 0.28, 0.72),
    ("HBM4 interface",             5.0, 0.00, 0.14, 0.10, 0.90),
    ("200G SerDes drivers",        3.0, 0.86, 1.00, 0.10, 0.90),
    ("Logic core / LIF / CSR",     3.0, 0.00, 1.00, 0.90, 1.00),
]


def build_power_density(n: int, die_m: float) -> np.ndarray:
    """Areal power density q(x,y) in W/m2 from the TDP map."""
    q = np.zeros((n, n), dtype=float)
    cell_a = (die_m / n) ** 2
    for _name, watts, x0, x1, y0, y1 in POWER_MAP:
        i0, i1 = int(round(y0 * n)), int(round(y1 * n))
        j0, j1 = int(round(x0 * n)), int(round(x1 * n))
        cells = (i1 - i0) * (j1 - j0)
        if cells <= 0:
            raise ValueError("empty power region")
        q[i0:i1, j0:j1] += watts / (cells * cell_a)
    return q


def solve_temperature(k: float, q: np.ndarray, die_m: float,
                      t_m: float, r_conv: float, t_fluid: float) -> dict:
    """Direct sparse solve of the steady-state field.

    Edges are insulated (no heat leaves the sides of the spreader), which is
    the conservative choice: any real package loses some heat laterally, so
    this cannot flatter the result. An insulated edge is imposed by
    mirroring, and a mirrored neighbour equals the cell itself, so each
    missing neighbour moves one coupling term onto the diagonal.

    This was an SOR iteration first. At 192x192 it needed too many sweeps to
    converge, and the k -> infinity limit check -- the one that proves the
    model collapses to P*R_conv -- is the worst case for an iterative
    method, because near-infinite conductivity couples every cell to every
    other. A direct solve has no convergence question to argue about.
    """
    import scipy.sparse as sp
    import scipy.sparse.linalg as spla

    n = q.shape[0]
    d = die_m / n
    area = die_m * die_m
    h = 1.0 / (r_conv * area)          # W/(m2.K)

    a_nb = k * t_m / (d * d)           # neighbour coupling

    idx = np.arange(n * n).reshape(n, n)
    rows, cols, vals = [], [], []
    diag = np.full((n, n), h, dtype=float)

    for di, dj in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        src = idx[max(0, -di):n - max(0, di), max(0, -dj):n - max(0, dj)]
        dst = idx[max(0, di):n - max(0, -di), max(0, dj):n - max(0, -dj)]
        rows.append(src.ravel())
        cols.append(dst.ravel())
        vals.append(np.full(src.size, -a_nb))
        # Every cell owes 4*a_nb to the diagonal; a real neighbour accounts
        # for one of them here, and a missing (mirrored) one is simply never
        # subtracted, which is exactly the insulated-edge condition.
        m = np.zeros((n, n), dtype=float)
        m[max(0, -di):n - max(0, di), max(0, -dj):n - max(0, dj)] = a_nb
        diag += m

    rows.append(idx.ravel())
    cols.append(idx.ravel())
    vals.append(diag.ravel())

    A = sp.csr_matrix((np.concatenate(vals),
                       (np.concatenate(rows), np.concatenate(cols))),
                      shape=(n * n, n * n))
    b = (q + h * t_fluid).ravel()
    T = spla.spsolve(A.tocsc(), b).reshape(n, n)

    resid_vec = b - A.dot(T.ravel())
    resid = resid_vec.reshape(n, n)
    it = 1
    delta = 0.0
    # Energy balance: all injected power must leave through the cold plate.
    p_in = float(np.sum(q) * d * d)
    p_out = float(np.sum(h * (T - t_fluid)) * d * d)

    return {
        "T": T,
        "method": "direct sparse",
        "converged": True,
        "max_delta": delta,
        "max_residual_W_m2": float(np.max(np.abs(resid))),
        "power_in_W": p_in,
        "power_out_W": p_out,
        "peak_C": float(np.max(T)),
        "mean_C": float(np.mean(T)),
        "min_C": float(np.min(T)),
        "hotspot_dT_C": float(np.max(T) - np.mean(T)),
    }


def main() -> int:
    die_m = DIE_MM * 1e-3
    t_m = SPREADER_T_MM * 1e-3
    q = build_power_density(GRID, die_m)

    print("=" * 70)
    print("Layer 1: CVD diamond heat spreader, 2D steady-state")
    print("=" * 70)
    print("die            : %.1f x %.1f mm (%.0f mm2)" % (DIE_MM, DIE_MM, DIE_MM ** 2))
    print("spreader       : %.2f mm thick" % SPREADER_T_MM)
    print("grid           : %d x %d" % (GRID, GRID))
    print("TDP            : %.0f W (%.2f W/mm2 average)" % (TDP_W, TDP_W / DIE_MM ** 2))
    print("cold plate     : fluid %.1f C, h_conv %.0f W/m2K" % (T_FLUID_C, H_CONV_W_M2K))
    print("               -> h*A = %.4f W/K, R_conv = %.3f K/W"
          % (H_CONV_W_M2K * (DIE_MM * 1e-3) ** 2, R_CONV_KW))
    print()
    print("TDP map:")
    for name, w, x0, x1, y0, y1 in POWER_MAP:
        frac = (x1 - x0) * (y1 - y0)
        print("  %-28s %5.0f W over %4.1f%% of the die -> %6.2f W/mm2"
              % (name, w, 100 * frac, w / (frac * DIE_MM ** 2)))
    print()

    floor = T_FLUID_C + TDP_W * R_CONV_KW
    print("Thermodynamic floor: no spreader can beat T_fluid + P*R_conv")
    print("  = %.1f + %.0f * %.3f = %.1f C uniform" % (T_FLUID_C, TDP_W, R_CONV_KW, floor))
    print()

    results = {}
    print("%-22s %9s %9s %9s %10s %7s" %
          ("material", "peak C", "mean C", "hotspot", "method", "conv"))
    for label, k in (("silicon (k=149)", K_SILICON), ("CVD diamond (k=2000)", K_DIAMOND)):
        r = solve_temperature(k, q, die_m, t_m, R_CONV_KW, T_FLUID_C)
        results[label] = r
        print("%-22s %9.2f %9.2f %9.2f %10s %7s"
              % (label, r["peak_C"], r["mean_C"], r["hotspot_dT_C"],
                 r["method"], "yes" if r["converged"] else "NO"))

    si = results["silicon (k=149)"]
    di = results["CVD diamond (k=2000)"]
    print()
    print("DIAMOND vs SILICON")
    print("  peak junction   : %.2f C -> %.2f C   (%+.2f C)"
          % (si["peak_C"], di["peak_C"], di["peak_C"] - si["peak_C"]))
    print("  hotspot spread  : %.2f C -> %.2f C   (%+.2f C)"
          % (si["hotspot_dT_C"], di["hotspot_dT_C"],
             di["hotspot_dT_C"] - si["hotspot_dT_C"]))
    print()
    print("  Datacenter silicon is usually operated below ~90-105 C junction.")
    for label, r in (("silicon", si), ("diamond", di)):
        v = "MEETS" if r["peak_C"] <= 85.0 else "FAILS"
        d = "MEETS" if r["hotspot_dT_C"] <= 3.0 else "FAILS"
        print("    %-8s peak %7.2f C -> %s 85 C | hotspot %6.2f C -> %s 3.0 C"
              % (label, r["peak_C"], v, r["hotspot_dT_C"], d))

    print()
    print("SELF-CHECKS (physics, not outcomes)")
    checks = errors = 0

    for label, r in results.items():
        checks += 1
        if not r["converged"]:
            errors += 1
            print("  FAIL [converge/%s]: max delta %.3g" % (label, r["max_delta"]))
        checks += 1
        rel = abs(r["power_out_W"] - r["power_in_W"]) / TDP_W
        if rel > 1e-6:
            errors += 1
            print("  FAIL [energy/%s]: in %.3f W out %.3f W (%.2g rel)"
                  % (label, r["power_in_W"], r["power_out_W"], rel))
        checks += 1
        if r["power_in_W"] < TDP_W * 0.999 or r["power_in_W"] > TDP_W * 1.001:
            errors += 1
            print("  FAIL [tdp/%s]: power map integrates to %.2f W, expected %.0f"
                  % (label, r["power_in_W"], TDP_W))
        checks += 1
        if r["mean_C"] < floor - 0.05 or r["mean_C"] > floor + 0.05:
            errors += 1
            print("  FAIL [floor/%s]: mean %.2f C, thermodynamic floor %.2f C"
                  % (label, r["mean_C"], floor))

    # Higher conductivity must spread better. This is the only ordering the
    # model is allowed to assume, and it follows from the equation itself.
    checks += 1
    if di["hotspot_dT_C"] >= si["hotspot_dT_C"]:
        errors += 1
        print("  FAIL [ordering]: k=2000 did not spread better than k=149")

    # Limit check: as k -> infinity the field must collapse to the floor.
    big = solve_temperature(1.0e6, q, die_m, t_m, R_CONV_KW, T_FLUID_C)
    checks += 1
    if abs(big["peak_C"] - floor) > 0.5:
        errors += 1
        print("  FAIL [limit]: k->inf gave peak %.2f C, floor is %.2f C"
              % (big["peak_C"], floor))
    else:
        print("  k->infinity limit: peak %.2f C vs floor %.2f C -- correct"
              % (big["peak_C"], floor))

    print()
    print("-" * 70)
    if errors == 0:
        print("PASS: thermal model passed all %d checks." % checks)
    else:
        print("FAIL: thermal model had %d errors in %d checks." % (errors, checks))
    print("-" * 70)
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
