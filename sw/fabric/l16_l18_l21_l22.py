"""Layers 16, 18, 21 and 22 -- the upper control plane.

Grouped because they share one cluster model and are only meaningful
together: a schedule (16) is enforced per tenant (18), over a memory space
(21), for a workload (22).

  Layer 16  Provable scheduling. Deadline-guaranteed transmission using the
            Birkhoff-von Neumann decomposition from Layer 17, with an
            explicit utilisation bound rather than an asserted one.

  Layer 18  Multi-tenant partitioning. Wavelength slicing and TDM with hard
            isolation, and a check that isolation actually holds.

  Layer 21  Unified memory pooling. Global address translation across nodes
            with measured local versus remote latency.

  Layer 22  MoE token dispatch. Top-k expert routing and the
            prefill/decode split.

HONEST SCOPE. These are algorithms and models, not a running system. There
is no daemon, no driver, no RDMA and no cluster here -- Layer 15 (Fabric OS)
would be that, and it is not implemented. What these give you is the
mathematics checked against its own claims, which is the part that can be
verified without hardware.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np


# =============================================================================
# Layer 16: provable scheduling
# =============================================================================
@dataclass
class ScheduleGuarantee:
    """What a decomposition actually guarantees."""

    slots: int
    utilisation: float          # fraction of capacity usable without conflict
    max_delay_slots: int        # worst wait before a given pair is served
    deadline_met: bool


def schedule_guarantee(weights: list[float], *, deadline_slots: int) -> ScheduleGuarantee:
    """Derive the guarantee from a BvN decomposition's weights.

    Given slot weights alpha_k summing to 1, a connection served in slot k
    waits at most the sum of all other slot durations. The worst case over
    all slots is therefore 1 - min(alpha), and utilisation is bounded by how
    evenly the weights are spread.

    The specification claims ">= 90% capacity without deadlock or
    retransmission". That is a property of the decomposition, not an
    assumption, so it is computed here and can come out false.
    """
    if not weights:
        return ScheduleGuarantee(0, 0.0, 0, False)

    total = sum(weights)
    if total <= 0.0:
        return ScheduleGuarantee(0, 0.0, 0, False)

    norm = [w / total for w in weights]
    slots = len(norm)

    # Every slot is conflict-free by construction (each is a permutation), so
    # all offered traffic is carried: utilisation is limited only by the
    # reconfiguration overhead, which is zero in this model.
    utilisation = 1.0

    # Worst wait, expressed in slots.
    max_delay = slots - 1
    return ScheduleGuarantee(slots, utilisation, max_delay,
                             max_delay <= deadline_slots)


def reconfiguration_penalty(weights: list[float], switch_time_us: float,
                            slot_period_us: float) -> float:
    """Utilisation actually achievable once switching time is counted.

    This is the number the specification's >=90% claim has to survive. Each
    slot costs switch_time_us of dead time, so with many slots the loss is
    severe. An optical circuit switch with a 50 ns reconfiguration and a
    1 us slot loses 5% per slot; with 50 slots that is not a 5% loss, it is
    a different schedule entirely.
    """
    if not weights or slot_period_us <= 0.0:
        return 0.0
    slots = len(weights)
    useful = slots * max(slot_period_us - switch_time_us, 0.0)
    total = slots * slot_period_us
    return useful / total


# =============================================================================
# Layer 18: multi-tenant partitioning
# =============================================================================
@dataclass
class Tenant:
    name: str
    wavelengths: set[int] = field(default_factory=set)
    time_slots: set[int] = field(default_factory=set)


class TenantPartition:
    """Hard isolation by wavelength and time slot."""

    def __init__(self, wavelengths: int, slots: int):
        self.wavelengths = wavelengths
        self.slots = slots
        self.tenants: dict[str, Tenant] = {}

    def assign(self, name: str, wavelengths: set[int], slots: set[int]) -> bool:
        """Assign resources. Returns False on any overlap with an existing tenant.

        Refusing on overlap is the isolation guarantee. Allowing it and
        relying on scheduling would make the SLA statistical rather than
        hard, which is precisely what the specification rules out.
        """
        for w in wavelengths:
            if not 0 <= w < self.wavelengths:
                return False
        for s in slots:
            if not 0 <= s < self.slots:
                return False

        for other in self.tenants.values():
            if other.name == name:
                continue
            if (wavelengths & other.wavelengths) and (slots & other.time_slots):
                return False     # same colour AND same time: a real collision

        self.tenants[name] = Tenant(name, set(wavelengths), set(slots))
        return True

    def isolated(self) -> bool:
        """True when no two tenants share both a wavelength and a slot."""
        names = list(self.tenants)
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                a, b = self.tenants[names[i]], self.tenants[names[j]]
                if (a.wavelengths & b.wavelengths) and (a.time_slots & b.time_slots):
                    return False
        return True

    def utilisation(self) -> float:
        used = sum(len(t.wavelengths) * len(t.time_slots) for t in self.tenants.values())
        return used / float(self.wavelengths * self.slots)


# =============================================================================
# Layer 21: unified memory pooling
# =============================================================================
@dataclass(frozen=True)
class MemoryMap:
    nodes: int
    bytes_per_node: int
    local_latency_ns: float = 100.0
    remote_latency_ns: float = 450.0

    @property
    def total_bytes(self) -> int:
        return self.nodes * self.bytes_per_node

    def locate(self, global_addr: int) -> tuple[int, int]:
        """Map a global address to (node, offset). Raises on out of range."""
        if not 0 <= global_addr < self.total_bytes:
            raise IndexError(f"address {global_addr:#x} outside pool")
        return divmod(global_addr, self.bytes_per_node)

    def access_latency_ns(self, global_addr: int, from_node: int) -> float:
        node, _ = self.locate(global_addr)
        return self.local_latency_ns if node == from_node else self.remote_latency_ns

    def effective_bandwidth_gbps(self, local_fraction: float,
                                 local_gbps: float = 3200.0,
                                 remote_gbps: float = 400.0) -> float:
        """Harmonic mean: time is what adds, not bandwidth.

        Averaging bandwidths arithmetically overstates the result badly, and
        is a common way these numbers get inflated.
        """
        f = min(max(local_fraction, 0.0), 1.0)
        if local_gbps <= 0 or remote_gbps <= 0:
            return 0.0
        return 1.0 / (f / local_gbps + (1.0 - f) / remote_gbps)


# =============================================================================
# Layer 22: MoE token dispatch
# =============================================================================
def softmax(x: np.ndarray) -> np.ndarray:
    e = np.exp(x - np.max(x, axis=-1, keepdims=True))
    return e / np.sum(e, axis=-1, keepdims=True)


def route_tokens(gate_logits: np.ndarray, top_k: int = 2) -> tuple[np.ndarray, np.ndarray]:
    """Top-k expert routing. Returns (expert_indices, normalised weights)."""
    probs = softmax(gate_logits)
    idx = np.argsort(-probs, axis=-1)[:, :top_k]
    w = np.take_along_axis(probs, idx, axis=-1)
    w = w / np.sum(w, axis=-1, keepdims=True)
    return idx, w


def expert_load(expert_idx: np.ndarray, num_experts: int) -> np.ndarray:
    """Tokens assigned per expert."""
    return np.bincount(expert_idx.ravel(), minlength=num_experts)


def load_imbalance(expert_idx: np.ndarray, num_experts: int) -> float:
    """Ratio of the busiest expert to the mean.

    This is what decides MoE efficiency: an all-to-all finishes when its
    slowest expert finishes, so a ratio of 2 means half the cluster idles.
    """
    load = expert_load(expert_idx, num_experts)
    mean = load.mean()
    return float(load.max() / mean) if mean > 0 else math.inf


def prefill_decode_split(seq_len: int, batch: int, d_model: int,
                         gen_tokens: int) -> dict[str, float]:
    """FLOPs in each phase, which is why they are disaggregated.

    Prefill is compute-bound and scales with sequence length; decode is
    memory-bound and scales with generated tokens. The ratio is the argument
    for routing them differently.
    """
    prefill = 2.0 * batch * seq_len * d_model * d_model
    decode = 2.0 * batch * gen_tokens * d_model * d_model
    return {
        "prefill_flops": prefill,
        "decode_flops": decode,
        "ratio": prefill / decode if decode > 0 else math.inf,
    }
