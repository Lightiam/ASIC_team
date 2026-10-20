"""Checks for the Layer 2 modulator model and the Layer 4 WDM plan.

Each specification target is checked against the model, and where the model
disagrees with the specification that is reported rather than smoothed over.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import math

from l02_tfln_mzm import (
    TflnMzmSpec,
    extinction_ratio_db,
    insertion_loss_db,
    link_budget_db,
    pam4_levels,
    phase_shift,
    transmission,
    velocity_mismatch_bandwidth_hz,
)
from l04_wdm import (
    WdmPlan,
    channel_spacing_nm,
    crosstalk_penalty_db,
    grid_discrepancy_nm,
    itu_wavelengths_nm,
    osnr_budget_db,
    spec_wavelengths_nm,
    summarise,
)

checks = 0
errors = 0


def check(cond, what):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print(f"FAIL: {what}")


print("=== Layer 2: TFLN Mach-Zehnder modulator ===")
spec = TflnMzmSpec()

print(f"  Vpi.L          = {spec.vpi_l_v_cm} V.cm")
print(f"  Vpi @ {spec.length_cm} cm   = {spec.vpi_v:.3f} V")
check(abs(spec.vpi_v - 1.8) < 1e-9, "Vpi at 1 cm equals Vpi.L")

# A drive of exactly Vpi must produce pi radians.
check(abs(phase_shift(spec, spec.vpi_v) - math.pi) < 1e-12,
      "driving Vpi gives exactly pi radians")

# Null and peak of the transfer function.
t_null = transmission(spec, spec.vpi_v, bias_rad=0.0)
t_peak = transmission(spec, 0.0, bias_rad=0.0)
print(f"  T(0 V, null bias)   = {t_peak:.6f}")
print(f"  T(Vpi, null bias)   = {t_null:.3e}")
check(abs(t_peak - 1.0) < 1e-12, "zero drive at null bias transmits fully")
check(t_null < 1e-20, "Vpi drive extinguishes")

er = extinction_ratio_db(spec, 0.0, spec.vpi_v, bias_rad=0.0)
print(f"  ideal extinction    = {er:.1f} dB  (spec target > 20 dB)")
check(er > 20.0, "ideal extinction exceeds the 20 dB target")

il = insertion_loss_db(spec)
print(f"  insertion loss      = {il:.3f} dB "
      f"(2 facets {2*spec.facet_loss_db:.2f} + splitters "
      f"{2*spec.splitter_loss_db:.2f} + propagation "
      f"{spec.alpha_db_cm*spec.length_cm:.2f})")
check(il > 2 * spec.facet_loss_db, "insertion loss includes more than facets")

print("  PAM4 levels (uniform voltage steps, quadrature bias):")
levels = pam4_levels(spec)
for sym, v, t in levels:
    print(f"    symbol {sym}:  V = {v:+.3f}  T = {t:.4f}")
gaps = [levels[i + 1][2] - levels[i][2] for i in range(3)]
spread = max(gaps) - min(gaps)
print(f"    optical level spacing varies by {spread:.4f} "
      f"-> eyes are NOT equal without pre-distortion")
check(spread > 1e-3,
      "cos^2 transfer makes uniform voltage steps give unequal optical levels")

# Bandwidth: the limit the spec omits.
for length_cm, label in ((1.0, "1.0 cm"), (0.5, "0.5 cm"), (0.3, "0.3 cm")):
    bw = velocity_mismatch_bandwidth_hz(length_cm)
    print(f"  velocity-mismatch BW @ {label}: {bw/1e9:.1f} GHz")
bw_1cm = velocity_mismatch_bandwidth_hz(1.0)
print(f"  spec claims 100 GHz at Vpi.L = 1.8 V.cm")
check(bw_1cm < 100e9,
      "100 GHz is NOT reachable at 1 cm with a 0.2 index mismatch "
      "(shorter electrode or better index matching required)")

budget = link_budget_db(spec)
print(f"  link budget: launch {budget['laser_dbm']:.1f} dBm, "
      f"total loss {budget['total_loss_db']:.2f} dB, "
      f"received {budget['received_dbm']:.2f} dBm, "
      f"margin {budget['margin_db']:.2f} dB")
check(budget["margin_db"] > 0.0, "link closes with positive margin")

print()
print("=== Layer 4: WDM plane ===")
plan = WdmPlan()
s = summarise(plan)

itu = itu_wavelengths_nm(plan)
sp = spec_wavelengths_nm(plan)
print(f"  channels            = {plan.channels} on a {plan.grid_ghz:.0f} GHz grid")
print(f"  ITU wavelengths     = {itu[0]:.3f} .. {itu[-1]:.3f} nm")
print(f"  spec wavelengths    = {sp[0]:.3f} .. {sp[-1]:.3f} nm")

spacings = channel_spacing_nm(plan)
print(f"  actual nm spacing   = {min(spacings):.4f} .. {max(spacings):.4f} nm "
      f"(spec assumes a constant 0.8)")
check(max(spacings) - min(spacings) > 1e-4,
      "a uniform-frequency grid does NOT give uniform nm spacing")

worst = s["worst_grid_error_nm"]
print(f"  worst grid error    = {worst*1000:.2f} pm "
      f"(spec's uniform-nm plan vs true ITU grid)")
check(worst > 0.0, "the spec's nm-uniform plan differs from the ITU grid")

cap = s["capacity_gbps_simplex"]
print(f"  capacity            = {cap/1000:.1f} Tbps simplex, "
      f"{s['capacity_gbps_dual_socket']/1000:.1f} Tbps dual-socket")
check(abs(cap - 3200.0) < 1e-6,
      "16 lanes x 200 Gbps = 3.2 Tbps simplex")
print("  NOTE the spec states 8 lanes x 200 Gbps = 1.6 Tbps simplex,")
print("       but also specifies a 16-channel comb. 16 channels give 3.2 Tbps")
print("       simplex, so the lane count and channel count disagree.")

pen = s["crosstalk_penalty_db"]
print(f"  crosstalk penalty   = {pen:.4f} dB with all {plan.channels} channels lit")
check(pen > 0.0, "a fully loaded comb carries a non-zero crosstalk penalty")

osnr = osnr_budget_db(plan, launch_dbm_per_ch=0.0, noise_figure_db=5.5,
                      span_loss_db=10.0)
print(f"  OSNR after one span = {osnr:.1f} dB (0.1 nm reference)")
check(osnr > 15.0, "OSNR adequate for PAM4 after one span")

print()
print("----------------------------------------------------------")
if errors == 0:
    print(f"PASS: photonic models passed all {checks} checks.")
else:
    print(f"FAIL: photonic models had {errors} errors in {checks} checks.")
print("----------------------------------------------------------")
sys.exit(0 if errors == 0 else 1)
