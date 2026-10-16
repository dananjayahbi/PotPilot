"""PC asyncio UDP receiver — Doc 13 (`plan-series/13_pc_asyncio_udp_receiver.md`).

High-throughput ``asyncio.DatagramProtocol`` bound to UDP 50505. Datagrams are
the frozen 8-byte ``<BBhhH`` layout (Doc 02; authority is the shared codec in
``udp_packet_codec.py``). The hot path runs synchronously on the event loop
thread — no queues, no awaits — to hold the < 2 ms dispatch budget.

Seams are constructor-injected (never imported at module level):
- ``auth`` — Doc 15 middleware exposing ``verify_udp_auth_byte(byte) -> bool``;
- ``mouse`` — Doc 06 mouse engine (``move_relative`` / ``scroll`` / ``button``);
- ``scrub_sink`` — Doc 09 seek handler wired in ``main.py`` (optional at
  construction for graceful partial startup).
"""

from __future__ import annotations

import asyncio
import logging
import socket
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from pc_agent.network import udp_packet_codec as codec
from pc_agent.network.udp_packet_codec import PacketError, join_seek_seconds, unpack_packet

log = logging.getLogger(__name__)

# --- Frozen wire constants (Doc 02 / overview §4.1) -------------------------
UDP_HOST: str = "0.0.0.0"
UDP_PORT: int = 50505
PACKET_FMT: str = codec.PACKET_FORMAT  # "<BBhhH" little-endian, fixed 8 bytes
PACKET_SIZE: int = codec.PACKET_SIZE
TYPE_MOUSE_MOVE: int = 0x01
TYPE_SCROLL: int = 0x02
TYPE_BUTTON: int = 0x03
TYPE_SCRUB: int = 0x04

# --- Tunable operational constants (Doc 13 §10 A3) -------------------------
RCVBUF_BYTES: int = 1_048_576  # kernel receive buffer for 120 Hz bursts
PEER_TIMEOUT_S: int = 300
MAX_PEERS: int = 128
MAX_SCRUB_SECONDS: int = 86_400  # 24 h sanity cap on scrub targets
_SEQ_WRAP_HALF: int = 0x7FFF
_PRUNE_EVERY_PACKETS: int = 2048
_AUTH_WARN_INTERVAL_S: float = 1.0

_VALID_BUTTON_IDS = frozenset({1, 2, 3})
_VALID_BUTTON_STATES = frozenset({1, 2, 3})


@dataclass(frozen=True, slots=True)
class UdpPacket:
    """Decoded wire fields of one 8-byte datagram."""

    ptype: int
    auth: int
    arg1: int
    arg2: int
    seq: int


@dataclass(slots=True)
class UdpStats:
    """Per-server counters; readable after shutdown for the dashboard."""

    received: int = 0
    accepted: int = 0
    parse_drops: int = 0
    auth_failures: int = 0
    seq_drops: int = 0
    bad_args: int = 0


class MouseEngine(Protocol):
    """Structural subset of the Doc 06 SendInput mouse engine."""

    def move_relative(self, dx: int, dy: int) -> None: ...

    def scroll(self, vertical: int, horizontal: int) -> None: ...

    def button(self, button_id: int, state: int) -> None: ...


class UdpAuthVerifier(Protocol):
    """Structural subset of the Doc 15 auth middleware (UDP path)."""

    def verify_udp_auth_byte(self, byte: int) -> bool: ...


ScrubSink = Callable[[int], None]


def parse_packet(data: bytes) -> UdpPacket | None:
    """Decode one datagram via the shared codec; ``None`` on any wire violation."""
    try:
        ptype, auth, arg1, arg2, seq = unpack_packet(data)
    except PacketError:
        return None
    return UdpPacket(ptype=ptype, auth=auth, arg1=arg1, arg2=arg2, seq=seq)


