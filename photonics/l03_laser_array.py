"""Layer 3: remote DFB laser array (ELSFP).

Rate-equation model of a single-mode DFB laser plus the array-level concerns
the specification lists: wavelength stability over temperature, relative
intensity noise, linewidth, and the eye-safety interlock.

The reason this layer matters beyond "it makes light": its RIN lands directly
on the Layer 7 receiver decision, and its thermal wavelength drift lands on
the Layer 4 WDM channel plan. Both were excluded from those models and are
supplied here, so the three can be checked against each other.

Standard semiconductor laser rate equations:

    dN/dt = I/(q*V) - N/tau_n - v_g * g(N) * S
    dS/dt = Gamma * v_g * g(N) * S - S/tau_p + Gamma * beta * N/tau_n

with gain g(N) = a*(N - N_tr)/(1 + eps*S).

What is NOT modelled: spatial hole burning, multi-mode competition,
facet reflectivity detail, gain compression beyond the single eps term,
and ageing. Those need measured device data.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

Q_E = 1.602176634e-19
H_PLANCK = 6.62607015e-34
C0 = 299_792_458.0


@dataclass(frozen=True)
class DfbSpec:
    """DFB laser parameters. Defaults follow the Layer 3 specification."""

    channels: int = 16
    wavelength_nm: float = 1550.0
    target_power_mw: float = 100.0        # per lane, CW
    bias_current_max_ma: float = 250.0
    rin_db_hz: float = -150.0             # spec <= -150 dB/Hz
    linewidth_hz: float = 500e3           # spec <= 500 kHz
    wavelength_stability_pm: float = 10.0 # spec +/- 10 pm over temperature
    temp_min_c: float = 20.0
    temp_max_c: float = 70.0
    # Thermal tuning coefficient for InP DFB, nm/K. This is the physical
    # constant that decides whether the stability target is reachable.
    dlambda_dt_nm_per_k: float = 0.09

    # Rate-equation parameters (typical 1550 nm InGaAsP DFB)
    active_volume_cm3: float = 9e-11
    tau_n_s: float = 2e-9                 # carrier lifetime
    tau_p_s: float = 2e-12                # photon lifetime
    n_tr_cm3: float = 1.0e18              # transparency carrier density
    gain_a_cm2: float = 2.5e-16           # differential gain
    confinement: float = 0.3              # Gamma
    group_index: float = 3.7
    beta_sp: float = 1e-4                 # spontaneous emission factor
    epsilon_cm3: float = 1.5e-17          # gain compression


def threshold_current_ma(spec: DfbSpec) -> float:
    """Current at which modal gain equals cavity loss."""
    v_g = C0 * 100.0 / spec.group_index          # cm/s
    # Threshold gain from photon lifetime.
    g_th = 1.0 / (spec.confinement * v_g * spec.tau_p_s)
    n_th = spec.n_tr_cm3 + g_th / spec.gain_a_cm2
    i_th_a = Q_E * spec.active_volume_cm3 * n_th / spec.tau_n_s
    return i_th_a * 1e3


def steady_state(spec: DfbSpec, current_ma: float) -> dict[str, float]:
    """Solve the rate equations for steady state at a given bias."""
    v_g = C0 * 100.0 / spec.group_index
    i_a = current_ma * 1e-3

    # Iterate: photon density couples back through gain compression.
    s = 1e14
    n = spec.n_tr_cm3
    for _ in range(500):
        g = spec.gain_a_cm2 * (n - spec.n_tr_cm3) / (1.0 + spec.epsilon_cm3 * s)
        # dS/dt = 0
        denom = spec.confinement * v_g * g - 1.0 / spec.tau_p_s
        s_new = (spec.confinement * spec.beta_sp * n / spec.tau_n_s)
        s_new = s_new / max(-denom, 1e-30) if denom < 0 else s * 1.05
        # dN/dt = 0
        n_new = (i_a / (Q_E * spec.active_volume_cm3)
                 - v_g * g * s) * spec.tau_n_s
        n = 0.5 * n + 0.5 * max(n_new, 0.0)
        s = 0.5 * s + 0.5 * max(s_new, 0.0)

    # Output power from photon density.
    nu = C0 / (spec.wavelength_nm * 1e-9)
    p_w = (s * spec.active_volume_cm3 * H_PLANCK * nu) / (spec.confinement * spec.tau_p_s)
    return {"carrier_cm3": n, "photon_cm3": s, "power_mw": p_w * 1e3}


def slope_efficiency_mw_per_ma(spec: DfbSpec) -> float:
    """Above threshold the L-I curve is linear; this is its slope."""
    i_th = threshold_current_ma(spec)
    hi = i_th + 100.0
    p_hi = steady_state(spec, hi)["power_mw"]
    p_th = steady_state(spec, i_th * 1.01)["power_mw"]
    return (p_hi - p_th) / (hi - i_th * 1.01)


def wavelength_at_temp_nm(spec: DfbSpec, temp_c: float, ref_c: float = 25.0) -> float:
    return spec.wavelength_nm + spec.dlambda_dt_nm_per_k * (temp_c - ref_c)


def uncooled_drift_pm(spec: DfbSpec) -> float:
    """Wavelength excursion across the operating range with no TEC."""
    lo = wavelength_at_temp_nm(spec, spec.temp_min_c)
    hi = wavelength_at_temp_nm(spec, spec.temp_max_c)
    return abs(hi - lo) * 1000.0


def required_tec_stability_k(spec: DfbSpec) -> float:
    """Temperature control needed to hold the stated wavelength tolerance."""
    return (spec.wavelength_stability_pm / 1000.0) / spec.dlambda_dt_nm_per_k


def rin_integrated_db(spec: DfbSpec, bandwidth_hz: float) -> float:
    """RIN integrated over a detection bandwidth, as a power ratio in dB."""
    return spec.rin_db_hz + 10.0 * math.log10(bandwidth_hz)


def rin_noise_current_a2(spec: DfbSpec, photocurrent_a: float,
                         bandwidth_hz: float) -> float:
    """Mean-square RIN-induced noise current at a detector.

    This is the term Layer 7 excluded. i_rin^2 = RIN * I^2 * B.
    """
    rin_lin = 10.0 ** (spec.rin_db_hz / 10.0)
    return rin_lin * (photocurrent_a ** 2) * bandwidth_hz


def coherence_length_m(spec: DfbSpec) -> float:
    """Coherence length from the linewidth; relevant to interferometric use."""
    return C0 / (math.pi * spec.linewidth_hz)


def array_power_budget(spec: DfbSpec) -> dict[str, float]:
    """Electrical and optical totals for the whole array."""
    i_th = threshold_current_ma(spec)
    slope = slope_efficiency_mw_per_ma(spec)
    i_needed = i_th + spec.target_power_mw / max(slope, 1e-9)
    # Forward voltage of a 1550 nm diode, plus series resistance.
    v_f = 1.0 + 0.005 * i_needed
    p_elec_w = spec.channels * i_needed * 1e-3 * v_f
    p_opt_w = spec.channels * spec.target_power_mw * 1e-3
    return {
        "threshold_ma": i_th,
        "slope_mw_per_ma": slope,
        "bias_per_lane_ma": i_needed,
        "within_bias_limit": 1.0 if i_needed <= spec.bias_current_max_ma else 0.0,
        "electrical_w": p_elec_w,
        "optical_w": p_opt_w,
        "wall_plug_efficiency": p_opt_w / max(p_elec_w, 1e-12),
    }


def eye_safety_class(total_optical_w: float) -> str:
    """IEC 60825-1 classification by accessible emission at 1550 nm.

    Class 1M allows up to about 10 mW for a collimated 1550 nm beam. The
    specification claims Class 1M for the module; this reports what the
    aggregate power actually is.
    """
    mw = total_optical_w * 1e3
    if mw <= 10.0:
        return "Class 1M (<=10 mW)"
    if mw <= 500.0:
        return "Class 3B (10-500 mW) -- interlock mandatory"
    return "Class 4 (>500 mW) -- interlock mandatory, severe hazard"
