// Doc 30 unit suite: golden wire vectors, fast-path <-> codec conformance,
// coalescing/rate cap, sequence wrap, int16 split, ordering, breaker.
// Clocks are fake (package:fake_async); sockets are loopback-only — the
// real-socket round trip lives in udp_sender_socket_integration_test.dart.

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/udp_packet_codec.dart' as codec;
import 'package:potpilot_remote/network/udp_sender.dart';

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

String _tokenForAuth(int authByte) =>
    authByte.toRadixString(16).padLeft(2, '0').padLeft(32, '0');

int _xorFold(String tokenHex32) {
  var fold = 0;
  for (var i = 0; i < 16; i++) {
    fold ^= int.parse(tokenHex32.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return fold;
}

void main() {
  final layout = loadSharedSpec('udp_packet_layout.json');
  final vectors = (layout['golden_vectors'] as List).cast<Map<String, dynamic>>();

  final sender = UdpSender.instance;
  final captured = <Uint8List>[];

  setUp(() {
    captured.clear();
    sender.sendSink = (Uint8List bytes) => captured.add(Uint8List.fromList(bytes));
  });

  tearDown(() async {
    sender.sendSink = null;
    await sender.close();
  });

  group('frozen constants', () {
    test('match shared spec and Doc 30 contract', () {
      expect(kUdpDefaultPort, 50505);
      expect(kMaxMovePacketsPerSecond, 120);
      expect(kUdpPacketSize, 8);
      expect(kMoveFlushInterval.inMicroseconds, 8333);
      expect(kUdpErrorBreakerThreshold, 32);
      expect(layout['udp_port'], kUdpDefaultPort);
      expect(layout['size'], kUdpPacketSize);
      expect(layout['format'], '<BBhhH>');
      expect(layout['endian'], 'little');
    });

    test('packet type / button registries mirror Doc 02', () {
      expect(UdpPacketType.mouseMove, 0x01);
      expect(UdpPacketType.scroll, 0x02);
      expect(UdpPacketType.button, 0x03);
      expect(UdpPacketType.scrub, 0x04);
      expect(MouseButton.left, 1);
      expect(MouseButton.right, 2);
      expect(MouseButton.middle, 3);
      expect(ButtonAction.down, 1);
      expect(ButtonAction.up, 2);
      expect(ButtonAction.click, 3);
      expect(UdpPacketType.mouseMove, codec.PacketType.mouseMove);
      expect(MouseButton.left, codec.ButtonId.left);
      expect(ButtonAction.click, codec.ButtonState.click);
    });
  });

  group('golden pack vectors (udp_packet_layout.json == Python struct.pack)', () {
    for (final vector in vectors) {
      final id = vector['id'] as String;
      final type = vector['packet_type'] as int;
      final auth = vector['auth_byte'] as int;
      final arg1 = vector['arg1'] as int;
      final arg2 = vector['arg2'] as int;
      final seq = vector['seq'] as int;

      test('$id serializes to the frozen 8 bytes', () async {
        await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(auth));
        sender.sequence = seq;
        captured.clear();

        if (type == codec.PacketType.mouseMove) {
          sender.sendMove(arg1, arg2);
          sender.flush();
        } else if (type == codec.PacketType.mouseScroll) {
          sender.sendScroll(arg1, arg2);
        } else if (type == codec.PacketType.mouseButton) {
          sender.sendButton(arg1, arg2);
        } else {
          sender.sendScrub(vector['target_seconds'] as int);
        }

        expect(captured, hasLength(1));
        final expected = hexToBytes(vector['hex'] as String);
        expect(captured.single, equals(expected));
        // Independent recomputation via the Doc 02 codec.
        expect(
          captured.single,
          equals(codec.packPacket(
            packetType: type,
            authByte: auth,
            arg1: arg1,
            arg2: arg2,
            seq: seq,
          )),
        );
        expect(sender.sequence, (seq + 1) & 0xFFFF);
      });
    }
  });

  group('fast path conformance with codec packPacket', () {
    test('1000 random scroll fields byte-equal the codec', () async {
      const token = '0123456789abcdef0123456789abcdef';
      await sender.configure(host: '127.0.0.1', tokenHex: token);
      final expectedAuth = _xorFold(token);
      expect(sender.authByte, expectedAuth);

      final rnd = Random(12345);
      for (var i = 0; i < 1000; i++) {
        final a1 = rnd.nextInt(65536) - 32768;
        final a2 = rnd.nextInt(65536) - 32768;
        final seq = rnd.nextInt(65536);
        sender.sequence = seq;
        captured.clear();
        sender.sendScroll(a1, a2);
        expect(captured, hasLength(1));
        expect(
          captured.single,
          equals(codec.packPacket(
            packetType: codec.PacketType.mouseScroll,
            authByte: expectedAuth,
            arg1: a1,
            arg2: a2,
            seq: seq,
          )),
          reason: 'mismatch at i=$i a1=$a1 a2=$a2 seq=$seq',
        );
      }
    });

    test('200 random move flushes byte-equal the codec', () async {
      const token = 'ffeeddccbbaa99887766554433221100';
      await sender.configure(host: '127.0.0.1', tokenHex: token);
      final expectedAuth = _xorFold(token);

      final rnd = Random(999);
      for (var i = 0; i < 200; i++) {
        final a1 = rnd.nextInt(65536) - 32768;
        final a2 = rnd.nextInt(65536) - 32768;
        final seq = rnd.nextInt(65536);
        sender.sequence = seq;
        captured.clear();
        sender.sendMove(a1, a2);
        sender.flush();
        expect(captured, hasLength(1));
        expect(
          captured.single,
          equals(codec.packPacket(
            packetType: codec.PacketType.mouseMove,
            authByte: expectedAuth,
            arg1: a1,
            arg2: a2,
            seq: seq,
          )),
          reason: 'mismatch at i=$i a1=$a1 a2=$a2 seq=$seq',
        );
      }
    });
  });

  group('byte order and auth', () {
    test('multi-byte fields are little-endian, never big-endian', () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      sender.sequence = 0;
      captured.clear();
      sender.sendScroll(0x1234, -2);
      final bytes = captured.single;
      expect(bytes[2], 0x34);
      expect(bytes[3], 0x12);
      expect(bytes.sublist(2, 4), isNot(equals(<int>[0x12, 0x34])));
      expect(bytes[4], 0xFE);
      expect(bytes[5], 0xFF);
      expect(bytes.sublist(4, 6), isNot(equals(<int>[0x00, 0x02])));
    });

    test('auth byte equals XOR fold of the 16 token bytes (Doc 15 algorithm)',
        () async {
      const token = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';
      await sender.configure(host: '127.0.0.1', tokenHex: token);
      expect(sender.authByte, _xorFold(token));
      captured.clear();
      sender.sendScroll(1, 1);
      expect(captured.single[1], _xorFold(token));
    });

    test('uppercase token input is canonicalized before folding', () async {
      const token = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';
      await sender.configure(host: '127.0.0.1', tokenHex: token.toUpperCase());
      expect(sender.authByte, _xorFold(token));
    });

    test('malformed token throws ArgumentError synchronously', () async {
      await expectLater(
        sender.configure(host: '127.0.0.1', tokenHex: 'not-hex'),
        throwsArgumentError,
      );
      await expectLater(
        sender.configure(
          host: '127.0.0.1',
          tokenHex: 'abcdef0123456789abcdef0123456789'
              'abcdef0123456789abcdef0123456789',
        ),
        throwsArgumentError, // 64 hex chars — not a 128-bit token
      );
    });
  });

  group('coalescing and rate cap', () {
    test('50 sendMove calls in one 8.33 ms window emit exactly one datagram',
        () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      fakeAsync((FakeAsync async) {
        for (var i = 0; i < 50; i++) {
          sender.sendMove(2, 3);
        }
        expect(captured, isEmpty); // nothing escapes before the tick
        async.elapse(const Duration(milliseconds: 9));
        expect(captured, hasLength(1));
        final packet = codec.unpackPacket(captured.single);
        expect(packet.arg1, 100);
        expect(packet.arg2, 150);
        async.elapse(const Duration(milliseconds: 100));
        expect(captured, hasLength(1)); // drained -> timer stopped
      });
    });

    test('1000 events across 1 fake second -> <=120 datagrams, sums preserved',
        () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      fakeAsync((FakeAsync async) {
        for (var i = 0; i < 1000; i++) {
          sender.sendMove(1, 2);
          async.elapse(const Duration(milliseconds: 1));
        }
        expect(captured.length, lessThanOrEqualTo(kMaxMovePacketsPerSecond));
        // Drain the tail the way the next input event or click would
        // (the coalescer cancels itself once drained, per Doc 30 §4.2).
        sender.flush();
        expect(captured.length, lessThanOrEqualTo(kMaxMovePacketsPerSecond));
        var sumX = 0;
        var sumY = 0;
        for (final bytes in captured) {
          final packet = codec.unpackPacket(bytes);
          sumX += packet.arg1;
          sumY += packet.arg2;
        }
        expect(sumX, 1000);
        expect(sumY, 2000);
      });
    });
  });

  group('sequence counter', () {
    test('wraps 65535 -> 0 exactly and increments per emitted datagram',
        () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      sender.sequence = 65535;
      captured.clear();
      sender.sendScroll(1, 0);
      sender.sendScroll(2, 0);
      expect(captured, hasLength(2));
      expect(codec.unpackPacket(captured[0]).seq, 0xFFFF);
      expect(codec.unpackPacket(captured[1]).seq, 0x0000);
      expect(sender.sequence, 1);

      sender.sequence = 40;
      captured.clear();
      sender.sendMove(1, 1);
      sender.flush();
      sender.sendButton(MouseButton.left, ButtonAction.click);
      sender.sendScrub(0);
      final seqs = captured.map((Uint8List b) => codec.unpackPacket(b).seq).toList();
      expect(seqs, <int>[40, 41, 42]);
    });
  });

  group('int16 clamp and split', () {
    test('sendMove(40000, 0) splits into two in-range packets, total preserved',
        () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      fakeAsync((FakeAsync async) {
        captured.clear();
        sender.sendMove(40000, 0);
        expect(captured, hasLength(1));
        expect(codec.unpackPacket(captured[0]).arg1, 32767);
        async.elapse(const Duration(milliseconds: 9));
        expect(captured, hasLength(2));
        final first = codec.unpackPacket(captured[0]);
        final second = codec.unpackPacket(captured[1]);
        expect(first.arg1, greaterThanOrEqualTo(-32768));
        expect(first.arg1, lessThanOrEqualTo(32767));
        expect(second.arg1, 7233);
        expect(first.arg1 + second.arg1, 40000);
        expect(first.arg2 + second.arg2, 0);
      });
    });

    test('large negative deltas split without wrap-around', () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      fakeAsync((FakeAsync async) {
        captured.clear();
        sender.sendMove(-40000, -40000);
        async.elapse(const Duration(milliseconds: 9));
        expect(captured.length, greaterThanOrEqualTo(1));
        var sumX = 0;
        var sumY = 0;
        for (final bytes in captured) {
          final packet = codec.unpackPacket(bytes);
          expect(packet.arg1, greaterThanOrEqualTo(-32768));
          expect(packet.arg1, lessThanOrEqualTo(32767));
          expect(packet.arg2, greaterThanOrEqualTo(-32768));
          expect(packet.arg2, lessThanOrEqualTo(32767));
          sumX += packet.arg1;
          sumY += packet.arg2;
        }
        expect(sumX, -40000);
        expect(sumY, -40000);
      });
    });
  });

  group('scrub split', () {
    test('sendScrub(70000) -> (high=1, low=4464), codec recombines', () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      captured.clear();
      sender.sendScrub(70000);
      expect(captured, hasLength(1));
      final packet = codec.unpackPacket(captured.single);
      expect(packet.packetType, codec.PacketType.scrubSeek);
      expect(packet.arg1, 1);
      expect(packet.arg2, 4464);
      expect(codec.joinSeekSeconds(packet.arg1, packet.arg2), 70000);
    });

    test('negative targets clamp to 0; >= 2^31 clamps to 0x7FFFFFFF', () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      captured.clear();
      sender.sendScrub(-5);
      final negative = codec.unpackPacket(captured.single);
      expect(negative.arg1, 0);
      expect(negative.arg2, 0);
      expect(codec.joinSeekSeconds(negative.arg1, negative.arg2), 0);

      captured.clear();
      sender.sendScrub(0x80000000);
      final oversized = codec.unpackPacket(captured.single);
      expect(
        codec.joinSeekSeconds(oversized.arg1, oversized.arg2),
        0x7FFFFFFF,
      );
    });
  });

  group('ordering and drops', () {
    test('button/scroll/scrub flush pending move first', () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      fakeAsync((FakeAsync async) {
        captured.clear();
        sender.sendMove(5, 5);
        sender.sendButton(MouseButton.left, ButtonAction.click);
        expect(captured, hasLength(2));
        expect(codec.unpackPacket(captured[0]).packetType, codec.PacketType.mouseMove);
        expect(codec.unpackPacket(captured[0]).arg1, 5);
        expect(codec.unpackPacket(captured[1]).packetType, codec.PacketType.mouseButton);

        captured.clear();
        sender.sendMove(3, 3);
        sender.sendScroll(1, 1);
        expect(captured, hasLength(2));
        expect(codec.unpackPacket(captured[0]).packetType, codec.PacketType.mouseMove);
        expect(codec.unpackPacket(captured[1]).packetType, codec.PacketType.mouseScroll);

        captured.clear();
        sender.sendMove(7, 7);
        sender.sendScrub(3661);
        expect(captured, hasLength(2));
        expect(codec.unpackPacket(captured[0]).packetType, codec.PacketType.mouseMove);
        expect(codec.unpackPacket(captured[1]).packetType, codec.PacketType.scrubSeek);
      });
    });

    test('calls before configure emit nothing and never throw', () async {
      await sender.close();
      captured.clear();
      expect(() {
        sender.sendMove(1, 1);
        sender.sendScroll(1, 1);
        sender.sendButton(MouseButton.left, ButtonAction.click);
        sender.sendScrub(1);
        sender.flush();
      }, returnsNormally);
      expect(captured, isEmpty);
      expect(sender.isReady, isFalse);
      expect(sender.droppedCount, 4);
    });
  });

  group('buffer reuse safety', () {
    test('two back-to-back sends arrive with distinct correct bytes', () async {
      final rx = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(rx.close);
      sender.sendSink = null; // exercise the real socket for this test

      await sender.configure(
        host: '127.0.0.1',
        tokenHex: _tokenForAuth(0x5A),
        port: rx.port,
      );
      final received = <Uint8List>[];
      final bothSeen = Completer<void>();
      void consider() {
        var sawScroll = false;
        var sawButton = false;
        for (final d in received) {
          if (d.isEmpty) continue;
          if (d[0] == 0x02) sawScroll = true;
          if (d[0] == 0x03) sawButton = true;
        }
        if (sawScroll && sawButton && !bothSeen.isCompleted) {
          bothSeen.complete();
        }
      }

      rx.listen((RawSocketEvent _) {
        // Drain: readiness is edge-triggered, so coalesced arrivals must all
        // be consumed in one callback or the second datagram waits forever.
        Datagram? datagram;
        while (true) {
          datagram = rx.receive();
          if (datagram == null) {
            break;
          }
          received.add(datagram.data);
        }
        consider();
      });

      sender.sendScroll(0x1111, -2222);
      sender.sendButton(MouseButton.left, ButtonAction.click);

      // The invariant under test is shared-buffer reuse producing two
      // CORRECT, DISTINCT encodings — not loss-free delivery. Plain UDP can
      // drop a datagram when cross-process load (e.g. the Python E2E suite
      // saturating the loopback) backs up kernel buffers, so re-send only
      // whichever encoding is still missing until both have landed. A buffer
      // overwrite bug would make one encoding unobservable no matter how
      // many retries happen.
      for (var round = 0; round < 50 && !bothSeen.isCompleted; round++) {
        await Future.any<void>([
          bothSeen.future,
          Future<void>.delayed(const Duration(milliseconds: 100)),
        ]);
        if (bothSeen.isCompleted) break;
        final kinds = <int>{for (final d in received) if (d.isNotEmpty) d[0]};
        if (!kinds.contains(0x02)) sender.sendScroll(0x1111, -2222);
        if (!kinds.contains(0x03)) {
          sender.sendButton(MouseButton.left, ButtonAction.click);
        }
      }
      if (!bothSeen.isCompleted) {
        fail(
          'encoding(s) never arrived after retries; '
          'kinds=${received.map((d) => d.isEmpty ? -1 : d[0]).toList()} '
          'isReady=${sender.isReady} ioErrors=${sender.ioErrorCount} '
          'dropped=${sender.droppedCount} seq=${sender.sequence} '
          'rxPort=${rx.port}',
        );
      }

      expect(received, hasLength(greaterThanOrEqualTo(2)));
      final decoded = <({int packetType, int authByte, int arg1, int arg2, int seq})>[];
      for (final raw in received) {
        expect(raw, hasLength(8), reason: 'every datagram is the frozen 8-byte frame');
        decoded.add(codec.unpackPacket(raw));
      }
      for (final p in decoded) {
        expect(p.authByte, 0x5A);
        if (p.packetType == 0x02) {
          expect(p.arg1, 0x1111);
          expect(p.arg2, -2222);
        } else if (p.packetType == 0x03) {
          expect(p.arg1, MouseButton.left);
          expect(p.arg2, ButtonAction.click);
        } else {
          fail('unexpected packet type 0x${p.packetType.toRadixString(16)}');
        }
      }
      // Both distinct encodings observed with correct payloads…
      expect(decoded.where((p) => p.packetType == 0x02), isNotEmpty);
      expect(decoded.where((p) => p.packetType == 0x03), isNotEmpty);
      final firstScroll = received.firstWhere((d) => d.isNotEmpty && d[0] == 0x02);
      final firstButton = received.firstWhere((d) => d.isNotEmpty && d[0] == 0x03);
      expect(firstScroll, isNot(equals(firstButton)));
      // …and no stale/duplicated bytes: every sequence number is unique.
      final seqs = decoded.map((p) => p.seq).toSet();
      expect(
        seqs,
        hasLength(decoded.length),
        reason: 'duplicate seq => reused buffer bytes leaked across sends',
      );
    });
  });

  group('circuit breaker', () {
    test('32 consecutive SocketExceptions trip; a success resets the streak',
        () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      var throwing = true;
      sender.sendSink = (Uint8List _) {
        if (throwing) {
          throw const SocketException('net down');
        }
      };

      for (var i = 0; i < 5; i++) {
        sender.sendScroll(1, 1);
      }
      expect(sender.ioErrorCount, 5);
      expect(sender.isReady, isTrue); // streak below threshold

      throwing = false;
      sender.sendScroll(1, 1); // success resets the consecutive streak
      expect(sender.isReady, isTrue);

      throwing = true;
      for (var i = 0; i < 31; i++) {
        sender.sendScroll(1, 1);
      }
      expect(sender.isReady, isTrue); // 31 < 32

      sender.sendScroll(1, 1); // 32nd consecutive failure -> trip
      expect(sender.isReady, isFalse);
      expect(sender.ioErrorCount, 5 + 32);

      final errorsAfterTrip = sender.ioErrorCount;
      sender.sendScroll(1, 1); // silently dropped, no throw, no send
      expect(sender.ioErrorCount, errorsAfterTrip);
      expect(sender.droppedCount, greaterThan(0));
    });

    test('configure() after a trip restores isReady and sending (round-6 '
        'WS-reconnect re-bind path)', () async {
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      sender.sendSink = (Uint8List _) => throw const SocketException('net down');
      for (var i = 0; i < kUdpErrorBreakerThreshold; i++) {
        sender.sendScroll(1, 1);
      }
      expect(sender.isReady, isFalse); // permanent trip with no re-configure

      sender.sendSink = null;
      await sender.configure(host: '127.0.0.1', tokenHex: _tokenForAuth(0x5A));
      expect(sender.isReady, isTrue); // breaker fully cleared
      final drops = sender.droppedCount;
      sender.sendScroll(1, 1); // real socket bind - no silent drop
      expect(sender.droppedCount, drops);
    });
  });
}
