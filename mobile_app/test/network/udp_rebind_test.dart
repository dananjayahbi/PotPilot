// Round 6: WS (re)connect must re-run the idempotent UDP configure -
// the leg that was missing when Doc 30's permanent breaker / frozen
// pair-time destination silently killed mid-drag scrub previews.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/network/udp_rebind.dart';
import 'package:potpilot_remote/network/ws_client.dart';

void main() {
  late StreamController<WsConnectionState> states;
  late List<PcHostRecord> configured;
  PcHostRecord? host;
  late UdpRebindWatcher watcher;

  PcHostRecord record(String ip) => PcHostRecord(
        hostname: 'DESKTOP-TEST',
        ipv4s: <String>[ip],
        tokenHex: '00112233445566778899aabbccddeeff',
        lastConnectedAt: DateTime(2026, 10, 18),
      );

  Future<void> configure(PcHostRecord h) async => configured.add(h);

  setUp(() {
    states = StreamController<WsConnectionState>.broadcast();
    configured = <PcHostRecord>[];
    host = record('192.168.1.10');
    watcher = UdpRebindWatcher(
      states: states.stream,
      resolveHost: () => host,
      configure: configure,
    );
  });

  tearDown(() async {
    watcher.dispose();
    await states.close();
  });

  Future<void> pumpEvents() async =>
      Future<void>.delayed(Duration.zero); // let the broadcast land

  test('WS connected transition re-runs configure with the cached host',
      () async {
    watcher.start();
    states.add(WsConnectionState.connected);
    await pumpEvents();
    expect(configured, hasLength(1));
    expect(configured.single.ipv4s, <String>['192.168.1.10']);
  });

  test('flapping reconnects each re-bind (the round-4 blip scenario)',
      () async {
    watcher.start();
    for (int i = 0; i < 3; i++) {
      states
        ..add(WsConnectionState.backoff)
        ..add(WsConnectionState.connecting)
        ..add(WsConnectionState.connected);
      await pumpEvents();
    }
    expect(configured, hasLength(3)); // every reconnect heals UDP
  });

  test('non-connected states never configure', () async {
    watcher.start();
    states
      ..add(WsConnectionState.connecting)
      ..add(WsConnectionState.backoff)
      ..add(WsConnectionState.authRejected)
      ..add(WsConnectionState.closed);
    await pumpEvents();
    expect(configured, isEmpty);
  });

  test('connected with no cached record is skipped (pair bootstrap owns it)',
      () async {
    host = null;
    watcher.start();
    states.add(WsConnectionState.connected);
    await pumpEvents();
    expect(configured, isEmpty);
  });

  test('already-connected initial state binds immediately', () async {
    watcher = UdpRebindWatcher(
      states: states.stream,
      resolveHost: () => host,
      configure: configure,
      initialState: WsConnectionState.connected,
    );
    watcher.start();
    await pumpEvents();
    expect(configured, hasLength(1));
  });

  test('start() is idempotent - one subscription, one configure per event',
      () async {
    watcher
      ..start()
      ..start();
    states.add(WsConnectionState.connected);
    await pumpEvents();
    expect(configured, hasLength(1));
  });

  test('dispose stops reacting to further transitions', () async {
    watcher.start();
    watcher.dispose();
    states.add(WsConnectionState.connected);
    await pumpEvents();
    expect(configured, isEmpty);
  });
}
