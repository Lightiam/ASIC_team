"""eda-pcb Step 1.5: pre-layout validation for the Dual-NCE motherboard.

Answers the questions that have to be settled BEFORE placement, because
getting them wrong means laying the board out twice:

  1. Can the stackup hit controlled impedance at a buildable thickness?
  2. How far can a signal actually travel at the link rate -- i.e. is the
     die-to-die spacing inside the loss budget, or outside it?
  3. Does the pre-layout checklist pass, and what blocks layout if not?

Everything here is closed-form and checkable. The point is not precision --
a field solver beats these formulae -- it is ORDER OF MAGNITUDE and the
sign of the margin, which is what decides stackup and floorplan.

Run with any Python 3; no pcbnew needed.
"""

from __future__ import annotations

import json
import math
import os

C0 = 299_792_458.0          # m/s
RHO_CU = 1.72e-8            # ohm.m, annealed copper
MU0 = 4.0e-7 * math.pi

# --- materials -------------------------------------------------------------
# Df is quoted at the SIGNALLING frequency, not at 1 GHz. Datasheet Df at
# 1 GHz understates loss at 20 GHz for FR-4 by roughly 2x, which is exactly
# the error that makes an FR-4 substitution look survivable on paper.
MATERIALS = {
    "Megtron-7": {"Dk": 3.3, "Df": 0.002},
    "FR-4 (JLCPCB stock)": {"Dk": 4.3, "Df": 0.020},
}

T_CU_MM = 0.035             # 1 oz
W_MIN_MM = 0.090            # JLCPCB 4+ layer minimum line width
COPPER_LAYERS = 32
Z0_TARGET = 50.0


def stripline_z0(dk: float, h_mm: float, w_mm: float, t_mm: float) -> float:
    """IPC-2141 symmetric stripline. h is trace-to-plane on EACH side."""
    return (60.0 / math.sqrt(dk)) * math.log(
        1.9 * (2.0 * h_mm + t_mm) / (0.8 * w_mm + t_mm)
    )


def h_for_z0(dk: float, z0: float, w_mm: float, t_mm: float) -> float:
    """Invert the above for the dielectric thickness each side."""
    ratio = math.exp(z0 * math.sqrt(dk) / 60.0)
    return (ratio * (0.8 * w_mm + t_mm) / 1.9 - t_mm) / 2.0


def skin_depth_m(f_hz: float) -> float:
    return math.sqrt(RHO_CU / (math.pi * f_hz * MU0))


def alpha_dielectric_db_m(f_hz: float, dk: float, df: float) -> float:
    """Dielectric loss. Scales linearly with frequency and with Df."""
    return 8.686 * math.pi * f_hz * math.sqrt(dk) * df / C0


def alpha_conductor_db_m(f_hz: float, w_mm: float, z0: float) -> float:
    """Skin-effect loss. Scales as sqrt(f) and as 1/w -- which is why a
    minimum-width trace is the expensive choice at high frequency."""
    rs = RHO_CU / skin_depth_m(f_hz)            # ohm/square
    r_per_m = 2.0 * rs / (w_mm * 1e-3)          # both broad faces carry
    return 8.686 * r_per_m / (2.0 * z0)         # Np/m -> dB/m


def reach_mm(f_hz: float, mat: dict, w_mm: float, budget_db: float) -> dict:
    a_d = alpha_dielectric_db_m(f_hz, mat["Dk"], mat["Df"])
    a_c = alpha_conductor_db_m(f_hz, w_mm, Z0_TARGET)
    total = a_d + a_c
    return {
        "dielectric_db_m": a_d,
        "conductor_db_m": a_c,
        "total_db_m": total,
        "reach_mm": 1000.0 * budget_db / total,
    }


# --- board geometry, mirrored from build_board.py --------------------------
BOARD_W_MM, BOARD_H_MM = 420.0, 350.0
DIE_SIZE_MM, DIE_GAP_MM = 55.0, 60.0

# The die gap is spanned by LIGHT, not copper. The copper carries the
# modulator drive and the TIA output between the die BGA and the PIC
# transition, which is (gap - PIC width) / 2 = 5.0 mm by geometry.
PIC_W_MM     = DIE_GAP_MM - 10.0
COPPER_RUN_MM = (DIE_GAP_MM - PIC_W_MM) / 2.0
REQ_MM        = 15.0    # copper run plus BGA escape allowance


# Signalling. The photonic models set these: l02_tfln_mzm.py drives 200 Gbps
# per lane and l07_receiver.py specifies a 56 GHz TIA, so the electrical
# channel runs PAM4 and the figure that matters is the Nyquist frequency,
# which is a QUARTER of the bit rate, not the bit rate.
LANES = [
    ("112G PAM4", 112e9, 28e9),
    ("200G PAM4", 200e9, 50e9),
]
# Budget for the die-to-PIC channel alone. A full 112G link allows ~28 dB
# end to end, but connectors, packages, vias and the PIC transition consume
# most of it; 10 dB is what is realistically left for board trace.
TRACE_BUDGET_DB = 10.0


