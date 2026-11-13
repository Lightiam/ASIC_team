#!/usr/bin/env python3
"""Master verification harness for the LightRail NCE repository.

WHAT THIS IS
------------
A wrapper. It runs the suites that already exist and reports their real
exit codes. It does NOT reimplement any check, because a harness that
prints its own version of a result is a second source of truth, and the
second one is always the one that drifts.

Every suite below is a script in this repository. If one of them is
removed, this reports MISSING and fails -- it does not quietly skip, since
a skipped check and a passing check look identical in a summary line.

WHAT IT CANNOT DO
-----------------
The RTL suites need Icarus, Verilator and the sky130 PDK, which live in the
hpretl/iic-osic-tools container. Run this inside that container to cover
them. Outside it, those suites are reported as UNAVAILABLE and the run
fails, rather than passing on the subset that happens to be reachable.

Usage:
    python3 run_master_verification.py            # everything
    python3 run_master_verification.py --host     # only host-runnable
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))

# (label, kind, workdir, command)
#   kind "host"      runs anywhere python3 and numpy/scipy exist
#   kind "container" needs the EDA toolchain
SUITES = [
    ("Layer 1  thermal, 25 W chiplet",      "host",
     "models",    [sys.executable, "l1_diamond_thermal.py"]),
    ("Layer 21 memory pool",                "host",
     "sw/fabric", [sys.executable, "test_l21_memory_pool.py"]),
    ("Layer 20 opt-in transport",           "host",
     "sw/shim",   [sys.executable, "test_lrai_transport_loopback.py"]),
    ("PHY requirements",                    "host",
     "phy",       [sys.executable, "phy_requirements.py"]),
    ("Photonic models, layers 1-7",         "container",
     ".",         ["bash", "scripts/run_photonics.sh"]),
    ("Stack-layer RTL, 8 suites",           "container",
     ".",         ["bash", "scripts/run_stack_layers.sh"]),
    ("Gap-fix suites",                      "container",
     ".",         ["bash", "scripts/run_gap_fixes.sh"]),
]


def have_toolchain() -> bool:
    return shutil.which("iverilog") is not None


def run(label: str, kind: str, workdir: str, cmd: list[str],
        host_only: bool) -> tuple[str, float, str]:
    """Returns (verdict, seconds, detail)."""
    wd = os.path.join(ROOT, workdir)
    script = cmd[-1]
    target = script if os.path.isabs(script) else os.path.join(wd, script)
    if cmd[0] == "bash":
        target = os.path.join(ROOT, script)
    if not os.path.exists(target):
        return "MISSING", 0.0, target

    if kind == "container" and (host_only or not have_toolchain()):
        return "UNAVAILABLE", 0.0, "needs the EDA container"

    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=wd, capture_output=True, text=True,
                           timeout=3600)
        rc = p.returncode
        tail = (p.stdout or "").strip().splitlines()
        detail = tail[-1] if tail else ""
    except subprocess.TimeoutExpired:
        return "TIMEOUT", time.time() - t0, "exceeded 3600 s"
    except Exception as exc:                       # noqa: BLE001
        return "ERROR", time.time() - t0, str(exc)[:70]
    return ("PASS" if rc == 0 else "FAIL"), time.time() - t0, detail


def main() -> int:
    host_only = "--host" in sys.argv

    print("=" * 74)
    print("LightRail NCE master verification")
    print("=" * 74)
    print("toolchain  : %s" %
          ("EDA container detected" if have_toolchain()
           else "host only -- iverilog not on PATH"))
    print("mode       : %s" % ("--host, container suites skipped"
                               if host_only else "all suites"))
    print()

    results = []
    for label, kind, wd, cmd in SUITES:
        print("--- %s" % label)
        verdict, secs, detail = run(label, kind, wd, cmd, host_only)
        results.append((label, verdict, secs, detail))
        print("    %-12s %6.1f s  %s" % (verdict, secs, detail[:60]))

    print()
    print("=" * 74)
    width = max(len(r[0]) for r in results)
    for label, verdict, secs, _ in results:
        print("  %-*s  %-12s %6.1f s" % (width, label, verdict, secs))
    print("=" * 74)

    npass = sum(1 for _, v, _, _ in results if v == "PASS")
    nunavail = sum(1 for _, v, _, _ in results if v == "UNAVAILABLE")
    nbad = len(results) - npass - nunavail

    print("  %d passed, %d failed, %d unavailable, of %d"
          % (npass, nbad, nunavail, len(results)))

    if nunavail and not host_only:
        print()
        print("  %d suite(s) could not run because the EDA toolchain is not" % nunavail)
        print("  present. This is reported as a FAILURE of the run, not as a")
        print("  pass, because an unrun check proves nothing. Re-run inside")
        print("  hpretl/iic-osic-tools to cover them.")

    print("=" * 74)

    if nbad == 0 and nunavail == 0:
        print("ALL SUITES PASSED")
        return 0
    if nbad == 0 and host_only:
        print("HOST SUITES PASSED (container suites deliberately skipped)")
        return 0
    print("RUN INCOMPLETE OR FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
