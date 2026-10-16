"""Doc 46 M1 — serialization overhead micro-benchmark + frozen golden vectors.

Benchmark file (Doc 46 §5/M1): select it alone with
``pytest pc_agent/tests/test_serialization_overhead.py``.
"""

from __future__ import annotations

import time

from pc_agent.network.udp_packet_codec import (
    PACKET_FORMAT,
    PACKET_SIZE,
    PacketType,
    pack_packet,
    unpack_packet,
)
from pc_agent.tests.conftest import UDP_LAYOUT, compute_stats, evaluate, format_stats

WARMUP_SAMPLES = 1_000
TIMED_SAMPLES = 100_000
M1_P99_BUDGET_MS = 2.0  # frozen spec budget (expected µs-range)


def test_udp_layout_json_matches_codec() -> None:
    """Round-trip byte-equality gate: codec constants == udp_packet_layout.json."""
    assert PACKET_FORMAT == UDP_LAYOUT["struct_format"]
    assert PACKET_SIZE == UDP_LAYOUT["size"]
    assert UDP_LAYOUT["endian"] == "little"
    assert len(UDP_LAYOUT["byte_layout"]) == 5
    offsets = [field["offset"] for field in UDP_LAYOUT["byte_layout"]]
    assert offsets == [0, 1, 2, 4, 6]


def test_golden_vectors_byte_identical() -> None:
    """Doc 02 golden vectors G1–G7: pack → exact hex; unpack → identical fields."""
    for vector in UDP_LAYOUT["golden_vectors"]:
        vector_id = vector["id"]
        expected = bytes.fromhex(vector["hex"])
        packed = pack_packet(
            vector["packet_type"],
            vector["auth_byte"],
            vector["arg1"],
            vector["arg2"],
            vector["seq"],
        )
        assert packed == expected, f"{vector_id}: packed {packed.hex(' ')} != {vector['hex']}"
        ptype, auth, arg1, arg2, seq = unpack_packet(packed)
        assert (ptype, auth, arg1, arg2, seq) == (
            vector["packet_type"],
            vector["auth_byte"],
            vector["arg1"],
            vector["arg2"],
            vector["seq"],
        ), f"{vector_id}: unpack round-trip mismatch"


def test_m1_serialization_overhead_p99_under_2ms() -> None:
    """M1 (Blocking): pack+unpack one <BBhhH> packet, p99 < 2.0 ms over 100k ops."""
    auth_byte = 0x5A
    for index in range(WARMUP_SAMPLES):  # discarded warm-up — Doc 46 §5 M1
        unpack_packet(pack_packet(int(PacketType.MOUSE_MOVE), auth_byte, index, -index, index))

    samples: list[float] = []
    for index in range(TIMED_SAMPLES):
        dx = (index % 64) - 32
        dy = -((index % 32) - 16)
        started = time.perf_counter_ns()
        packet = pack_packet(int(PacketType.MOUSE_MOVE), auth_byte, dx, dy, index & 0xFFFF)
        unpack_packet(packet)
        samples.append((time.perf_counter_ns() - started) / 1_000_000.0)

    stats = compute_stats(samples)
    print(format_stats("M1 serialization pack+unpack", stats))
    assert len(stats.samples_ms) == TIMED_SAMPLES
    assert evaluate(stats, M1_P99_BUDGET_MS, percentile="p99"), (
        f"M1 FAIL: p99={stats.p99:.6f} ms >= {M1_P99_BUDGET_MS} ms budget"
    )
    # Report-only line for the release gate (M8-style visibility).
    print(f"M1 vs {M1_P99_BUDGET_MS} ms p99 budget: PASS")
