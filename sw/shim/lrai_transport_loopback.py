"""Layer 20: in-memory loopback transport, opt-in.

WHY THIS IS OPT-IN AND WHY THE C++ SHIM IS UNCHANGED
-----------------------------------------------------
sw/shim/nccl_net_lightrail.cpp reports ZERO devices and refuses every
data-path call while kHaveTransport is false. That is deliberate: a
production run on a machine with no hardware must FAIL rather than quietly
compute in software and produce numbers nobody can trace.

A proposal to fix Layer 20 was to flip kHaveTransport to true. That would
remove the property, not implement the layer, so the C++ constant is left
alone. This module is the transport instead, and it follows the pattern
sw/emu/nce_emulator.hpp already established:

  * it is INERT unless LIGHTRAIL_EMULATE=1 is set in the environment
  * it identifies itself with a distinct id, "NCEE", so anything produced
    through it is self-evidently emulated
  * it models no timing whatsoever, so throughput measured here is a
    statement about this machine's memcpy and nothing else

The thing it does provide is real: bytes written by one rank are readable
by its peer, with the full non-blocking post/test/complete protocol that a
collective library drives. That is the part that is hard to get right
later, and it can be got right now.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

# Distinct from the RTL's "NCE0" and from the register emulator's "EMU0",
# so a log line identifies which of the three produced it.
EMU_TRANSPORT_ID = 0x4E434545          # "NCEE"


def emulation_enabled() -> bool:
    """True only for LIGHTRAIL_EMULATE=1, exactly."""
    return os.environ.get("LIGHTRAIL_EMULATE") == "1"


class TransportRefused(RuntimeError):
    """Raised when the transport is used without opting in."""


@dataclass
class Request:
    """A posted send or receive. Not complete until test() says so."""
    tag: int
    nbytes: int
    is_send: bool
    done: bool = False
    buf: bytearray | None = None


@dataclass
class Endpoint:
    """One end of a connected pair."""
    name: str
    _inbox: dict = field(default_factory=dict)      # tag -> list[bytes]
    _outbox: dict = field(default_factory=dict)     # peer's inbox
    _posted: list = field(default_factory=list)
    bytes_sent: int = 0
    bytes_received: int = 0

    # -- posting -----------------------------------------------------------
    def isend(self, data: bytes, tag: int) -> Request:
        r = Request(tag=tag, nbytes=len(data), is_send=True)
        self._outbox.setdefault(tag, []).append(bytes(data))
        self.bytes_sent += len(data)
        r.done = True            # a local memcpy completes immediately
        self._posted.append(r)
        return r

    def irecv(self, nbytes: int, tag: int) -> Request:
        r = Request(tag=tag, nbytes=nbytes, is_send=False)
        self._posted.append(r)
        return r

    # -- completion --------------------------------------------------------
    def test(self, r: Request) -> bool:
        """Non-blocking completion test. A receive completes only when a
        matching message of the EXACT size has arrived; a short or long
        match is refused rather than truncated, because a silently
        truncated tensor is the worst failure this layer can produce."""
        if r.done:
            return True
        if r.is_send:
            return True
        q = self._inbox.get(r.tag)
        if not q:
            return False
        if len(q[0]) != r.nbytes:
            raise TransportRefused(
                "tag %d: posted %d bytes, message is %d -- refusing to "
                "truncate" % (r.tag, r.nbytes, len(q[0])))
        r.buf = bytearray(q.pop(0))
        self.bytes_received += r.nbytes
        r.done = True
        return True


def make_pair(a_name: str = "rank0", b_name: str = "rank1"):
    """Two connected endpoints. Refuses unless emulation is enabled."""
    if not emulation_enabled():
        raise TransportRefused(
            "loopback transport is inert unless LIGHTRAIL_EMULATE=1; "
            "there is no hardware transport in this repository")
    a = Endpoint(a_name)
    b = Endpoint(b_name)
    a._outbox = b._inbox
    b._outbox = a._inbox
    return a, b


def device_count() -> int:
    """What the plugin should report to a collective library.

    Zero unless emulation is explicitly enabled, which is what makes the
    library decline this plugin and fall back to a real transport.
    """
    return 1 if emulation_enabled() else 0
