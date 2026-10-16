// Doc 46 §3 — on-device UDP round-trip latency driver (M2 RTT initiator).
//
// Sends [samples] frozen 8-byte auth-valid probes to the PC echo responder,
// measures each RTT with Stopwatch (microsecond resolution), and prints one
// parseable `BENCH_RESULT:{json}` line for the pytest orchestrator
// (pc_agent/tests/test_udp_latency_benchmark.py).
//
// Run via:
//   flutter test integration_test/udp_latency_bench_test.dart -d <device> \
//     --dart-define=PC_HOST=<lan-ip> [--dart-define=PC_PORT=50505] \
//     [--dart-define=PC_TOKEN=<32-hex>] [--dart-define=PC_SAMPLES=500]

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:potpilot_remote/network/udp_packet_codec.dart';

/// Immutable RTT summary in milliseconds (Doc 46 §3 contract).
class BenchResult {
  const BenchResult({
    required this.p50Ms,
    required this.p95Ms,
    required this.p99Ms,
    required this.meanMs,
    required this.minMs,
    required this.maxMs,
    required this.sampleCount,
    required this.samplesMs,
  });

  final double p50Ms;
  final double p95Ms;
  final double p99Ms;
  final double meanMs;
  final double minMs;
  final double maxMs;
  final int sampleCount;

  /// Raw per-probe RTTs in arrival order (lets pytest rebuild full stats).
  final List<double> samplesMs;

  Map<String, Object> toJson() => <String, Object>{
        'p50Ms': p50Ms,
        'p95Ms': p95Ms,
        'p99Ms': p99Ms,
        'meanMs': meanMs,
        'minMs': minMs,
        'maxMs': maxMs,
        'sampleCount': sampleCount,
        'samplesMs': samplesMs,
      };
}

double _percentile(List<double> orderedAscending, double percentile) {
  // Nearest-rank — identical to the Python side's compute_stats().
  if (orderedAscending.isEmpty) {
    return 0.0;
  }
  final int rank = (percentile / 100.0 * orderedAscending.length).ceil();
  final int index = (rank < 1)
      ? 0
      : (rank > orderedAscending.length
          ? orderedAscending.length - 1
          : rank - 1);
  return orderedAscending[index];
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

Uint8List _hexToBytes(String hex) {
  final Uint8List out = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Sends [samples] auth-valid probes to the echo responder and measures RTT.
///
/// 50 warm-up probes are discarded first (AP wake / ARP); after that a probe
/// lost for [probeTimeout] is retried up to 3 times, then the bench aborts
/// with an explicit network/screen-off error (Doc 46 §7).
Future<BenchResult> measureRtt({
  required String host,
  int port = udpPort,
  int samples = 500,
  int warmup = 50,
  int authByte = 0x5A,
  Duration probeTimeout = const Duration(milliseconds: 1000),
}) async {
  final RawDatagramSocket socket =
      await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final InternetAddress target =
      InternetAddress.tryParse(host) ?? (await InternetAddress.lookup(host)).first;
  final StreamIterator<RawSocketEvent> events =
      StreamIterator<RawSocketEvent>(socket);
  final List<double> rttsMs = <double>[];
  try {
    int seq = 0;
    for (int index = 0; index < warmup + samples; index++) {
      seq = (seq + 1) & 0xFFFF;
      final Uint8List packet = packPacket(
        packetType: PacketType.mouseMove,
        authByte: authByte,
        arg1: (index % 64) - 32,
        arg2: (index % 32) - 16,
        seq: seq,
      );
      double? rttMs;
      for (int attempt = 0; attempt < 3 && rttMs == null; attempt++) {
        final Stopwatch stopwatch = Stopwatch()..start();
        socket.send(packet, target, port);
        final bool hasNext = await events
            .moveNext()
            .timeout(probeTimeout, onTimeout: () => false);
        stopwatch.stop();
        if (!hasNext) {
          continue; // timed out -> retry the same probe
        }
        final Datagram? datagram = socket.receive();
        if (datagram == null || !_sameBytes(datagram.data, packet)) {
          continue; // stray datagram -> retry
        }
        rttMs = stopwatch.elapsedMicroseconds / 1000.0;
      }
      if (rttMs == null) {
        throw StateError(
          'probe $index lost after 3 attempts — '
          'check Wi-Fi (AP power save) and keep the screen on',
        );
      }
      if (index >= warmup) {
        rttsMs.add(rttMs);
      }
    }
  } finally {
    await events.cancel();
    socket.close();
  }
  final List<double> ordered = List<double>.of(rttsMs)..sort();
  final double sum =
      rttsMs.fold<double>(0.0, (double total, double value) => total + value);
  return BenchResult(
    p50Ms: _percentile(ordered, 50),
    p95Ms: _percentile(ordered, 95),
    p99Ms: _percentile(ordered, 99),
    meanMs: sum / rttsMs.length,
    minMs: ordered.first,
    maxMs: ordered.last,
    sampleCount: rttsMs.length,
    samplesMs: rttsMs,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String pcHost = String.fromEnvironment('PC_HOST');
  const int pcPort = int.fromEnvironment('PC_PORT', defaultValue: udpPort);
  const int pcSamples = int.fromEnvironment('PC_SAMPLES', defaultValue: 500);
  // Default token XORs to 0x5A (matching the illustrative Doc 02 vectors);
  // the orchestrator overrides it with the real pairing token.
  const String pcToken = String.fromEnvironment(
    'PC_TOKEN',
    defaultValue: '5a' '0000000000' '0000000000' '0000000000',
  );

  test(
    'M2 on-device UDP round-trip benchmark (Doc 46 §3)',
    () async {
      final int authByte = xorAuthByte(_hexToBytes(pcToken));
      final BenchResult result = await measureRtt(
        host: pcHost,
        port: pcPort,
        samples: pcSamples,
        warmup: 50,
        authByte: authByte,
      );
      stdout.writeln('BENCH_RESULT:${jsonEncode(result.toJson())}');
    },
    skip: pcHost.isEmpty
        ? 'PC_HOST not provided — pass --dart-define=PC_HOST=<lan-ip>'
        : false,
  );
}
