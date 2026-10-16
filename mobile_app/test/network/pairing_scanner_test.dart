// Doc 32 §9 — QR payload parsing/validation + pairing state machine tests.
// No camera, no network, no real WsClient: every seam is faked here.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/network/pairing_scanner.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Doc 17 §5 exact on-wire example (frozen).
const String _qrJson =
    '{"host":"BEDROOM-PC","ips":["192.168.1.42"],'
    '"token":"9f3c1a7be0d24c8fab5561d3ce77b0aa","udp":50505,"v":1,"ws":50506}';

const String _tokenA = '9f3c1a7be0d24c8fab5561d3ce77b0aa';
const String _tokenB = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeEngine implements QrScanEngine {
  bool grant = true;
  int startCalls = 0;
  int stopCalls = 0;
  bool _disposed = false;
  final StreamController<String> codes = StreamController<String>.broadcast();

  @override
  Future<bool> start() async {
    startCalls++;
    return grant;
  }

  @override
  void stop() => stopCalls++;

  @override
  Stream<String> get rawCodes => codes.stream;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.shrink();

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    codes.close();
  }
}

class _FakeSocket implements PairingSocket {
  final StreamController<WsConnectionState> stateCtrl =
      StreamController<WsConnectionState>.broadcast();
  final List<String> hosts = <String>[];
  int connectCalls = 0;
  int disconnectCalls = 0;

  /// State emitted (asynchronously) from [connect].
  WsConnectionState emit = WsConnectionState.connected;

  /// When true, connect never settles the handshake (deadline path).
  bool silent = false;

  @override
  Future<void> connect({
    required String host,
    required String tokenHex,
    int port = kWsPort,
  }) async {
    connectCalls++;
    hosts.add(host);
    if (!silent) {
      scheduleMicrotask(() {
        if (!stateCtrl.isClosed) {
          stateCtrl.add(emit);
        }
      });
    }
  }

  @override
  Future<void> disconnect() async => disconnectCalls++;

  @override
  Stream<WsConnectionState> get stateChanges => stateCtrl.stream;
}

/// Cache that records writes without touching storage (`isReady` stays
/// false, which the controller treats as "no cached IPs").
class _CountingCache extends ConnectionCache {
  _CountingCache() : super.forTest();

  final List<PcHostRecord> saved = <PcHostRecord>[];
  final List<String> activated = <String>[];

  @override
  Future<void> saveHost(PcHostRecord host) async => saved.add(host);

  @override
  Future<void> setActiveHost(String id) async => activated.add(id);
}

class _FakeBackend implements MdnsBackend {
  int openCalls = 0;
  int closeCalls = 0;
  final List<List<int>> sent = <List<int>>[];
  final StreamController<List<int>> out =
      StreamController<List<int>>.broadcast();

  @override
  Future<void> open() async => openCalls++;

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> send(List<int> query) async => sent.add(query);

  @override
  Stream<List<int>> get responses => out.stream;
}

/// Resolver with an instant, deterministic [resolveHost] result and a
/// pushable advertisement stream.
class _FakeResolver extends MdnsAgentResolver {
  _FakeResolver._(this.backendRef, {this.resolveResult})
      : super(backend: backendRef);

  factory _FakeResolver({String? resolveResult}) {
    final _FakeBackend backend = _FakeBackend();
    return _FakeResolver._(backend, resolveResult: resolveResult);
  }

  final _FakeBackend backendRef;
  final String? resolveResult;
  final StreamController<MdnsAgentInfo> ads =
      StreamController<MdnsAgentInfo>.broadcast();

  @override
  Future<String?> resolveHost({Duration timeout = kMdnsResolveTimeout}) async =>
      resolveResult;

  @override
  Stream<MdnsAgentInfo> watchAgents() => ads.stream;
}

PcHostRecord _record(String token) => PcHostRecord(
      hostname: 'BEDROOM-PC',
      ipv4s: const <String>['192.168.1.42'],
      tokenHex: token,
      lastConnectedAt: DateTime(2026, 2, 2, 10),
    );

