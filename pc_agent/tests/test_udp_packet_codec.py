"""Doc 02 conformance suite: golden vectors, round-trips, bounds, auth byte, sequence rules."""

import json
import random
import struct
from pathlib import Path

import pytest

from pc_agent.network.udp_packet_codec import (
    PACKET_FORMAT,
    PACKET_SIZE,
    SEQ_MODULO,
    SEQ_RESET_TIMEOUT_S,
    UDP_PORT,
    ButtonId,
    ButtonState,
    PacketError,
    PacketType,
    from_i16,
    join_seek_seconds,
    pack_packet,
    split_seek_seconds,
    to_i16,
    unpack_packet,
    xor_auth_byte,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
LAYOUT = json.loads(
    (REPO_ROOT / "shared_specs" / "udp_packet_layout.json").read_text(encoding="utf-8")
)
VECTORS = LAYOUT["golden_vectors"]
VECTOR_IDS = [vector["id"] for vector in VECTORS]


def _fields(vector: dict) -> tuple[int, int, int, int, int]:
    return (
        vector["packet_type"],
        vector["auth_byte"],
        vector["arg1"],
        vector["arg2"],
        vector["seq"],
    )


def _raw(vector: dict) -> bytes:
    return bytes.fromhex(vector["hex"])


def test_frozen_constants() -> None:
    assert UDP_PORT == 50505
    # Doc 02 §3: executable struct format (the trailing '>' some docs render is
    # markdown notation; struct rejects it with "bad char in struct format").
    assert PACKET_FORMAT == "<BBhhH"
    assert PACKET_SIZE == 8
    assert struct.calcsize(PACKET_FORMAT) == 8
    assert SEQ_MODULO == 65536
    assert SEQ_RESET_TIMEOUT_S == 5.0
    assert [int(member) for member in PacketType] == [1, 2, 3, 4]
    assert [int(member) for member in ButtonId] == [1, 2, 3]
    assert [int(member) for member in ButtonState] == [1, 2, 3]


def test_layout_json_matches_frozen_constants() -> None:
    # Doc 01 §5.1/§5.3 render the frozen format as "<BBhhH>"; the executable
    # spelling (Doc 02 §3) lives beside it as struct_format.
    assert LAYOUT["udp_port"] == UDP_PORT
    assert LAYOUT["format"] == "<BBhhH>"
    assert LAYOUT["struct_format"] == PACKET_FORMAT
    assert LAYOUT["size"] == PACKET_SIZE == struct.calcsize(LAYOUT["struct_format"])
    assert LAYOUT["endian"] == "little"


def test_layout_json_registry_matches_enum() -> None:
    by_name = {entry["name"]: entry["value"] for entry in LAYOUT["packet_types"].values()}
    assert by_name == {member.name: int(member) for member in PacketType}
    assert LAYOUT["button_ids"] == {"LEFT": 1, "RIGHT": 2, "MIDDLE": 3}
    assert LAYOUT["button_states"] == {"DOWN": 1, "UP": 2, "CLICK": 3}


def test_seven_golden_vectors_present() -> None:
    assert VECTOR_IDS == ["G1", "G2", "G3", "G4", "G5", "G6", "G7"]


@pytest.mark.parametrize("vector", VECTORS, ids=VECTOR_IDS)
def test_golden_pack_matches_hex(vector: dict) -> None:
    assert pack_packet(*_fields(vector)) == _raw(vector)


@pytest.mark.parametrize("vector", VECTORS, ids=VECTOR_IDS)
def test_golden_unpack_matches_fields(vector: dict) -> None:
    assert unpack_packet(_raw(vector)) == _fields(vector)


@pytest.mark.parametrize("vector", VECTORS, ids=VECTOR_IDS)
def test_golden_round_trip_both_directions(vector: dict) -> None:
    packed = pack_packet(*_fields(vector))
    unpacked = unpack_packet(packed)
    assert unpacked == _fields(vector)
    assert pack_packet(*unpacked) == _raw(vector)
    assert len(packed) == PACKET_SIZE


@pytest.mark.parametrize(
    "vector",
    [vector for vector in VECTORS if vector["packet_type"] == int(PacketType.SCRUB_SEEK)],
    ids=[vector["id"] for vector in VECTORS if vector["packet_type"] == int(PacketType.SCRUB_SEEK)],
)
def test_seek_vectors_align_with_split_join(vector: dict) -> None:
    target = vector["target_seconds"]
    assert split_seek_seconds(target) == (vector["arg1"], vector["arg2"])
    assert join_seek_seconds(vector["arg1"], vector["arg2"]) == target


@pytest.mark.parametrize("packet_type", [int(member) for member in PacketType])
def test_random_round_trip(packet_type: int) -> None:
    rng = random.Random(0xC0FFEE + packet_type)
    for _ in range(2500):
        auth_byte = rng.randint(0, 255)
        seq = rng.randint(0, 65535)
        if packet_type == int(PacketType.MOUSE_BUTTON):
            arg1 = rng.randint(1, 3)
            arg2 = rng.randint(1, 3)
        elif packet_type == int(PacketType.SCRUB_SEEK):
            arg1, arg2 = split_seek_seconds(rng.randrange(1 << 31))
        else:
            arg1 = rng.randint(-32768, 32767)
            arg2 = rng.randint(-32768, 32767)
        data = pack_packet(packet_type, auth_byte, arg1, arg2, seq)
        assert len(data) == PACKET_SIZE
        assert unpack_packet(data) == (packet_type, auth_byte, arg1, arg2, seq)
        assert pack_packet(*unpack_packet(data)) == data


@pytest.mark.parametrize(
    ("packet_type", "auth_byte", "arg1", "arg2", "seq"),
    [
        (0x05, 0x5A, 0, 0, 1),
        (0x00, 0x5A, 0, 0, 1),
        (-1, 0x5A, 0, 0, 1),
        (0x01, 0x100, 0, 0, 1),
        (0x01, -1, 0, 0, 1),
        (0x01, 0x5A, 0, 0, 65536),
        (0x01, 0x5A, 0, 0, -1),
        (0x01, 0x5A, 32768, 0, 1),
        (0x01, 0x5A, 0, -32769, 1),
        (0x03, 0x5A, 4, 1, 1),
        (0x03, 0x5A, 0, 1, 1),
        (0x03, 0x5A, 1, 4, 1),
        (0x03, 0x5A, 1, 0, 1),
    ],
)
def test_pack_rejects_out_of_range(
    packet_type: int, auth_byte: int, arg1: int, arg2: int, seq: int
) -> None:
    with pytest.raises(ValueError):
        pack_packet(packet_type, auth_byte, arg1, arg2, seq)


@pytest.mark.parametrize("size", [0, 1, 7, 9, 16])
def test_unpack_rejects_bad_length(size: int) -> None:
    with pytest.raises(PacketError):
        unpack_packet(bytes(size))


def test_unpack_rejects_unknown_type() -> None:
    with pytest.raises(PacketError):
        unpack_packet(bytes([0x05, 0x5A, 0, 0, 0, 0, 0, 0]))
    with pytest.raises(PacketError):
        unpack_packet(bytes([0x00, 0x00, 0, 0, 0, 0, 0, 0]))


def test_xor_auth_byte_folds_token() -> None:
    token = bytes(range(16))
    expected = 0
    for byte in token:
        expected ^= byte
    assert xor_auth_byte(token) == expected
    assert xor_auth_byte(bytes(16)) == 0
    # 16 identical bytes cancel pairwise; 15 leave the single-byte value behind.
    assert xor_auth_byte(bytes([0x5A] * 16)) == 0x00
    assert xor_auth_byte(bytes([0x5A] * 15 + [0x00])) == 0x5A
    assert xor_auth_byte(bytes([0x01, 0x02] * 7 + [0x00, 0x00])) == 0x03


def test_xor_auth_byte_requires_16_bytes() -> None:
    with pytest.raises(ValueError):
        xor_auth_byte(b"short")
    with pytest.raises(ValueError):
        xor_auth_byte(bytes(15))
    with pytest.raises(ValueError):
        xor_auth_byte(bytes(17))


def test_seek_split_join_round_trip() -> None:
    assert split_seek_seconds(3661) == (0, 3661)
    assert split_seek_seconds(70000) == (1, 4464)
    assert join_seek_seconds(0, 3661) == 3661
    assert join_seek_seconds(1, 4464) == 70000
    for target in (0, 1, 32767, 32768, 65535, 65536, 70000, (1 << 31) - 1):
        high, low = split_seek_seconds(target)
        assert join_seek_seconds(high, low) == target
    rng = random.Random(7)
    for _ in range(1000):
        target = rng.randrange(1 << 31)
        high, low = split_seek_seconds(target)
        assert join_seek_seconds(high, low) == target


def test_seek_split_rejects_out_of_range_target() -> None:
    with pytest.raises(ValueError):
        split_seek_seconds(-1)
    with pytest.raises(ValueError):
        split_seek_seconds(1 << 31)
    with pytest.raises(ValueError):
        split_seek_seconds(1 << 40)


def test_split_seek_low_word_sign_aliasing() -> None:
    # Low words above 32767 arrive as negative int16 and must mask back correctly.
    high, low = split_seek_seconds(0x8000)
    assert (high, low) == (0, -32768)
    assert join_seek_seconds(high, low) == 0x8000
    assert (low & 0xFFFF) == 0x8000


def test_to_i16_from_i16() -> None:
    assert to_i16(0) == 0
    assert to_i16(32767) == 32767
    assert to_i16(32768) == -32768
    assert to_i16(65535) == -1
    assert to_i16(65536) == 0
    assert to_i16(-1) == -1
    assert to_i16(-32768) == -32768
    assert to_i16(-32769) == 32767
    assert to_i16(0x12345) == to_i16(0x2345)
    for value in (0, 1, -1, 12345, -12345, 32767, -32768):
        assert from_i16(value) == value
        assert to_i16(from_i16(value)) == value


def test_sequence_field_bounds_and_wrap() -> None:
    for seq in (0, 1, 32768, 65534, 65535):
        assert unpack_packet(pack_packet(0x01, 0, 1, 1, seq))[4] == seq
    with pytest.raises(ValueError):
        pack_packet(0x01, 0, 1, 1, 65536)
    with pytest.raises(ValueError):
        pack_packet(0x01, 0, 1, 1, -1)


def test_sequence_drop_rules_modulo_65536() -> None:
    # Doc 02 §4.3: delta = (seq - last_seq) & 0xFFFF; 0 -> duplicate,
    # 1..32767 -> accept (gaps allowed), >= 32768 -> stale drop.
    last_seq = 65535
    assert (0 - last_seq) & (SEQ_MODULO - 1) == 1  # wrap 65535 -> 0 accepted
    assert (65535 - 65535) & (SEQ_MODULO - 1) == 0  # duplicate dropped
    assert (10 - 5) & (SEQ_MODULO - 1) == 5  # forward gap accepted
    assert (5 - 10) & (SEQ_MODULO - 1) == SEQ_MODULO - 5  # backward -> stale drop
    assert (SEQ_MODULO - 5) >= 32768
