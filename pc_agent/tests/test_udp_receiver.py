"""Unit + integration tests for the Doc 13 asyncio UDP receiver."""

from __future__ import annotations

import asyncio
import socket
import struct

from pc_agent.network.udp_packet_codec import pack_packet, split_seek_seconds
from pc_agent.network.udp_server import (
    MAX_PEERS,
    MAX_SCRUB_SECONDS,
    PEER_TIMEOUT_S,
    SequenceTracker,
    UdpReceiverProtocol,
    UdpStats,
    parse_packet,
    start_udp_server,
)

AUTH_BYTE = 0x5A
PEER = ("10.0.0.5", 40000)


class FakeAuth:
    """Doc 15 seam: accepts exactly one auth byte."""

    def __init__(self, ok_byte: int = AUTH_BYTE) -> None:
        self.ok_byte = ok_byte
        self.calls: list[int] = []

    def verify_udp_auth_byte(self, byte: int) -> bool:
        self.calls.append(byte)
        return byte == self.ok_byte


class FakeMouse:
    """Doc 06 seam: records every sink call."""

    def __init__(self) -> None:
        self.moves: list[tuple[int, int]] = []
        self.scrolls: list[tuple[int, int]] = []
        self.buttons: list[tuple[int, int]] = []

    def move_relative(self, dx: int, dy: int) -> None:
        self.moves.append((dx, dy))

    def scroll(self, vertical: int, horizontal: int) -> None:
        self.scrolls.append((vertical, horizontal))

    def button(self, button_id: int, state: int) -> None:
        self.buttons.append((button_id, state))


