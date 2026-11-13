"""Tests for Layer 21: disaggregated memory pool.

These check the properties the layer claims, including the ones that are
supposed to FAIL: an out-of-range address and a write from a non-owner must
both raise, because a pool that silently accepts either is worse than no
pool at all.
"""

from __future__ import annotations

import sys

from l21_memory_pool import (POOL_BASE, PAGE_SIZE, MemoryPool, MemoryPoolError,
                             PoolConfig, measure_lookup_ns)

checks = 0
errors = 0


def check(cond: bool, msg: str) -> None:
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print("FAIL [%s]" % msg)


print("=" * 66)
print("Layer 21: disaggregated coherent memory pool")
print("=" * 66)

pool = MemoryPool(PoolConfig(nodes=4, local_node=0, wdm_channels=16,
                             pages_per_node=1024))
base, size = pool.map_pool()
print("pool base      : 0x%016X" % base)
print("pool size      : %d pages x %d KiB = %.1f GiB"
      % (pool.total_pages, PAGE_SIZE // 1024, size / 2 ** 30))
print("nodes          : %d, local node %d" % (pool.cfg.nodes, pool.cfg.local_node))
print("WDM channels   : %d" % pool.cfg.wdm_channels)
print()

check(base == POOL_BASE, "pool base is the documented constant")
check(size == pool.total_pages * PAGE_SIZE, "size is pages x page size")

# --- resolution -----------------------------------------------------------
d0 = pool.resolve(base)
check(d0.node_id == 0 and d0.is_local, "page 0 resolves to the local node")
check(d0.channel_id == -1, "a local page uses no optical channel")

d1 = pool.resolve(base + PAGE_SIZE)
check(d1.node_id == 1 and not d1.is_local, "page 1 resolves to a remote node")
check(0 <= d1.channel_id < pool.cfg.wdm_channels, "remote page gets a WDM channel")
print("page 0 -> node %d %s" % (d0.node_id, "local" if d0.is_local else "remote"))
print("page 1 -> node %d channel %d" % (d1.node_id, d1.channel_id))

# Every page must resolve, and the spread must be even.
hist = [0] * pool.cfg.nodes
chans = set()
for p in range(pool.total_pages):
    d = pool.resolve(pool.page_addr(p))
    hist[d.node_id] += 1
    if not d.is_local:
        chans.add((d.node_id, d.channel_id))
check(len(set(hist)) == 1, "pages are spread evenly across nodes")
check(all(0 <= c < pool.cfg.wdm_channels for _n, c in chans),
      "every remote channel index is in range")
print("per-node pages : %s" % hist)
print("distinct (node,channel) routes: %d" % len(chans))

# --- addresses outside the pool must be refused ---------------------------
for bad, label in ((base - 1, "below the pool"),
                   (base + size, "one past the end"),
                   (0, "a null address")):
    try:
        pool.resolve(bad)
        check(False, "resolve accepted an address %s" % label)
    except MemoryPoolError:
        check(True, "refused %s" % label)
print("out-of-range addresses refused: yes")

# --- single-writer ownership ----------------------------------------------
addr = pool.page_addr(5)
owner = pool.resolve(addr).node_id
pool.acquire_write(addr, owner)
try:
    pool.check_write(addr, owner)
    check(True, "owner may write its own page")
except MemoryPoolError:
    check(False, "owner was refused a write to its own page")

other = (owner + 1) % pool.cfg.nodes
try:
    pool.check_write(addr, other)
    check(False, "a non-owner was allowed to write")
except MemoryPoolError:
    check(True, "non-owner write refused")

try:
    pool.acquire_write(addr, other)
    check(False, "ownership was stolen from the current owner")
except MemoryPoolError:
    check(True, "ownership cannot be stolen")
print("single-writer ownership enforced: yes")

# --- lookup cost ----------------------------------------------------------
ns = measure_lookup_ns(pool)
print()
print("lookup cost    : %.0f ns per resolve, measured in this process" % ns)
print("                 This is the LOOKUP, not a memory access. Remote")
print("                 access latency is set by the optical link and the")
print("                 remote HBM, neither of which exists yet.")

# O(1) means the cost must not grow with pool size. Compare a pool 8x
# larger; anything near-linear would show up as a large ratio.
big = MemoryPool(PoolConfig(nodes=4, local_node=0, wdm_channels=16,
                            pages_per_node=8192))
ns_big = measure_lookup_ns(big)
ratio = ns_big / ns if ns > 0 else 0.0
print("8x larger pool : %.0f ns  (ratio %.2f)" % (ns_big, ratio))
check(ratio < 2.0, "lookup is O(1): 8x the pages must not cost ~8x the time")

print()
print("-" * 66)
if errors == 0:
    print("PASS: memory pool passed all %d checks." % checks)
else:
    print("FAIL: memory pool had %d errors in %d checks." % (errors, checks))
print("-" * 66)
sys.exit(0 if errors == 0 else 1)