void main() {
  // ---------------------------------------------------------------------------
  // tryParse (Doc 17 §5 exact example + malformed shapes)
  // ---------------------------------------------------------------------------
  group('PcPairingPayload.tryParse', () {
    test("Doc 17's exact on-wire example parses to the full payload", () {
      final PcPairingPayload? p = PcPairingPayload.tryParse(_qrJson);
      expect(p, isNotNull);
      expect(p!.version, 1);
      expect(p.hostname, 'BEDROOM-PC');
      expect(p.ipv4s, <String>['192.168.1.42']);
      expect(p.udpPort, 50505);
      expect(p.wsPort, 50506);
      expect(p.tokenHex, _tokenA);
    });

    test('potpilot://pair? wrapper containing the JSON parses', () {
      final String uri =
          'potpilot://pair?data=${Uri.encodeComponent(_qrJson)}';
      final PcPairingPayload? p = PcPairingPayload.tryParse(uri);
      expect(p, isNotNull);
      expect(p!.hostname, 'BEDROOM-PC');
    });

    test('truncated JSON / non-JSON / wrong shape → null', () {
      expect(PcPairingPayload.tryParse(_qrJson.substring(0, 30)), isNull);
      expect(PcPairingPayload.tryParse('hello world'), isNull);
      expect(PcPairingPayload.tryParse(''), isNull);
      expect(PcPairingPayload.tryParse('[1,2,3]'), isNull);
      expect(PcPairingPayload.tryParse('{"v":1}'), isNull);
      expect(PcPairingPayload.tryParse('potpilot://pair?data=nope'), isNull);
    });

    test('missing key or extra key → null (six-key shape is frozen)', () {
      expect(
        PcPairingPayload.tryParse(
          '{"host":"X","ips":["192.168.1.1"],"udp":50505,"v":1,"ws":50506}',
        ),
        isNull,
      ); // no token
      expect(
        PcPairingPayload.tryParse(
          '{"host":"X","ips":["192.168.1.1"],"token":"$_tokenA",'
          '"udp":50505,"v":1,"ws":50506,"extra":true}',
        ),
        isNull,
      );
    });

    test('wrong value types → null', () {
      expect(
        PcPairingPayload.tryParse(
          '{"host":"X","ips":"192.168.1.1","token":"$_tokenA",'
          '"udp":50505,"v":1,"ws":50506}',
        ),
        isNull,
      ); // ips not a list
      expect(
        PcPairingPayload.tryParse(
          '{"host":"X","ips":["192.168.1.1","192.168.1.2"],'
          '"token":"$_tokenA","udp":50505,"v":"1","ws":50506}',
        ),
        isNull,
      ); // v not an int
      expect(
        PcPairingPayload.tryParse(
          '{"host":"X","ips":[9],"token":"$_tokenA",'
          '"udp":50505,"v":1,"ws":50506}',
        ),
        isNull,
      ); // non-string ip
      expect(
        PcPairingPayload.tryParse(
          '{"host":"X","ips":["192.168.1.1"],"token":123,'
          '"udp":50505,"v":1,"ws":50506}',
        ),
        isNull,
      ); // token not a string
    });
  });

  // ---------------------------------------------------------------------------
  // validate matrix (Doc 32 §4.3 order: version → ports → token → IPv4)
  // ---------------------------------------------------------------------------
  group('PcPairingPayload.validate', () {
    PcPairingPayload build({
      int v = 1,
      int udp = 50505,
      int ws = 50506,
      String token = _tokenA,
      List<String> ips = const <String>['192.168.1.42'],
    }) =>
        PcPairingPayload(
          version: v,
          hostname: 'BEDROOM-PC',
          ipv4s: ips,
          udpPort: udp,
          wsPort: ws,
          tokenHex: token,
        );

    const Map<String, PairingFailure> table = <String, PairingFailure>{
      'v=2': PairingFailure.unsupportedVersion,
      'udp=50506': PairingFailure.wrongPorts,
      'ws=8080': PairingFailure.wrongPorts,
      'token=31': PairingFailure.badToken,
      'token=33': PairingFailure.badToken,
      'token=nonhex': PairingFailure.badToken,
      'ips empty': PairingFailure.noReachableHost,
      'ips invalid': PairingFailure.noReachableHost,
    };

    for (final MapEntry<String, PairingFailure> entry in table.entries) {
      test('${entry.key} → ${entry.value.name}', () {
        final PcPairingPayload payload;
        switch (entry.key) {
          case 'v=2':
            payload = build(v: 2);
          case 'udp=50506':
            payload = build(udp: 50506);
          case 'ws=8080':
            payload = build(ws: 8080);
          case 'token=31':
            payload = build(token: _tokenA.substring(0, 31));
          case 'token=33':
            payload = build(token: '${_tokenA}a');
          case 'token=nonhex':
            payload = build(token: 'z' * 31 + 'a');
          case 'ips empty':
            payload = build(ips: const <String>[]);
          case 'ips invalid':
            payload = build(ips: const <String>['999.1.1.1', 'nope']);
          default:
            throw StateError('unhandled case ${entry.key}');
        }
        expect(payload.validate(), entry.value);
      });
    }

    test('compliant payload → null', () {
      expect(build().validate(), isNull);
    });

    test('uppercase token accepted and normalized to lowercase', () {
      final PcPairingPayload payload = build(token: _tokenA.toUpperCase());
      expect(payload.validate(), isNull);
      expect(payload.tokenHex.toLowerCase(), _tokenA);
    });
  });

  // ---------------------------------------------------------------------------
  // State machine
  // ---------------------------------------------------------------------------
  group('PairingController state machine', () {
    late _FakeEngine engine;
    late _FakeSocket socket;
    late _CountingCache cache;
    late _FakeResolver resolver;
    late PairingController controller;
    late List<PairingState> seen;
    late StreamSubscription<PairingState> sub;

    Future<void> pump0() => Future<void>.delayed(Duration.zero);

    setUp(() async {
      engine = _FakeEngine();
      socket = _FakeSocket();
      cache = _CountingCache();
      resolver = _FakeResolver();
      controller = PairingController(
        scanEngine: engine,
        socket: socket,
        cache: cache,
        resolver: resolver,
        connectTimeout: const Duration(milliseconds: 80),
      );
      seen = <PairingState>[];
      sub = controller.states.listen(seen.add);
      await pump0();
    });

    tearDown(() async {
      await sub.cancel();
      controller.dispose();
      await resolver.stop();
      await resolver.ads.close();
      await socket.stateCtrl.close();
    });

    test('happy path emits phases in exact order and persists once', () async {
      int bindCalls = 0;
      final PairingController c = PairingController(
        scanEngine: engine,
        socket: socket,
        cache: cache,
        resolver: resolver,
        connectTimeout: const Duration(milliseconds: 80),
        onBindTelemetry: () async => bindCalls++,
      );
      final List<PairingPhase> phases = <PairingPhase>[];
      final StreamSubscription<PairingState> s =
          c.states.listen((PairingState st) => phases.add(st.phase));

      await c.startScanning();
      await c.pairFromQr(_qrJson);
      await pump0();

      expect(
        phases,
        <PairingPhase>[
          PairingPhase.scanning,
          PairingPhase.validating,
          PairingPhase.handshaking,
          PairingPhase.persisting,
          PairingPhase.paired,
        ],
      );
      expect(cache.saved, hasLength(1));
      final PcHostRecord record = cache.saved.single;
      expect(record.hostname, 'BEDROOM-PC');
      expect(record.udpPort, 50505);
      expect(record.wsPort, 50506);
      expect(record.tokenHex, _tokenA);
      expect(record.ipv4s, contains('192.168.1.42'));
      expect(cache.activated, <String>[record.id]);
      expect(c.state.phase, PairingPhase.paired);
      expect(c.state.pairedHost?.id, record.id);
      // Only the QR IP was needed — cache was empty.
      expect(socket.hosts, <String>['192.168.1.42']);
      expect(bindCalls, 1);
      expect(engine.stopCalls, greaterThanOrEqualTo(1));

      await s.cancel();
      c.dispose();
    });

    test('auth rejection ends failed/authRejected with zero cache writes',
        () async {
      socket.emit = WsConnectionState.authRejected;
      await controller.startScanning();
      await controller.pairFromQr(_qrJson);
      await pump0();

      expect(controller.state.phase, PairingPhase.failed);
      expect(controller.state.failure, PairingFailure.authRejected);
      expect(cache.saved, isEmpty);
      expect(cache.activated, isEmpty);
      expect(seen.where((PairingState s) => s.phase == PairingPhase.persisting),
          isEmpty);
    });

    test('re-entrancy: second pairFromQr in the same tick is ignored',
        () async {
      final Future<void> first = controller.pairFromQr(_qrJson);
      final Future<void> second = controller.pairFromQr(_qrJson);
      await Future.wait(<Future<void>>[first, second]);
      await pump0();

      expect(socket.connectCalls, 1);
      expect(cache.saved, hasLength(1));
      expect(
        seen.where((PairingState s) => s.phase == PairingPhase.validating),
        hasLength(1),
      );
      expect(controller.state.attempt, 1);
    });

    test('malformed QR bounces failed/invalidQr → scanning', () async {
      await controller.startScanning();
      await controller.pairFromQr('not a qr at all');
      await pump0();
      expect(controller.state.phase, PairingPhase.scanning);
      expect(controller.state.failure, PairingFailure.invalidQr);
      expect(socket.connectCalls, 0);
    });

    test('valid JSON with ws=8080 bounces failed/wrongPorts → scanning',
        () async {
      await controller.startScanning();
      await controller.pairFromQr(
        '{"host":"X","ips":["192.168.1.1"],"token":"$_tokenA",'
        '"udp":50505,"v":1,"ws":8080}',
      );
      await pump0();
      expect(controller.state.phase, PairingPhase.scanning);
      expect(controller.state.failure, PairingFailure.wrongPorts);
      expect(socket.connectCalls, 0);
      expect(cache.saved, isEmpty);
    });

    test('denied camera → failed/cameraDenied without any QR', () async {
      engine.grant = false;
      await controller.startScanning();
      await pump0();
      expect(controller.state.phase, PairingPhase.failed);
      expect(controller.state.failure, PairingFailure.cameraDenied);
      expect(engine.startCalls, 1);
    });

    test('no candidate and no mDNS answer → failed/noReachableHost',
        () async {
      socket.silent = true;
      final _FakeResolver noAds = _FakeResolver(resolveResult: null);
      final PairingController c = PairingController(
        scanEngine: engine,
        socket: socket,
        cache: cache,
        resolver: noAds,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await c.pairFromQr(_qrJson);
      await pump0();
      expect(c.state.phase, PairingPhase.failed);
      expect(c.state.failure, PairingFailure.noReachableHost);
      expect(cache.saved, isEmpty);
      c.dispose();
      await noAds.stop();
      await noAds.ads.close();
    });

    test('candidate + mDNS candidate both time out → failed/handshakeTimeout',
        () async {
      socket.silent = true;
      final _FakeResolver slowAds =
          _FakeResolver(resolveResult: '10.0.0.5');
      final PairingController c = PairingController(
        scanEngine: engine,
        socket: socket,
        cache: cache,
        resolver: slowAds,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await c.pairFromQr(_qrJson);
      await pump0();
      expect(c.state.phase, PairingPhase.failed);
      expect(c.state.failure, PairingFailure.handshakeTimeout);
      // QR IP first, then the mDNS answer — two candidates tried.
      expect(socket.hosts, <String>['192.168.1.42', '10.0.0.5']);
      expect(cache.saved, isEmpty);
      c.dispose();
      await slowAds.stop();
      await slowAds.ads.close();
    });

    test('cold start: pairFromCache connects without the camera (AC7)',
        () async {
      final PcHostRecord record = _record(_tokenA);
      await controller.pairFromCache(record);
      await pump0();
      expect(controller.state.phase, PairingPhase.paired);
      expect(engine.startCalls, 0);
      expect(socket.hosts, <String>['192.168.1.42']);
      expect(cache.saved, hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Real cache: re-scan merge across pairing runs (AC: 1 record, latest token)
  // ---------------------------------------------------------------------------
  group('re-scan merge (real ConnectionCache)', () {
    late ConnectionCache realCache;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      realCache = ConnectionCache.forTest();
      await realCache.init();
    });

    Future<PcHostRecord> runPairing(String token) async {
      final _FakeEngine engine = _FakeEngine();
      final _FakeSocket socket = _FakeSocket();
      final _FakeResolver resolver = _FakeResolver();
      final PairingController c = PairingController(
        scanEngine: engine,
        socket: socket,
        cache: realCache,
        resolver: resolver,
        connectTimeout: const Duration(milliseconds: 80),
      );
      await c.pairFromQr(_qrJson.replaceAll(_tokenA, token));
      await Future<void>.delayed(Duration.zero);
      final PairingPhase phase = c.state.phase;
      c.dispose();
      await resolver.stop();
      await resolver.ads.close();
      await socket.stateCtrl.close();
      expect(phase, PairingPhase.paired);
      return realCache.activeHost!;
    }

    test('pairing the same hostname twice keeps one record, latest token',
        () async {
      final PcHostRecord first = await runPairing(_tokenA);
      final PcHostRecord second = await runPairing(_tokenB);
      expect(second.id, first.id);
      expect(realCache.hosts, hasLength(1));
      expect(realCache.hosts.single.tokenHex, _tokenB);
      expect(realCache.activeHost?.id, second.id);
    });
  });

  // ---------------------------------------------------------------------------
  // Live mDNS DHCP change → cache rewrite + single ipChanged emission (AC6)
  // ---------------------------------------------------------------------------
  test('simulated DHCP change rewrites cache and emits ipChanged once',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ConnectionCache cache = ConnectionCache.forTest();
    await cache.init();
    await cache.saveHost(_record(_tokenA));
    await cache.setActiveHost(_record(_tokenA).id);

    final _FakeEngine engine = _FakeEngine();
    final _FakeSocket socket = _FakeSocket();
    final _FakeResolver resolver = _FakeResolver();
    final PairingController controller = PairingController(
      scanEngine: engine,
      socket: socket,
      cache: cache,
      resolver: resolver,
    );
    final List<String> ipChanges = <String>[];
    final StreamSubscription<String> sub =
        controller.ipChanged.listen(ipChanges.add);

    // Arms the live mDNS watch (§4.7).
    await controller.startScanning();

    Future<void> advertise(String ip) async {
      resolver.ads.add(
        MdnsAgentInfo(
          serviceName: 'bedroom-pc',
          hostname: 'bedroom-pc',
          ipv4: ip,
          udpPort: 50505,
          wsPort: 50506,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    await advertise('192.168.1.99');
    expect(cache.activeHost!.ipv4s.first, '192.168.1.99');
    expect(ipChanges, <String>['192.168.1.99']);

    // Unchanged advertisement → no churn.
    await advertise('192.168.1.99');
    expect(ipChanges, <String>['192.168.1.99']);

    // A genuinely new IP → exactly one more emission.
    await advertise('192.168.1.100');
    expect(cache.activeHost!.ipv4s.first, '192.168.1.100');
    expect(ipChanges, <String>['192.168.1.99', '192.168.1.100']);

    // A different agent never touches the active record.
    resolver.ads.add(
      const MdnsAgentInfo(
        serviceName: 'kitchen-pc',
        hostname: 'kitchen-pc',
        ipv4: '192.168.1.7',
        udpPort: 50505,
        wsPort: 50506,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ipChanges, hasLength(2));
    expect(cache.activeHost!.ipv4s.first, '192.168.1.100');

    await sub.cancel();
    controller.dispose();
    await resolver.stop();
    await resolver.ads.close();
    await socket.stateCtrl.close();
  });
}
