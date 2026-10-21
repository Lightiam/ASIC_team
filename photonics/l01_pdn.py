"""Layer 1: physical fabric -- PDN impedance and board stackup.

The specification states a target power-distribution-network impedance

    Z_target <= dV_allowed / dI = (0.8 V * 0.03) / 1000 A = 24 uohm

from DC to 100 MHz, delivered by a 24-phase DrMOS array, on a 32-layer
Megtron-7 board.

That arithmetic is correct. Whether it is *achievable* is a different
question, and it is the one this module answers: a PDN is a network of
capacitors with parasitic inductance, and above a few MHz the inductance
dominates. This builds the impedance profile from a real decoupling network
and reports where it crosses the target.

What is modelled: VRM output impedance, bulk/ceramic/package capacitor banks
with ESR and ESL, plane spreading inductance, and the resulting Z(f).

What is NOT modelled: plane resonance and cavity modes, via inductance in
detail, anti-resonance between banks beyond the lumped sum, current-crowding
under the die, and transient droop from a real di/dt profile. A sign-off PDN
needs a 3D solver such as the Sigrity-class extraction the specification
mentions.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np


@dataclass(frozen=True)
class CapBank:
    """A bank of identical decoupling capacitors in parallel."""

    name: str
    count: int
    capacitance_f: float
    esr_ohm: float
    esl_h: float

    def impedance(self, f: np.ndarray) -> np.ndarray:
        """Complex impedance of the bank at frequencies f."""
        w = 2.0 * math.pi * f
        z_one = self.esr_ohm + 1j * (w * self.esl_h - 1.0 / (w * self.capacitance_f))
        return z_one / self.count

    def srf_hz(self) -> float:
        """Self-resonant frequency: where the bank is most effective."""
        return 1.0 / (2.0 * math.pi * math.sqrt(self.capacitance_f * self.esl_h))


@dataclass
class Pdn:
    """Power distribution network model."""

    vdd_v: float = 0.8
    ripple_fraction: float = 0.03
    current_a: float = 1000.0

    # VRM: effective output impedance and its control bandwidth.
    vrm_r_ohm: float = 0.25e-3
    vrm_l_h: float = 50e-9
    vrm_bandwidth_hz: float = 500e3

    # Plane spreading inductance from the package to the die.
    plane_l_h: float = 5e-12

    banks: list[CapBank] = field(default_factory=list)

    @property
    def z_target_ohm(self) -> float:
        return self.vdd_v * self.ripple_fraction / self.current_a

    def vrm_impedance(self, f: np.ndarray) -> np.ndarray:
        """VRM looks like a resistor below its bandwidth and an inductor above."""
        w = 2.0 * math.pi * f
        z = self.vrm_r_ohm * (1.0 + 1j * f / self.vrm_bandwidth_hz)
        return z + 1j * w * self.vrm_l_h

    def impedance(self, f: np.ndarray) -> np.ndarray:
        """Total Z(f): VRM and all banks in parallel, plus plane inductance."""
        y = 1.0 / self.vrm_impedance(f)
        for b in self.banks:
            y = y + 1.0 / b.impedance(f)
        z = 1.0 / y
        return z + 1j * 2.0 * math.pi * f * self.plane_l_h

    def profile(self, f_min: float = 1e3, f_max: float = 1e9,
                points: int = 400) -> tuple[np.ndarray, np.ndarray]:
        f = np.logspace(math.log10(f_min), math.log10(f_max), points)
        return f, np.abs(self.impedance(f))

    def first_violation_hz(self, f_min: float = 1e3, f_max: float = 1e9) -> float | None:
        """Lowest frequency at which |Z| exceeds the target, or None."""
        f, z = self.profile(f_min, f_max)
        over = np.flatnonzero(z > self.z_target_ohm)
        return float(f[over[0]]) if over.size else None

    def worst_in_band(self, f_hi: float = 100e6) -> tuple[float, float]:
        """Worst |Z| and the frequency it occurs at, within the stated band."""
        f, z = self.profile(1e3, f_hi)
        i = int(np.argmax(z))
        return float(f[i]), float(z[i])


def capacitors_required(z_target_ohm: float, f_hz: float, esl_h: float) -> int:
    """How many capacitors of a given ESL are needed to hit Z at frequency f.

    Above self-resonance a capacitor is just an inductor, so the count is
    set by ESL alone: n >= 2*pi*f*ESL / Z_target. This is the arithmetic
    that decides whether a target is physically reachable on a given board.
    """
    if z_target_ohm <= 0.0:
        return 0
    return int(math.ceil(2.0 * math.pi * f_hz * esl_h / z_target_ohm))


def stackup_summary(layers: int = 32, dk: float = 3.3, df: float = 0.002,
                    board_mm: tuple[float, float] = (420.0, 350.0)) -> dict[str, float]:
    """Basic properties of the stated Megtron-7 stackup."""
    # Typical split for a 32-layer HDI power-plane heavy stack.
    power_pairs = layers // 8
    area_m2 = (board_mm[0] * 1e-3) * (board_mm[1] * 1e-3)
    # Interplane capacitance, parallel-plate, 100 um separation.
    eps0 = 8.854e-12
    sep_m = 100e-6
    c_plane_f = eps0 * dk * area_m2 / sep_m * power_pairs
    return {
        "layers": float(layers),
        "power_plane_pairs": float(power_pairs),
        "board_area_m2": area_m2,
        "interplane_capacitance_nf": c_plane_f * 1e9,
        "dk": dk,
        "df": df,
    }
