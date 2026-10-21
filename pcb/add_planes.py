"""eda-pcb Step 6: turn the named plane layers into actual copper.

build_board.py NAMES layers GND1, VDD3 and so on. A name is not copper: the
board had zero zones, so every "plane" was an empty layer and the PDN model's
plane resistance had nothing behind it on this board. This adds a filled zone
on each power and ground layer and reports the resistance it actually buys.

Nets are created directly rather than imported from a netlist, because there
is no schematic yet. That is legitimate for planes -- a plane's net is the
rail, not a pin -- but it is the ONLY thing that can be done this way. Signal
routing still needs the netlist.

Run with KiCad's bundled Python:
    ".../KiCad/10.0/bin/python.exe" add_planes.py
"""

from __future__ import annotations

import os
import sys

import pcbnew

MM = 1_000_000
RHO_CU = 1.72e-8          # ohm.m
T_CU_M = 35e-6            # 1 oz


def mm(x: float) -> int:
    return int(round(x * MM))


BOARD_W_MM, BOARD_H_MM = 420.0, 350.0
INSET_MM = 0.5            # pull the pour back from the edge, > the 0.3 rule


def plane_layers(board: pcbnew.BOARD) -> dict[int, str]:
    """Collect the layers build_board.py named as power or ground."""
    out = {}
    for lid in board.GetEnabledLayers().CuStack():
        nm = board.GetLayerName(lid)
        if nm.startswith("GND") or nm.startswith("VDD"):
            out[lid] = nm
    return out


def ensure_net(board: pcbnew.BOARD, name: str) -> pcbnew.NETINFO_ITEM:
    net = board.FindNet(name)
    if net is None:
        net = pcbnew.NETINFO_ITEM(board, name)
        board.Add(net)
    return net


def add_zone(board: pcbnew.BOARD, lid: int, net: pcbnew.NETINFO_ITEM) -> pcbnew.ZONE:
    zone = pcbnew.ZONE(board)
    zone.SetLayer(lid)
    zone.SetNet(net)
    zone.SetIsFilled(True)
    zone.SetLocalClearance(mm(0.15))
    zone.SetMinThickness(mm(0.15))

    poly = zone.Outline()
    poly.NewOutline()
    for x, y in ((INSET_MM, INSET_MM),
                 (BOARD_W_MM - INSET_MM, INSET_MM),
                 (BOARD_W_MM - INSET_MM, BOARD_H_MM - INSET_MM),
                 (INSET_MM, BOARD_H_MM - INSET_MM)):
        poly.Append(mm(x), mm(y))

    board.Add(zone)
    return zone


def sheet_resistance_ohm_sq() -> float:
    return RHO_CU / T_CU_M


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "lightrail_dual_nce.kicad_pcb")
    board = pcbnew.LoadBoard(path)

    layers = plane_layers(board)
    if not layers:
        print("no GND/VDD layers found -- run build_board.py first")
        return 1

    before = len(list(board.Zones()))
    # Idempotent: drop any zones already present. Running this twice without
    # it leaves two overlapping fills per plane layer -- which happened, and
    # produced 30 zones on 15 layers, because build_board.py was failing and
    # the board was never actually regenerated underneath.
    for z in list(board.Zones()):
        board.Remove(z)

    gnd = ensure_net(board, "GND")
    vdd = ensure_net(board, "VDD")

    n_gnd = n_vdd = 0
    for lid, nm in sorted(layers.items()):
        net = gnd if nm.startswith("GND") else vdd
        add_zone(board, lid, net)
        if nm.startswith("GND"):
            n_gnd += 1
        else:
            n_vdd += 1

    filler = pcbnew.ZONE_FILLER(board)
    filler.Fill(board.Zones())
    pcbnew.SaveBoard(path, board)

    # --- what the copper actually buys -----------------------------------
    rs = sheet_resistance_ohm_sq()
    # VRM bank to die: the DrMOS rows sit 12 mm from each edge and the dies
    # are centred, so the spreading run is roughly a quarter of the height.
    run_mm = BOARD_H_MM / 4.0
    squares = run_mm / BOARD_W_MM
    r_one = rs * squares
    r_par = r_one / max(n_vdd, 1)

    print("zones before      : %d" % before)
    print("zones added       : %d  (%d GND, %d VDD)" % (n_gnd + n_vdd, n_gnd, n_vdd))
    print("zones now         : %d" % len(list(board.Zones())))
    print("copper layers     : %d" % board.GetCopperLayerCount())
    print()
    print("sheet resistance  : %.4f mohm/square (1 oz)" % (rs * 1e3))
    print("VRM-to-die run    : %.0f mm over %.0f mm width = %.4f squares"
          % (run_mm, BOARD_W_MM, squares))
    print("one VDD plane     : %.1f uohm" % (r_one * 1e6))
    print("%2d VDD in parallel: %.1f uohm" % (n_vdd, r_par * 1e6))
    print()
    print("PDN target        : 24.0 uohm")
    print("plane term alone  : %.1f uohm  (%.2fx target)"
          % (r_par * 1e6, r_par * 1e6 / 24.0))
    print()
    print("This is the PLANE SPREADING term only, and it is the most")
    print("favourable term in the budget. It does not include via, package,")
    print("BGA ball or on-die resistance, which is where l01_pdn.py finds")
    print("the 296x shortfall. A plane term under target does not rescue")
    print("that -- it confirms the deficit is not in the planes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
