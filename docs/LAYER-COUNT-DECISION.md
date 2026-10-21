# Layer count: 32

Recorded because `eda-pcb` Step 1.5 requires the layer count to be a decision
with a reason attached, not an inherited number.

## Decision

32 copper layers, in the repeating pattern `GND / SIG / VDD / SIG`.

## Why not fewer

The count is set by two independent demands that do not share layers.

**Power.** The PDN target is 24 uohm at the die. Plane resistance falls as
`1/N` for N parallel planes, so halving the plane count doubles the IR drop.
`photonics/l01_pdn.py` already shows the board misses 24 uohm by 296x with the
planes it has; removing planes makes an already-failing number worse. The 15
power and ground layers are the floor, not a preference.

**Signalling.** Every PAM4 layer must sit between two reference planes or its
return current has nowhere local to go. In the `GND/SIG/VDD/SIG` pattern each
signal layer gets that for free. Thinning the stack breaks the adjacency and
forces return current through stitching vias, which at 50 GHz is a stub.

## Why not more

The drill. See `STACKUP-DECISION.md`: at 32 layers the board is already
4.54 mm and the through-via aspect ratio is 15.1:1, inside advanced capability
but outside the standard 10:1 process. Layer 33 onwards makes the board
unmanufacturable as a through-via design and forces a full HDI build-up with
sequential lamination.

## What this rules out

32 layers at 420 x 350 mm is not a JLCPCB order. It is within their stated
layer and size capability, but the material and aspect ratio are not --
see `../pcb/FAB_NOTES.md`.
