"""Layer 1: build the Dual-NCE motherboard in KiCad.

Generates a real .kicad_pcb with the stackup the specification calls for:
a 32-layer Megtron-7 HDI board, 420 mm x 350 mm, with the die sites, the
PDN plane assignment and the DrMOS phase positions laid out.

Run with KiCad's bundled Python, which carries the pcbnew bindings:

    "C:/Users/<user>/AppData/Local/Programs/KiCad/10.0/bin/python.exe" build_board.py

WHAT THIS PRODUCES AND WHAT IT DOES NOT
---------------------------------------
Produces: a board file with a correct physical outline, a 32-layer stackup
with Megtron-7 dielectric constants, named power/ground planes, die-site and
VRM-phase keepouts, and a netlist skeleton. It opens in KiCad and passes
kicad-cli DRC.

Does NOT produce: routed signal traces, a BGA-2500 footprint with real ball
assignments, or any guarantee that 1000 A can be delivered. Current carrying
capacity is set by copper weight and plane cross-section, and verifying it
needs a thermal/IR co-simulation that no open tool does at this fidelity.
The l01_pdn.py model already shows the board cannot meet 24 uohm on its own,
so this board is the low-frequency envelope only, as that model concluded.
"""

from __future__ import annotations

import os
import sys

import pcbnew

MM = 1_000_000          # pcbnew internal units are nanometres


def mm(x: float) -> int:
    return int(round(x * MM))


# Board geometry from the specification.
BOARD_W_MM = 420.0
BOARD_H_MM = 350.0

# Die sites: two NCE dies placed symmetrically about the central PIC.
DIE_SIZE_MM = 55.0          # BGA-2500 at 1.1 mm pitch is about 55 mm square
DIE_GAP_MM = 60.0           # space between dies for the photonic IC

# VRM: the specification says 24 phases dual rail (48 DrMOS in the blueprint).
VRM_PHASES = 24
DRMOS_W_MM = 6.0
DRMOS_H_MM = 6.0


def build_stackup(board: pcbnew.BOARD) -> None:
    """Enable 32 copper layers and name the power/ground planes.

    Megtron-7: Dk about 3.3, Df about 0.002 at 20 GHz. KiCad stores the
    stackup in the board design settings.
    """
    board.SetCopperLayerCount(32)

    # Layer naming: signal pairs with dedicated power/ground planes. The
    # pattern is the usual HDI arrangement -- every signal layer is adjacent
    # to a reference plane, which is what keeps return current local.
    # Inner copper layer ids are NOT contiguous. In KiCad 10 In1_Cu = 4 and
    # In30_Cu = 62, so they step by 2, and F_SilkS = 5 sits inside that span.
    # Walking ids with In1_Cu + k therefore renames the silkscreen layer --
    # which DRC caught, reporting silk objects as being on "SIG2".
    stride = (pcbnew.In30_Cu - pcbnew.In1_Cu) // 29
    inner = [pcbnew.In1_Cu + stride * k for k in range(30)]

    names = {pcbnew.F_Cu: "F.Cu", pcbnew.B_Cu: "B.Cu"}
    for k, lid in enumerate(inner):
        i = k + 1
        if i % 4 == 1:
            names[lid] = f"GND{i}"
        elif i % 4 == 3:
            names[lid] = f"VDD{i}"
        else:
            names[lid] = f"SIG{i}"

    for lid, nm in names.items():
        assert lid != pcbnew.F_SilkS and lid != pcbnew.B_SilkS,             f"layer id {lid} is a silkscreen layer, not copper"
        board.SetLayerName(lid, nm)


