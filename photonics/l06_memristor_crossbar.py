"""Layer 6: memristive synaptic crossbar -- ngspice model and MVM accuracy.

The specification states the computing rule as Kirchhoff's current law:

    I_j = sum_i  V_i * G_ij

That identity is exact only for an ideal crossbar with zero wire resistance.
A fabricated array has finite metal resistance along every row and column, so
the voltage actually reaching a cell is lower than the voltage applied at the
pad, and the current summed at a column has to flow back out through shared
metal. The result is IR drop, and it makes the realised matrix-vector product
differ from the ideal one by an amount that grows with array size and with
conductance.

This module builds the crossbar as an ngspice netlist with explicit wire
resistance, solves it, and compares the measured column currents against the
ideal product. That comparison is the point: it turns "analog MVM" from an
assertion into a number, and it shows where the 128x128 array the
specification asks for actually lands.

Requires ngspice, which is present in the iic-osic-tools container.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class CrossbarSpec:
    """Device and array parameters. Defaults follow the Layer 6 spec."""

    rows: int = 8
    cols: int = 8
    g_min_s: float = 10e-9        # 10 nS
    g_max_s: float = 100e-6       # 100 uS
    # Metal resistance per cell pitch, ohms. A realistic value for a fine
    # pitch BEOL line; the specification does not give one, and this is the
    # parameter the whole accuracy result hinges on.
    wire_ohm_per_cell: float = 2.5
    read_voltage: float = 0.2     # small, to stay in the linear region


def quantise_conductance(spec: CrossbarSpec, weights: np.ndarray) -> np.ndarray:
    """Map weights in [0, 1] onto the device conductance window."""
    w = np.clip(np.asarray(weights, dtype=float), 0.0, 1.0)
    return spec.g_min_s + w * (spec.g_max_s - spec.g_min_s)


def ideal_currents(g: np.ndarray, v: np.ndarray) -> np.ndarray:
    """The textbook result: I = G^T V, with no wire resistance."""
    return g.T @ v


def build_netlist(spec: CrossbarSpec, g: np.ndarray, v: np.ndarray) -> str:
    """Emit an ngspice netlist for the crossbar including wire resistance.

    Row i is driven at its left edge; column j is sensed at its bottom edge
    through a 0 V source, which ngspice reports as a branch current. Every
    cell-to-cell hop on both rows and columns carries a series resistor, so
    the solved currents include IR drop and sneak paths.
    """
    rows, cols = spec.rows, spec.cols
    rw = spec.wire_ohm_per_cell

    lines = ["* memristive crossbar with parasitic wire resistance", ".options savecurrents"]

    # Row drives and the resistive row lines.
    for i in range(rows):
        lines.append(f"Vrow{i} rin{i} 0 DC {v[i]:.9g}")
        lines.append(f"Rr{i}_0 rin{i} r{i}_0 {rw:.6g}")
        for j in range(cols - 1):
            lines.append(f"Rr{i}_{j+1} r{i}_{j} r{i}_{j+1} {rw:.6g}")

    # Column lines down to the sense node.
    for j in range(cols):
        for i in range(rows - 1):
            lines.append(f"Rc{j}_{i} c{j}_{i} c{j}_{i+1} {rw:.6g}")
        lines.append(f"Rc{j}_out c{j}_{rows-1} cout{j} {rw:.6g}")
        # Sense at virtual ground through a 0 V source to read the current.
        lines.append(f"Vsense{j} cout{j} 0 DC 0")

    # The synaptic devices themselves, as conductances.
    for i in range(rows):
        for j in range(cols):
            r = 1.0 / max(g[i, j], 1e-15)
            lines.append(f"Rg{i}_{j} r{i}_{j} c{j}_{i} {r:.9g}")

    lines += [".control", "op", "print " + " ".join(f"i(Vsense{j})" for j in range(cols)),
              ".endc", ".end", ""]
    return "\n".join(lines)


def parse_currents(output: str, cols: int) -> np.ndarray:
    """Pull the sense-source branch currents out of ngspice's print output."""
    vals = np.zeros(cols)
    for j in range(cols):
        m = re.search(rf"i\(vsense{j}\)\s*=\s*([-\d.eE+]+)", output, re.IGNORECASE)
        if m:
            # ngspice reports the branch current through Vsense with the
            # sign already matching the column current flowing to ground.
            # Negating here double-flips it and yields exactly -ideal, which
            # shows up as a relative error of 2.0 even with zero wire
            # resistance -- a useful tell that the error is a convention bug
            # and not a physical effect.
            vals[j] = float(m.group(1))
    return vals


def simulate(spec: CrossbarSpec, g: np.ndarray, v: np.ndarray,
             *, ngspice: str = "ngspice") -> np.ndarray:
    """Run ngspice on the crossbar and return the measured column currents.

    ngspice does not accept a netlist on stdin in batch mode, so the deck is
    written to a temporary file.
    """
    netlist = build_netlist(spec, g, v)
    fd, path = tempfile.mkstemp(suffix=".cir")
    with os.fdopen(fd, "w") as fh:
        fh.write(netlist)
    try:
        proc = subprocess.run(
            [ngspice, "-b", path], capture_output=True, text=True, timeout=300
        )
        if "vsense0" not in proc.stdout.lower():
            raise RuntimeError(
                "ngspice produced no sense currents: "
                + proc.stdout[:300] + " | " + proc.stderr[:300]
            )
        return parse_currents(proc.stdout, spec.cols)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def relative_error(measured: np.ndarray, ideal: np.ndarray) -> float:
    """Worst-case relative error across the output vector."""
    denom = np.maximum(np.abs(ideal), 1e-18)
    return float(np.max(np.abs(measured - ideal) / denom))


def effective_bits(rel_err: float) -> float:
    """Resolution implied by a relative error, in bits.

    An MVM accurate to a relative error e can distinguish about log2(1/e)
    levels. This is the number to compare against the precision a model
    actually needs.
    """
    if rel_err <= 0.0:
        return float("inf")
    return float(np.log2(1.0 / rel_err))
