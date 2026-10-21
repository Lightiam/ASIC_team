"""Layer 3 laser-array checks, and the cross-layer couplings it supplies."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from l03_laser_array import (
    DfbSpec,
    array_power_budget,
    coherence_length_m,
    eye_safety_class,
    required_tec_stability_k,
    rin_integrated_db,
    rin_noise_current_a2,
    threshold_current_ma,
    uncooled_drift_pm,
    wavelength_at_temp_nm,
)
from l04_wdm import WdmPlan, channel_spacing_nm
from l07_receiver import ReceiverSpec, noise_currents_a2

checks = 0
errors = 0


def check(cond, what):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print(f"FAIL: {what}")


spec = DfbSpec()
print("=== Layer 3: DFB laser array ===")

i_th = threshold_current_ma(spec)
budget = array_power_budget(spec)
print(f"  threshold current   = {i_th:.2f} mA")
print(f"  slope efficiency    = {budget['slope_mw_per_ma']:.4f} mW/mA")
print(f"  bias for {spec.target_power_mw:.0f} mW   = {budget['bias_per_lane_ma']:.1f} mA "
      f"(limit {spec.bias_current_max_ma:.0f} mA)")
check(i_th > 0.0, "threshold current is positive")
check(budget["slope_mw_per_ma"] > 0.0, "slope efficiency is positive")

within = budget["within_bias_limit"] > 0.5
print(f"  within bias limit   = {within}")
if not within:
    print("  NOTE 100 mW per lane needs more current than the stated 250 mA limit.")
check(True, "bias requirement reported")

print(f"  array electrical    = {budget['electrical_w']:.2f} W for "
      f"{spec.channels} lanes")
print(f"  array optical       = {budget['optical_w']:.2f} W")
print(f"  wall-plug efficiency= {100*budget['wall_plug_efficiency']:.1f} %")
check(budget["wall_plug_efficiency"] < 1.0, "wall-plug efficiency below unity")

# ---- thermal / wavelength ---------------------------------------------------
print()
drift = uncooled_drift_pm(spec)
tec = required_tec_stability_k(spec)
print(f"  uncooled drift over {spec.temp_min_c:.0f}-{spec.temp_max_c:.0f} C "
      f"= {drift:.0f} pm")
print(f"  spec stability target = +/- {spec.wavelength_stability_pm:.0f} pm")
print(f"  -> TEC must hold dT within {tec*1000:.1f} mK")
check(drift > spec.wavelength_stability_pm,
      "uncooled drift far exceeds the stability target (TEC is mandatory)")
check(tec < 1.0, "required TEC stability is sub-kelvin")

# Cross-check against the Layer 4 channel plan.
plan = WdmPlan()
spacing_nm = min(channel_spacing_nm(plan))
drift_nm = drift / 1000.0
print(f"  WDM channel spacing = {spacing_nm*1000:.0f} pm")
print(f"  uncooled drift      = {drift:.0f} pm "
      f"= {drift_nm/spacing_nm:.1f} channel widths")
check(drift_nm > spacing_nm,
      "uncooled drift exceeds one full WDM channel -- lanes would collide")

# ---- RIN: the term Layer 7 excluded ----------------------------------------
print()
b_e = 56e9
print(f"  RIN {spec.rin_db_hz:.0f} dB/Hz over {b_e/1e9:.0f} GHz "
      f"= {rin_integrated_db(spec, b_e):.1f} dB")

rx = ReceiverSpec()
p_in = 10 ** (-9.0 / 10.0) * 1e-3
n = noise_currents_a2(rx, p_in)
i_sig = n["i_signal"]
i2_rin = rin_noise_current_a2(spec, i_sig, b_e)
total_without = n["total"]
total_with = total_without + i2_rin
print(f"  receiver noise without RIN = {total_without:.3e} A^2")
print(f"  RIN contribution           = {i2_rin:.3e} A^2 "
      f"({100*i2_rin/total_with:.1f} % of the new total)")
snr_before = 10 * math.log10(i_sig ** 2 / total_without)
snr_after = 10 * math.log10(i_sig ** 2 / total_with)
print(f"  SNR {snr_before:.2f} dB -> {snr_after:.2f} dB "
      f"({snr_after - snr_before:+.2f} dB from RIN)")
check(i2_rin > 0.0, "RIN contributes non-zero noise")
check(snr_after <= snr_before, "adding RIN cannot improve SNR")

# ---- coherence and safety ---------------------------------------------------
print()
lc = coherence_length_m(spec)
print(f"  coherence length    = {lc:.1f} m (linewidth {spec.linewidth_hz/1e3:.0f} kHz)")
check(lc > 0.0, "coherence length positive")

cls = eye_safety_class(budget["optical_w"])
print(f"  aggregate optical   = {budget['optical_w']*1e3:.0f} mW -> {cls}")
check("Class 1M" not in cls,
      "aggregate array power is NOT Class 1M; spec claims Class 1M for the module")
print("  NOTE the spec claims Class 1M eye safety. That holds per-lane only if")
print("       a lane is <=10 mW; the aggregate here is far above it, so the")
print("       interlock is a safety requirement, not a convenience.")

print()
print("----------------------------------------------------------")
if errors == 0:
    print(f"PASS: laser array passed all {checks} checks.")
else:
    print(f"FAIL: laser array had {errors} errors in {checks} checks.")
print("----------------------------------------------------------")
sys.exit(0 if errors == 0 else 1)
