"""Reference/conformance codec for the frozen 8-byte PotPilot UDP datagram (Doc 02).

Pure functions, zero I/O, zero third-party deps — the only place struct knowledge
lives. Runtime modules (Doc 13 sender/receiver) may import this or mirror it
inline; either way they must pass the golden-vector conformance suites.
"""

import struct
from enum import IntEnum

UDP_PORT = 50505
PACKET_FORMAT = "<BBhhH"
PACKET_SIZE = 8
SEQ_MODULO = 65536
SEQ_RESET_TIMEOUT_S = 5.0

_I16_MIN = -32768
_I16_MAX = 32767
_TOKEN_SIZE = 16
_SEEK_MAX_EXCLUSIVE = 2**31


class PacketError(Exception):
    """Raised when a datagram cannot be parsed per the frozen wire format."""


class PacketType(IntEnum):
    MOUSE_MOVE = 0x01
    MOUSE_SCROLL = 0x02
    MOUSE_BUTTON = 0x03
    SCRUB_SEEK = 0x04


class ButtonId(IntEnum):
    LEFT = 1
    RIGHT = 2
    MIDDLE = 3


class ButtonState(IntEnum):
    DOWN = 1
    UP = 2
    CLICK = 3


_VALID_PACKET_TYPES = frozenset(int(packet_type) for packet_type in PacketType)
_VALID_BUTTON_IDS = frozenset(int(button_id) for button_id in ButtonId)
_VALID_BUTTON_STATES = frozenset(int(state) for state in ButtonState)


def to_i16(value: int) -> int:
    """Wrap any int into signed int16 two's-complement range (low word & producer clamps)."""
    return ((value + 0x8000) & 0xFFFF) - 0x8000


def from_i16(value: int) -> int:
    """Identity sign-passthrough; receivers mask with 0xFFFF where semantics are unsigned."""
    return value


def xor_auth_byte(token_bytes: bytes) -> int:
    """Fold a 128-bit (16-byte) pairing token to its 8-bit XOR checksum."""
    if len(token_bytes) != _TOKEN_SIZE:
        raise ValueError(
            f"pairing token must be exactly {_TOKEN_SIZE} bytes, got {len(token_bytes)}"
        )
    auth_byte = 0
    for byte in token_bytes:
        auth_byte ^= byte
    return auth_byte


def split_seek_seconds(target_seconds: int) -> tuple[int, int]:
    """Encode seek target as (high, low) int16-safe words; target in [0, 2**31)."""
    if not 0 <= target_seconds < _SEEK_MAX_EXCLUSIVE:
        raise ValueError(f"seek target must be in [0, 2**31), got {target_seconds}")
    high = target_seconds >> 16
    low = to_i16(target_seconds & 0xFFFF)
    return high, low


def join_seek_seconds(high: int, low: int) -> int:
    """Reassemble (high, low) words into unsigned target_seconds."""
    return ((high & 0xFFFF) << 16) | (low & 0xFFFF)


def _validate_args(packet_type: int, arg1: int, arg2: int) -> None:
    for name, value in (("arg1", arg1), ("arg2", arg2)):
        if not _I16_MIN <= value <= _I16_MAX:
            raise ValueError(f"{name} out of int16 range: {value}")
    if packet_type == PacketType.MOUSE_BUTTON:
        if arg1 not in _VALID_BUTTON_IDS:
            raise ValueError(f"invalid button_id: {arg1}")
        if arg2 not in _VALID_BUTTON_STATES:
            raise ValueError(f"invalid button state: {arg2}")


def pack_packet(packet_type: int, auth_byte: int, arg1: int, arg2: int, seq: int) -> bytes:
    """Serialize one 8-byte datagram; raises ValueError on out-of-range fields."""
    if packet_type not in _VALID_PACKET_TYPES:
        raise ValueError(f"unknown packet_type: {packet_type}")
    if not 0 <= auth_byte <= 0xFF:
        raise ValueError(f"auth_byte out of uint8 range: {auth_byte}")
    if not 0 <= seq <= 0xFFFF:
        raise ValueError(f"seq out of uint16 range: {seq}")
    _validate_args(packet_type, arg1, arg2)
    return struct.pack(PACKET_FORMAT, packet_type, auth_byte, arg1, arg2, seq)


def unpack_packet(data: bytes) -> tuple[int, int, int, int, int]:
    """Parse (packet_type, auth_byte, arg1, arg2, seq); raises PacketError on bad length/type."""
    if len(data) != PACKET_SIZE:
        raise PacketError(f"expected {PACKET_SIZE} bytes, got {len(data)}")
    try:
        packet_type, auth_byte, arg1, arg2, seq = struct.unpack(PACKET_FORMAT, data)
    except struct.error as exc:  # pragma: no cover - guarded by the length check above
        raise PacketError(str(exc)) from exc
    if packet_type not in _VALID_PACKET_TYPES:
        raise PacketError(f"unknown packet_type: 0x{packet_type:02X}")
    return packet_type, auth_byte, arg1, arg2, seq
