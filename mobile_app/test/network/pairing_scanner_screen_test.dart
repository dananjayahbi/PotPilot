// Doc 32 §9 — PairingScannerScreen widget tests.
// Permission-denied rationale + manual-token path, and the paired → deck
// hand-off firing exactly once. No camera/platform channels: seams faked.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/network/pairing_scanner.dart';
import 'package:potpilot_remote/network/ws_client.dart';

const String _token = '9f3c1a7be0d24c8fab5561d3ce77b0aa';

class _FakeEngine implements QrScanEngine {
  bool grant = true;
  int startCalls = 0;
  bool _disposed = false;
  final StreamController<String> codes = StreamController<String>.broadcast();

  @override
  Future<bool> start() async {
    startCalls++;
    return grant;
  }

  @override
  void stop() {}

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

  @override
  Future<void> connect({
    required String host,
    required String tokenHex,
    int port = kWsPort,
  }) async {
    hosts.add(host);
    scheduleMicrotask(() {
      if (!stateCtrl.isClosed) {
        stateCtrl.add(WsConnectionState.connected);
      }
    });
  }

  @override
  Future<void> disconnect() async {}

  @override
  Stream<WsConnectionState> get stateChanges => stateCtrl.stream;
}

class _CountingCache extends ConnectionCache {
  _CountingCache() : super.forTest();

  final List<PcHostRecord> saved = <PcHostRecord>[];

  @override
  Future<void> saveHost(PcHostRecord host) async => saved.add(host);

  @override
  Future<void> setActiveHost(String id) async {}
}

class _FakeBackend implements MdnsBackend {
  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> send(List<int> query) async {}

  @override
  Stream<List<int>> get responses => const Stream<List<int>>.empty();
}

class _FakeResolver extends MdnsAgentResolver {
  _FakeResolver._(this.backendRef) : super(backend: backendRef);

  factory _FakeResolver() => _FakeResolver._(_FakeBackend());

  final _FakeBackend backendRef;
  final StreamController<MdnsAgentInfo> ads =
      StreamController<MdnsAgentInfo>.broadcast();

  /// No-op: a real [start] would arm a periodic refresh timer, which the
  /// widget-test binding forbids (pending-timer invariant). No camera or
  /// multicast is involved in these tests anyway.
  @override
  Future<void> start() async {}

  @override
  Future<String?> resolveHost({Duration timeout = kMdnsResolveTimeout}) async =>
      null;

  @override
  Stream<MdnsAgentInfo> watchAgents() => ads.stream;
}

void main() {
  late _FakeEngine engine;
  late _FakeSocket socket;
  late _CountingCache cache;
  late _FakeResolver resolver;
  late PairingController controller;

  setUp(() {
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
  });

  tearDown(() async {
    controller.dispose();
    await resolver.stop();
    await resolver.ads.close();
    await socket.stateCtrl.close();
  });

  Widget screen({void Function(BuildContext)? onPaired}) => MaterialApp(
        home: PairingScannerScreen(
          controller: controller,
          onPaired: onPaired,
        ),
      );

  testWidgets(
      'permission denied renders the rationale UI with the manual-token path',
      (WidgetTester tester) async {
    engine.grant = false;
    // Awaiting pre-pump is safe: the binding's initial flush drives the
    // pure-microtask chain to completion before the frame machinery runs.
    await controller.startScanning();

    await tester.pumpWidget(screen());
    await tester.pump();

    expect(controller.state.phase, PairingPhase.failed);
    expect(controller.state.failure, PairingFailure.cameraDenied);
    expect(
      find.text('Camera permission is needed to scan the pairing QR.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Enable camera access in system settings'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    // No-camera fallback lives right in the rationale.
    expect(find.text('Manual pairing'), findsOneWidget);
    expect(find.text('Paste 32-character token'), findsOneWidget);
    expect(find.text('Waiting for PC discovery (mDNS)…'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('idle screen toggles the manual-token panel from its button',
      (WidgetTester tester) async {
    await tester.pumpWidget(screen());
    await tester.pump();

    expect(find.text('Pair with PotPlayer'), findsOneWidget);
    expect(find.text('Manual pairing'), findsNothing);

    await tester.tap(find.text('Enter token manually'));
    await tester.pump();

    expect(find.text('Manual pairing'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('paired phase invokes the deck hand-off exactly once',
      (WidgetTester tester) async {
    int pairedCalls = 0;
    final PcHostRecord record = PcHostRecord(
      hostname: 'BEDROOM-PC',
      ipv4s: const <String>['192.168.1.42'],
      tokenHex: _token,
      lastConnectedAt: DateTime(2026, 1, 1),
    );
    // Drive pairing to completion before mounting (pre-pump awaits are
    // completed by the binding's initial microtask flush).
    // Drive pairing to completion before mounting. The handshake spans
    // stream/timer/completer hops that strand inside the widget binding's
    // single fake-microtask flush — runAsync runs it on the real zone
    // (the sanctioned escape hatch; the binding flushes on completion).
    await tester.runAsync(() => controller.pairFromCache(record));
    expect(controller.state.phase, PairingPhase.paired);
    expect(cache.saved, hasLength(1));
    expect(engine.startCalls, 0, reason: 'no camera on the cached path');

    // The screen mounts mid-pairing-done: initState must arm the deck
    // hand-off for an already-paired controller.
    await tester.pumpWidget(
      screen(onPaired: (_) => pairedCalls++),
    );
    await tester.pump(); // let the armed post-frame hand-off fire if needed
    expect(pairedCalls, 1);
    expect(controller.state.phase, PairingPhase.paired);

    // Rebuilds and late frames must never re-fire the navigation.
    await tester.pump();
    await tester.pump();
    expect(pairedCalls, 1);
  });
}
