import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';

void main() {
  group('PcHostRecord v1 schema (golden JSON)', () {
    test('toJson locks the frozen wire shape', () {
      final PcHostRecord record = PcHostRecord(
        hostname: 'BEDROOM-PC',
        ipv4s: const <String>['192.168.1.42'],
        tokenHex: '9f3c1a7be0d24c8fab5561d3ce77b0aa',
        lastConnectedAt: DateTime(2026, 1, 2, 3, 4, 5),
      );
      expect(
        record.toJson(),
        <String, Object?>{
          // sha1('bedroom-pc')[0..16] — identity is hostname-derived.
          'id': 'a009a353437af0f7',
          'hostname': 'BEDROOM-PC',
          'ipv4s': <String>['192.168.1.42'],
          'udpPort': 50505,
          'wsPort': 50506,
          'tokenHex': '9f3c1a7be0d24c8fab5561d3ce77b0aa',
          'lastConnectedAt': '2026-01-02T03:04:05.000',
        },
      );
    });

    test('fromJson round-trips the golden literal exactly', () {
      const Map<String, dynamic> golden = <String, dynamic>{
        'id': 'a009a353437af0f7',
        'hostname': 'BEDROOM-PC',
        'ipv4s': <String>['192.168.1.42'],
        'udpPort': 50505,
        'wsPort': 50506,
        'tokenHex': '9f3c1a7be0d24c8fab5561d3ce77b0aa',
        'lastConnectedAt': '2026-01-02T03:04:05.000',
      };
      final PcHostRecord record = PcHostRecord.fromJson(golden);
      expect(record.toJson(), golden);
      expect(record.id, PcHostRecord.idForHostname('BEDROOM-PC'));
    });

    test('id is case-insensitive on hostname (NetBIOS)', () {
      expect(
        PcHostRecord.idForHostname('BEDROOM-PC'),
        PcHostRecord.idForHostname('bedroom-pc'),
      );
    });
  });

  group('TrackpadProfile v1 schema (golden JSON)', () {
    test('defaults toJson locks the frozen wire shape', () {
      expect(
        TrackpadProfile.defaults.toJson(),
        <String, Object?>{
          'sensitivity': 1.0,
          'accelerationGain': 2.0,
          'accelerationThreshold': 0.8,
          'scrollMultiplier': 1.0,
        },
      );
    });

    test('fromJson(golden defaults) == defaults', () {
      expect(
        TrackpadProfile.fromJson(<String, dynamic>{
          'sensitivity': 1.0,
          'accelerationGain': 2.0,
          'accelerationThreshold': 0.8,
          'scrollMultiplier': 1.0,
        }),
        TrackpadProfile.defaults,
      );
    });
  });
}
