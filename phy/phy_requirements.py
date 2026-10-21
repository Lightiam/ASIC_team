"""200G PAM4 PHY: what it must deliver, and what the die must do to feed it.

WHY THIS FILE EXISTS
--------------------
The analog PHY is vendor IP. It is not written here and no amount of RTL
closes the 6000x gap. But "buy a PHY" is not a task either -- a vendor
quotes against a specification, and the specification is derived work that
has to be done by whoever owns the system. This produces it, from the
models already in the repository rather than from assumption:

  photonics/l02_tfln_mzm.py   Vpi -> the driver swing the PHY must produce
                              velocity mismatch -> the bandwidth ceiling
  photonics/l07_receiver.py   responsivity and noise -> required OMA
  photonics/l04_wdm.py        channel count -> lanes per die

THE PART THAT IS OURS
---------------------
Between the core and the analog PHY sits the PCS, which is ordinary
synthesisable digital: FEC, gearbox, alignment. That is buildable here, and
the first thing this computes is the interface it has to present -- because
the 6000x gap, restated, is a BUS WIDTH problem, and it has a concrete
answer at every core clock.

Nothing here claims the PHY exists. It states what would have to be bought
and what the die must do to use it.
"""

from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "photonics"))

from l02_tfln_mzm import (TflnMzmSpec, link_budget_db,              # noqa: E402
                          velocity_mismatch_bandwidth_hz)
from l07_receiver import ReceiverSpec                               # noqa: E402

# --- target ----------------------------------------------------------------
PAYLOAD_GBPS = 200.0            # per lane, the deck's figure
BITS_PER_SYMBOL = 2             # PAM4

# KP4 Reed-Solomon RS(544,514) over GF(2^10) is the standard FEC for
# 100G-per-lane and above. It costs overhead in line rate and buys about
# 5 dB of coding gain, without which the required OMA is unreachable.
KP4_N, KP4_K = 544, 514
FEC_OVERHEAD = KP4_N / KP4_K

# The implemented link, for the comparison that matters.
RTL_BITS_PER_CLOCK = 1
RTL_CLOCK_HZ = 1.0 / 30.0e-9    # 30 ns period


def line_rate_gbps() -> float:
    return PAYLOAD_GBPS * FEC_OVERHEAD


def baud_rate_gbd() -> float:
    return line_rate_gbps() / BITS_PER_SYMBOL


def nyquist_hz() -> float:
    return baud_rate_gbd() * 1e9 / 2.0


def pcs_width_bits(core_clock_hz: float) -> float:
    """Bus width needed to carry one lane at a given core clock."""
    return line_rate_gbps() * 1e9 / core_clock_hz


def required_oma_dbm(rx: ReceiverSpec, target_ber: float = 2.4e-4) -> dict:
    """Optical modulation amplitude the PHY must present to the receiver.

    2.4e-4 is the pre-FEC BER that KP4 corrects to below 1e-15, so that is
    the operating point, not 1e-12. Working to an uncorrected BER would
    overstate the required power by several dB and inflate the laser budget.
    """
    # Q for the target BER: BER = 0.5*erfc(Q/sqrt(2)); invert numerically.
    lo, hi = 0.1, 12.0
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        ber = 0.5 * math.erfc(mid / math.sqrt(2.0))
        if ber > target_ber:
            lo = mid
        else:
            hi = mid
    q = 0.5 * (lo + hi)

    # PAM4 has three eyes, so each eye carries a third of the OMA, and the
    # outer levels see the full swing: a 3x (9.54 dB) penalty against NRZ.
    pam4_penalty_lin = 3.0

    bw = rx.tia_bandwidth_hz
    i_noise = rx.tia_input_noise_a_rthz * math.sqrt(bw)     # A rms
    # Required signal current for Q at one eye, scaled to full OMA.
    i_oma = q * 2.0 * i_noise * pam4_penalty_lin
    p_oma_w = i_oma / rx.responsivity_a_w
    return {
        "q": q,
        "noise_current_a_rms": i_noise,
        "oma_w": p_oma_w,
        "oma_dbm": 10.0 * math.log10(p_oma_w * 1e3),
        "pam4_penalty_db": 10.0 * math.log10(pam4_penalty_lin),
    }


