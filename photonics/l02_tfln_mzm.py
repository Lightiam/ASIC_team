"""Layer 2: TFLN travelling-wave Mach-Zehnder modulator.

Two parts:

  * An analytic electro-optic model -- phase shift, transfer function,
    extinction ratio, Vpi, link budget. Closed form, no solver needed, and
    it is what you check a datasheet against.

  * A PhotonForge geometry builder for the modulator, so the layout exists
    as a real component and can be streamed to GDS or handed to Tidy3D for
    FDTD.

WHAT IS MODELLED AND WHAT IS NOT
--------------------------------
The analytic model is exact for an ideal push-pull MZM: it assumes perfect
50:50 splitters, no chirp, and a velocity-matched travelling-wave electrode.
Those assumptions are good enough to size Vpi and check an extinction-ratio
claim, and not good enough to predict a fabricated device.

What it does NOT include: microwave/optical velocity mismatch and the
resulting bandwidth roll-off, electrode conductor and dielectric loss,
RF reflections from impedance discontinuities, DC-bias drift (a known TFLN
problem), temperature dependence of Vpi, or photorefractive effects.

Running the FDTD step requires a Tidy3D API key and spends FlexCredits. This
module never triggers that implicitly -- build_component() only constructs
geometry; the solve is a separate, explicit call by the caller.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


# Physical constants
C0_M_S = 299_792_458.0


@dataclass(frozen=True)
class TflnMzmSpec:
    """Device parameters. Defaults are the Layer 2 specification targets."""

    # Half-wave voltage-length product, V.cm
    vpi_l_v_cm: float = 1.8
    # Electrode interaction length, cm
    length_cm: float = 1.0
    # Propagation loss, dB/cm at 1550 nm
    alpha_db_cm: float = 0.15
    # Per-facet coupling loss, dB
    facet_loss_db: float = 0.54
    # Splitter/combiner excess loss, dB (two of them)
    splitter_loss_db: float = 0.10
    # Operating wavelength, m
    wavelength_m: float = 1550e-9
    # Electro-optic 3 dB bandwidth, Hz
    bandwidth_hz: float = 100e9

    @property
    def vpi_v(self) -> float:
        """Half-wave voltage for this electrode length."""
        return self.vpi_l_v_cm / self.length_cm


def phase_shift(spec: TflnMzmSpec, v_drive: float) -> float:
    """Electro-optic phase shift in radians.

    delta_phi = pi * V / Vpi
    """
    return math.pi * v_drive / spec.vpi_v


def transmission(spec: TflnMzmSpec, v_drive: float, bias_rad: float = math.pi / 2) -> float:
    """Normalised optical power transmission of the MZM.

    T = cos^2((delta_phi + phi_bias) / 2)

    Quadrature bias (pi/2) is the default, which is the linear operating
    point used for analogue drive. For digital PAM levels you generally bias
    at a null or peak instead.
    """
    return math.cos((phase_shift(spec, v_drive) + bias_rad) / 2.0) ** 2


def extinction_ratio_db(spec: TflnMzmSpec, v_low: float, v_high: float,
                        bias_rad: float = 0.0) -> float:
    """Extinction ratio between two drive levels, in dB."""
    t_hi = transmission(spec, v_high, bias_rad)
    t_lo = transmission(spec, v_low, bias_rad)
    hi, lo = max(t_hi, t_lo), min(t_hi, t_lo)
    if lo <= 0.0:
        return float("inf")
    return 10.0 * math.log10(hi / lo)


def insertion_loss_db(spec: TflnMzmSpec) -> float:
    """Total device insertion loss: two facets, two splitters, propagation."""
    return (
        2.0 * spec.facet_loss_db
        + 2.0 * spec.splitter_loss_db
        + spec.alpha_db_cm * spec.length_cm
    )


def pam4_levels(spec: TflnMzmSpec, v_swing: float = 1.8) -> list[tuple[int, float, float]]:
    """Drive voltages and transmissions for the four PAM4 symbols.

    Returns (symbol, v_drive, transmission). Levels are placed evenly in
    voltage, which is what a simple DAC does; note the resulting optical
    levels are NOT evenly spaced because the transfer function is cos^2.
    Equalising the optical levels requires pre-distorting the drive, and a
    design that assumes linear spacing will have unequal eye openings.
    """
    out = []
    for sym in range(4):
        v = -v_swing / 2.0 + (v_swing * sym / 3.0)
        out.append((sym, v, transmission(spec, v, bias_rad=math.pi / 2)))
    return out


def velocity_mismatch_bandwidth_hz(
    length_cm: float, n_optical: float = 2.2, n_microwave: float = 2.4
) -> float:
    """3 dB bandwidth limit set by optical/microwave velocity mismatch.

    f_3dB ~= 1.4 * c / (pi * L * |n_rf - n_opt|)

    This is the dominant bandwidth limit in a travelling-wave modulator and
    is absent from the specification's parameter list. With index matching
    the limit is large; a small mismatch collapses it, so this is the number
    that decides whether 100 GHz is reachable at a given length.
    """
    dn = abs(n_microwave - n_optical)
    if dn < 1e-9:
        return float("inf")
    length_m = length_cm * 1e-2
    return 1.4 * C0_M_S / (math.pi * length_m * dn)


def link_budget_db(
    spec: TflnMzmSpec,
    laser_power_dbm: float = 20.0,
    receiver_sensitivity_dbm: float = -12.0,
    wdm_mux_loss_db: float = 3.0,
    fibre_loss_db: float = 1.0,
) -> dict[str, float]:
    """End-to-end optical power budget for one lane.

    Returns the margin, which is what decides whether the link closes.
    """
    losses = (
        insertion_loss_db(spec) + wdm_mux_loss_db + fibre_loss_db
    )
    received = laser_power_dbm - losses
    return {
        "laser_dbm": laser_power_dbm,
        "modulator_il_db": insertion_loss_db(spec),
        "mux_loss_db": wdm_mux_loss_db,
        "fibre_loss_db": fibre_loss_db,
        "total_loss_db": losses,
        "received_dbm": received,
        "sensitivity_dbm": receiver_sensitivity_dbm,
        "margin_db": received - receiver_sensitivity_dbm,
    }


# -----------------------------------------------------------------------------
# PhotonForge geometry
# -----------------------------------------------------------------------------
def build_component(
    spec: TflnMzmSpec | None = None,
    *,
    arm_separation_um: float = 30.0,
    waveguide_width_um: float = 1.2,
    electrode_gap_um: float = 5.0,
):
    """Construct the MZM layout as a PhotonForge component.

    Geometry only. No solver is invoked, so this costs nothing and needs no
    API key. Returns the component; call write_gds() on it to stream out.
    """
    import photonforge as pf  # imported lazily so the analytic model stands alone

    spec = spec or TflnMzmSpec()
    pf.config.default_technology = pf.basic_technology()

    length_um = spec.length_cm * 1e4
    c = pf.Component("tfln_mzm")

    taper = 50.0
    split = 100.0
    half = arm_separation_um / 2.0

    # Input bus up to the splitter
    c.add("WG_CORE", pf.Rectangle((0.0, -waveguide_width_um / 2.0),
                                  (taper, waveguide_width_um / 2.0)))

    # Two arms, offset either side of the axis
    arm_x0 = taper + split
    arm_x1 = arm_x0 + length_um
    for y in (+half, -half):
        c.add("WG_CORE", pf.Rectangle((arm_x0, y - waveguide_width_um / 2.0),
                                      (arm_x1, y + waveguide_width_um / 2.0)))

    # Output bus after the combiner
    out_x0 = arm_x1 + split
    c.add("WG_CORE", pf.Rectangle((out_x0, -waveguide_width_um / 2.0),
                                  (out_x0 + taper, waveguide_width_um / 2.0)))

    # Travelling-wave electrodes: ground-signal-ground over the two arms
    e_half = waveguide_width_um / 2.0 + electrode_gap_um
    c.add("METAL", pf.Rectangle((arm_x0, -e_half), (arm_x1, e_half)))
    for y in (+half, -half):
        c.add("METAL", pf.Rectangle((arm_x0, y + e_half),
                                    (arm_x1, y + e_half + 10.0)))

    # Cladding over the whole device
    c.add("WG_CLAD", pf.Rectangle((-5.0, -half - 30.0),
                                  (out_x0 + taper + 5.0, half + 30.0)))
    return c
