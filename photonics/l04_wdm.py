"""Layer 4: multi-spectral WDM plane.

Channel plan on the ITU-T G.694.1 100 GHz grid, crosstalk accounting, and the
aggregate-capacity arithmetic the specification asserts.

The specification states the plan as

    lambda_k = 1530.0 nm + k * 0.8 nm,  k in [0, 15]

That is a WAVELENGTH-uniform grid. The ITU grid it cites is defined on
uniform FREQUENCY spacing, and the two are not the same: at 1550 nm a
100 GHz channel spacing is about 0.80 nm, but the nm spacing drifts across
the band because lambda = c/f is non-linear. Over 16 channels the
accumulated error is small but not zero, and a filter designed to a uniform
nm plan will sit progressively off-centre at the band edges. Both plans are
provided here so the difference can be seen rather than argued about.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

C0_NM_HZ = 299_792_458.0 * 1e9  # speed of light, nm.Hz


@dataclass(frozen=True)
class WdmPlan:
    channels: int = 16
    grid_ghz: float = 100.0
    anchor_thz: float = 193.1          # ITU anchor, 1552.524 nm
    adjacent_isolation_db: float = 28.0
    nonadjacent_isolation_db: float = 40.0
    per_lane_gbps: float = 200.0       # PAM4


def itu_frequencies_thz(plan: WdmPlan) -> list[float]:
    """Channel frequencies on the true ITU grid, uniform in frequency."""
    step_thz = plan.grid_ghz / 1000.0
    # Centre the comb on the anchor.
    first = plan.anchor_thz - step_thz * (plan.channels - 1) / 2.0
    return [first + k * step_thz for k in range(plan.channels)]


def itu_wavelengths_nm(plan: WdmPlan) -> list[float]:
    """Channel wavelengths derived from the ITU frequency grid, ascending.

    Frequency ascends, so wavelength descends. The list is sorted so it can
    be compared index-for-index against a wavelength-ordered plan; comparing
    the raw order against an ascending plan pairs channel 0 with channel 15
    and reports a nonsense discrepancy.
    """
    return sorted(C0_NM_HZ / (f_thz * 1e12) for f_thz in itu_frequencies_thz(plan))


def spec_wavelengths_nm(plan: WdmPlan, start_nm: float = 1530.0,
                        step_nm: float = 0.8) -> list[float]:
    """The specification's wavelength-uniform plan, for comparison."""
    return [start_nm + k * step_nm for k in range(plan.channels)]


def grid_discrepancy_nm(plan: WdmPlan) -> list[float]:
    """Per-channel offset between the spec plan and a true ITU grid.

    Both combs are first aligned on their centre channel, so this isolates
    the non-linearity rather than reporting a constant offset.
    """
    itu = itu_wavelengths_nm(plan)
    spec = spec_wavelengths_nm(plan)
    mid = plan.channels // 2
    shift = itu[mid] - spec[mid]
    return [(s + shift) - i for s, i in zip(spec, itu)]


def channel_spacing_nm(plan: WdmPlan) -> list[float]:
    """Actual nm spacing between adjacent ITU channels across the band."""
    wl = itu_wavelengths_nm(plan)
    return [wl[k + 1] - wl[k] for k in range(len(wl) - 1)]


def aggregate_capacity_gbps(plan: WdmPlan) -> float:
    """Simplex capacity of one fibre carrying the full comb."""
    return plan.channels * plan.per_lane_gbps


def crosstalk_penalty_db(plan: WdmPlan, loaded_channels: int | None = None) -> float:
    """Power penalty from accumulated crosstalk of all other channels.

    Interferers add in power: two adjacent neighbours at the adjacent
    isolation, the rest at the non-adjacent isolation. The penalty is the
    degradation of the signal-to-crosstalk ratio.

    This is the figure the specification's per-channel isolation numbers
    imply once a full comb is loaded, which is not the same as the
    two-channel isolation they quote.
    """
    n = loaded_channels if loaded_channels is not None else plan.channels
    if n <= 1:
        return 0.0
    adjacent = min(2, n - 1)
    nonadjacent = max(0, n - 1 - adjacent)

    x = adjacent * 10.0 ** (-plan.adjacent_isolation_db / 10.0)
    x += nonadjacent * 10.0 ** (-plan.nonadjacent_isolation_db / 10.0)
    if x <= 0.0:
        return 0.0
    # Penalty on the signal-to-crosstalk ratio.
    return -10.0 * math.log10(1.0 - x)


def osnr_budget_db(plan: WdmPlan, launch_dbm_per_ch: float,
                   noise_figure_db: float, span_loss_db: float) -> float:
    """OSNR after one amplified span, in a 0.1 nm reference bandwidth."""
    # 58 dBm is the standard constant for 0.1 nm reference at 1550 nm.
    return launch_dbm_per_ch - span_loss_db - noise_figure_db + 58.0


def summarise(plan: WdmPlan) -> dict[str, float]:
    disc = grid_discrepancy_nm(plan)
    spacings = channel_spacing_nm(plan)
    return {
        "channels": float(plan.channels),
        "capacity_gbps_simplex": aggregate_capacity_gbps(plan),
        "capacity_gbps_dual_socket": 2.0 * aggregate_capacity_gbps(plan),
        "min_spacing_nm": min(spacings),
        "max_spacing_nm": max(spacings),
        "worst_grid_error_nm": max(abs(d) for d in disc),
        "crosstalk_penalty_db": crosstalk_penalty_db(plan),
    }
