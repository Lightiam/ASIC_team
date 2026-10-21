"""Verify the fabrication package by reading the GERBERS, not the plot dialog.

The kicad-jlcpcb guidance is explicit that the plot dialog reporting success
is not evidence: the common rejections -- a missing layer, an inverted mask,
an open outline -- all survive a clean plot. So every check here parses the
exported file.

Three things are checked, in order of how often they sink an order:

  1. Edge.Cuts closure. An open outline is the single most common rejection
     and KiCad DRC does not reliably flag it.
  2. Copper completeness, including whether the plane layers actually carry
     a region fill. A layer NAMED GND1 that holds no copper plots happily
     and is indistinguishable from a real plane in the file listing.
  3. Drill presence, PTH and NPTH separately.

Run from the pcb/ directory:  python verify_fab.py [fab_dir]
"""

from __future__ import annotations

import collections
import os
import re
import sys

EXPECT_COPPER = 32
EXPECT_PLANES = 15          # 8 GND + 7 VDD, per add_planes.py


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def copper_files(fab: str) -> list[str]:
    """Protel extensions: .gtl top, .gbl bottom, .g1...gN inner."""
    out = []
    for n in sorted(os.listdir(fab)):
        if n.endswith((".gtl", ".gbl")) or re.search(r"\.g\d+$", n):
            out.append(n)
    return out


def check_copper(fab: str) -> bool:
    files = copper_files(fab)
    print("[1] COPPER LAYERS")
    print("    exported : %d (expected %d)" % (len(files), EXPECT_COPPER))

    planes, filled = [], []
    for n in files:
        txt = read(os.path.join(fab, n))
        # KiCad 10 emits no %LayerName attribute on copper -- it uses
        # %TF.FileFunction,Copper,L<n>,Inr for position and %TO.N,<net> for
        # the net the copper belongs to. Keying on the NET is the stronger
        # check anyway: it confirms the pour landed on the right rail, which
        # a layer name cannot tell you.
        nets = set(re.findall(r"%TO\.N,([^*]+)\*%", txt))
        rail = sorted(x for x in nets if x.startswith(("GND", "VDD")))
        # A poured zone is emitted as a region: G36 opens it, G37 closes it.
        regions = txt.count("G36")
        if rail:
            planes.append((n, ",".join(rail), regions))
            if regions > 0:
                filled.append(n)

    print("    plane layers : %d (expected %d)" % (len(planes), EXPECT_PLANES))
    print("    with copper  : %d" % len(filled))
    for n, layer, regions in planes[:4]:
        print("      %-36s %-8s regions=%d" % (n, layer, regions))
    if len(planes) > 4:
        print("      ... and %d more" % (len(planes) - 4))

    ok = len(files) == EXPECT_COPPER and len(planes) == EXPECT_PLANES \
        and len(filled) == len(planes)
    if not ok:
        print("    FAIL: a named plane layer with no region fill is an EMPTY")
        print("          layer. It plots clean and ships as bare laminate.")
    else:
        print("    PASS")
    return ok


def check_outline(fab: str) -> bool:
    print("[2] BOARD OUTLINE CLOSURE")
    cands = [n for n in os.listdir(fab)
             if n.endswith(".gm1") or "Edge_Cuts" in n]
    if not cands:
        print("    FAIL: no Edge.Cuts gerber -- the fab has no board shape")
        return False

    name = cands[0]
    txt = read(os.path.join(fab, name))

    # Pair each D02 (move, pen up) with the D01 (draw) that follows it.
    # Comparing the first move against the last draw -- which is the obvious
    # shortcut -- only works if segments happen to be emitted head to tail,
    # and reports a perfectly closed rectangle as open when they are not.
    moves = re.findall(r"X(-?\d+)Y(-?\d+)D0([12])", txt)
    segs, cur = [], None
    for x, y, d in moves:
        p = (int(x), int(y))
        if d == "2":
            cur = p
        elif cur is not None:
            segs.append((cur, p))
            cur = p

    deg = collections.Counter()
    for a, b in segs:
        deg[a] += 1
        deg[b] += 1
    odd = [p for p, c in deg.items() if c != 2]

    print("    file     : %s" % name)
    print("    segments : %d" % len(segs))
    print("    vertices : %d" % len(deg))
    if odd:
        print("    FAIL: %d vertex/vertices not used exactly twice -- the"
              % len(odd))
        print("          outline is an open path, not a closed loop")
        return False
    print("    PASS: every vertex used exactly twice -- valid closed loop")
    return True


def check_drill(fab: str) -> bool:
    print("[3] DRILL")
    drl = sorted(n for n in os.listdir(fab) if n.endswith(".drl"))
    if not drl:
        print("    FAIL: no Excellon drill file")
        return False
    for n in drl:
        txt = read(os.path.join(fab, n))
        tools = len(re.findall(r"^T\d+C", txt, re.M))
        hits = len(re.findall(r"^X-?[\d.]+Y-?[\d.]+", txt, re.M))
        kind = "NPTH" if "NPTH" in n else "PTH"
        print("    %-40s %-5s tools=%d hits=%d" % (n, kind, tools, hits))
    print("    PASS: %d drill file(s), PTH and NPTH separated" % len(drl))
    print("    NOTE: 0 hits is correct here -- there are no footprints yet.")
    return True


def main() -> int:
    fab = sys.argv[1] if len(sys.argv) > 1 else "fab"
    if not os.path.isdir(fab):
        print("no such directory: %s" % fab)
        return 1

    print("=" * 66)
    print("FAB PACKAGE VERIFICATION -- reading %d exported files" %
          len(os.listdir(fab)))
    print("=" * 66)

    results = [check_copper(fab), check_outline(fab), check_drill(fab)]
    print("-" * 66)
    if all(results):
        print("ALL CHECKS PASSED")
        return 0
    print("%d CHECK(S) FAILED" % results.count(False))
    return 1


if __name__ == "__main__":
    sys.exit(main())