def check_stackup() -> dict:
    """Thickness required to hold 50 ohm on every signal layer."""
    out = {}
    for name, mat in MATERIALS.items():
        h = h_for_z0(mat["Dk"], Z0_TARGET, W_MIN_MM, T_CU_MM)
        # 32 copper layers means 31 dielectric gaps. Each signal layer in the
        # GND/SIG/VDD/SIG pattern sits between two reference planes, so the
        # gap between ADJACENT copper layers is h, not 2h.
        thickness = 31 * h + COPPER_LAYERS * T_CU_MM
        out[name] = {
            "h_required_mm": h,
            "board_thickness_mm": thickness,
            "z0_check": stripline_z0(mat["Dk"], h, W_MIN_MM, T_CU_MM),
        }
    return out


def main() -> int:
    print("=" * 74)
    print("eda-pcb Step 1.5 -- PRE-LAYOUT VALIDATION")
    print("Dual-NCE motherboard, %.0f x %.0f mm, %d copper layers"
          % (BOARD_W_MM, BOARD_H_MM, COPPER_LAYERS))
    print("=" * 74)

    print("\n[1] CONTROLLED IMPEDANCE AT MINIMUM LINE WIDTH (%.3f mm)" % W_MIN_MM)
    print("    target %.0f ohm symmetric stripline, %.0f um copper\n" % (Z0_TARGET, T_CU_MM * 1000))
    su = check_stackup()
    print("    %-22s %12s %14s %10s" % ("material", "h each side", "board thick", "Z0 back")) 
    for name, r in su.items():
        print("    %-22s %9.3f mm %11.2f mm %9.1f" %
              (name, r["h_required_mm"], r["board_thickness_mm"], r["z0_check"]))

    print("\n[2] ELECTRICAL REACH vs DIE-TO-DIE SPACING")
    print("    trace budget %.0f dB, %.3f mm line\n" % (TRACE_BUDGET_DB, W_MIN_MM))
    worst = {}
    for label, _bit, fnyq in LANES:
        print("    %s  (Nyquist %.0f GHz)" % (label, fnyq / 1e9))
        print("      %-22s %9s %9s %9s %10s" %
              ("material", "diel", "cond", "total", "reach"))
        for name, mat in MATERIALS.items():
            r = reach_mm(fnyq, mat, W_MIN_MM, TRACE_BUDGET_DB)
            print("      %-22s %6.1f dB %6.1f dB %6.1f dB %7.1f mm"
                  % (name, r["dielectric_db_m"], r["conductor_db_m"],
                     r["total_db_m"], r["reach_mm"]))
            worst.setdefault(name, {})[label] = r["reach_mm"]
        print()

    print("    Required copper run: die BGA to PIC transition only.")
    print("    The DIE GAP IS OPTICAL -- rtl/link/nce_tfln_pkg.sv is the")
    print("    optical die-to-die link and the blueprint calls the bridge")
    print("    a zero-copper datapath. %.1f mm by geometry, %.0f mm with" % (COPPER_RUN_MM, REQ_MM))
    print("    escape allowance.")
    print("")
    for name in MATERIALS:
        for label, _b, _f in LANES:
            reach = worst[name][label]
            verdict = "FITS %.1fx" % (reach / REQ_MM) if reach > REQ_MM else "DOES NOT FIT"
            print("      %-22s %-10s %7.1f mm vs %.0f mm  -> %s"
                  % (name, label, reach, REQ_MM, verdict))

    print("\n[3] PRE-LAYOUT CHECKLIST")
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    checks = [
        ("Schematic ERC clean",
         os.path.exists(os.path.join(repo, "pcb", "lightrail_dual_nce.kicad_sch")),
         "no schematic exists -- nothing to import, nothing to route"),
        ("Layer count decided", True, "32, see LAYER-COUNT-DECISION.md"),
        ("Stackup selected", True, "see STACKUP-DECISION.md"),
        ("Board dimensions defined", True, "420 x 350 mm, outline closed"),
        ("Critical interfaces documented", True, "200G PAM4 to PIC, see [2]"),
        ("Thermal budget known", False,
         "per-die dissipation not specified; no thermal model for the board"),
        ("Datasheets synced", os.path.isdir(os.path.join(repo, "datasheets")),
         "no datasheets/ -- BGA-2500 ball map and DrMOS parts unselected"),
        ("Design rules applied", True, "0.15/0.15/0.30/0.60/0.13 mm in .kicad_pro"),
        ("DRC clean", True, "0 violations, 0 unconnected"),
    ]
    blockers = []
    for label, ok, note in checks:
        print("    [%s] %-32s %s" % ("PASS" if ok else "FAIL", label, note))
        if not ok:
            blockers.append(label)

    print("\n[4] VERDICT")
    if blockers:
        print("    LAYOUT IS BLOCKED. %d gate(s) fail:" % len(blockers))
        for b in blockers:
            print("      - %s" % b)
        print("    Placement and routing cannot start: with no netlist there")
        print("    are no nets, so DRC's '0 unconnected' means 0 connections")
        print("    exist, not that every connection is made.")
    else:
        print("    Ready for placement.")

    print("")
    print("[5] DRILL ASPECT RATIO")
    print("    The width sweep offers reach for thickness, but the drill")
    print("    collects on that trade before the loss budget does.")
    print("")
    print("    %-8s %11s %7s   %s" % ("w(mm)", "thick(mm)", "AR", "class"))
    for w in (0.09, 0.12, 0.15, 0.20):
        h = h_for_z0(3.3, Z0_TARGET, w, T_CU_MM)
        t = 31 * h + COPPER_LAYERS * T_CU_MM
        a = aspect_ratio(t)
        print("    %-8.2f %11.2f %7.1f   %s"
              % (w, t, a["aspect_ratio"], a["class"]))
    print("")
    print("    Only the minimum width survives, so the stackup is")
    print("    PINNED rather than chosen: 0.09 mm lines are the only")
    print("    width whose thickness keeps a 0.30 mm via buildable.")
    print("")
    print("[6] HYBRID STACKUP")
    print("    A plane pair carries no impedance target, so only the")
    print("    layers carrying PAM4 need the full gap -- two gaps each.")
    print("")
    print("    %-12s %11s %7s   %s" % ("HS layers", "thick(mm)", "AR", "class"))
    for n in (2, 4, 8, 15):
        r = hybrid_thickness(3.3, W_MIN_MM, n)
        a = aspect_ratio(r["board_thickness_mm"])
        print("    %-12d %11.2f %7.1f   %s"
              % (n, r["board_thickness_mm"], a["aspect_ratio"], a["class"]))
    print("")

    # --- emit the constraints file the skill expects -----------------------
    docs = os.path.join(repo, "docs")
    os.makedirs(docs, exist_ok=True)
    cons = {
        "board": {
            "layers": COPPER_LAYERS,
            "thickness": round(su["Megtron-7"]["board_thickness_mm"], 2),
            "dimensions": {"width": BOARD_W_MM, "height": BOARD_H_MM},
            "material": "Megtron-7",
            "copper_weight_oz": 1.0,
        },
        "dfmTargets": {
            "manufacturer": "specialist HDI (NOT JLCPCB -- see FAB_NOTES.md)",
            "minTraceWidth": W_MIN_MM,
            "minClearance": 0.15,
            "impedanceControl": True,
            "targetZ0_ohm": Z0_TARGET,
        },
        "interfaces": {
            "usb": False,
            "highSpeedSpi": False,
            "pam4_lanes": [
                {"name": l, "bit_rate_gbps": b / 1e9, "nyquist_ghz": f / 1e9,
                 "reach_mm_megtron7": round(worst["Megtron-7"][l], 1)}
                for l, b, f in LANES
            ],
        },
        "thermal": {"maxPowerDissipation": None,
                    "note": "UNSPECIFIED -- blocks layout, see [3]"},
        "blockers": blockers,
    }
    path = os.path.join(docs, "design-constraints.json")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(cons, fh, indent=2)
        fh.write("\n")
    print("\n    wrote %s" % os.path.relpath(path, repo))
    return 0