class SequenceTracker:
    """Wrap-aware duplicate/out-of-order filter plus bounded peer bookkeeping.

    Per ``(ip, port)`` peer the first packet is accepted; afterwards
    ``delta = (seq - last) & 0xFFFF`` is accepted iff ``1 <= delta <= 0x7FFF``.
    That drops duplicates and rewinds while surviving the uint16 wrap
    65535 -> 0.
    """

    def __init__(
        self,
        *,
        clock: Callable[[], float] = time.monotonic,
        timeout_s: float = PEER_TIMEOUT_S,
        max_peers: int = MAX_PEERS,
    ) -> None:
        self._clock = clock
        self._timeout_s = timeout_s
        self._max_peers = max_peers
        self._peers: dict[tuple[str, int], tuple[int, float]] = {}

    def accept(self, peer: tuple[str, int], seq: int) -> bool:
        """Return True iff ``seq`` is fresh for ``peer``; track last-seen on accept."""
        last = self._peers.get(peer)
        now = self._clock()
        if last is not None:
            delta = (seq - last[0]) & 0xFFFF
            if not 1 <= delta <= _SEQ_WRAP_HALF:
                return False
        elif len(self._peers) >= self._max_peers:
            self._evict_oldest()
        self._peers[peer] = (seq & 0xFFFF, now)
        return True

    def prune(self) -> None:
        """Evict peers idle longer than the timeout."""
        now = self._clock()
        stale = [peer for peer, (_, seen) in self._peers.items() if now - seen > self._timeout_s]
        for peer in stale:
            del self._peers[peer]

    def clear(self) -> None:
        """Drop every peer entry (shutdown)."""
        self._peers.clear()

    @property
    def peer_count(self) -> int:
        return len(self._peers)

    def _evict_oldest(self) -> None:
        if self._peers:
            oldest = min(self._peers, key=lambda peer: self._peers[peer][1])
            del self._peers[oldest]


