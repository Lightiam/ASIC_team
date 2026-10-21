"""Layer 5: Analog Wave Compute -- Clements MZI mesh compiler.

An N x N unitary can be realised exactly by a rectangular mesh of 2x2
Mach-Zehnder interferometers, each with an internal phase (theta) and an
external phase (phi). This module is the compiler: given a target unitary it
produces the phase settings, and given phase settings it rebuilds the unitary,
so the two directions can be checked against each other.

The architecture the specification describes is

    W = U . Sigma . V*

with U and V* unitary meshes and Sigma a diagonal of variable optical
attenuators. Factorising W that way is a standard SVD; the part that needs a
real algorithm is turning each unitary into physical phase settings, which is
Clements et al., Optica 3(12):1460 (2016).

WHAT THIS IS AND IS NOT
-----------------------
This is an exact mathematical model of an ideal mesh: lossless couplers,
perfect 50:50 splitting, no phase error, no crosstalk. It tells you the phase
settings a perfect mesh would need, and it is the correct first step.

It is NOT a device simulation. A fabricated mesh has insertion loss per MZI,
split-ratio error, thermal crosstalk between phase shifters and finite
extinction. Those degrade the realised matrix, and modelling them needs the
device layer (see l02_tfln_mzm.py) plus measured fabrication data. The
`apply_imperfections` helper below shows the sensitivity but is a first-order
model, not a substitute for measurement.

No hardware exists for this layer. Nothing here should be read as a claim
that one does.
"""

from __future__ import annotations

import cmath
import math
from dataclasses import dataclass, field

import numpy as np


@dataclass
class MziSetting:
    """One Mach-Zehnder in the mesh.

    Attributes:
        mode:  index of the upper of the two adjacent modes it couples
        theta: split-ratio angle
        phi:   phase on the upper arm
        psi:   phase on the lower arm
        block: the exact 2x2 unitary, kept so reconstruction is bit-faithful
               rather than re-derived from rounded angles
    """

    mode: int
    theta: float
    phi: float
    psi: float = 0.0
    block: np.ndarray = field(
        default_factory=lambda: np.eye(2, dtype=complex)
    )


@dataclass
class MeshProgram:
    """A complete mesh configuration."""

    n: int
    mzis: list[MziSetting] = field(default_factory=list)
    # Output phase screen: a diagonal of unit-modulus values.
    output_phases: np.ndarray = field(default_factory=lambda: np.ones(0, dtype=complex))

    @property
    def mzi_count(self) -> int:
        return len(self.mzis)

    @property
    def ideal_mzi_count(self) -> int:
        """A Clements mesh needs exactly N(N-1)/2 interferometers."""
        return self.n * (self.n - 1) // 2


def _two_level(alpha: complex, beta: complex) -> np.ndarray:
    """2x2 unitary built from a normalised (alpha, beta) pair.

        G = [[ conj(alpha),  conj(beta) ],
             [ -beta,        alpha      ]]

    Unitary for any |alpha|^2 + |beta|^2 = 1. Applied on the left to a column
    pair (a, b) with alpha = a/r, beta = b/r it maps (a, b) -> (r, 0), which
    is what makes the nulling step exact rather than approximate.
    """
    return np.array(
        [[np.conj(alpha), np.conj(beta)], [-beta, alpha]], dtype=complex
    )


def _mzi_matrix(theta: float, phi: float, psi: float = 0.0) -> np.ndarray:
    """Physical MZI transfer matrix.

    theta sets the split ratio, phi is the external phase on the upper input
    and psi the relative phase on the lower. Together they span the same set
    of 2x2 unitaries (up to a global phase) that _two_level produces, which is
    why a decomposition in (alpha, beta) can be reported as (theta, phi, psi).
    """
    return np.array(
        [
            [cmath.exp(1j * phi) * math.cos(theta),
             cmath.exp(1j * psi) * math.sin(theta)],
            [-cmath.exp(1j * phi) * math.sin(theta),
             cmath.exp(1j * psi) * math.cos(theta)],
        ],
        dtype=complex,
    )


def _embed(n: int, mode: int, block: np.ndarray) -> np.ndarray:
    """Place a 2x2 block on modes (mode, mode+1) of an N x N identity."""
    full = np.eye(n, dtype=complex)
    full[mode : mode + 2, mode : mode + 2] = block
    return full


