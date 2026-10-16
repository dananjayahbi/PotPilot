// Doc 30 socket integration: real loopback datagrams to 127.0.0.1:<ephemeral>.
// No external network — the receiver is a local RawDatagramSocket.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/udp_packet_codec.dart' as codec;
import 'package:potpilot_remote/network/udp_sender.dart';

void main() {
  test('every received datagram over loopback is exactly 8 bytes', () async {
    final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(receiver.close);

    final sender = UdpSender.instance;
    addTearDown(sender.close);
    sender.sendSink = null; // real socket path for this suite
    await sender.configure(
      host: '127.0.0.1',
      tokenHex: '00112233445566778899aabbccddeeff',
      port: receiver.port,
    );

    final received = <Uint8List>[];
    final allArrived = Completer<void>();
    const int expectedCount = 5;
    receiver.listen((RawSocketEvent _) {
      // Drain everything pending: readiness events are edge-triggered and
      // can coalesce under full-suite load.
      Datagram? datagram;
      while (true) {
        datagram = receiver.receive();
        if (datagram == null) {
          break;
        }
        received.add(datagram.data);
      }
      if (received.length >= expectedCount && !allArrived.isCompleted) {
        allArrived.complete();
      }
    });

    sender.sendMove(10, -5);
    sender.flush(); // move #1 (immediate)
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sender.sendScroll(3, -1); // scroll
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sender.sendButton(MouseButton.left, ButtonAction.click); // button
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sender.sendScrub(70000); // scrub
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sender.sendMove(-7, 9);
    sender.flush(); // move #2 (immediate)
    await allArrived.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail(
        'timed out with ${received.length}/$expectedCount datagrams; '
        'isReady=${sender.isReady} seq=${sender.sequence} '
        'ioErrors=${sender.ioErrorCount} dropped=${sender.droppedCount}',
      ),
    );

    expect(received, hasLength(expectedCount));
    for (final datagram in received) {
      expect(datagram, hasLength(kUdpPacketSize));
      // Must fully unpack — no ragged or truncated frames on the wire.
      expect(() => codec.unpackPacket(datagram), returnsNormally);
    }

    final types = received
        .map((Uint8List d) => codec.unpackPacket(d).packetType)
        .toList();
    expect(
      types,
      <int>[
        codec.PacketType.mouseMove,
        codec.PacketType.mouseScroll,
        codec.PacketType.mouseButton,
        codec.PacketType.scrubSeek,
        codec.PacketType.mouseMove,
      ],
    );

    // Sequence advances by exactly 1 per emitted datagram, in order.
    final seqs =
        received.map((Uint8List d) => codec.unpackPacket(d).seq).toList();
    expect(seqs, <int>[0, 1, 2, 3, 4]);

    // Auth byte on the wire equals the XOR fold of the token.
    var expectedAuth = 0;
    const token = '00112233445566778899aabbccddeeff';
    for (var i = 0; i < 16; i++) {
      expectedAuth ^= int.parse(token.substring(i * 2, i * 2 + 2), radix: 16);
    }
    for (final datagram in received) {
      expect(datagram[1], expectedAuth);
    }

    await sender.close();
  });
}
