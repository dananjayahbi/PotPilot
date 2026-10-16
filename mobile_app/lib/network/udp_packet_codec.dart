// Reference/conformance codec for the frozen 8-byte PotPilot UDP datagram
// (Doc 02). Pure dart:typed_data, zero I/O — the Dart twin of
// pc_agent/network/udp_packet_codec.py; both must agree byte-for-byte.

import 'dart:typed_data';

const int udpPort = 50505;
const int packetSize = 8;
const int seqModulo = 65536;
const double seqResetTimeoutS = 5.0;

const int _i16Min = -32768;
const int _i16Max = 32767;
const int _tokenSize = 16;
const int _seekMaxExclusive = 1 << 31;

/// Packet-type registry (Doc 02 §5.2).
abstract final class PacketType {
  static const int mouseMove = 0x01;
  static const int mouseScroll = 0x02;
  static const int mouseButton = 0x03;
  static const int scrubSeek = 0x04;
}

/// Mouse button ids carried in arg1 of MOUSE_BUTTON packets.
abstract final class ButtonId {
  static const int left = 1;
  static const int right = 2;
  static const int middle = 3;
}

/// Button states carried in arg2 of MOUSE_BUTTON packets.
abstract final class ButtonState {
  static const int down = 1;
  static const int up = 2;
  static const int click = 3;
}

const Set<int> _validPacketTypes = <int>{
  PacketType.mouseMove,
  PacketType.mouseScroll,
  PacketType.mouseButton,
  PacketType.scrubSeek,
};
const Set<int> _validButtonIds = <int>{ButtonId.left, ButtonId.right, ButtonId.middle};
const Set<int> _validButtonStates = <int>{ButtonState.down, ButtonState.up, ButtonState.click};

/// Wraps any int into the signed int16 two's-complement range.
int toI16(int value) => ((value + 0x8000) & 0xFFFF) - 0x8000;

/// Identity sign-passthrough; receivers mask with 0xFFFF where unsigned.
int fromI16(int value) => value;

/// Folds a 128-bit (16-byte) pairing token to its 8-bit XOR checksum.
int xorAuthByte(Uint8List tokenBytes) {
  if (tokenBytes.length != _tokenSize) {
    throw ArgumentError.value(
      tokenBytes.length,
      'tokenBytes',
      'pairing token must be exactly $_tokenSize bytes',
    );
  }
  var authByte = 0;
  for (final byte in tokenBytes) {
    authByte ^= byte;
  }
  return authByte;
}

/// Encodes a seek target as (high, low) int16-safe words; target in [0, 2^31).
({int high, int low}) splitSeekSeconds(int targetSeconds) {
  if (targetSeconds < 0 || targetSeconds >= _seekMaxExclusive) {
    throw ArgumentError.value(
      targetSeconds,
      'targetSeconds',
      'seek target must be in [0, 2^31)',
    );
  }
  final high = targetSeconds >> 16;
  final low = toI16(targetSeconds & 0xFFFF);
  return (high: high, low: low);
}

/// Reassembles (high, low) words into an unsigned target_seconds value.
int joinSeekSeconds(int high, int low) => ((high & 0xFFFF) << 16) | (low & 0xFFFF);

void _checkI16(int value, String name) {
  if (value < _i16Min || value > _i16Max) {
    throw ArgumentError.value(value, name, 'out of int16 range');
  }
}

void _validateArgs(int packetType, int arg1, int arg2) {
  _checkI16(arg1, 'arg1');
  _checkI16(arg2, 'arg2');
  if (packetType == PacketType.mouseButton) {
    if (!_validButtonIds.contains(arg1)) {
      throw ArgumentError.value(arg1, 'arg1', 'invalid button id');
    }
    if (!_validButtonStates.contains(arg2)) {
      throw ArgumentError.value(arg2, 'arg2', 'invalid button state');
    }
  }
}

/// Serializes one 8-byte datagram; throws [ArgumentError] on out-of-range fields.
Uint8List packPacket({
  required int packetType,
  required int authByte,
  required int arg1,
  required int arg2,
  required int seq,
}) {
  if (!_validPacketTypes.contains(packetType)) {
    throw ArgumentError.value(packetType, 'packetType', 'unknown packet type');
  }
  if (authByte < 0 || authByte > 0xFF) {
    throw ArgumentError.value(authByte, 'authByte', 'out of uint8 range');
  }
  if (seq < 0 || seq > 0xFFFF) {
    throw ArgumentError.value(seq, 'seq', 'out of uint16 range');
  }
  _validateArgs(packetType, arg1, arg2);
  final data = ByteData(packetSize);
  data.setUint8(0, packetType);
  data.setUint8(1, authByte);
  data.setInt16(2, arg1, Endian.little);
  data.setInt16(4, arg2, Endian.little);
  data.setUint16(6, seq, Endian.little);
  return data.buffer.asUint8List();
}

/// Parses a datagram; throws [FormatException] on bad length or unknown type.
({int packetType, int authByte, int arg1, int arg2, int seq}) unpackPacket(Uint8List data) {
  if (data.length != packetSize) {
    throw FormatException('expected $packetSize bytes, got ${data.length}');
  }
  final view = ByteData.view(data.buffer, data.offsetInBytes, packetSize);
  final packetType = view.getUint8(0);
  if (!_validPacketTypes.contains(packetType)) {
    throw FormatException(
      'unknown packet type 0x${packetType.toRadixString(16).padLeft(2, '0')}',
    );
  }
  return (
    packetType: packetType,
    authByte: view.getUint8(1),
    arg1: view.getInt16(2, Endian.little),
    arg2: view.getInt16(4, Endian.little),
    seq: view.getUint16(6, Endian.little),
  );
}
