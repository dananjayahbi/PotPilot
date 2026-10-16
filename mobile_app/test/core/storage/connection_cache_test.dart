import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const String _token32 = '9f3c1a7be0d24c8fab5561d3ce77b0aa';

PcHostRecord host(
  String name, {
  String token = _token32,
  List<String> ips = const <String>['192.168.1.42'],
  DateTime? at,
  int udpPort = 50505,
  int wsPort = 50506,
}) {
  return PcHostRecord(
    hostname: name,
    ipv4s: ips,
    udpPort: udpPort,
    wsPort: wsPort,
    tokenHex: token,
    lastConnectedAt: at ?? DateTime(2026, 1, 1, 12),
  );
}

/// Never-completing prefs store (Doc 34 §8 "never-completing prefs mock").
class _HangingPrefsStore extends SharedPreferencesStorePlatform {
  final Completer<Map<String, Object>> _gate = Completer<Map<String, Object>>();

  void release() {
    if (!_gate.isCompleted) {
      _gate.complete(<String, Object>{});
    }
  }

  @override
  Future<Map<String, Object>> getAll() => _gate.future;

  @override
  Future<bool> remove(String key) async => true;

  @override
  Future<bool> clear() async => true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      true;
}

void main() {
  late ConnectionCache cache;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    cache = ConnectionCache.forTest();
  });

  group('pre-init guard', () {
    test('every accessor throws StateError while init never completes',
        () async {
      final _HangingPrefsStore store = _HangingPrefsStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();

      final Future<void> pending = cache.init();
      await Future<void>.delayed(Duration.zero);

      expect(cache.isReady, isFalse);
      expect(() => cache.hosts, throwsStateError);
      expect(() => cache.activeHost, throwsStateError);
      expect(() => cache.trackpadProfile, throwsStateError);
      expect(() => cache.startupTab, throwsStateError);
      expect(() => cache.saveHost(host('PC')), throwsStateError);
      expect(() => cache.saveStartupTab('deck'), throwsStateError);
      expect(() => cache.clearAll(), throwsStateError);

      // Restore a healthy store for the remaining tests.
      store.release();
      unawaited(pending.catchError((Object _) {}));
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });
  });

  group('persistence round-trip', () {
    test('hosts + profile + tab survive a fresh init on the same prefs',
        () async {
      await cache.init();
      final PcHostRecord record = host(
        'BEDROOM-PC',
        at: DateTime(2026, 2, 3, 4, 5, 6),
        ips: const <String>['192.168.1.42', '10.0.0.7'],
      );
      await cache.saveHost(record);
      await cache.setActiveHost(record.id);
      await cache.saveTrackpadProfile(
        const TrackpadProfile(
          sensitivity: 1.5,
          accelerationGain: 3.0,
          accelerationThreshold: 1.2,
          scrollMultiplier: 0.9,
        ),
      );
      await cache.saveStartupTab('bed');

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();

      expect(fresh.hosts, hasLength(1));
      final PcHostRecord loaded = fresh.hosts.single;
      expect(loaded.id, record.id);
      expect(loaded.hostname, 'BEDROOM-PC');
      expect(loaded.ipv4s, <String>['192.168.1.42', '10.0.0.7']);
      expect(loaded.udpPort, 50505);
      expect(loaded.wsPort, 50506);
      expect(loaded.tokenHex, record.tokenHex);
      expect(
        loaded.lastConnectedAt.isAtSameMomentAs(record.lastConnectedAt),
        isTrue,
      );
      expect(fresh.activeHost?.id, record.id);
      expect(
        fresh.trackpadProfile,
        const TrackpadProfile(
          sensitivity: 1.5,
          accelerationGain: 3.0,
          accelerationThreshold: 1.2,
          scrollMultiplier: 0.9,
        ),
      );
      expect(fresh.startupTab, 'bed');
    });

    test('token round-trips byte-identically', () async {
      await cache.init();
      await cache.saveHost(host('BEDROOM-PC', token: _token32));

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(fresh.hosts.single.tokenHex, _token32);
      expect(fresh.hosts.single.tokenHex, cache.hosts.single.tokenHex);
    });
  });

  group('upsert semantics', () {
    test('re-pairing the same hostname merges into one record, latest token',
        () async {
      await cache.init();
      await cache.saveHost(
        host('BEDROOM-PC', token: _token32, at: DateTime(2026, 1, 1)),
      );
      const String rotated = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await cache.saveHost(
        host('BEDROOM-PC', token: rotated, at: DateTime(2026, 1, 2)),
      );

      expect(cache.hosts, hasLength(1));
      expect(cache.hosts.single.tokenHex, rotated);
      expect(cache.hosts.single.lastConnectedAt, DateTime(2026, 1, 2));

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(fresh.hosts, hasLength(1));
      expect(fresh.hosts.single.tokenHex, rotated);
    });
  });

  group('LRU cap', () {
    test('6 hosts saved in increasing recency ⇒ 5 kept, oldest evicted, desc',
        () async {
      await cache.init();
      for (int i = 0; i < 6; i++) {
        await cache.saveHost(
          host('pc$i', at: DateTime(2026, 1, 1).add(Duration(hours: i))),
        );
      }

      expect(cache.hosts, hasLength(kMaxHosts));
      expect(
        cache.hosts.map((PcHostRecord h) => h.hostname),
        <String>['pc5', 'pc4', 'pc3', 'pc2', 'pc1'],
      );
      expect(
        cache.hosts.any((PcHostRecord h) => h.hostname == 'pc0'),
        isFalse,
      );
    });

    test('evicting the active host falls back to the newest record', () async {
      await cache.init();
      for (int i = 0; i < 6; i++) {
        await cache.saveHost(
          host('pc$i', at: DateTime(2026, 1, 1).add(Duration(hours: i))),
        );
      }
      // pc0 already evicted; oldest present is pc1 — make it active.
      expect(cache.hosts.last.hostname, 'pc1');
      await cache.setActiveHost(cache.hosts.last.id);

      // 7th save evicts pc1 ⇒ active falls back to the newest (pc6).
      await cache.saveHost(
        host('pc6', at: DateTime(2026, 1, 1).add(const Duration(hours: 6))),
      );
      expect(cache.hosts, hasLength(kMaxHosts));
      expect(cache.hosts.first.hostname, 'pc6');
      expect(cache.activeHost?.id, cache.hosts.first.id);
    });
  });

  group('IP trim', () {
    test('6 IPs saved ⇒ 4 kept, newest first', () async {
      await cache.init();
      await cache.saveHost(
        host(
          'BEDROOM-PC',
          ips: const <String>[
            '192.168.1.50',
            '192.168.1.49',
            '192.168.1.48',
            '192.168.1.47',
            '192.168.1.46',
            '192.168.1.45',
          ],
        ),
      );
      expect(
        cache.hosts.single.ipv4s,
        <String>[
          '192.168.1.50',
          '192.168.1.49',
          '192.168.1.48',
          '192.168.1.47',
        ],
      );
    });

    test('updateHostIps trims to 4 newest-first and persists', () async {
      await cache.init();
      final PcHostRecord record = host('BEDROOM-PC');
      await cache.saveHost(record);
      await cache.updateHostIps(
        record.id,
        <String>['10.0.0.6', '10.0.0.5', '10.0.0.4', '10.0.0.3', '10.0.0.2'],
      );
      expect(
        cache.hosts.single.ipv4s,
        <String>['10.0.0.6', '10.0.0.5', '10.0.0.4', '10.0.0.3'],
      );

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(fresh.hosts.single.ipv4s.first, '10.0.0.6');
    });
  });

  group('corruption matrix', () {
    test('garbage hosts JSON ⇒ init succeeds, hosts empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeys.hostsV1: 'not json',
      });
      final ConnectionCache c = ConnectionCache.forTest();
      await c.init();
      expect(c.isReady, isTrue);
      expect(c.hosts, isEmpty);
      expect(c.activeHost, isNull);
    });

    test('one bad entry + two good ⇒ bad skipped, good survive', () async {
      final Map<String, dynamic> good1 = host(
        'PC-A',
        at: DateTime(2026, 1, 1),
      ).toJson();
      final Map<String, dynamic> good2 = host(
        'PC-B',
        at: DateTime(2026, 1, 2),
      ).toJson();
      final Map<String, dynamic> bad = <String, dynamic>{
        'hostname': 123,
        'ipv4s': <Object>[],
      };
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeys.hostsV1: jsonEncode(<dynamic>[good1, bad, good2]),
      });
      final ConnectionCache c = ConnectionCache.forTest();
      await c.init();
      expect(
        c.hosts.map((PcHostRecord h) => h.hostname),
        <String>['PC-B', 'PC-A'],
      );
    });

    test('garbage profile field falls back per-field', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeys.trackpadProfileV1: jsonEncode(<String, Object>{
          'sensitivity': 2.5,
          'accelerationGain': 'x',
        }),
      });
      final ConnectionCache c = ConnectionCache.forTest();
      await c.init();
      expect(c.trackpadProfile.sensitivity, 2.5);
      expect(
        c.trackpadProfile.accelerationGain,
        TrackpadProfile.defaults.accelerationGain,
      );
      expect(
        c.trackpadProfile.scrollMultiplier,
        TrackpadProfile.defaults.scrollMultiplier,
      );
    });

    test('completely unparseable profile ⇒ all defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeys.trackpadProfileV1: '{"sensitivity":"x"}',
      });
      final ConnectionCache c = ConnectionCache.forTest();
      await c.init();
      expect(c.trackpadProfile, TrackpadProfile.defaults);
    });

    test('invalid persisted startup tab loads as deck', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeys.startupTab: 'home',
      });
      final ConnectionCache c = ConnectionCache.forTest();
      await c.init();
      expect(c.startupTab, 'deck');
    });

    test('dangling active_host_id resolves to null', () async {
      final Map<String, dynamic> good = host('PC-A').toJson();
      SharedPreferences.setMockInitialValues(<String, Object>{
        CacheKeys.hostsV1: jsonEncode(<dynamic>[good]),
        CacheKeys.activeHostId: 'deadbeefdeadbeef',
      });
      final ConnectionCache c = ConnectionCache.forTest();
      await c.init();
      expect(c.hosts, hasLength(1));
      expect(c.activeHost, isNull);
    });
  });

  group('validation at the API boundary', () {
    test('31-char token throws ArgumentError at saveHost', () async {
      await cache.init();
      expect(
        () => cache.saveHost(host('PC', token: 'a' * 31)),
        throwsArgumentError,
      );
      expect(cache.hosts, isEmpty);
    });

    test('33-char token throws ArgumentError at saveHost', () async {
      await cache.init();
      expect(
        () => cache.saveHost(host('PC', token: 'a' * 33)),
        throwsArgumentError,
      );
    });

    test('non-hex token throws ArgumentError at saveHost', () async {
      await cache.init();
      expect(
        () => cache.saveHost(host('PC', token: 'z' * 32)),
        throwsArgumentError,
      );
    });

    test('udpPort 50507 throws ArgumentError', () async {
      await cache.init();
      expect(
        () => cache.saveHost(host('PC', udpPort: 50507)),
        throwsArgumentError,
      );
    });

    test('wsPort 8080 throws ArgumentError', () async {
      await cache.init();
      expect(
        () => cache.saveHost(host('PC', wsPort: 8080)),
        throwsArgumentError,
      );
    });

    test('uppercase token accepted and persisted lowercased', () async {
      await cache.init();
      await cache.saveHost(
        host('PC', token: '9F3C1A7BE0D24C8FAB5561D3CE77B0AA'),
      );
      expect(cache.hosts.single.tokenHex, _token32);

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(fresh.hosts.single.tokenHex, _token32);
    });

    test('out-of-range profile fields throw ArgumentError', () async {
      await cache.init();
      expect(
        () =>
            cache.saveTrackpadProfile(const TrackpadProfile(sensitivity: 5.0)),
        throwsArgumentError,
      );
      expect(
        () => cache.saveTrackpadProfile(
          const TrackpadProfile(accelerationGain: 0.5),
        ),
        throwsArgumentError,
      );
      expect(
        () => cache.saveTrackpadProfile(
          const TrackpadProfile(sensitivity: double.nan),
        ),
        throwsArgumentError,
      );
      expect(
        () => cache.saveTrackpadProfile(
          const TrackpadProfile(accelerationThreshold: -1.0),
        ),
        throwsArgumentError,
      );
      expect(cache.trackpadProfile, TrackpadProfile.defaults);
    });

    test('unknown startup tab id throws ArgumentError', () async {
      await cache.init();
      expect(() => cache.saveStartupTab('home'), throwsArgumentError);
    });
  });

  group('trackpad + tab defaults', () {
    test('defaults before any save; saved values readable after', () async {
      await cache.init();
      expect(cache.trackpadProfile, TrackpadProfile.defaults);
      expect(cache.startupTab, 'deck');

      await cache.saveTrackpadProfile(
        const TrackpadProfile(
          sensitivity: 2.0,
          accelerationGain: 1.5,
          accelerationThreshold: 0.4,
          scrollMultiplier: 2.5,
        ),
      );
      await cache.saveStartupTab('library');

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(
        fresh.trackpadProfile,
        const TrackpadProfile(
          sensitivity: 2.0,
          accelerationGain: 1.5,
          accelerationThreshold: 0.4,
          scrollMultiplier: 2.5,
        ),
      );
      expect(fresh.startupTab, 'library');
    });
  });

  group('active host lifecycle', () {
    test('removing the active host clears the pointer and persists', () async {
      await cache.init();
      final PcHostRecord record = host('BEDROOM-PC');
      await cache.saveHost(record);
      await cache.setActiveHost(record.id);
      expect(cache.activeHost?.id, record.id);

      await cache.removeHost(record.id);
      expect(cache.hosts, isEmpty);
      expect(cache.activeHost, isNull);

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(fresh.hosts, isEmpty);
      expect(fresh.activeHost, isNull);
    });
  });

  group('clearAll', () {
    test('wipes exactly the pp.* namespace; unrelated keys survive', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'other_key': 'keep',
      });
      await cache.init();
      final PcHostRecord record = host('BEDROOM-PC');
      await cache.saveHost(record);
      await cache.setActiveHost(record.id);
      await cache.saveStartupTab('library');
      await cache.saveTrackpadProfile(const TrackpadProfile(sensitivity: 2.0));

      await cache.clearAll();

      expect(cache.hosts, isEmpty);
      expect(cache.activeHost, isNull);
      expect(cache.trackpadProfile, TrackpadProfile.defaults);
      expect(cache.startupTab, 'deck');

      final ConnectionCache fresh = ConnectionCache.forTest();
      await fresh.init();
      expect(fresh.hosts, isEmpty);
      expect(fresh.trackpadProfile, TrackpadProfile.defaults);
      expect(fresh.startupTab, 'deck');

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('other_key'), 'keep');
      expect(prefs.getString(CacheKeys.hostsV1), isNull);
    });
  });
}
