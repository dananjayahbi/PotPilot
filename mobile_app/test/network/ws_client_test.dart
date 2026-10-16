// Doc 31 unit/integration suite: backoff math, state machine against a local
// dart:io WebSocket test server, ?auth= handshake, 401/4401 terminality,
// liveness watchdog, queue overflow, mDNS-IP fallback — all with fake timers
// and loopback sockets only (no real network, no real mDNS, no real clock
// for client-owned timers).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

const String validToken = '00112233445566778899aabbccddeeff';

/// Server-side requests arrive as origin-form targets; rebuild an absolute
/// URI (scheme/host/port) from the `Host` header for assertions.
Uri _absoluteUri(HttpRequest request) {
  final String? hostHeader = request.headers.value(HttpHeaders.hostHeader);
  if (hostHeader == null) {
    return request.uri;
  }
  final int colon = hostHeader.lastIndexOf(':');
  final String host = colon > 0 ? hostHeader.substring(0, colon) : hostHeader;
  final int port = colon > 0
      ? (int.tryParse(hostHeader.substring(colon + 1)) ?? 80)
      : 80;
  return request.uri.replace(scheme: 'http', host: host, port: port);
}

// ---------------------------------------------------------------------------
// Local test server (upgrades, records URIs, never touches the network
// beyond 127.0.0.x).
// ---------------------------------------------------------------------------

class WsTestServer {
  WsTestServer._(this._http);

  final HttpServer _http;
  late final StreamSubscription<HttpRequest> _subscription;

  final List<Uri> requestUris = <Uri>[];
  final List<WebSocket> sockets = <WebSocket>[];
  final List<String> received = <String>[];

  bool reject401 = false;
  bool sendGreeting = true;

  int get port => _http.port;