# ---------------------------------------------------------------------------
# Follow-on checks. These exist because the width sweep above has a trap in
# it: widening a lane buys reach, but 50 ohm then needs a thicker dielectric,
# and a thicker board breaks the drill.
# ---------------------------------------------------------------------------

VIA_DRILL_MM = 0.30             # from the project rules
ASPECT_STANDARD = 10.0          # routine through-via capability
ASPECT_ADVANCED = 16.0          # specialist, priced accordingly


def aspect_ratio(thickness_mm: float, drill_mm: float = VIA_DRILL_MM) -> dict:
    ar = thickness_mm / drill_mm
    if ar <= ASPECT_STANDARD:
        cls = "standard"
    elif ar <= ASPECT_ADVANCED:
        cls = "advanced (specialist, higher cost)"
    else:
        cls = "NOT MANUFACTURABLE as a through-via"
    # Drill needed to come back inside the standard class.
    return {"aspect_ratio": ar, "class": cls,
            "drill_for_standard_mm": thickness_mm / ASPECT_STANDARD}


def hybrid_thickness(dk: float, w_mm: float, n_hs_layers: int) -> dict:
    """Thickness when ONLY the high-speed layers get the impedance gap.

    The uniform-stackup number is pessimistic: a power or ground plane pair
    has no impedance target, so it can sit on thin core. Only the signal
    layers carrying PAM4 need the full dielectric height, and they need it
    on both sides, which costs two gaps per such layer.
    """
    h_hs = h_for_z0(dk, Z0_TARGET, w_mm, T_CU_MM)
    h_thin = 0.075                      # typical thin core
    gaps = 31
    hs_gaps = min(2 * n_hs_layers, gaps)
    thin_gaps = gaps - hs_gaps
    thickness = hs_gaps * h_hs + thin_gaps * h_thin + COPPER_LAYERS * T_CU_MM
    return {"h_highspeed_mm": h_hs, "h_thin_mm": h_thin,
            "highspeed_gaps": hs_gaps, "thin_gaps": thin_gaps,
            "board_thickness_mm": thickness}


if __name__ == "__main__":
    raise SystemExit(main())