class FakeClock:
    def __init__(self, now: float = 1000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def make_protocol(**overrides) -> tuple[UdpReceiverProtocol, FakeMouse, FakeAuth, list[int]]:
    mouse = overrides.pop("mouse", None) or FakeMouse()
    auth = overrides.pop("auth", None) or FakeAuth()
    scrub_targets: list[int] | None = overrides.pop("scrub_targets", None)
    if "scrub_sink" not in overrides:
        if scrub_targets is None:
            scrub_targets = []
        overrides["scrub_sink"] = scrub_targets.append
    protocol = UdpReceiverProtocol(auth=auth, mouse=mouse, **overrides)
    return protocol, mouse, auth, (scrub_targets if scrub_targets is not None else [])


def feed(protocol: UdpReceiverProtocol, data: bytes, addr: tuple[str, int] = PEER) -> None:
    protocol.datagram_received(data, addr)


def test_parse_packet_valid_and_invalid() -> None:
    data = pack_packet(0x01, AUTH_BYTE, 25, -15, 7)
    packet = parse_packet(data)
    assert packet is not None
    assert (packet.ptype, packet.auth, packet.arg1, packet.arg2, packet.seq) == (
        0x01,
        AUTH_BYTE,
        25,
        -15,
        7,
    )
    assert parse_packet(data[:7]) is None  # 7-byte datagram
    assert parse_packet(data + b"\x00") is None  # 9-byte datagram
    assert parse_packet(b"") is None


def test_dispatch_by_type() -> None:
    protocol, mouse, _, scrub_targets = make_protocol()
    feed(protocol, pack_packet(0x01, AUTH_BYTE, 25, -15, 1))
    feed(protocol, pack_packet(0x02, AUTH_BYTE, -3, 0, 2))
    feed(protocol, pack_packet(0x03, AUTH_BYTE, 1, 3, 3))
    feed(protocol, pack_packet(0x04, AUTH_BYTE, *split_seek_seconds(3661), 4))
    assert mouse.moves == [(25, -15)]
    assert mouse.scrolls == [(-3, 0)]
    assert mouse.buttons == [(1, 3)]
    assert scrub_targets == [3661]
    assert protocol.stats == UdpStats(received=4, accepted=4)


def test_auth_failure_drops() -> None:
    protocol, mouse, auth, scrub_targets = make_protocol()
    feed(protocol, pack_packet(0x01, AUTH_BYTE ^ 0xFF, 10, 10, 1))
    assert mouse.moves == []
    assert scrub_targets == []
    assert auth.calls == [AUTH_BYTE ^ 0xFF]
    assert protocol.stats == UdpStats(received=1, auth_failures=1)


def test_sequence_tracker_wrap() -> None:
    clock = FakeClock()
    tracker = SequenceTracker(clock=clock)
    assert tracker.accept(PEER, 65534) is True
    assert tracker.accept(PEER, 65535) is True
    assert tracker.accept(PEER, 0) is True  # uint16 wrap 65535 -> 0
    assert tracker.accept(PEER, 1) is True
    assert tracker.accept(PEER, 0) is False  # rewind 1 -> 0
    assert tracker.accept(PEER, 1) is False  # duplicate 1 -> 1
    # Protocol-level: duplicates land in seq_drops, sinks stay silent.
    protocol, mouse, _, _ = make_protocol()
    feed(protocol, pack_packet(0x01, AUTH_BYTE, 1, 1, 10))
    feed(protocol, pack_packet(0x01, AUTH_BYTE, 2, 2, 10))  # duplicate
    feed(protocol, pack_packet(0x01, AUTH_BYTE, 3, 3, 9))  # out of order
    assert mouse.moves == [(1, 1)]
    assert protocol.stats == UdpStats(received=3, accepted=1, seq_drops=2)


def test_peer_prune_and_cap() -> None:
    clock = FakeClock()
    tracker = SequenceTracker(clock=clock, max_peers=3)
    assert tracker.accept(("10.0.0.1", 1), 1) is True
    clock.now += 1
    assert tracker.accept(("10.0.0.2", 2), 1) is True
    clock.now += 1
    assert tracker.accept(("10.0.0.3", 3), 1) is True
    clock.now += 1
    assert tracker.accept(("10.0.0.4", 4), 1) is True  # evicts oldest (10.0.0.1)
    assert tracker.peer_count == 3
    assert tracker.accept(("10.0.0.1", 1), 1) is True  # evicted peer counts as new
    assert tracker.peer_count == 3
    clock.now += PEER_TIMEOUT_S + 1
    tracker.prune()
    assert tracker.peer_count == 0


def test_peer_cap_bound_holds_under_churn() -> None:
    clock = FakeClock()
    tracker = SequenceTracker(clock=clock, max_peers=MAX_PEERS)
    for index in range(MAX_PEERS + 50):
        clock.now += 0.001
        assert tracker.accept((f"10.1.0.{index % 200}", index), 1) is True
    assert tracker.peer_count <= MAX_PEERS


def test_scrub_reconstruction() -> None:
    protocol, _, _, scrub_targets = make_protocol()
    high, low = split_seek_seconds(40_000)
    feed(protocol, pack_packet(0x04, AUTH_BYTE, high, low, 1))
    assert scrub_targets == [40_000]
    assert protocol.stats.accepted == 1


def test_scrub_cap_and_missing_sink() -> None:
    # Seconds above the 24 h cap are rejected (bad_args), sink never called.
    protocol, _, _, scrub_targets = make_protocol()
    high, low = split_seek_seconds(MAX_SCRUB_SECONDS)  # exactly 24 h: allowed
    feed(protocol, pack_packet(0x04, AUTH_BYTE, high, low, 1))
    assert scrub_targets == [MAX_SCRUB_SECONDS]
    over_high, over_low = split_seek_seconds(MAX_SCRUB_SECONDS + 1)
    feed(protocol, pack_packet(0x04, AUTH_BYTE, over_high, over_low, 2))
    assert protocol.stats.bad_args == 1

    # Missing scrub sink: graceful partial startup, mouse path unaffected.
    protocol2, mouse2, _, _ = make_protocol(scrub_sink=None)
    feed(protocol2, pack_packet(0x04, AUTH_BYTE, high, low, 1))
    feed(protocol2, pack_packet(0x01, AUTH_BYTE, 5, 6, 2))
    assert mouse2.moves == [(5, 6)]
    assert protocol2.stats.bad_args == 1
    assert protocol2.stats.accepted == 1


def test_invalid_button_args_counted() -> None:
    protocol, mouse, _, _ = make_protocol()
    # struct-level craft: the codec refuses to serialize invalid button args.
    feed(protocol, struct.pack("<BBhhH", 0x03, AUTH_BYTE, 9, 1, 1))  # bad button_id
    assert mouse.buttons == []
    assert protocol.stats.bad_args == 1
    assert protocol.stats.accepted == 0


def test_udp_server_roundtrip() -> None:
    """Integration smoke: real socket on localhost, fake sinks record packets."""
    auth = FakeAuth()
    mouse = FakeMouse()
    scrub_targets: list[int] = []

    async def scenario() -> tuple[int, UdpStats]:
        handle = await start_udp_server(
            auth=auth, mouse=mouse, scrub_sink=scrub_targets.append, host="127.0.0.1", port=0
        )
        port = handle.port
        assert port > 0
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.sendto(pack_packet(0x01, AUTH_BYTE, 25, -15, 1), ("127.0.0.1", port))
            sock.sendto(pack_packet(0x01, AUTH_BYTE ^ 0xFF, 99, 99, 2), ("127.0.0.1", port))
            sock.sendto(pack_packet(0x01, AUTH_BYTE, 1, 1, 1), ("127.0.0.1", port))  # dup seq
            sock.sendto(pack_packet(0x02, AUTH_BYTE, -2, 0, 3), ("127.0.0.1", port))
            sock.sendto(b"\x01\x02\x03", ("127.0.0.1", port))  # wrong length
            scrub = pack_packet(0x04, AUTH_BYTE, *split_seek_seconds(90), 4)
            sock.sendto(scrub, ("127.0.0.1", port))
            await asyncio.sleep(0.1)
            stats = handle.stats
            await handle.stop()
            return port, stats
        finally:
            sock.close()

    port, stats = asyncio.run(scenario())
    assert mouse.moves == [(25, -15)]  # duplicate-seq move never reached the sink
    assert mouse.scrolls == [(-2, 0)]
    assert scrub_targets == [90]
    assert stats.received == 6
    assert stats.accepted == 3
    assert stats.auth_failures == 1
    assert stats.seq_drops == 1
    assert stats.parse_drops == 1
    # stop() released the port: an immediate rebind succeeds.
    rebind = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        rebind.bind(("127.0.0.1", port))
    finally:
        rebind.close()