  static Future<WsTestServer> start({
    String address = '127.0.0.1',
    int? port,
    bool reject401 = false,
    bool sendGreeting = true,
  }) async {
    final InternetAddress bindAddress = address == '127.0.0.1'
        ? InternetAddress.loopbackIPv4
        : InternetAddress(address);
    final HttpServer http = await HttpServer.bind(bindAddress, port ?? 0);
    final WsTestServer server = WsTestServer._(http);
    server.reject401 = reject401;
    server.sendGreeting = sendGreeting;
    server._subscription = http.listen(server._handle);
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    requestUris.add(_absoluteUri(request));
    if (reject401) {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    if (request.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() !=
        'websocket') {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final WebSocket socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.listen(
      (dynamic data) {
        if (data is String) {
          received.add(data);
        }
      },
      onError: (Object _) {},
      onDone: () {},
    );
    if (sendGreeting) {
      socket.add(jsonEncode(buildTelemetryFull(<String, dynamic>{
        'position_ms': 0,
        'duration_ms': 0,
        'is_playing': false,
      }).toJson()));
    }
  }

  /// The client's upgrade completes on its side before the server's
  /// `WebSocketTransformer.upgrade` future resumes — wait for parity.
  Future<void> waitForSession(
      {Duration timeout = const Duration(seconds: 5)}) async {
    await waitFor(() => sockets.isNotEmpty, 'server session upgrade',
        timeout: timeout);
  }

  Future<void> sendRaw(String raw) async {
    await waitForSession();
    sockets.last.add(raw);
  }

  Future<void> sendDelta(Map<String, dynamic> changed) async {
    await waitForSession();
    sockets.last.add(jsonEncode(buildTelemetryDelta(changed).toJson()));
  }

  Future<void> closeLastSession([int? code, String? reason]) async {
    await waitForSession();
    try {
      await sockets.last.close(code, reason);
    } catch (_) {
      // Already-closed sockets are fine for these tests.
    }
  }

  Future<void> stop() async {
    await _subscription.cancel();
    for (final WebSocket socket in sockets.toList()) {
      unawaited(socket.close().catchError((Object _) {}));
    }
    sockets.clear();
    await _http.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// Fake one-shot timers (client timerFactory seam).
// ---------------------------------------------------------------------------

class FakeTimers {
  final List<FakeOneShot> created = <FakeOneShot>[];

  Timer makeTimer(Duration duration, void Function(Timer) callback) {
    final FakeOneShot timer = FakeOneShot._(duration, callback);
    created.add(timer);
    return timer;
  }

  Iterable<FakeOneShot> get pending =>
      created.where((FakeOneShot timer) => timer.isActive);

  int get pendingCount => pending.length;

  /// Fires every currently-pending timer once; timers scheduled *by* those
  /// callbacks are not fired in the same pass.
  void fireAllPending() {
    for (final FakeOneShot timer in pending.toList()) {
      timer.debugFire();
    }
  }
}

class FakeOneShot implements Timer {
  FakeOneShot._(this.duration, this._callback);

  final Duration duration;
  final void Function(Timer) _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void debugFire() {
    if (!_active) {
      return;
    }
    _active = false;
    _callback(this);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<void> waitFor(
  bool Function() condition,
  String description, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

WsClient makeClient({
  FakeTimers? timers,
  Future<String?> Function()? mdnsLookup,
  double jitter01 = 0.5,
}) {
  final WsClient client = WsClient(
    mdnsLookup: mdnsLookup ?? () async => null,
    jitterSource: () => jitter01,
  );
  client.timerFactory = (timers ?? FakeTimers()).makeTimer;
  return client;
}

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

/// Doc 31 acceptance: frames produced by `send()` validate against the
/// frozen `ws_command_schema.json` envelope contract.
void expectValidEnvelope(Object? raw, Map<String, dynamic> schema) {
  expect(raw, isA<Map<String, dynamic>>());
  final Map<String, dynamic> env = raw! as Map<String, dynamic>;
  expect(env.keys.toSet(), unorderedEquals(envelopeKeys));
  final RegExp idPattern =
      RegExp(schema['envelope']['id']['pattern'] as String);
  expect(env['id'], matches(idPattern));
  expect(
    (schema['envelope']['type']['enum'] as List).cast<String>(),
    contains(env['type']),
  );
  final RegExp actionPattern =
      RegExp(schema['envelope']['action']['pattern'] as String);
  expect(env['action'], matches(actionPattern));
  expect(env['payload'], isA<Map<String, dynamic>>());
  expect(env['timestamp'], isA<int>());
}

void main() {
  final Map<String, dynamic> schema = loadSharedSpec('ws_command_schema.json');

  group('computeBackoff (pure)', () {
    test('ladder 500 -> 1000 -> 2000 -> 4000 -> 8000 -> 15000 cap', () {
      final List<int> expectedMs = <int>[
        500,
        1000,
        2000,
        4000,
        8000,
        15000,
        15000,
        15000,
        15000,
        15000,
      ];
      for (var attempt = 1; attempt <= 10; attempt++) {
        final Duration delay = WsClient.computeBackoff(attempt, 0.5);
        expect(
          delay,
          Duration(milliseconds: expectedMs[attempt - 1]),
          reason: 'attempt $attempt',
        );
      }
    });

    test('jitter stays within +/-20 % of the uncapped base', () {
      for (var attempt = 1; attempt <= 6; attempt++) {
        final double base = 500 * (1 << (attempt - 1)).toDouble();
        final double capped =
            base > 15000 ? 15000 : base;
        for (final double jitter01 in <double>[0.0, 0.25, 0.75, 0.999999]) {
          final Duration delay =
              WsClient.computeBackoff(attempt, jitter01);
          expect(
            delay.inMilliseconds,
            greaterThanOrEqualTo((capped * 0.8).round() - 1),
            reason: 'attempt $attempt jitter $jitter01 lower bound',
          );
          expect(
            delay.inMilliseconds,
            lessThanOrEqualTo((capped * 1.2).round() + 1),
            reason: 'attempt $attempt jitter $jitter01 upper bound',
          );
        }
      }
      expect(WsClient.computeBackoff(1, 0.0), const Duration(milliseconds: 400));
      expect(WsClient.computeBackoff(1, 1.0), const Duration(milliseconds: 600));
      expect(
        WsClient.computeBackoff(6, 1.0),
        const Duration(milliseconds: 18000), // 15 s cap x 1.2 jitter
      );
    });
  });

  group('handshake and state machine', () {
    test(
        'idle -> connecting -> connected; ?auth=<lowercase token> on the '
        'upgrade URL; first frame is the TELEMETRY_SYNC snapshot', () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      final List<WsConnectionState> states = <WsConnectionState>[];
      final StreamSubscription<WsConnectionState> stateSub =
          client.stateChanges.listen(states.add);
      addTearDown(stateSub.cancel);
      final Future<WsEnvelope> firstEnvelope = client.envelopes.first;

      expect(client.state, WsConnectionState.idle);
      await client.connect(
        host: '127.0.0.1',
        tokenHex: validToken.toUpperCase(),
        port: server.port,
      );
      expect(client.state, WsConnectionState.connected);
      await waitFor(() => states.length >= 2, 'connecting + connected events');
      expect(
        states,
        <WsConnectionState>[
          WsConnectionState.connecting,
          WsConnectionState.connected,
        ],
      );

      expect(server.requestUris, hasLength(1));
      final Uri uri = server.requestUris.single;
      expect(uri.path, '/');
      expect(uri.queryParameters['auth'], validToken); // canonical lowercase

      final WsEnvelope envelope =
          await firstEnvelope.timeout(const Duration(seconds: 5));
      expect(envelope.type, typeTelemetrySync);
      expect(envelope.action, actionFullState);

      // Only the liveness watchdog remains armed.
      expect(timers.pendingCount, 1);
      expect(timers.pending.single.duration, kLivenessTimeout);
    });

    test('connect() while connecting is a no-op single flight', () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final WsClient client = makeClient();
      addTearDown(client.disconnect);

      final Future<void> first =
          client.connect(host: '127.0.0.1', tokenHex: validToken, port: server.port);
      final Future<void> second =
          client.connect(host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(identical(first, second), isTrue);
      await first;
      expect(client.state, WsConnectionState.connected);
      expect(server.requestUris, hasLength(1));
    });

    test('second connect() while connected is a no-op', () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final WsClient client = makeClient();
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(client.state, WsConnectionState.connected);
      expect(server.requestUris, hasLength(1));
    });

    test('malformed token throws ArgumentError synchronously', () {
      final WsClient client = makeClient();
      expect(
        () => client.connect(host: '127.0.0.1', tokenHex: 'nope'),
        throwsArgumentError,
      );
    });
  });

  group('reconnect backoff', () {
    test(
        'delays follow 500 -> 1000 -> 2000 -> 4000 -> 8000 -> 15000 cap with '
        'exactly one mDNS lookup at attempt 3', () async {
      final WsTestServer server = await WsTestServer.start();
      final int port = server.port;
      var lookups = 0;
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(
        timers: timers,
        mdnsLookup: () async {
          lookups++;
          return null;
        },
      );
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: port);
      expect(client.state, WsConnectionState.connected);

      // PC disappears mid-session: clean FIN -> backoff at attempt 1.
      await server.stop();
      await waitFor(
          () => client.state == WsConnectionState.backoff, 'clean-close backoff');
      expect(client.attempt, 1);
      expect(client.lastBackoffDelay, const Duration(milliseconds: 500));

      Future<void> fireAndExpect(int attempt, Duration delay) async {
        timers.fireAllPending();
        await waitFor(
          () =>
              client.attempt == attempt && client.lastBackoffDelay == delay,
          'attempt $attempt with delay $delay',
        );
      }

      await fireAndExpect(2, const Duration(milliseconds: 1000));
      await fireAndExpect(3, const Duration(milliseconds: 2000));
      await fireAndExpect(4, const Duration(milliseconds: 4000));
      await fireAndExpect(5, const Duration(milliseconds: 8000));
      await fireAndExpect(6, const Duration(milliseconds: 15000));
      await fireAndExpect(7, const Duration(milliseconds: 15000));
      expect(lookups, 1); // exactly one lookup per 3-failure streak
      expect(client.state, WsConnectionState.backoff);
    });

    test('a successful upgrade resets the ladder to 500 ms', () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(client.state, WsConnectionState.connected);

      await server.closeLastSession();
      await waitFor(
          () => client.state == WsConnectionState.backoff, 'first backoff');
      expect(client.lastBackoffDelay, const Duration(milliseconds: 500));

      timers.fireAllPending(); // reconnect against the still-alive server
      await waitFor(
          () => client.state == WsConnectionState.connected, 'reconnected');
      expect(client.attempt, 0);

      await server.closeLastSession();
      await waitFor(
          () => client.state == WsConnectionState.backoff, 'second backoff');
      expect(client.lastBackoffDelay, const Duration(milliseconds: 500));
    });

    test('queued command sent during an outage is delivered post-reconnect',
        () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      await server.closeLastSession();
      await waitFor(
          () => client.state == WsConnectionState.backoff, 'outage backoff');

      await client.send('CMD_SYSTEM', 'REQUEST_STATE');
      expect(server.received, isEmpty);

      timers.fireAllPending();
      await waitFor(
          () => client.state == WsConnectionState.connected, 'back online');
      await waitFor(() => server.received.isNotEmpty, 'queued delivery');

      final Map<String, dynamic> frame =
          jsonDecode(server.received.single) as Map<String, dynamic>;
      expect(frame['type'], typeCmdSystem);
      expect(frame['action'], Action.requestState);
      expectValidEnvelope(frame, schema);
    });
  });

  group('auth rejection', () {
    test('HTTP 401 -> authRejected with zero automatic retries', () async {
      final WsTestServer server =
          await WsTestServer.start(reject401: true);
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(client.state, WsConnectionState.authRejected);
      expect(timers.pendingCount, 0); // no backoff scheduled, ever

      final int requestsAt401 = server.requestUris.length;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(client.state, WsConnectionState.authRejected);
      expect(server.requestUris.length, requestsAt401); // zero retries

      // Re-pair path: an explicit connect() recovers.
      server.reject401 = false;
      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(client.state, WsConnectionState.connected);
      expect(server.requestUris.length, requestsAt401 + 1);
    });

    test('mid-session 4401 close is terminal authRejected', () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      await server.closeLastSession(closeCodeUnauthorized, 'revoked');
      await waitFor(() => client.state == WsConnectionState.authRejected,
          '4401 terminal state');
      expect(timers.pendingCount, 0);

      final int requests = server.requestUris.length;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(client.state, WsConnectionState.authRejected);
      expect(server.requestUris.length, requests);
    });
  });

  group('liveness watchdog', () {
    test('5 s of silence force-reconnects; inbound frames keep it alive',
        () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      final List<WsEnvelope> envelopes = <WsEnvelope>[];
      final StreamSubscription<WsEnvelope> envSub =
          client.envelopes.listen(envelopes.add);
      addTearDown(envSub.cancel);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(client.state, WsConnectionState.connected);
      expect(timers.pendingCount, 1);
      expect(timers.pending.single.duration, kLivenessTimeout);

      // The greeting snapshot arms/resets the watchdog before we snapshot
      // the created-timer count (frames reset it; no reconnect while data
      // flows).
      await waitFor(() => envelopes.isNotEmpty, 'greeting frame');
      final int createdBefore = timers.created.length;
      await server.sendDelta(<String, dynamic>{'position_ms': 10});
      await server.sendDelta(<String, dynamic>{'position_ms': 20});
      await server.sendDelta(<String, dynamic>{'position_ms': 30});
      await waitFor(() => envelopes.length >= 4, 'greeting + 3 deltas');
      expect(client.state, WsConnectionState.connected);
      expect(timers.created.length, createdBefore + 3);
      expect(timers.pendingCount, 1);

      // Silence: fire the watchdog -> dead link detected -> backoff.
      timers.fireAllPending();
      expect(client.state, WsConnectionState.backoff);
      expect(client.lastBackoffDelay, const Duration(milliseconds: 500));

      // Server still alive: next attempt reconnects and re-arms the watchdog.
      timers.fireAllPending();
      await waitFor(
          () => client.state == WsConnectionState.connected, 'reconnect');
      expect(timers.pendingCount, 1);
      expect(timers.pending.single.duration, kLivenessTimeout);
    });
  });