def main() -> int:
    checks = errors = 0

    def check(cond, msg):
        nonlocal checks, errors
        checks += 1
        if not cond:
            errors += 1
            print("  FAIL [%s]" % msg)

    print("=" * 72)
    print("200G PAM4 PHY requirements")
    print("=" * 72)

    lr = line_rate_gbps()
    bd = baud_rate_gbd()
    ny = nyquist_hz()
    print("payload           : %.1f Gbps per lane, PAM4" % PAYLOAD_GBPS)
    print("FEC               : KP4 RS(%d,%d), overhead %.4f" % (KP4_N, KP4_K, FEC_OVERHEAD))
    print("line rate         : %.2f Gbps" % lr)
    print("symbol rate       : %.2f GBd" % bd)
    print("Nyquist           : %.2f GHz" % (ny / 1e9))
    print()

    # --- 1. the PCS interface: the gap restated as a bus width ------------
    print("[1] PCS INTERFACE -- what the die must present per lane")
    print("    The gap is a bus-width problem and it has an answer at every")
    print("    core clock. Width x clock must equal the line rate.")
    print()
    print("    %-18s %14s   %s" % ("core clock", "bits/clock", "verdict"))
    rows = [("33.33 MHz (today)", RTL_CLOCK_HZ), ("200 MHz", 200e6),
            ("400 MHz", 400e6), ("800 MHz", 800e6), ("1.0 GHz", 1.0e9)]
    for label, f in rows:
        w = pcs_width_bits(f)
        if w > 2048:
            v = "unroutable"
        elif w > 1024:
            v = "very wide"
        elif w > 256:
            v = "wide but normal for 100G+"
        else:
            v = "comfortable"
        print("    %-18s %14.0f   %s" % (label, w, v))
    today = pcs_width_bits(RTL_CLOCK_HZ)
    print()
    print("    At today's clock one lane needs a %.0f-bit bus. The core runs" % today)
    print("    %d bit per clock, so the shortfall is %.0fx -- the same 6000x" %
          (RTL_BITS_PER_CLOCK, today / RTL_BITS_PER_CLOCK))
    print("    from docs/BANDWIDTH-STATEMENT.md, seen from the digital side.")
    check(abs(today / RTL_BITS_PER_CLOCK / 6000.0 - 1.0) < 0.10,
          "digital-side shortfall agrees with the stated 6000x")

    # --- 2. modulator drive ------------------------------------------------
    print()
    print("[2] MODULATOR DRIVE -- from photonics/l02_tfln_mzm.py")
    mzm = TflnMzmSpec()
    vpi = mzm.vpi_v
    vmb = velocity_mismatch_bandwidth_hz(mzm.length_cm)
    print("    Vpi               : %.3f V at %.1f cm" % (vpi, mzm.length_cm))
    print("    PAM4 drive needed : %.3f Vpp (4 levels across Vpi)" % vpi)
    print("    per-level step    : %.3f V" % (vpi / 3.0))
    print("    velocity limit    : %.2f GHz at %.1f cm" % (vmb / 1e9, mzm.length_cm))
    print("    required Nyquist  : %.2f GHz" % (ny / 1e9))
    if vmb >= ny:
        print("    -> the electrode supports the symbol rate at this length")
    else:
        need_cm = mzm.length_cm * vmb / ny
        print("    -> ELECTRODE TOO LONG. %.2f GHz < %.2f GHz needed." % (vmb / 1e9, ny / 1e9))
        print("       Shorten to <= %.2f cm, which raises Vpi to %.2f V" %
              (need_cm, mzm.vpi_l_v_cm / need_cm))
        print("       and so raises the driver swing the PHY must deliver.")
    check(vmb > 0, "velocity-mismatch bandwidth is finite and positive")

    # --- 3. receiver -------------------------------------------------------
    print()
    print("[3] RECEIVER -- from photonics/l07_receiver.py")
    rx = ReceiverSpec()
    r = required_oma_dbm(rx)
    print("    TIA bandwidth     : %.1f GHz (spec), %.2f GHz needed" %
          (rx.tia_bandwidth_hz / 1e9, ny / 1e9))
    print("    input noise       : %.1f pA/rtHz -> %.2f uA rms over the band" %
          (rx.tia_input_noise_a_rthz * 1e12, r["noise_current_a_rms"] * 1e6))
    print("    target BER        : 2.4e-4 pre-FEC (KP4 corrects to <1e-15)")
    print("    Q required        : %.2f" % r["q"])
    print("    PAM4 penalty      : %.2f dB" % r["pam4_penalty_db"])
    print("    required OMA      : %.2f dBm" % r["oma_dbm"])
    if rx.tia_bandwidth_hz < ny:
        print("    -> TIA BANDWIDTH SHORT by %.2f GHz" % ((ny - rx.tia_bandwidth_hz) / 1e9))
    check(r["oma_dbm"] < 20.0, "required OMA is a physically sane power level")

    # --- 4. what to put in an RFQ -----------------------------------------
    print()
    print("[4] VENDOR SPECIFICATION")
    print("    These are the numbers a PHY vendor quotes against.")
    print()
    for k, v in [
        ("modulation", "PAM4, %d bits/symbol" % BITS_PER_SYMBOL),
        ("payload rate", "%.0f Gbps per lane" % PAYLOAD_GBPS),
        ("line rate", "%.2f Gbps (KP4)" % lr),
        ("symbol rate", "%.2f GBd" % bd),
        ("Nyquist", "%.2f GHz" % (ny / 1e9)),
        ("lanes per die", "16 (photonics/l04_wdm.py)"),
        ("aggregate", "%.1f Tbps per die" % (PAYLOAD_GBPS * 16 / 1000.0)),
        ("driver output", "%.2f Vpp differential into the MZM" % vpi),
        ("required OMA", "%.2f dBm" % r["oma_dbm"]),
        ("pre-FEC BER", "2.4e-4"),
        ("FEC", "KP4 RS(544,514), on-die in the PCS"),
        ("host interface", "%.0f bits at %s" % (pcs_width_bits(800e6), "800 MHz")),
    ]:
        print("      %-16s %s" % (k, v))

    print()
    print("[5] DIVISION OF WORK")
    print("    BUY  analog front end: driver, CDR, CTLE/DFE, serialiser.")
    print("         50+ GHz mixed-signal. Not writable in open tools and not")
    print("         synthesisable from anything in this repository.")
    print("    BUILD PCS: KP4 FEC, gearbox, lane alignment, PRBS. Ordinary")
    print("         synthesisable digital, and ours.")
    print("    FIX  the core clock. At 33.33 MHz no PHY helps, because the")
    print("         die cannot source %.0f bits per clock." % today)

    print()
    print("-" * 72)
    if errors == 0:
        print("PASS: PHY requirements passed all %d checks." % checks)
    else:
        print("FAIL: PHY requirements had %d errors in %d checks." % (errors, checks))
    print("-" * 72)
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
