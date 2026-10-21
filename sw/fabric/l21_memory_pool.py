"""Layer 21: disaggregated coherent memory pool with O(1) route resolution.

ON THE NAME
-----------
The deck calls this layer "Holographic Unified Memory Pooling". The word
holographic is not used here and the file is not named for it, because
nothing in this design is holographic: there is no volumetric storage, no
interference-pattern encoding, and no optical medium holding state. What
there is is a disaggregated memory pool whose pages live on several nodes
and are reached over optical links.

That is a real and useful thing. It is also a thing a memory architect has
a name for, and using a different word invites them to stop reading. The
audit found "holographic" matching zero files in the repository; this
resolves that by implementing the layer rather than by renaming the gap.

WHAT THIS IS
------------
A 64-bit global address space split across nodes. Given a virtual address
the engine resolves, in constant time, which node holds the page, whether
that page is local HBM or remote, and which optical channel reaches it.

WHAT THIS IS NOT
----------------
It is not a coherence protocol. Resolving where a page lives is the easy
half; keeping replicas consistent is the hard half, and this does not do
it. Single-writer ownership is tracked so that the structure cannot
silently claim coherence it does not provide -- a write to a page owned by
another node is REFUSED rather than performed, which is the honest failure.

Latency figures printed here are the cost of the LOOKUP, measured in this
process. They are not memory access latency, which is dominated by the
optical link and the remote HBM, neither of which exists.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

# Pool base. Chosen in the upper half of the 64-bit space so a pool address
# is distinguishable at a glance from anything in the lower half.
POOL_BASE = 0x8000_0000_0000_0000
PAGE_SHIFT = 21                       # 2 MiB pages
PAGE_SIZE = 1 << PAGE_SHIFT


@dataclass(frozen=True)
class PageDescriptor:
    """Where one page lives and how to reach it."""
    virtual_addr: int
    node_id: int
    channel_id: int                   # WDM channel index, -1 when local
    is_local: bool
    owner_node: int                   # single-writer owner


@dataclass
class PoolConfig:
    nodes: int = 4
    local_node: int = 0
    wdm_channels: int = 16            # matches photonics/l04_wdm.py
    pages_per_node: int = 1024


class MemoryPoolError(RuntimeError):
    pass


@dataclass
class MemoryPool:
    cfg: PoolConfig = field(default_factory=PoolConfig)
    _owner_override: dict = field(default_factory=dict)

    # -- geometry ----------------------------------------------------------
    @property
    def total_pages(self) -> int:
        return self.cfg.nodes * self.cfg.pages_per_node

    @property
    def size_bytes(self) -> int:
        return self.total_pages * PAGE_SIZE

    def map_pool(self) -> tuple[int, int]:
        """Return (base, size) of the coherent pool."""
        return POOL_BASE, self.size_bytes

    # -- resolution --------------------------------------------------------
    def resolve(self, vaddr: int) -> PageDescriptor:
        """Resolve a virtual address to its page descriptor in O(1).

        Interleaving is page-granular round robin across nodes. That is a
        deliberate choice and it has a cost: a sequential sweep touches
        every node in turn, which maximises link utilisation and minimises
        locality. A locality-preserving layout would block-partition
        instead. Round robin is used because the collective traffic this
        fabric is built for is bandwidth-bound rather than latency-bound,
        and the scheduler in l17 assumes an even spread.
        """
        if vaddr < POOL_BASE or vaddr >= POOL_BASE + self.size_bytes:
            raise MemoryPoolError(
                "address 0x%016X is outside the pool [0x%016X, 0x%016X)"
                % (vaddr, POOL_BASE, POOL_BASE + self.size_bytes))

        offset = vaddr - POOL_BASE
        page = offset >> PAGE_SHIFT
        node = page % self.cfg.nodes
        local = node == self.cfg.local_node
        # One WDM channel per (node, stripe) pair, so concurrent streams to
        # the same node do not all land on channel 0.
        chan = -1 if local else (page // self.cfg.nodes) % self.cfg.wdm_channels
        owner = self._owner_override.get(page, node)
        return PageDescriptor(virtual_addr=vaddr, node_id=node,
                              channel_id=chan, is_local=local,
                              owner_node=owner)

    # -- ownership ---------------------------------------------------------
    def acquire_write(self, vaddr: int, node: int) -> None:
        """Take single-writer ownership of a page."""
        d = self.resolve(vaddr)
        page = (vaddr - POOL_BASE) >> PAGE_SHIFT
        if d.owner_node != node and page in self._owner_override:
            raise MemoryPoolError(
                "page %d is owned by node %d, node %d cannot take it"
                % (page, d.owner_node, node))
        self._owner_override[page] = node

    def check_write(self, vaddr: int, node: int) -> None:
        """Refuse a write from a node that does not own the page."""
        d = self.resolve(vaddr)
        if d.owner_node != node:
            raise MemoryPoolError(
                "node %d may not write 0x%016X; owner is node %d"
                % (node, vaddr, d.owner_node))

    def page_addr(self, page: int) -> int:
        return POOL_BASE + (page << PAGE_SHIFT)


def measure_lookup_ns(pool: MemoryPool, n: int = 20000) -> float:
    """Median-ish lookup cost in this process, in nanoseconds."""
    addrs = [pool.page_addr(i % pool.total_pages) for i in range(n)]
    t0 = time.perf_counter()
    for a in addrs:
        pool.resolve(a)
    t1 = time.perf_counter()
    return (t1 - t0) * 1e9 / n