  group('outbound queue', () {
    test('40 sends while idle -> 32 newest survive, flush FIFO, schema-valid',
        () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final WsClient client = makeClient();
      addTearDown(client.disconnect);

      for (var i = 0; i < 40; i++) {
        await client.send(
            'CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'cmd-$i'});
      }
      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      await waitFor(
          () => server.received.length >= kSendQueueCapacity, 'queue flush');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.received, hasLength(kSendQueueCapacity));

      final List<String> texts = server.received.map((String frame) {
        final Map<String, dynamic> envelope =
            jsonDecode(frame) as Map<String, dynamic>;
        final Map<String, dynamic> payload =
            envelope['payload'] as Map<String, dynamic>;
        return payload['text']! as String;
      }).toList();
      expect(texts.first, 'cmd-8'); // oldest 8 dropped on overflow
      expect(texts.last, 'cmd-39');
      expect(texts, List<String>.generate(32, (int i) => 'cmd-${i + 8}'));

      for (final String frame in server.received) {
        expectValidEnvelope(jsonDecode(frame), schema);
      }
    });
  });

  group('malformed frames', () {
    test('a broken frame is dropped; the connection stays connected', () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      final List<WsEnvelope> envelopes = <WsEnvelope>[];
      final StreamSubscription<WsEnvelope> envSub =
          client.envelopes.listen(envelopes.add);
      addTearDown(envSub.cancel);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);

      await server.sendRaw('{"broken');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(client.malformedFrames, 1);
      expect(client.state, WsConnectionState.connected);
      expect(timers.pendingCount, 1); // watchdog intact, no reconnect

      await server.sendDelta(<String, dynamic>{'position_ms': 42});
      await waitFor(() => envelopes.length >= 2, 'valid frame after garbage');
      final WsEnvelope delta = envelopes.last;
      expect(delta.type, typeTelemetrySync);
      expect(delta.payload['position_ms'], 42);
      expect(client.state, WsConnectionState.connected);
    });
  });

  group('mDNS IP fallback', () {
    test('3 failures on a stale IP -> one lookup, IP persisted, attempt reset',
        () async {
      // Server listens ONLY on 127.0.0.2; the stale cached IP (127.0.0.1)
      // refuses connections on that port.
      final WsTestServer server =
          await WsTestServer.start(address: '127.0.0.2');
      addTearDown(server.stop);

      var lookups = 0;
      final List<String> persisted = <String>[];
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(
        timers: timers,
        mdnsLookup: () async {
          lookups++;
          return '127.0.0.2';
        },
      );
      client.ipPersistOverride = (String newIp) async => persisted.add(newIp);
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      await waitFor(
          () =>
              client.attempt == 1 && client.state == WsConnectionState.backoff,
          'first stale refusal');
      expect(lookups, 0);

      timers.fireAllPending(); // second stale attempt
      await waitFor(() => client.attempt == 2, 'second stale refusal');
      expect(lookups, 0);

      timers.fireAllPending(); // third refusal -> lookup -> swap -> 500 ms
      await waitFor(
        () =>
            lookups == 1 &&
            client.attempt == 1 &&
            client.lastBackoffDelay == const Duration(milliseconds: 500),
        'mDNS swap with reset attempt',
      );
      expect(persisted, <String>['127.0.0.2']);
      expect(client.lastBackoffDelay, const Duration(milliseconds: 500));

      timers.fireAllPending(); // first attempt against the fresh IP
      await waitFor(
          () => client.state == WsConnectionState.connected,
          'connected via fresh IP');
      expect(lookups, 1);
      expect(server.requestUris, hasLength(1));
      expect(server.requestUris.single.host, '127.0.0.2');
    });
  });

  group('connect timeout', () {
    test('upgrade that never answers fails at 5 s (fake clock) -> backoff',
        () async {
      final ServerSocket hold =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(hold.close);
      addTearDown(() async {
        // Nothing is ever written back; drop accepted sockets with the server.
      });
      final List<Socket> accepted = <Socket>[];
      hold.listen(accepted.add);
      addTearDown(() async {
        for (final Socket socket in accepted) {
          socket.destroy();
        }
      });

      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      final Future<void> connecting = client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: hold.port);
      expect(client.state, WsConnectionState.connecting);
      expect(timers.pendingCount, 1); // the connect timeout
      expect(timers.pending.single.duration, kConnectTimeout);

      timers.fireAllPending(); // 5 s fake clock elapses
      await connecting;
      expect(client.state, WsConnectionState.backoff);
      expect(client.lastBackoffDelay, const Duration(milliseconds: 500));
    });
  });

  group('disconnect', () {
    test('disconnect() is terminal until connect() re-invokes a fresh session',
        () async {
      final WsTestServer server = await WsTestServer.start();
      addTearDown(server.stop);
      final FakeTimers timers = FakeTimers();
      final WsClient client = makeClient(timers: timers);
      addTearDown(client.disconnect);

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      await client.disconnect();
      expect(client.state, WsConnectionState.closed);
      expect(timers.pendingCount, 0);

      await server.closeLastSession();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(client.state, WsConnectionState.closed); // no auto-reconnect
      expect(server.requestUris, hasLength(1));

      await client.connect(
          host: '127.0.0.1', tokenHex: validToken, port: server.port);
      expect(client.state, WsConnectionState.connected);
      expect(server.requestUris, hasLength(2));
      await client.disconnect();
    });
  });
}
