"""Tests for the Layer 20 opt-in loopback transport.

The first and most important test is that the transport REFUSES to work
when nobody asked for it. A transport that quietly activates is exactly the
failure the C++ shim was written to prevent.
"""

from __future__ import annotations

import os
import sys

import lrai_transport_loopback as T

checks = 0
errors = 0


def check(cond: bool, msg: str) -> None:
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print("FAIL [%s]" % msg)


print("=" * 66)
print("Layer 20: opt-in loopback transport")
print("=" * 66)

# --- 1. inert by default --------------------------------------------------
os.environ.pop("LIGHTRAIL_EMULATE", None)
check(not T.emulation_enabled(), "emulation is off when the variable is unset")
check(T.device_count() == 0, "reports ZERO devices when not opted in")
try:
    T.make_pair()
    check(False, "transport was created without opting in")
except T.TransportRefused:
    check(True, "refused to create a transport without opting in")

for val in ("0", "", "true", "yes", "2", " 1"):
    os.environ["LIGHTRAIL_EMULATE"] = val
    check(not T.emulation_enabled(), "value %r does not enable emulation" % val)
    check(T.device_count() == 0, "value %r still reports zero devices" % val)
print("default state  : 0 devices, transport refused")
print("only the exact string '1' enables it")

# --- 2. opt-in ------------------------------------------------------------
os.environ["LIGHTRAIL_EMULATE"] = "1"
check(T.emulation_enabled(), "LIGHTRAIL_EMULATE=1 enables emulation")
check(T.device_count() == 1, "reports one device once opted in")
check(T.EMU_TRANSPORT_ID == 0x4E434545, "transport id is NCEE")
print()
print("opted in       : %d device, id 0x%08X (%s)"
      % (T.device_count(), T.EMU_TRANSPORT_ID,
         bytes.fromhex("%08X" % T.EMU_TRANSPORT_ID).decode()))

a, b = T.make_pair()

# --- 3. bytes actually move ----------------------------------------------
payload = bytes(range(256)) * 16          # 4 KiB
sreq = a.isend(payload, tag=7)
rreq = b.irecv(len(payload), tag=7)
check(a.test(sreq), "send completes")
check(b.test(rreq), "receive completes once the message is there")
check(bytes(rreq.buf) == payload, "payload survives the round trip intact")
print("4 KiB payload  : %d bytes sent, %d received, contents match"
      % (a.bytes_sent, b.bytes_received))

# --- 4. a receive with nothing posted must NOT complete -------------------
pending = b.irecv(128, tag=99)
check(not b.test(pending), "a receive with no matching message stays pending")
check(not pending.done, "pending request is not marked done")
print("unmatched recv : stays pending, does not fabricate data")

# --- 5. size mismatch is refused, not truncated ---------------------------
a.isend(b"short", tag=11)
bad = b.irecv(4096, tag=11)
try:
    b.test(bad)
    check(False, "a size mismatch was silently accepted")
except T.TransportRefused:
    check(True, "size mismatch refused rather than truncated")
print("size mismatch  : refused, not truncated")

# --- 6. tags do not cross -------------------------------------------------
a.isend(b"AAAA", tag=1)
a.isend(b"BBBB", tag=2)
r2 = b.irecv(4, tag=2)
r1 = b.irecv(4, tag=1)
check(b.test(r2) and bytes(r2.buf) == b"BBBB", "tag 2 delivers its own data")
check(b.test(r1) and bytes(r1.buf) == b"AAAA", "tag 1 delivers its own data")
print("tag isolation  : out-of-order receive gets the right payload")

# --- 7. bidirectional -----------------------------------------------------
b.isend(b"reply", tag=5)
rr = a.irecv(5, tag=5)
check(a.test(rr) and bytes(rr.buf) == b"reply", "the peer can send back")
print("bidirectional  : yes")

# --- 8. no timing is claimed ---------------------------------------------
print()
print("NOTE Throughput is not measured and must not be. This models no")
print("     timing at all; any rate observed here describes this machine's")
print("     memcpy, not a fabric.")

os.environ.pop("LIGHTRAIL_EMULATE", None)
check(T.device_count() == 0, "returns to zero devices when opt-in is removed")

print()
print("-" * 66)
if errors == 0:
    print("PASS: loopback transport passed all %d checks." % checks)
else:
    print("FAIL: loopback transport had %d errors in %d checks." % (errors, checks))
print("-" * 66)
sys.exit(0 if errors == 0 else 1)