class UdpReceiverProtocol(asyncio.DatagramProtocol):
    """Receives 8-byte datagrams, gates them (length/auth/seq), dispatches sync."""

    def __init__(
        self,
        *,
        auth: UdpAuthVerifier,
        mouse: MouseEngine,
        scrub_sink: ScrubSink | None = None,
        stats: UdpStats | None = None,
        clock: Callable[[], float] = time.monotonic,
        tracker: SequenceTracker | None = None,
    ) -> None:
        self._auth = auth
        self._mouse = mouse
        self._scrub_sink = scrub_sink
        self.stats = stats if stats is not None else UdpStats()
        self._tracker = tracker if tracker is not None else SequenceTracker(clock=clock)
        self._transport: asyncio.DatagramTransport | None = None
        self._auth_warn_at: dict[tuple[str, int], float] = {}
        self._packets_since_prune = 0
        self._scrub_sink_warned = False

    # -- DatagramProtocol --------------------------------------------------
    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self._transport = transport  # type: ignore[assignment]

    def error_received(self, exc: Exception) -> None:
        log.debug("UDP socket error: %s", exc)

    def connection_lost(self, exc: Exception | None) -> None:
        self._tracker.clear()
        self._auth_warn_at.clear()

    # -- Hot path (synchronous, Doc 13 §4.2) -------------------------------
    def datagram_received(self, data: bytes, addr: tuple[str | int, ...]) -> None:
        stats = self.stats
        stats.received += 1
        peer = (str(addr[0]), int(addr[1]))

        packet = parse_packet(data)
        if packet is None:
            stats.parse_drops += 1  # wrong length or unknown ptype; debug only
            return

        if not self._auth.verify_udp_auth_byte(packet.auth):
            stats.auth_failures += 1
            self._warn_auth_failure(peer)
            return

        if not self._tracker.accept(peer, packet.seq):
            stats.seq_drops += 1
            return

        if self._dispatch(packet):
            stats.accepted += 1

        self._packets_since_prune += 1
        if self._packets_since_prune >= _PRUNE_EVERY_PACKETS:
            self._packets_since_prune = 0
            self._tracker.prune()

    # -- Internals ---------------------------------------------------------
    def _dispatch(self, packet: UdpPacket) -> bool:
        """Route by ptype; False means dropped (counted in ``bad_args``)."""
        if packet.ptype == TYPE_MOUSE_MOVE:
            self._mouse.move_relative(packet.arg1, packet.arg2)
            return True
        if packet.ptype == TYPE_SCROLL:
            self._mouse.scroll(packet.arg1, packet.arg2)
            return True
        if packet.ptype == TYPE_BUTTON:
            if (
                packet.arg1 not in _VALID_BUTTON_IDS
                or packet.arg2 not in _VALID_BUTTON_STATES
            ):
                self.stats.bad_args += 1
                return False
            self._mouse.button(packet.arg1, packet.arg2)
            return True
        if packet.ptype == TYPE_SCRUB:
            target_s = join_seek_seconds(packet.arg1, packet.arg2)
            if target_s > MAX_SCRUB_SECONDS:
                self.stats.bad_args += 1
                return False
            if self._scrub_sink is None:
                # Graceful partial startup (Doc 13 §7): aggregated warning, no crash.
                self.stats.bad_args += 1
                if not self._scrub_sink_warned:
                    self._scrub_sink_warned = True
                    log.warning("scrub packets dropping: no scrub sink wired yet")
                return False
            self._scrub_sink(target_s)
            return True
        return False  # unreachable: parse_packet already filters unknown ptypes

    def _warn_auth_failure(self, peer: tuple[str, int]) -> None:
        """Rate-limited warning: at most one log per peer per second."""
        now = time.monotonic()
        last = self._auth_warn_at.get(peer)
        if last is None or now - last >= _AUTH_WARN_INTERVAL_S:
            self._auth_warn_at[peer] = now
            log.warning("dropping UDP packet from %s: auth byte mismatch", peer)
        if len(self._auth_warn_at) > 4 * MAX_PEERS:
            self._auth_warn_at = {
                p: t for p, t in self._auth_warn_at.items() if now - t < _AUTH_WARN_INTERVAL_S
            }


@dataclass(frozen=True)
class UdpServerHandle:
    """Lifecycle handle returned by :func:`start_udp_server`."""

    transport: asyncio.DatagramTransport
    protocol: UdpReceiverProtocol

    async def stop(self) -> None:
        """Close the transport and clear peer state; stats remain readable."""
        self.transport.close()
        self.protocol.connection_lost(None)

    @property
    def stats(self) -> UdpStats:
        return self.protocol.stats

    @property
    def port(self) -> int:
        """Actual bound port (useful when started with ``port=0``)."""
        sockname = self.transport.get_extra_info("sockname")
        return int(sockname[1]) if sockname else 0


async def start_udp_server(
    *,
    auth: UdpAuthVerifier,
    mouse: MouseEngine,
    scrub_sink: ScrubSink | None = None,
    host: str = UDP_HOST,
    port: int = UDP_PORT,
) -> UdpServerHandle:
    """Bind the UDP receiver; raises ``RuntimeError`` with context on bind failure."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setblocking(False)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RCVBUF_BYTES)
        sock.bind((host, port))
    except OSError as exc:
        sock.close()
        raise RuntimeError(f"UDP receiver could not bind {host}:{port}: {exc}") from exc

    def factory() -> UdpReceiverProtocol:
        return UdpReceiverProtocol(auth=auth, mouse=mouse, scrub_sink=scrub_sink)

    try:
        transport, protocol = await asyncio.get_running_loop().create_datagram_endpoint(
            factory, sock=sock
        )
    except OSError as exc:
        sock.close()
        raise RuntimeError(f"UDP receiver could not start on {host}:{port}: {exc}") from exc
    log.info("UDP receiver listening on %s:%s", host, transport.get_extra_info("sockname")[1])
    return UdpServerHandle(transport=transport, protocol=protocol)
