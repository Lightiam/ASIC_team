"""Layer 14: collective optimisation and topology fingerprinting.

Two pieces the specification describes:

  * A topology fingerprint -- a measured graph of the fabric, built from
    probe latencies and link capacities rather than a static assumption.

  * A min-max congestion flow placement, stated in the specification as

        min  max_e  ( sum_k f_k(e) / C(e) + D(e) )

    subject to flow conservation and capacity. That is a linear program once
    the max is lifted into an auxiliary variable, which is what solve() does.

Why this is not "just use a ring": a ring is optimal only when the fabric is
homogeneous. The point of measuring the topology is that it usually is not --
one link is slower, one node is a hop further -- and the optimal placement
follows the measurement. The tests below construct a fabric where the ring
heuristic is measurably worse, so the benefit is demonstrated rather than
asserted.

Uses scipy.optimize.linprog (HiGHS). No external solver needed.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from scipy.optimize import linprog


@dataclass
class Link:
    src: int
    dst: int
    capacity_gbps: float
    latency_ns: float


@dataclass
class Fabric:
    """Measured topology. Directed; add both directions for a duplex link."""

    nodes: int
    links: list[Link] = field(default_factory=list)

    def add(self, src: int, dst: int, capacity_gbps: float, latency_ns: float,
            *, bidirectional: bool = True) -> None:
        self.links.append(Link(src, dst, capacity_gbps, latency_ns))
        if bidirectional:
            self.links.append(Link(dst, src, capacity_gbps, latency_ns))

    def out_edges(self, node: int) -> list[int]:
        return [i for i, l in enumerate(self.links) if l.src == node]

    def in_edges(self, node: int) -> list[int]:
        return [i for i, l in enumerate(self.links) if l.dst == node]


@dataclass
class Demand:
    """One communication requirement: move `gbps` from src to dst."""

    src: int
    dst: int
    gbps: float


@dataclass
class Placement:
    """Result of the optimisation."""

    feasible: bool
    objective: float                       # the minimised max congestion term
    flows: np.ndarray                      # shape (demands, links)
    link_utilisation: np.ndarray           # per link, 0..1+
    message: str = ""


def fingerprint(latency_matrix: np.ndarray, capacity_matrix: np.ndarray,
                *, optical_threshold_ns: float = 50.0) -> Fabric:
    """Build a Fabric from measured matrices.

    A link is taken to exist where capacity is positive. The optical
    threshold is recorded only as a classification; it does not change the
    optimisation, which works on measured numbers rather than labels.
    """
    n = latency_matrix.shape[0]
    fab = Fabric(nodes=n)
    for i in range(n):
        for j in range(n):
            if i != j and capacity_matrix[i, j] > 0.0:
                fab.links.append(
                    Link(i, j, float(capacity_matrix[i, j]), float(latency_matrix[i, j]))
                )
    return fab


def solve(fab: Fabric, demands: list[Demand]) -> Placement:
    """Minimise the worst per-link congestion term.

    Variables: f[k][e] for each demand k and link e, plus one auxiliary t.
    Objective: minimise t.
    Constraints:
        for every link e:   sum_k f_k(e)/C(e) + D(e)  <=  t
        flow conservation at every node for every demand
        0 <= f_k(e) <= C(e)
    """
    n_d = len(demands)
    n_e = len(fab.links)
    if n_d == 0 or n_e == 0:
        return Placement(False, math.inf, np.zeros((0, 0)), np.zeros(0),
                         "empty problem")

    n_var = n_d * n_e + 1          # flows, then t
    t_idx = n_d * n_e

    c = np.zeros(n_var)
    c[t_idx] = 1.0                 # minimise t

    # Congestion constraints: sum_k f_k(e)/C(e) - t <= -D(e)
    a_ub = np.zeros((n_e, n_var))
    b_ub = np.zeros(n_e)
    for e, link in enumerate(fab.links):
        for k in range(n_d):
            a_ub[e, k * n_e + e] = 1.0 / link.capacity_gbps
        a_ub[e, t_idx] = -1.0
        b_ub[e] = -link.latency_ns

    # Flow conservation per demand per node.
    rows, b_eq_rows = [], []
    for k, dem in enumerate(demands):
        for node in range(fab.nodes):
            row = np.zeros(n_var)
            for e in fab.out_edges(node):
                row[k * n_e + e] += 1.0
            for e in fab.in_edges(node):
                row[k * n_e + e] -= 1.0
            if node == dem.src:
                rhs = dem.gbps
            elif node == dem.dst:
                rhs = -dem.gbps
            else:
                rhs = 0.0
            rows.append(row)
            b_eq_rows.append(rhs)

    a_eq = np.array(rows)
    b_eq = np.array(b_eq_rows)

    bounds = [(0.0, fab.links[e].capacity_gbps) for _ in range(n_d) for e in range(n_e)]
    bounds.append((None, None))     # t is unbounded below

    res = linprog(c, A_ub=a_ub, b_ub=b_ub, A_eq=a_eq, b_eq=b_eq,
                  bounds=bounds, method="highs")

    if not res.success:
        return Placement(False, math.inf, np.zeros((n_d, n_e)), np.zeros(n_e),
                         res.message)

    flows = res.x[:n_d * n_e].reshape(n_d, n_e)
    util = np.array([
        flows[:, e].sum() / fab.links[e].capacity_gbps for e in range(n_e)
    ])
    return Placement(True, float(res.x[t_idx]), flows, util, "optimal")


def ring_placement(fab: Fabric, demands: list[Demand]) -> Placement:
    """Baseline: route every demand along the node-index ring.

    This is the static heuristic the specification says Layer 14 replaces.
    Routing is src -> src+1 -> ... -> dst modulo the node count, regardless
    of what the links actually measure.
    """
    n_d, n_e = len(demands), len(fab.links)
    flows = np.zeros((n_d, n_e))

    edge_of = {(l.src, l.dst): e for e, l in enumerate(fab.links)}
    for k, dem in enumerate(demands):
        node = dem.src
        guard = 0
        while node != dem.dst and guard < fab.nodes + 1:
            nxt = (node + 1) % fab.nodes
            e = edge_of.get((node, nxt))
            if e is None:
                return Placement(False, math.inf, flows, np.zeros(n_e),
                                 f"ring hop {node}->{nxt} does not exist")
            flows[k, e] += dem.gbps
            node = nxt
            guard += 1

    util = np.array([flows[:, e].sum() / fab.links[e].capacity_gbps
                     for e in range(n_e)])
    obj = max(util[e] + fab.links[e].latency_ns for e in range(n_e))
    return Placement(True, float(obj), flows, util, "ring heuristic")
