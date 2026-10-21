"""Layer 14 checks: does measured routing actually beat the ring heuristic?

The specification's claim is that replacing static ring heuristics with
topology-aware placement recovers stranded capacity. That is testable: build
a fabric where one link is degraded, route it both ways, and compare.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from l14_collective_opt import Demand, Fabric, Demand as D, fingerprint, ring_placement, solve

checks = 0
errors = 0


def check(cond, what):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print(f"FAIL: {what}")


print("=== Layer 14: topology-aware collective placement ===")

# ---------------------------------------------------------------------------
# A 4-node ring where one hop is degraded. The ring heuristic must use it;
# the optimiser can route the other way round.
# ---------------------------------------------------------------------------
# The degraded hop must lie ON the ring path the heuristic will take,
# otherwise the comparison measures nothing. The ring routes by ascending
# node index, so a demand 0 -> 2 goes 0 -> 1 -> 2 and is forced through
# link 1 -> 2. That is the link to degrade.
fab = Fabric(nodes=4)
fab.add(0, 1, capacity_gbps=400.0, latency_ns=10.0)
fab.add(1, 2, capacity_gbps=50.0,  latency_ns=10.0)   # degraded, ON the ring path
fab.add(2, 3, capacity_gbps=400.0, latency_ns=10.0)
fab.add(3, 0, capacity_gbps=400.0, latency_ns=10.0)

# 300 Gbps from 0 to 2. The ring must push all of it through the 50 Gbps
# hop; the optimiser can send it the other way round, 0 -> 3 -> 2.
demands = [D(0, 2, 300.0)]

opt = solve(fab, demands)
ring = ring_placement(fab, demands)

print(f"  optimiser : feasible={opt.feasible} objective={opt.objective:.4f}")
print(f"  ring      : feasible={ring.feasible} objective={ring.objective:.4f}")
check(opt.feasible, "optimiser finds a feasible placement")
check(ring.feasible, "ring placement is constructible")
check(opt.objective <= ring.objective + 1e-9,
      "optimiser is no worse than the ring heuristic")

if opt.feasible and ring.feasible:
    gain = ring.objective - opt.objective
    print(f"  improvement = {gain:.4f} on the min-max congestion term")
    print(f"  worst link utilisation: optimiser {opt.link_utilisation.max():.3f}, "
          f"ring {ring.link_utilisation.max():.3f}")
    check(opt.link_utilisation.max() <= ring.link_utilisation.max() + 1e-9,
          "optimiser does not exceed the ring's worst link utilisation")
    if ring.link_utilisation.max() > 1.0 >= opt.link_utilisation.max():
        print("  NOTE the ring heuristic OVERSUBSCRIBES the degraded link "
              f"({ring.link_utilisation.max():.2f}x) while the optimiser does not.")

# ---------------------------------------------------------------------------
# Flow conservation must hold exactly for every demand.
# ---------------------------------------------------------------------------
if opt.feasible:
    ok = True
    for k, dem in enumerate(demands):
        for node in range(fab.nodes):
            out = sum(opt.flows[k, e] for e in fab.out_edges(node))
            inn = sum(opt.flows[k, e] for e in fab.in_edges(node))
            net = out - inn
            want = dem.gbps if node == dem.src else (-dem.gbps if node == dem.dst else 0.0)
            if abs(net - want) > 1e-6:
                ok = False
    check(ok, "flow conservation holds at every node for every demand")

    cap_ok = all(opt.flows[:, e].sum() <= fab.links[e].capacity_gbps + 1e-6
                 for e in range(len(fab.links)))
    check(cap_ok, "no link exceeds its capacity")

# ---------------------------------------------------------------------------
# A homogeneous fabric: the optimiser should match the ring, not beat it.
# If it claimed a gain here, the comparison would be rigged.
# ---------------------------------------------------------------------------
print()
even = Fabric(nodes=4)
for i in range(4):
    even.add(i, (i + 1) % 4, capacity_gbps=400.0, latency_ns=10.0)
d2 = [D(0, 1, 50.0), D(1, 2, 50.0), D(2, 3, 50.0)]
o2 = solve(even, d2)
r2 = ring_placement(even, d2)
print(f"  homogeneous fabric: optimiser={o2.objective:.4f} ring={r2.objective:.4f}")
check(abs(o2.objective - r2.objective) < 0.05,
      "on a homogeneous fabric the optimiser matches the ring (no false gain)")

# ---------------------------------------------------------------------------
# Infeasible demand must be reported, not silently truncated.
# ---------------------------------------------------------------------------
print()
tiny = Fabric(nodes=2)
tiny.add(0, 1, capacity_gbps=10.0, latency_ns=5.0)
imposs = solve(tiny, [D(0, 1, 1000.0)])
print(f"  over-capacity demand: feasible={imposs.feasible} ({imposs.message[:40]})")
check(not imposs.feasible, "a demand beyond total capacity is reported infeasible")

# ---------------------------------------------------------------------------
# fingerprint() from measured matrices.
# ---------------------------------------------------------------------------
print()
lat = np.array([[0, 12, 0], [12, 0, 40], [0, 40, 0]], dtype=float)
cap = np.array([[0, 400, 0], [400, 0, 100], [0, 100, 0]], dtype=float)
fp = fingerprint(lat, cap)
print(f"  fingerprint: {fp.nodes} nodes, {len(fp.links)} directed links")
check(len(fp.links) == 4, "fingerprint finds exactly the measured links")
check(all(l.capacity_gbps > 0 for l in fp.links), "all links carry capacity")

print()
print("----------------------------------------------------------")
if errors == 0:
    print(f"PASS: collective optimiser passed all {checks} checks.")
else:
    print(f"FAIL: collective optimiser had {errors} errors in {checks} checks.")
print("----------------------------------------------------------")
sys.exit(0 if errors == 0 else 1)
