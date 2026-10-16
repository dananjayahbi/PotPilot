// Doc 02 Dart conformance suite: same G1–G7 golden vectors as the Python
// suite, read from shared_specs/udp_packet_layout.json (no duplicated constants).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/udp_packet_codec.dart';

Map<String, dynamic> loadSharedSpec(String name) {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final file = File('${dir.path}/shared_specs/$name');
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    dir = dir.parent;
  }
  throw StateError('shared_specs/$name not found above ${Directory.current.path}');
}

Uint8List hexToBytes(String hex) {
  return Uint8List.fromList(
    hex.trim().split(RegExp(r'\s+')).map((b) => int.parse(b, radix: 16)).toList(),
  );
}

String bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

void main() {
  final layout = loadSharedSpec('udp_packet_layout.json');
  final vectors = (layout['golden_vectors'] as List).cast<Map<String, dynamic>>();

  test('frozen constants match shared spec', () {
    expect(udpPort, 50505);
    expect(packetSize, 8);
    expect(seqModulo, 65536);
    expect(seqResetTimeoutS, 5.0);
    expect(layout['udp_port'], udpPort);
    expect(layout['size'], packetSize);
    expect(layout['format'], '<BBhhH>');
    expect(layout['endian'], 'little');
  });

  test('seven golden vectors G1-G7 present', () {
    expect(vectors.map((v) => v['id']).toList(), ['G1', 'G2', 'G3', 'G4', 'G5', 'G6', 'G7']);
  });

  for (final vector in vectors) {
    final id = vector['id'] as String;
    final expected = hexToBytes(vector['hex'] as String);
    final fields = (
      packetType: vector['packet_type'] as int,
      authByte: vector['auth_byte'] as int,
      arg1: vector['arg1'] as int,
      arg2: vector['arg2'] as int,
      seq: vector['seq'] as int,
    );

    test('golden $id packs to frozen bytes', () {
      final packed = packPacket(
        packetType: fields.packetType,
        authByte: fields.authByte,
        arg1: fields.arg1,
        arg2: fields.arg2,
        seq: fields.seq,
      );
      expect(bytesToHex(packed), bytesToHex(expected));
      expect(packed, equals(expected));
    });

    test('golden $id unpacks to fields', () {
      expect(unpackPacket(expected), equals(fields));
    });

    test('golden $id round trips both directions', () {
      final unpacked = unpackPacket(expected);
      expect(unpacked, equals(fields));
      final repacked = packPacket(
        packetType: unpacked.packetType,
        authByte: unpacked.authByte,
        arg1: unpacked.arg1,
        arg2: unpacked.arg2,
        seq: unpacked.seq,
      );
      expect(repacked, equals(expected));
      expect(repacked.length, packetSize);
    });
  }

  test('seek vectors align with split/join', () {
    for (final vector in vectors.where((v) => v['packet_type'] == PacketType.scrubSeek)) {
      final target = vector['target_seconds'] as int;
      final split = splitSeekSeconds(target);
      expect(split.high, vector['arg1']);
      expect(split.low, vector['arg2']);
      expect(joinSeekSeconds(split.high, split.low), target);
      expect(joinSeekSeconds(vector['arg1'] as int, vector['arg2'] as int), target);
    }
  });

  test('10000 random in-range tuples survive pack->unpack', () {
    final rng = Random(0xC0FFEE);
    for (var i = 0; i < 10000; i++) {
      final packetType = PacketType.mouseMove + rng.nextInt(4);
      final authByte = rng.nextInt(256);
      final seq = rng.nextInt(65536);
      final int arg1;
      final int arg2;
      if (packetType == PacketType.mouseButton) {
        arg1 = 1 + rng.nextInt(3);
        arg2 = 1 + rng.nextInt(3);
      } else if (packetType == PacketType.scrubSeek) {
        final split = splitSeekSeconds(rng.nextInt(1 << 31));
        arg1 = split.high;
        arg2 = split.low;
      } else {
        arg1 = -32768 + rng.nextInt(65536);
        arg2 = -32768 + rng.nextInt(65536);
      }
      final packed = packPacket(
        packetType: packetType,
        authByte: authByte,
        arg1: arg1,
        arg2: arg2,
        seq: seq,
      );
      expect(packed.length, packetSize);
      final unpacked = unpackPacket(packed);
      expect(unpacked, (packetType: packetType, authByte: authByte, arg1: arg1, arg2: arg2, seq: seq));
      final repacked = packPacket(
        packetType: unpacked.packetType,
        authByte: unpacked.authByte,
        arg1: unpacked.arg1,
        arg2: unpacked.arg2,
        seq: unpacked.seq,
      );
      expect(repacked, equals(packed));
    }
  });

  test('pack throws ArgumentError on out-of-range fields', () {
    void expectRejected(int packetType, int authByte, int arg1, int arg2, int seq) {
      expect(
        () => packPacket(
          packetType: packetType,
          authByte: authByte,
          arg1: arg1,
          arg2: arg2,
          seq: seq,
        ),
        throwsArgumentError,
      );
    }

    expectRejected(0x05, 0x5A, 0, 0, 1);
    expectRejected(0x00, 0x5A, 0, 0, 1);
    expectRejected(0x01, 0x100, 0, 0, 1);
    expectRejected(0x01, -1, 0, 0, 1);
    expectRejected(0x01, 0x5A, 0, 0, 65536);
    expectRejected(0x01, 0x5A, 0, 0, -1);
    expectRejected(0x01, 0x5A, 32768, 0, 1);
    expectRejected(0x01, 0x5A, 0, -32769, 1);
    expectRejected(0x03, 0x5A, 4, 1, 1);
    expectRejected(0x03, 0x5A, 0, 1, 1);
    expectRejected(0x03, 0x5A, 1, 4, 1);
    expectRejected(0x03, 0x5A, 1, 0, 1);
  });

  test('unpack throws FormatException on bad length or unknown type', () {
    expect(() => unpackPacket(Uint8List(0)), throwsFormatException);
    expect(() => unpackPacket(Uint8List(7)), throwsFormatException);
    expect(() => unpackPacket(Uint8List(9)), throwsFormatException);
    expect(() => unpackPacket(Uint8List(16)), throwsFormatException);
    expect(() => unpackPacket(hexToBytes('05 5A 00 00 00 00 00 00')), throwsFormatException);
    expect(() => unpackPacket(Uint8List(packetSize)), throwsFormatException);
  });

  test('xor auth byte folds a 16-byte token', () {
    final token = Uint8List.fromList(List<int>.generate(16, (i) => i));
    var expected = 0;
    for (final byte in token) {
      expected ^= byte;
    }
    expect(xorAuthByte(token), expected);
    expect(xorAuthByte(Uint8List(16)), 0);
    expect(xorAuthByte(Uint8List.fromList(List<int>.filled(16, 0x5A))), 0x00);
    expect(
      xorAuthByte(Uint8List.fromList(<int>[...List<int>.filled(15, 0x5A), 0x00])),
      0x5A,
    );
  });

  test('xor auth byte rejects tokens that are not 16 bytes', () {
    expect(() => xorAuthByte(Uint8List(15)), throwsArgumentError);
    expect(() => xorAuthByte(Uint8List(17)), throwsArgumentError);
    expect(() => xorAuthByte(Uint8List.fromList(utf8.encode('short'))), throwsArgumentError);
  });

  test('seek split/join round trip and bounds', () {
    expect(splitSeekSeconds(3661), (high: 0, low: 3661));
    expect(splitSeekSeconds(70000), (high: 1, low: 4464));
    expect(joinSeekSeconds(0, 3661), 3661);
    expect(joinSeekSeconds(1, 4464), 70000);
    expect(() => splitSeekSeconds(-1), throwsArgumentError);
    expect(() => splitSeekSeconds(1 << 31), throwsArgumentError);
    // Low words above 32767 arrive as negative int16 and mask back correctly.
    final split = splitSeekSeconds(0x8000);
    expect(split, (high: 0, low: -32768));
    expect(joinSeekSeconds(split.high, split.low), 0x8000);
    final rng = Random(7);
    for (var i = 0; i < 1000; i++) {
      final target = rng.nextInt(1 << 31);
      final words = splitSeekSeconds(target);
      expect(joinSeekSeconds(words.high, words.low), target);
    }
  });

  test('toI16 wraps and fromI16 is identity', () {
    expect(toI16(0), 0);
    expect(toI16(32767), 32767);
    expect(toI16(32768), -32768);
    expect(toI16(65535), -1);
    expect(toI16(65536), 0);
    expect(toI16(-1), -1);
    expect(toI16(-32768), -32768);
    expect(toI16(-32769), 32767);
    expect(fromI16(12345), 12345);
    expect(fromI16(-12345), -12345);
  });

  test('sequence field bounds and 65535->0 wrap', () {
    for (final seq in const [0, 1, 32768, 65534, 65535]) {
      final unpacked = unpackPacket(
        packPacket(packetType: 0x01, authByte: 0, arg1: 1, arg2: 1, seq: seq),
      );
      expect(unpacked.seq, seq);
    }
    expect(() => packPacket(packetType: 0x01, authByte: 0, arg1: 1, arg2: 1, seq: 65536),
        throwsArgumentError);
    expect(
      () => packPacket(packetType: 0x01, authByte: 0, arg1: 1, arg2: 1, seq: -1),
      throwsArgumentError,
    );
    // Doc 02 §4.3 modulo-65536 delta rules.
    expect((0 - 65535) & (seqModulo - 1), 1);
    expect((65535 - 65535) & (seqModulo - 1), 0);
    expect((10 - 5) & (seqModulo - 1), 5);
    expect((5 - 10) & (seqModulo - 1), seqModulo - 5);
    expect(seqModulo - 5 >= 32768, isTrue);
  });
}
