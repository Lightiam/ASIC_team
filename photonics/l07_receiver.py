"""Layer 7: analog signal restoration -- SOA gain and TIA receive chain.

The specification gives SOA gain, noise figure and TIA bandwidth and
input-referred noise as independent targets. They are not independent: the
SOA's amplified spontaneous emission and the TIA's input noise both land on
the same decision, and what matters is the resulting signal-to-noise ratio at
the slicer and hence the bit error rate.

This module computes that chain end to end, so a claimed BER can be checked
against the stated component numbers rather than assumed.

Noise sources included, referred to the photodiode current:
  * TIA input-referred current noise      (specified as A/sqrt(Hz))
  * Shot noise on the signal photocurrent
  * Signal-spontaneous beat noise from the SOA
  * Spontaneous-spontaneous beat noise from the SOA

Not included: RIN from the laser (Layer 3 covers it), thermal noise of the
feedback resistor beyond what the input-referred figure already folds in,
and any equaliser or FEC coding gain beyond the stated KP4 assumption.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# Physical constants
Q_E = 1.602176634e-19      # elementary charge, C
H_PLANCK = 6.62607015e-34  # J.s
C0 = 299_792_458.0         # m/s


@dataclass(frozen=True)
class ReceiverSpec:
    """Layer 7 specification targets."""

    soa_gain_db: float = 15.0            # spec range 12-18 dB
    soa_noise_figure_db: float = 5.5     # spec <= 5.5 dB
    tia_bandwidth_hz: float = 56e9       # spec >= 56 GHz
    tia_input_noise_a_rthz: float = 15e-12   # spec <= 15 pA/sqrt(Hz)
    responsivity_a_w: float = 0.9        # photodiode, A/W
    wavelength_m: float = 1550e-9
    optical_bandwidth_hz: float = 100e9  # filter in front of the detector


def photon_energy_j(wavelength_m: float) -> float:
    return H_PLANCK * C0 / wavelength_m


def soa_output_power_w(spec: ReceiverSpec, p_in_w: float) -> float:
    return p_in_w * 10.0 ** (spec.soa_gain_db / 10.0)


def ase_power_w(spec: ReceiverSpec) -> float:
    """Amplified spontaneous emission power in the optical bandwidth.

    P_ASE = n_sp * (G - 1) * h*nu * B_opt, with the spontaneous emission
    factor derived from the noise figure as n_sp = (F*G - 1) / (2*(G-1)).
    """
    g = 10.0 ** (spec.soa_gain_db / 10.0)
    f = 10.0 ** (spec.soa_noise_figure_db / 10.0)
    if g <= 1.0:
        return 0.0
    n_sp = (f * g - 1.0) / (2.0 * (g - 1.0))
    return n_sp * (g - 1.0) * photon_energy_j(spec.wavelength_m) * spec.optical_bandwidth_hz


def noise_currents_a2(spec: ReceiverSpec, p_in_w: float) -> dict[str, float]:
    """Mean-square noise currents at the detector, in A^2."""
    b_e = spec.tia_bandwidth_hz
    g = 10.0 ** (spec.soa_gain_db / 10.0)

    p_sig = soa_output_power_w(spec, p_in_w)
    p_ase = ase_power_w(spec)

    i_sig = spec.responsivity_a_w * p_sig
    r = spec.responsivity_a_w

    # TIA input-referred noise over the electrical bandwidth.
    i2_tia = (spec.tia_input_noise_a_rthz ** 2) * b_e

    # Shot noise on signal plus ASE.
    i2_shot = 2.0 * Q_E * r * (p_sig + p_ase) * b_e

    # Signal-spontaneous beat: usually the dominant term after an amplifier.
    rho_ase = p_ase / spec.optical_bandwidth_hz      # ASE spectral density
    i2_sig_sp = 4.0 * (r ** 2) * p_sig * rho_ase * b_e

    # Spontaneous-spontaneous beat.
    i2_sp_sp = 2.0 * (r ** 2) * (rho_ase ** 2) * spec.optical_bandwidth_hz * b_e

    return {
        "tia": i2_tia,
        "shot": i2_shot,
        "sig_sp": i2_sig_sp,
        "sp_sp": i2_sp_sp,
        "total": i2_tia + i2_shot + i2_sig_sp + i2_sp_sp,
        "i_signal": i_sig,
    }


def snr_db(spec: ReceiverSpec, p_in_w: float) -> float:
    n = noise_currents_a2(spec, p_in_w)
    if n["total"] <= 0.0:
        return float("inf")
    return 10.0 * math.log10((n["i_signal"] ** 2) / n["total"])


def _erfc(x: float) -> float:
    return math.erfc(x)


def ber_nrz(spec: ReceiverSpec, p_in_w: float) -> float:
    """BER for NRZ with the computed SNR."""
    snr_lin = 10.0 ** (snr_db(spec, p_in_w) / 10.0)
    q = math.sqrt(snr_lin) / 2.0
    return 0.5 * _erfc(q / math.sqrt(2.0))


def ber_pam4(spec: ReceiverSpec, p_in_w: float) -> float:
    """BER for PAM4.

    PAM4 packs three eyes into the same amplitude, so each eye is a third the
    NRZ height -- a 9.5 dB SNR penalty before any other effect. That penalty
    is why a link that closes comfortably at NRZ can fail at PAM4, and the
    specification quotes PAM4 throughput with NRZ-style margins.
    """
    snr_lin = 10.0 ** (snr_db(spec, p_in_w) / 10.0)
    q = math.sqrt(snr_lin) / 6.0        # eye is 1/3, and Q uses half-amplitude
    # 3/4 symbol-error-to-bit-error factor for Gray-coded PAM4.
    return 0.75 * _erfc(q / math.sqrt(2.0))


def sensitivity_dbm(spec: ReceiverSpec, target_ber: float = 1e-6,
                    *, pam4: bool = True) -> float:
    """Input power needed to reach a target BER, in dBm.

    Bisection on optical power. The specification's raw target is BER <= 1e-6
    before KP4 FEC, so that is the default.
    """
    lo, hi = 1e-9, 1e-1       # 0.001 uW .. 100 mW
    fn = ber_pam4 if pam4 else ber_nrz
    for _ in range(200):
        mid = math.sqrt(lo * hi)
        if fn(spec, mid) > target_ber:
            lo = mid
        else:
            hi = mid
    return 10.0 * math.log10(hi * 1e3)


def dominant_noise(spec: ReceiverSpec, p_in_w: float) -> str:
    n = noise_currents_a2(spec, p_in_w)
    terms = {k: n[k] for k in ("tia", "shot", "sig_sp", "sp_sp")}
    return max(terms, key=terms.get)
