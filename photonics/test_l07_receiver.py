"""Layer 7 receive-chain checks: does the quoted BER follow from the parts?"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from l07_receiver import (
    ReceiverSpec,
    ase_power_w,
    ber_nrz,
    ber_pam4,
    dominant_noise,
    noise_currents_a2,
    sensitivity_dbm,
    snr_db,
)

checks = 0
errors = 0


def check(cond, what):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print(f"FAIL: {what}")


spec = ReceiverSpec()
print("=== Layer 7: SOA + TIA receive chain ===")
print(f"  SOA gain {spec.soa_gain_db} dB, NF {spec.soa_noise_figure_db} dB")
print(f"  TIA {spec.tia_bandwidth_hz/1e9:.0f} GHz, "
      f"{spec.tia_input_noise_a_rthz*1e12:.0f} pA/sqrt(Hz)")

p_ase = ase_power_w(spec)
print(f"  ASE power in 100 GHz: {p_ase*1e6:.3f} uW")
check(p_ase > 0.0, "SOA generates non-zero ASE")

print()
print("  P_in      SNR     dominant   BER(NRZ)    BER(PAM4)")
for dbm in (-20.0, -15.0, -12.0, -9.0, -6.0, -3.0):
    p = 10 ** (dbm / 10.0) * 1e-3
    s = snr_db(spec, p)
    print("  %6.1f dBm %6.1f dB  %-9s %.2e   %.2e"
          % (dbm, s, dominant_noise(spec, p), ber_nrz(spec, p), ber_pam4(spec, p)))

# SNR must rise with input power.
check(snr_db(spec, 1e-4) > snr_db(spec, 1e-6), "SNR increases with input power")

# PAM4 must always be worse than NRZ at the same power.
p_test = 10 ** (-9.0 / 10.0) * 1e-3
check(ber_pam4(spec, p_test) > ber_nrz(spec, p_test),
      "PAM4 BER is worse than NRZ at equal power")

sens_nrz = sensitivity_dbm(spec, 1e-6, pam4=False)
sens_pam4 = sensitivity_dbm(spec, 1e-6, pam4=True)
print()
print(f"  sensitivity @ BER 1e-6, NRZ : {sens_nrz:7.2f} dBm")
print(f"  sensitivity @ BER 1e-6, PAM4: {sens_pam4:7.2f} dBm")
penalty = sens_pam4 - sens_nrz
print(f"  PAM4 penalty                : {penalty:7.2f} dB")
check(penalty > 0.0, "PAM4 costs sensitivity relative to NRZ")
check(penalty > 5.0, "PAM4 penalty is substantial (theory: ~9.5 dB)")

# Which noise term dominates, and does the TIA spec matter?
p_op = 10 ** (-9.0 / 10.0) * 1e-3
n = noise_currents_a2(spec, p_op)
tot = n["total"]
print()
print("  noise breakdown at -9 dBm input:")
for k in ("tia", "shot", "sig_sp", "sp_sp"):
    print(f"    {k:8s} {100.0*n[k]/tot:5.1f} %")
dom = dominant_noise(spec, p_op)
print(f"  dominant: {dom}")
check(dom in ("tia", "sig_sp", "shot", "sp_sp"), "a dominant noise term is identified")

# Does tightening the TIA actually help, or is the SOA the limit?
better = ReceiverSpec(tia_input_noise_a_rthz=5e-12)
gain = snr_db(better, p_op) - snr_db(spec, p_op)
print(f"  improving TIA 15 -> 5 pA/sqrt(Hz) changes SNR by {gain:+.2f} dB")
if gain < 0.5:
    print("  NOTE the TIA is NOT the limit here; the SOA's beat noise is.")
    print("       Tightening the TIA specification buys almost nothing.")
check(gain >= 0.0, "a quieter TIA never makes SNR worse")

# Removing the SOA entirely, for comparison.
no_soa = ReceiverSpec(soa_gain_db=0.0, soa_noise_figure_db=0.0)
print(f"  SNR with SOA    : {snr_db(spec, p_op):6.2f} dB")
print(f"  SNR without SOA : {snr_db(no_soa, p_op):6.2f} dB")

print()
print("----------------------------------------------------------")
if errors == 0:
    print(f"PASS: receiver chain passed all {checks} checks.")
else:
    print(f"FAIL: receiver chain had {errors} errors in {checks} checks.")
print("----------------------------------------------------------")
sys.exit(0 if errors == 0 else 1)