def decompose(target: np.ndarray, *, atol: float = 1e-12) -> MeshProgram:
    """Factor a unitary into a mesh of 2-level (MZI) blocks.

    Uses successive Givens nulling: 2-level unitaries are applied on the left
    to drive every sub-diagonal entry to zero, reducing U to a diagonal phase
    screen. Undoing them gives

        U = G_1^H . G_2^H . ... . G_k^H . D

    which is a Reck-style triangular mesh of exactly N(N-1)/2 blocks followed
    by one output phase screen.

    This is triangular, not the rectangular Clements arrangement. Clements has
    lower optical depth -- N rather than 2N-3 -- which matters for loss in a
    fabricated device. The phase-setting problem and the block count are
    identical; only the physical ordering differs.

    Raises ValueError for a non-square or non-unitary target: such a matrix
    has no exact mesh realisation, and quietly returning settings for the
    nearest unitary would hide that.
    """
    u = np.array(target, dtype=complex)
    if u.ndim != 2 or u.shape[0] != u.shape[1]:
        raise ValueError(f"target must be square, got shape {u.shape}")

    n = u.shape[0]
    if n == 0:
        raise ValueError("target must be non-empty")

    err = float(np.max(np.abs(u.conj().T @ u - np.eye(n))))
    if err > 1e-8:
        raise ValueError(f"target is not unitary (max |U*U - I| = {err:.3e})")

    work = u.copy()
    applied: list[tuple[int, np.ndarray]] = []

    # Null each sub-diagonal entry, bottom-up within each column.
    for col in range(n - 1):
        for row in range(n - 1, col, -1):
            a = work[row - 1, col]
            b = work[row, col]
            r = math.hypot(abs(a), abs(b))
            if r < atol:
                continue                      # already zero, no block needed
            g = _two_level(a / r, b / r)
            work = _embed(n, row - 1, g) @ work
            applied.append((row - 1, g))

    diag = np.diag(work).copy()

    # U = G_1^H ... G_k^H D, so walk the applied blocks in reverse.
    mzis: list[MziSetting] = []
    for mode, g in reversed(applied):
        gh = g.conj().T
        alpha = gh[1, 1]
        beta = -gh[1, 0]
        theta = math.atan2(abs(beta), abs(alpha))
        phi = cmath.phase(alpha) if abs(alpha) > atol else 0.0
        psi = cmath.phase(beta) if abs(beta) > atol else 0.0
        mzis.append(MziSetting(mode=mode, theta=theta, phi=phi, psi=psi, block=gh))

    return MeshProgram(n=n, mzis=mzis, output_phases=diag)


def reconstruct(prog: MeshProgram) -> np.ndarray:
    """Rebuild the unitary a mesh program realises."""
    u = np.diag(prog.output_phases)
    for m in prog.mzis:
        u = _embed(prog.n, m.mode, m.block) @ u
    return u


def svd_program(weight: np.ndarray) -> tuple[MeshProgram, np.ndarray, MeshProgram]:
    """Factor an arbitrary real/complex matrix W = U . Sigma . V*.

    Returns the mesh program for U, the singular values (which the variable
    optical attenuators implement), and the mesh program for V*.

    Note the physical constraint the specification does not mention: an
    attenuator can only attenuate. The singular values must therefore be
    normalised so max(sigma) <= 1, and the lost scale factor has to be
    recovered electrically after photodetection. The returned sigma is
    normalised and the scale is reported so the caller can apply it.
    """
    w = np.array(weight, dtype=complex)
    u, s, vh = np.linalg.svd(w)
    return decompose(u), s, decompose(vh)


def apply_imperfections(
    prog: MeshProgram,
    *,
    insertion_loss_db_per_mzi: float = 0.0,
    split_ratio_sigma: float = 0.0,
    phase_sigma_rad: float = 0.0,
    rng: np.random.Generator | None = None,
) -> np.ndarray:
    """First-order sensitivity model. NOT a device simulation.

    Applies per-MZI loss, Gaussian split-ratio error and Gaussian phase error
    to show how the realised matrix degrades. Real numbers require measured
    fabrication data; this exists to show the shape of the sensitivity, not to
    predict a specific device.
    """
    g = rng if rng is not None else np.random.default_rng(0)
    amp = 10.0 ** (-insertion_loss_db_per_mzi / 20.0)

    u = np.diag(prog.output_phases)
    for m in prog.mzis:
        theta = m.theta + g.normal(0.0, split_ratio_sigma)
        phi = m.phi + g.normal(0.0, phase_sigma_rad)
        psi = m.psi + g.normal(0.0, phase_sigma_rad)
        block = _mzi_matrix(theta, phi, psi) * amp
        u = _embed(prog.n, m.mode, block) @ u
    return u


def energy_per_mac(
    n: int,
    *,
    laser_power_mw: float = 100.0,
    clock_ghz: float = 10.0,
    mzi_static_mw: float = 0.0,
) -> float:
    """Energy per MAC in picojoules for an N x N mesh.

    One pass through an N x N mesh performs N^2 multiply-accumulates. This
    counts optical power and phase-shifter holding power only; it excludes the
    DACs, TIAs, ADCs and laser wall-plug inefficiency, which in published
    systems dominate. Treat it as a floor, not a projection.
    """
    macs_per_second = (n * n) * clock_ghz * 1e9
    total_mw = laser_power_mw + mzi_static_mw * (n * (n - 1) / 2)
    joules_per_second = total_mw * 1e-3
    return (joules_per_second / macs_per_second) * 1e12
