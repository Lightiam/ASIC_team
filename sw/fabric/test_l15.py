"""Layer 15 Fabric OS control-plane checks.

The behaviours worth testing are the failure ones: does hysteresis stop
route flapping, does a degraded link get avoided rather than deleted, and
does the daemon halt honestly when no feasible placement exists.
"""

import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from l14_collective_opt import Demand, Fabric
from l15_fabric_os import (DaemonState, FabricOs, HealthPolicy, LinkHealth,
                           LinkTelemetry, classify)
from l16_l18_l21_l22 import MemoryMap

checks = errors = 0
def check(c, w):
    global checks, errors
    checks += 1
    if not c:
        errors += 1; print("FAIL:", w)

print("=== Layer 15: Fabric OS control plane ===")

fab = Fabric(nodes=4)
for i in range(4):
    fab.add(i, (i + 1) % 4, capacity_gbps=400.0, latency_ns=10.0)

os_ = FabricOs(fab, memory=MemoryMap(nodes=4, bytes_per_node=128 * 1024**3))
check(os_.state is DaemonState.INIT, "starts in INIT")
check(os_.discover(), "discovery succeeds on a populated fabric")
check(os_.state is DaemonState.READY, "reaches READY after discovery")

empty = FabricOs(Fabric(nodes=0))
check(not empty.discover(), "discovery fails on an empty fabric")
check(empty.state is DaemonState.HALTED, "empty fabric halts rather than pretending")

# ---- classification ------------------------------------------------------
p = HealthPolicy()
check(classify(LinkTelemetry(ber=0.0, optical_power_dbm=0.0), p) is LinkHealth.HEALTHY,
      "a clean link is healthy")
check(classify(LinkTelemetry(ber=1e-4, optical_power_dbm=0.0), p) is LinkHealth.DEGRADED,
      "BER 1e-4 is degraded")
check(classify(LinkTelemetry(ber=1e-2, optical_power_dbm=0.0), p) is LinkHealth.FAILED,
      "BER 1e-2 is failed")
check(classify(LinkTelemetry(ber=0.0, optical_power_dbm=-5.0), p) is LinkHealth.DEGRADED,
      "low optical power is degraded")

# ---- hysteresis ----------------------------------------------------------
print()
changed = [os_.observe(0, LinkTelemetry(ber=1e-4)) for _ in range(2)]
check(not any(changed), "two bad samples do NOT change state (hysteresis holds)")
check(os_.health[0] is LinkHealth.HEALTHY, "link still healthy after two samples")

third = os_.observe(0, LinkTelemetry(ber=1e-4))
check(third, "the third consecutive bad sample DOES change state")
check(os_.health[0] is LinkHealth.DEGRADED, "link is now degraded")
print(f"  hysteresis = {p.hysteresis} samples: state changed on sample 3, not 1")

# ---- degraded links are de-rated, not deleted ----------------------------
usable = os_.usable_fabric()
check(len(usable.links) == len(fab.links),
      "a degraded link is RETAINED (removing it can make routing infeasible)")
degraded_cap = usable.links[0].capacity_gbps
check(degraded_cap < fab.links[0].capacity_gbps,
      "the degraded link is de-rated so the optimiser avoids it when it can")
print(f"  degraded link de-rated {fab.links[0].capacity_gbps:.0f} -> "
      f"{degraded_cap:.0f} Gbps, still present")

# ---- planning ------------------------------------------------------------
print()
pl = os_.plan([Demand(0, 2, 100.0)])
check(pl.feasible, "a feasible demand is placed even with a degraded link")
check(os_.state is DaemonState.DEGRADED,
      "state reports DEGRADED while a link is impaired, not READY")
print(f"  state={os_.state.value} feasible={pl.feasible}")

# ---- failed link removed -------------------------------------------------
for _ in range(p.hysteresis):
    os_.observe(1, LinkTelemetry(ber=1e-2))
check(os_.health[1] is LinkHealth.FAILED, "sustained high BER marks the link failed")
check(len(os_.usable_fabric().links) == len(fab.links) - 1,
      "a FAILED link is removed from the usable fabric")

# ---- honest halt ---------------------------------------------------------
print()
tiny = Fabric(nodes=2)
tiny.add(0, 1, capacity_gbps=10.0, latency_ns=5.0)
t = FabricOs(tiny); t.discover()
pl2 = t.plan([Demand(0, 1, 5000.0)])
check(not pl2.feasible, "an impossible demand is reported infeasible")
check(t.state is DaemonState.HALTED,
      "the daemon HALTS rather than reporting a placement it cannot deliver")
print(f"  impossible demand -> state={t.state.value}, feasible={pl2.feasible}")

# ---- reroute counting ----------------------------------------------------
before = os_.reroute_count
os_.reroute([Demand(0, 2, 50.0)])
check(os_.reroute_count == before + 1, "reroutes are counted")

s = os_.summary()
print()
print("  summary:", {k: s[k] for k in ("state","links_total","links_healthy",
                                        "links_degraded","links_failed","reroutes")})
check(s["links_degraded"] >= 1 and s["links_failed"] >= 1,
      "summary reflects both degraded and failed links")

print()
print("----------------------------------------------------------")
print(("PASS: Fabric OS passed all %d checks." % checks) if errors == 0
      else ("FAIL: %d errors in %d checks." % (errors, checks)))
print("----------------------------------------------------------")
sys.exit(0 if errors == 0 else 1)