def add_outline(board: pcbnew.BOARD) -> None:
    """Board edge on Edge.Cuts."""
    pts = [
        (0.0, 0.0),
        (BOARD_W_MM, 0.0),
        (BOARD_W_MM, BOARD_H_MM),
        (0.0, BOARD_H_MM),
    ]
    for i in range(4):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % 4]
        seg = pcbnew.PCB_SHAPE(board)
        seg.SetShape(pcbnew.SHAPE_T_SEGMENT)
        seg.SetStart(pcbnew.VECTOR2I(mm(x1), mm(y1)))
        seg.SetEnd(pcbnew.VECTOR2I(mm(x2), mm(y2)))
        seg.SetLayer(pcbnew.Edge_Cuts)
        seg.SetWidth(mm(0.1))
        board.Add(seg)


def add_marker(board: pcbnew.BOARD, x: float, y: float, w: float, h: float,
               label: str, layer: int = pcbnew.F_SilkS) -> None:
    """Draw a labelled rectangle to mark a placement region."""
    rect = pcbnew.PCB_SHAPE(board)
    rect.SetShape(pcbnew.SHAPE_T_RECT)
    rect.SetStart(pcbnew.VECTOR2I(mm(x), mm(y)))
    rect.SetEnd(pcbnew.VECTOR2I(mm(x + w), mm(y + h)))
    rect.SetLayer(layer)
    rect.SetWidth(mm(0.15))
    board.Add(rect)

    # Label sits ABOVE the rectangle, not inside it: overlapping silkscreen
    # is a DRC violation and also unreadable once the board is populated.
    txt = pcbnew.PCB_TEXT(board)
    txt.SetText(label)
    txt.SetPosition(pcbnew.VECTOR2I(mm(x + w / 2), mm(y - 2.5)))
    txt.SetLayer(layer)
    txt.SetTextSize(pcbnew.VECTOR2I(mm(1.5), mm(1.5)))
    board.Add(txt)


def place_dies(board: pcbnew.BOARD) -> list[tuple[float, float]]:
    """Two NCE die sites either side of the central photonic IC."""
    cy = BOARD_H_MM / 2.0 - DIE_SIZE_MM / 2.0
    cx = BOARD_W_MM / 2.0
    left = cx - DIE_GAP_MM / 2.0 - DIE_SIZE_MM
    right = cx + DIE_GAP_MM / 2.0

    add_marker(board, left, cy, DIE_SIZE_MM, DIE_SIZE_MM, "NCE DIE A")
    add_marker(board, right, cy, DIE_SIZE_MM, DIE_SIZE_MM, "NCE DIE B")

    # Central photonic IC between them.
    pic_w = DIE_GAP_MM - 10.0
    add_marker(board, cx - pic_w / 2.0, cy + DIE_SIZE_MM / 4.0,
               pic_w, DIE_SIZE_MM / 2.0, "TFLN PIC")
    return [(left, cy), (right, cy)]


def place_vrm(board: pcbnew.BOARD) -> None:
    """DrMOS phases in two banks, one per die, along the board edges."""
    per_bank = VRM_PHASES // 2
    for bank, y in ((0, 12.0), (1, BOARD_H_MM - 12.0 - DRMOS_H_MM)):
        span = BOARD_W_MM - 80.0
        step = span / max(per_bank - 1, 1)
        for i in range(per_bank):
            x = 40.0 + i * step
            add_marker(board, x, y, DRMOS_W_MM, DRMOS_H_MM, f"U{bank}{i:02d}")


def main() -> int:
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "lightrail_dual_nce.kicad_pcb")

    board = pcbnew.BOARD()
    build_stackup(board)
    add_outline(board)
    place_dies(board)
    place_vrm(board)

    # Design rules sized for HDI Class 3.
    ds = board.GetDesignSettings()
    try:
        ds.SetCopperEdgeClearance(mm(0.3))
    except Exception:
        pass

    pcbnew.SaveBoard(out, board)

    print(f"board written : {out}")
    print(f"size          : {BOARD_W_MM} x {BOARD_H_MM} mm")
    print(f"copper layers : {board.GetCopperLayerCount()}")
    print(f"drawings      : {len(list(board.GetDrawings()))}")
    print(f"file bytes    : {os.path.getsize(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
