import sys, os, numpy as np
sys.path.insert(0, "/src/photonics")
from l06_memristor_crossbar import (CrossbarSpec, quantise_conductance, ideal_currents,
                                    simulate, relative_error, effective_bits)
rng = np.random.default_rng(3)
print("=== Layer 6: does I = G^T V actually hold on a real crossbar? ===")
print("    (spec states Kirchhoff MVM; this adds wire resistance and solves it)")
print()
print("%-8s %-10s %-14s %-14s %-10s" % ("size","wire_ohm","worst_rel_err","eff_bits","verdict"))
for n in (4, 8, 16, 32):
    for rw in (0.0, 2.5):
        spec = CrossbarSpec(rows=n, cols=n, wire_ohm_per_cell=rw)
        w = rng.random((n, n))
        g = quantise_conductance(spec, w)
        v = np.full(n, spec.read_voltage)
        meas = simulate(spec, g, v)
        ideal = ideal_currents(g, v)
        err = relative_error(meas, ideal)
        bits = effective_bits(err)
        verdict = "exact" if err < 1e-9 else ("ok" if bits >= 8 else "DEGRADED")
        print("%-8s %-10.1f %-14.3e %-14.1f %-10s" % (f"{n}x{n}", rw, err, bits, verdict))
