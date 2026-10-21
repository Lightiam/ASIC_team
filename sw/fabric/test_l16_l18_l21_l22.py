"""Checks for Layers 16, 18, 21 and 22."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from l16_l18_l21_l22 import (
    MemoryMap,
    TenantPartition,
    expert_load,
    load_imbalance,
    prefill_decode_split,
    reconfiguration_penalty,
    route_tokens,
    schedule_guarantee,
)

checks = 0
errors = 0


def check(cond, what):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print(f"FAIL: {what}")


# ---------------------------------------------------------------- Layer 16
print("=== Layer 16: provable scheduling ===")
weights = [0.4, 0.3, 0.2, 0.1]
g = schedule_guarantee(weights, deadline_slots=5)
print(f"  slots={g.slots} utilisation={g.utilisation:.3f} "
      f"max_delay={g.max_delay_slots} slots deadline_met={g.deadline_met}")
check(g.slots == 4, "slot count matches the decomposition")
check(g.deadline_met, "a 5-slot deadline is met by a 4-slot schedule")

tight = schedule_guarantee(weights, deadline_slots=2)
check(not tight.deadline_met, "a 2-slot deadline is correctly NOT met")

# The >=90% claim against real reconfiguration time.
print()
print("  utilisation once optical switching time is counted:")
for switch_ns, slot_us in ((50.0, 1.0), (50.0, 10.0), (500.0, 1.0), (500.0, 10.0)):
    u = reconfiguration_penalty(weights, switch_ns / 1000.0, slot_us)
    flag = "" if u >= 0.90 else "   <- below the 90% claim"
    print(f"    switch {switch_ns:5.0f} ns, slot {slot_us:5.1f} us -> "
          f"{100*u:5.1f} %{flag}")
u_fast = reconfiguration_penalty(weights, 0.05, 1.0)
u_slow = reconfiguration_penalty(weights, 0.5, 1.0)
check(u_fast > u_slow, "slower switching reduces utilisation")
check(u_slow < 0.90,
      "a 500 ns switch on a 1 us slot CANNOT reach the 90% utilisation claim")
print("  NOTE the >=90% claim is only reachable when slot period greatly")
print("       exceeds switching time. It is a scheduling choice, not a given.")

# ---------------------------------------------------------------- Layer 18
print()
print("=== Layer 18: multi-tenant isolation ===")
part = TenantPartition(wavelengths=16, slots=8)
check(part.assign("alpha", {0, 1, 2, 3}, {0, 1, 2, 3}), "tenant alpha assigned")
check(part.assign("beta", {4, 5, 6, 7}, {0, 1, 2, 3}),
      "tenant beta assigned on different wavelengths, same slots")
check(part.assign("gamma", {0, 1}, {4, 5}),
      "tenant gamma may reuse alpha's wavelengths in different slots")

clash = part.assign("delta", {0, 1}, {0, 1})
check(not clash,
      "a tenant sharing BOTH wavelength and slot with alpha is REFUSED")
check(part.isolated(), "all accepted tenants are mutually isolated")
print(f"  tenants={len(part.tenants)} isolated={part.isolated()} "
      f"utilisation={100*part.utilisation():.1f} %")

check(not part.assign("bad", {99}, {0}), "out-of-range wavelength refused")
check(not part.assign("bad2", {0}, {99}), "out-of-range slot refused")

# ---------------------------------------------------------------- Layer 21
print()
print("=== Layer 21: unified memory pooling ===")
mm = MemoryMap(nodes=1024, bytes_per_node=128 * 1024**3)   # 128 GiB per node
print(f"  pool = {mm.nodes} nodes x 128 GiB = {mm.total_bytes/1024**4:.0f} TiB")
check(mm.total_bytes == 1024 * 128 * 1024**3, "pool size is the product")

node, off = mm.locate(0)
check((node, off) == (0, 0), "address 0 maps to node 0 offset 0")
node, off = mm.locate(mm.bytes_per_node + 4096)
check((node, off) == (1, 4096), "address past node 0 maps into node 1")

try:
    mm.locate(mm.total_bytes)
    check(False, "address past the pool must raise")
except IndexError:
    check(True, "address past the pool raises rather than wrapping")

check(mm.access_latency_ns(0, 0) == 100.0, "local access is 100 ns")
check(mm.access_latency_ns(mm.bytes_per_node, 0) == 450.0, "remote access is 450 ns")

print("  effective bandwidth vs locality (harmonic mean):")
for f in (1.0, 0.9, 0.5, 0.0):
    bw = mm.effective_bandwidth_gbps(f)
    print(f"    {100*f:5.1f} % local -> {bw:7.1f} Gbps")
bw90 = mm.effective_bandwidth_gbps(0.9)
bw100 = mm.effective_bandwidth_gbps(1.0)
check(bw90 < bw100, "any remote traffic reduces effective bandwidth")
loss = 1.0 - bw90 / bw100
check(loss > 0.35,
      "10 % remote traffic costs more than a third of effective bandwidth")
print(f"  NOTE a 'unified' pool is only useful if accesses stay local: 10 %")
print(f"       remote traffic already costs {100*loss:.0f} % of bandwidth, because")
print(f"       time adds, not bandwidth. (An arithmetic mean would claim")
print(f"       {0.9*3200 + 0.1*400:.0f} Gbps here -- overstating it by "
      f"{100*((0.9*3200+0.1*400)/bw90 - 1):.0f} %.)")

# ---------------------------------------------------------------- Layer 22
print()
print("=== Layer 22: MoE dispatch ===")
rng = np.random.default_rng(11)
n_tok, n_exp = 4096, 64

balanced = rng.normal(size=(n_tok, n_exp)) * 0.1
idx, w = route_tokens(balanced, top_k=2)
check(idx.shape == (n_tok, 2), "top-2 routing returns two experts per token")
check(np.allclose(w.sum(axis=1), 1.0), "routing weights sum to 1 per token")
imb_bal = load_imbalance(idx, n_exp)
print(f"  balanced gate: load imbalance = {imb_bal:.3f}x")
check(imb_bal < 1.5, "a near-uniform gate gives low imbalance")

skewed = rng.normal(size=(n_tok, n_exp)) * 0.1
skewed[:, 0] += 5.0            # one very popular expert
idx2, _ = route_tokens(skewed, top_k=2)
imb_skew = load_imbalance(idx2, n_exp)
print(f"  skewed gate  : load imbalance = {imb_skew:.3f}x")
check(imb_skew > imb_bal, "a skewed gate raises imbalance")
print(f"  -> with {imb_skew:.1f}x imbalance, the all-to-all waits on one expert")
print(f"     and roughly {100*(1-1/imb_skew):.0f} % of expert capacity idles.")

split = prefill_decode_split(seq_len=4096, batch=1, d_model=4096, gen_tokens=1)
print(f"  prefill/decode FLOPs ratio at seq=4096, 1 token: {split['ratio']:.0f}x")
check(split["ratio"] > 1000.0,
      "prefill dominates decode by orders of magnitude (hence disaggregation)")

print()
print("----------------------------------------------------------")
if errors == 0:
    print(f"PASS: upper control plane passed all {checks} checks.")
else:
    print(f"FAIL: upper control plane had {errors} errors in {checks} checks.")
print("----------------------------------------------------------")
sys.exit(0 if errors == 0 else 1)
