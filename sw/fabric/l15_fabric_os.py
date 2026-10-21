"""Layer 15: Fabric OS control plane.

The daemon that ties the other layers together: it discovers the topology
(14), computes placements (14) and schedules (16/17), enforces tenant
isolation (18), tracks the memory pool (21), and monitors device health.

SCOPE, STATED PLAINLY
---------------------
This is the control-plane LOGIC, implemented and testable in process. It is
not a running system daemon. Specifically absent, and deliberately so:

  * No VFIO, no /dev node, no mmap of real hardware. The HAL (Layer 19)
    already defines the register interface and takes a pluggable backend;
    wiring this to it needs a kernel driver that does not exist.
  * No gRPC server and no /dev/shm control queue. Those are transport, and
    adding them without a device behind them would create the same hazard
    the Layer 20 plugin avoids: an interface that accepts commands and
    silently does nothing.
  * No RDMA, no PCIe.

What IS here is the state machine and the policy: what the daemon decides,
given measurements, and why. That part is verifiable now, and it is the part
that would be hard to change later.

The health model matters most. A fabric controller that cannot tell a
degraded link from a dead one, or that reroutes on a single bad sample,
makes things worse than no controller at all.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum

import numpy as np

from l14_collective_opt import Demand, Fabric, solve
from l16_l18_l21_l22 import MemoryMap, TenantPartition


class LinkHealth(Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"     # usable, but should be avoided when possible
    FAILED = "failed"         # must not carry traffic


class DaemonState(Enum):
    INIT = "init"
    DISCOVERING = "discovering"
    READY = "ready"
    REROUTING = "rerouting"
    DEGRADED = "degraded"     # running, but without full capacity
    HALTED = "halted"


@dataclass
class LinkTelemetry:
    """What the daemon measures per link."""

    ber: float = 0.0
    optical_power_dbm: float = 0.0
    latency_ns: float = 0.0
    # Consecutive samples outside limits. Acting on one sample causes
    # route flapping, which is worse than the fault being reacted to.
    consecutive_bad: int = 0


@dataclass
class HealthPolicy:
    """Thresholds, from the Layer 17 specification."""

    ber_degraded: float = 1e-5
    ber_failed: float = 1e-3
    power_min_dbm: float = -3.0
    # Samples required before a link changes state, in either direction.
    hysteresis: int = 3
    # Deadline for pushing new routes after a topology change.
    reroute_budget_us: float = 100.0


def classify(tele: LinkTelemetry, policy: HealthPolicy) -> LinkHealth:
    """Single-sample classification, before hysteresis."""
    if tele.ber >= policy.ber_failed:
        return LinkHealth.FAILED
    if tele.ber >= policy.ber_degraded or tele.optical_power_dbm < policy.power_min_dbm:
        return LinkHealth.DEGRADED
    return LinkHealth.HEALTHY


class FabricOs:
    """Control-plane state machine."""

    def __init__(self, fabric: Fabric, policy: HealthPolicy | None = None,
                 memory: MemoryMap | None = None):
        self.fabric = fabric
        self.policy = policy or HealthPolicy()
        self.memory = memory
        self.state = DaemonState.INIT
        self.health: list[LinkHealth] = [LinkHealth.HEALTHY] * len(fabric.links)
        self.telemetry: list[LinkTelemetry] = [LinkTelemetry() for _ in fabric.links]
        self.tenants: TenantPartition | None = None
        self.reroute_count = 0
        self.last_placement = None

    # ---- lifecycle ---------------------------------------------------------
    def discover(self) -> bool:
        """Probe the fabric. Returns False if nothing usable is found."""
        self.state = DaemonState.DISCOVERING
        if not self.fabric.links:
            self.state = DaemonState.HALTED
            return False
        self.state = DaemonState.READY
        return True

    def observe(self, link_index: int, tele: LinkTelemetry) -> bool:
        """Feed one telemetry sample. Returns True if the link changed state.

        Hysteresis is applied in both directions: a link must be bad for
        `hysteresis` consecutive samples to be demoted, and good for the same
        to be restored. Without that, one noisy sample reroutes the cluster.
        """
        observed = classify(tele, self.policy)
        current = self.health[link_index]
        prev = self.telemetry[link_index]

        if observed == current:
            tele.consecutive_bad = 0
            self.telemetry[link_index] = tele
            return False

        tele.consecutive_bad = prev.consecutive_bad + 1
        self.telemetry[link_index] = tele

        if tele.consecutive_bad >= self.policy.hysteresis:
            self.health[link_index] = observed
            tele.consecutive_bad = 0
            return True
        return False

    def usable_fabric(self) -> Fabric:
        """Fabric with failed links removed and degraded links de-rated.

        A degraded link is kept but given a tenth of its capacity, so the
        optimiser routes around it when it can and still uses it when there
        is no alternative. Removing it outright can make the problem
        infeasible, which is a worse failure than carrying reduced traffic.
        """
        out = Fabric(nodes=self.fabric.nodes)
        for i, link in enumerate(self.fabric.links):
            h = self.health[i]
            if h is LinkHealth.FAILED:
                continue
            cap = link.capacity_gbps * (0.1 if h is LinkHealth.DEGRADED else 1.0)
            out.links.append(type(link)(link.src, link.dst, cap, link.latency_ns))
        return out

    def plan(self, demands: list[Demand]):
        """Compute a placement over the currently usable fabric."""
        fab = self.usable_fabric()
        placement = solve(fab, demands)
        self.last_placement = placement

        if not placement.feasible:
            self.state = DaemonState.HALTED
        elif any(h is not LinkHealth.HEALTHY for h in self.health):
            self.state = DaemonState.DEGRADED
        else:
            self.state = DaemonState.READY
        return placement

    def reroute(self, demands: list[Demand]):
        """Recompute after a topology change."""
        self.state = DaemonState.REROUTING
        self.reroute_count += 1
        return self.plan(demands)

    # ---- tenancy -----------------------------------------------------------
    def attach_tenants(self, wavelengths: int, slots: int) -> TenantPartition:
        self.tenants = TenantPartition(wavelengths, slots)
        return self.tenants

    # ---- reporting ---------------------------------------------------------
    def summary(self) -> dict[str, object]:
        counts = {h: 0 for h in LinkHealth}
        for h in self.health:
            counts[h] += 1
        return {
            "state": self.state.value,
            "links_total": len(self.fabric.links),
            "links_healthy": counts[LinkHealth.HEALTHY],
            "links_degraded": counts[LinkHealth.DEGRADED],
            "links_failed": counts[LinkHealth.FAILED],
            "reroutes": self.reroute_count,
            "feasible": bool(self.last_placement.feasible) if self.last_placement else None,
            "pool_bytes": self.memory.total_bytes if self.memory else 0,
        }
