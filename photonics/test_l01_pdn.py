import os, sys
sys.path.insert(0, os.path.join("nce_fix_clone","photonics"))
import numpy as np
from l01_pdn import Pdn, CapBank, capacitors_required, stackup_summary

checks=errors=0
def check(c,w):
    global checks,errors
    checks+=1
    if not c: errors+=1; print("FAIL:",w)

print("=== Layer 1: PDN impedance against the 24 uohm target ===")
pdn = Pdn()
print("  Z_target = %.1f uohm  (%.1f V x %.0f%% / %.0f A)"
      % (pdn.z_target_ohm*1e6, pdn.vdd_v, 100*pdn.ripple_fraction, pdn.current_a))
check(abs(pdn.z_target_ohm - 24e-6) < 1e-7, "target arithmetic matches the spec (24 uohm)")

# A serious decoupling network.
pdn.banks = [
    CapBank("bulk 470uF",   20,  470e-6, 5e-3,   3e-9),
    CapBank("ceramic 100uF",100, 100e-6, 2e-3,   1e-9),
    CapBank("ceramic 10uF", 400,  10e-6, 2e-3, 500e-12),
    CapBank("ceramic 1uF",  800,   1e-6, 3e-3, 250e-12),
    CapBank("package 100nF",2000,100e-9, 5e-3,  50e-12),
]
tot = sum(b.count for b in pdn.banks)
print("  decoupling: %d capacitors across %d banks" % (tot, len(pdn.banks)))
for b in pdn.banks:
    print("    %-16s n=%-5d SRF=%8.2f MHz" % (b.name, b.count, b.srf_hz()/1e6))

f, z = pdn.profile()
print()
print("  |Z| across frequency:")
for probe in (1e3, 1e4, 1e5, 1e6, 1e7, 1e8):
    zi = float(np.abs(pdn.impedance(np.array([probe])))[0])
    flag = "" if zi <= pdn.z_target_ohm else "  <- OVER TARGET"
    print("    %7.3f MHz : %9.2f uohm%s" % (probe/1e6, zi*1e6, flag))

fw, zw = pdn.worst_in_band(100e6)
print()
print("  worst in DC-100 MHz band: %.2f uohm at %.3f MHz" % (zw*1e6, fw/1e6))
print("  target                  : %.2f uohm" % (pdn.z_target_ohm*1e6))
print("  exceeded by             : %.1fx" % (zw/pdn.z_target_ohm))
check(zw > 0, "impedance computed")

viol = pdn.first_violation_hz()
if viol: print("  first exceeds target at : %.3f MHz" % (viol/1e6))

print()
print("  capacitors needed at 100 MHz purely from ESL:")
for esl, lbl in ((50e-12,"package 50 pH"),(250e-12,"0402 250 pH"),(10e-12,"on-die 10 pH")):
    n = capacitors_required(pdn.z_target_ohm, 100e6, esl)
    print("    %-16s %9d caps" % (lbl, n))
n_pkg = capacitors_required(pdn.z_target_ohm, 100e6, 50e-12)
check(n_pkg > 1000, "hitting 24 uohm at 100 MHz needs an impractical cap count")

s = stackup_summary()
print()
print("  stackup: %d layers, %d power-plane pairs, %.3f m^2, interplane C = %.1f nF"
      % (s["layers"], s["power_plane_pairs"], s["board_area_m2"], s["interplane_capacitance_nf"]))
check(s["interplane_capacitance_nf"] > 0, "interplane capacitance computed")

print()
print("----------------------------------------------------------")
print(("PASS: PDN model passed all %d checks." % checks) if errors==0
      else ("FAIL: %d errors in %d checks." % (errors,checks)))
print("----------------------------------------------------------")
sys.exit(0 if errors==0 else 1)
