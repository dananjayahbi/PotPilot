// Doc 43 unit suite (§9): exact §5 envelopes for both routing targets,
// the hold/seek state machine (fake clocks + fake key events), the §4.2 gate
// matrix (pass-through), bound clamping with wall feedback, monotonic scrub
// targets decoded against the frozen `<BBhhH>` 0x04 layout, HUD badge
// lifetime, and settings persistence. No real network/telephony: WS and
// telemetry are faked, UDP is loopback-configured with a capture sink.

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/hardware_hooks/volume_button_hijack.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/udp_packet_codec.dart';
import 'package:potpilot_remote/network/udp_sender.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Capturing Doc 31 fake — one fresh-uuid envelope per send, no sockets.
class _FakeWsClient extends WsClient {
  bool connected = true;

  final List<WsMessage> sent = <WsMessage>[];

  @override
  WsConnectionState get state =>
      connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(buildMessage(type: type, action: action, payload: payload));
  }
}

/// Records every waveform the Doc 42 engine emits — no plugin traffic.
class _FakeVibrationPort implements VibrationPort {
  @override
  bool isSupported = true;

  final List<({List<int> timingsMs, List<int> amplitudes})> emissions =
      <({List<int> timingsMs, List<int> amplitudes})>[];

  @override
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  }) async {
    emissions.add(
      (
        timingsMs: List<int>.of(timingsMs),
        amplitudes: List<int>.of(amplitudes),
      ),
    );
  }

  @override
  Future<void> cancel() async {}

  bool emitted(HapticPattern pattern) {
    return emissions.any(
      (({List<int> timingsMs, List<int> amplitudes}) wave) =>
          switch (pattern) {
            HapticPattern.microTick =>
              wave.timingsMs.length == 1 && wave.timingsMs.first == 10,
            HapticPattern.volumeTick =>
              wave.timingsMs.length == 1 && wave.timingsMs.first == 12,
            HapticPattern.minuteTick =>
              wave.timingsMs.length == 1 && wave.timingsMs.first == 18,
            _ => false,
          },
    );
  }
}

const String _tokenHex = '00112233445566778899aabbccddeeff';

final RegExp _uuid4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
  r'[0-9a-f]{12}$',
);

/// Decodes one captured datagram against Doc 02 §5.2 (`<BBhhH>` LE).
({int type, int auth, int target, int seq}) _decodeScrub(Uint8List bytes) {
  final ({
    int packetType,
    int authByte,
    int arg1,
    int arg2,
    int seq,
  }) parsed = unpackPacket(bytes);
  return (
    type: parsed.packetType,
    auth: parsed.authByte,
    target: joinSeekSeconds(parsed.arg1, parsed.arg2),
    seq: parsed.seq,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWsClient ws;
  late _FakeVibrationPort port;
  late HapticEngine engine;
  late VolumeButtonHijack hijack;
  late TelemetryState current;
  late SharedPreferences prefs;
  final List<Uint8List> scrubs = <Uint8List>[];
  int fakeNowSec = 1760000000;
  bool inCall = false;
  bool paired = false;

  TelemetryState telemetry({
    int volume = 40,
    int? sysVolume,
    bool? potFound,
    int positionMs = 120000,
    int durationMs = 600000,
    bool playing = true,
    String? title = 'Interstellar',
    bool connected = true,
    int? timestamp,
  }) {
    final Map<String, Object?> extras = <String, Object?>{};
    if (sysVolume != null) {
      extras['sys_volume'] = sysVolume;
    }
    if (potFound != null) {
      extras['potplayer_found'] = potFound;
    }
    return TelemetryState(
      timestamp: timestamp ?? fakeNowSec,
      positionMs: positionMs,
      durationMs: durationMs,
      isPlaying: playing,
      speed: 1.0,
      potPlayerVolume: volume,
      fileTitle: title,
      extras: extras,
      isConnected: connected,
    );
  }

  Future<void> press(LogicalKeyboardKey key) async {
    await simulateKeyDownEvent(key);
    await simulateKeyUpEvent(key);
  }

  setUp(() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    fakeNowSec = 1760000000;
    inCall = false;
    paired = false;
    scrubs.clear();
    ws = _FakeWsClient();
    port = _FakeVibrationPort();
    engine = HapticEngine(port: port, preferences: prefs);
    current = telemetry(volume: 40, sysVolume: 30, potFound: true);
    hijack = VolumeButtonHijack(
      ws: ws,
      udp: UdpSender.instance,
      telemetry: () => current,
      haptics: engine,
      callActive: () => inCall,
      isPaired: () => paired,
      nowSec: () => fakeNowSec,
      preferences: prefs,
    );
    expect(hijack.attach(), isTrue);
    hijack.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  tearDown(() async {
    hijack.detach();
    engine.dispose();
    UdpSender.instance.sendSink = null;
    await UdpSender.instance.close();
  });

  group('short press → exact §5 envelopes (both routes)', () {
    test('potplayer_found true → CMD_POTPLAYER SET_VOLUME {percent}',
        () async {
      current = telemetry(volume: 40, potFound: true);
      await press(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, hasLength(1));
      final WsMessage envelope = ws.sent.single;
      expect(envelope.type, 'CMD_POTPLAYER');
      expect(envelope.action, 'SET_VOLUME');
      expect(envelope.payload, <String, dynamic>{'percent': 45});
      expect(envelope.id, matches(_uuid4));
      expect(envelope.timestamp, isA<int>());
      expect(envelope.timestamp, greaterThan(1700000000));
      expect(hijack.hudValue.value, 45);
    });

    test('potplayer_found false → CMD_SYSTEM SET_SYSTEM_VOLUME on sys_volume',
        () async {
      current = telemetry(volume: 40, sysVolume: 30, potFound: false);
      await press(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, hasLength(1));
      final WsMessage envelope = ws.sent.single;
      expect(envelope.type, 'CMD_SYSTEM');
      expect(envelope.action, 'SET_SYSTEM_VOLUME');
      expect(envelope.payload, <String, dynamic>{'percent': 35});
      expect(envelope.id, matches(_uuid4));
    });

    test('potplayer_found absent (cold telemetry) → system route',
        () async {
      current = telemetry(sysVolume: 60); // no `potplayer_found` key at all
      await press(LogicalKeyboardKey.audioVolumeDown);
      expect(ws.sent, hasLength(1));
      expect(ws.sent.single.type, 'CMD_SYSTEM');
      expect(ws.sent.single.action, 'SET_SYSTEM_VOLUME');
      expect(ws.sent.single.payload, <String, dynamic>{'percent': 55});
    });

    test('each press emits a fresh uuid4 id (no id reuse)', () async {
      current = telemetry(volume: 40, potFound: true);
      await press(LogicalKeyboardKey.audioVolumeUp);
      // TELEMETRY_SYNC echo (250 ms cadence) — the base moves to 45.
      current = telemetry(volume: 45, potFound: true);
      await press(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, hasLength(2));
      expect(ws.sent[0].id, isNot(ws.sent[1].id));
      expect(ws.sent[0].payload['percent'], 45);
      expect(ws.sent[1].payload['percent'], 50);
    });

    test('volume-down steps down from the routed base', () async {
      current = telemetry(volume: 40, potFound: true);
      await press(LogicalKeyboardKey.audioVolumeDown);
      expect(ws.sent.single.payload, <String, dynamic>{'percent': 35});
    });
  });

  group('state machine (fake_async §4.1)', () {
    // Real socket binding cannot complete inside a fake-async zone, so the
    // loopback UDP + capture sink are armed here (real async) per test.
    setUp(() async {
      await UdpSender.instance.configure(
        host: '127.0.0.1',
        tokenHex: _tokenHex,
      );
      UdpSender.instance.sendSink = (Uint8List bytes) {
        scrubs.add(Uint8List.fromList(bytes));
      };
    });

    tearDown(() async {
      UdpSender.instance.sendSink = null;
      await UdpSender.instance.close();
    });

    test(
        'tap: one step, repeats coalesced pre-threshold, release <600 ms '
        'never scrubs', () {
      fakeAsync((FakeAsync async) {
        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        expect(ws.sent, hasLength(1), reason: 'zero-latency first press');
        expect(port.emitted(HapticPattern.volumeTick), isTrue);

        async.elapse(const Duration(milliseconds: 400)); // OS repeat window
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        expect(ws.sent, hasLength(1), reason: 'pre-threshold repeat coalesced');
        expect(scrubs, isEmpty, reason: 'no 0x04 before the threshold');

        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(scrubs, isEmpty, reason: 'release <600 ms = zero scrub packets');
        expect(ws.sent, hasLength(1));
        expect(hijack.phase, VolumeHijackPhase.idle);
      });
    });

    test(
        'hold ≥600 ms → first scrub at the threshold, N repeats → N more, '
        'keyUp stops immediately', () {
      fakeAsync((FakeAsync async) {
        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        expect(ws.sent, hasLength(1));

        async.elapse(const Duration(milliseconds: 599));
        expect(scrubs, isEmpty, reason: 'not yet seekActive');

        async.elapse(const Duration(milliseconds: 1)); // t = 600 ms
        expect(scrubs, hasLength(1), reason: 'first seek at threshold');

        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        expect(scrubs, hasLength(3), reason: '2 repeats → 2 more scrubs');

        // Position 120 s, ±30 s per tick → 150, 180, 210 (monotonic).
        final List<({int type, int auth, int target, int seq})> decoded =
            scrubs.map(_decodeScrub).toList();
        expect(
          decoded.map(
            (({int type, int auth, int target, int seq}) d) => d.target,
          ).toList(),
          <int>[150, 180, 210],
        );
        for (final ({int type, int auth, int target, int seq}) d in decoded) {
          expect(d.type, 0x04, reason: 'frozen packet type');
          expect(d.auth, UdpSender.instance.authByte,
              reason: 'auth byte = XOR of the pairing token (Doc 15)');
        }
        for (int i = 1; i < decoded.length; i++) {
          expect(decoded[i].seq, decoded[i - 1].seq + 1,
              reason: 'monotonic Doc 30 sequence counter');
        }

        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(scrubs, hasLength(3), reason: 'keyUp stops packets at once');
        expect(ws.sent, hasLength(1), reason: 'seek traffic is UDP-only');
        expect(hijack.phase, VolumeHijackPhase.idle);
      });
    });

    test('down-long-press seeks backwards with decreasing clamped targets',
        () {
      fakeAsync((FakeAsync async) {
        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
        async.flushMicrotasks();
        expect(ws.sent.single.payload['percent'], 35); // volume step first

        async.elapse(const Duration(milliseconds: 600)); // → seekActive
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeDown);
        async.flushMicrotasks();
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeDown);
        async.flushMicrotasks();
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeDown);
        async.flushMicrotasks();
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeDown);
        async.flushMicrotasks();
        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
        async.flushMicrotasks();

        // Position 120 s, −30 s/tick: 90, 60, 30, 0, 0 (lower clamp holds).
        expect(
          scrubs.map((Uint8List b) => _decodeScrub(b).target).toList(),
          <int>[90, 60, 30, 0, 0],
        );
        UdpSender.instance.sendSink = null;
      });
    });

    test('repeatIndex clamps at durationSec (upper bound)', () {
      fakeAsync((FakeAsync async) {
        current = telemetry(positionMs: 595000, durationMs: 600000);

        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 600));
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();

        expect(
          scrubs.map((Uint8List b) => _decodeScrub(b).target).toList(),
          <int>[600, 600],
          reason: 'targets never exceed the media duration',
        );
        UdpSender.instance.sendSink = null;
      });
    });

    test('stale telemetry (>1 s) suppresses seek sends, keeps local ticks',
        () {
      fakeAsync((FakeAsync async) {
        current = telemetry(timestamp: fakeNowSec - 5); // 5 s old → stale

        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 600));
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();

        expect(scrubs, isEmpty, reason: 'no target seconds computable (§7)');
        expect(port.emitted(HapticPattern.minuteTick), isTrue,
            reason: 'local seek feedback still ticks');
        expect(hijack.hudValue.value, isNull, reason: 'HUD shows "—"');
        UdpSender.instance.sendSink = null;
      });
    });

    test('WS drops mid-hold: steps dropped, crimson HUD, seek suppressed',
        () {
      fakeAsync((FakeAsync async) {
        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        expect(ws.sent, hasLength(1));

        ws.connected = false; // Doc 31 dropped after the press began
        async.elapse(const Duration(milliseconds: 600));
        simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();

        expect(ws.sent, hasLength(1), reason: 'no queued/fresh WS traffic');
        expect(scrubs, isEmpty, reason: 'no UDP while isConnected == false');
        expect(hijack.hudOffline.value, isTrue, reason: 'crimson PC offline');
        expect(port.emitted(HapticPattern.minuteTick), isTrue,
            reason: 'local haptic feedback still ticks');
        UdpSender.instance.sendSink = null;
      });
    });
  });

  group('gate matrix → pass-through (§4.2 step 2, §9)', () {
    test('backgrounded: handled == false, zero sends; resumed re-arms',
        () async {
      hijack.didChangeAppLifecycleState(AppLifecycleState.paused);
      final bool handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(handled, isFalse);
      expect(ws.sent, isEmpty);
      expect(scrubs, isEmpty);

      hijack.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final bool armed = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(armed, isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, hasLength(1));
    });

    test('callActive (Doc 44 OFFHOOK): handled == false, zero sends',
        () async {
      inCall = true;
      final bool handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(handled, isFalse);
      expect(ws.sent, isEmpty);

      inCall = false; // re-armed on IDLE
      final bool armed = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(armed, isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, hasLength(1));
    });

    test('enabled=false: instant pass-through without an app restart',
        () async {
      hijack.settings = const VolumeHijackSettings(enabled: false);
      final bool handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(handled, isFalse);
      expect(ws.sent, isEmpty);

      hijack.settings = const VolumeHijackSettings(enabled: true);
      final bool armed = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(armed, isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, hasLength(1));
    });

    test('disconnected + unpaired + UDP unarmed: handled == false, zero sends',
        () async {
      ws.connected = false;
      paired = false;
      expect(UdpSender.instance.isReady, isFalse,
          reason: 'this group never configures UDP');
      final bool handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(handled, isFalse);
      expect(ws.sent, isEmpty);
    });

    test('attach is idempotent; after detach keys pass through', () async {
      expect(hijack.attach(), isFalse, reason: 'already attached');
      hijack.detach();
      final bool handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeUp,
      );
      expect(handled, isFalse);
      expect(ws.sent, isEmpty);
      expect(hijack.attach(), isTrue, reason: 'detach → re-attach works');
    });
  });

  group('clamp + wall feedback (§7, §9)', () {
    test('PotPlayer route at 100 → swallow, microTick, no wire traffic',
        () async {
      current = telemetry(volume: 100, potFound: true);
      await press(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, isEmpty);
      expect(port.emitted(HapticPattern.microTick), isTrue);
      expect(port.emitted(HapticPattern.volumeTick), isFalse);
      expect(hijack.hudValue.value, 100, reason: 'badge shows the stuck base');
    });

    test('system route at 0 → swallow, microTick, no wire traffic',
        () async {
      current = telemetry(sysVolume: 0, potFound: false);
      await press(LogicalKeyboardKey.audioVolumeDown);
      expect(ws.sent, isEmpty);
      expect(port.emitted(HapticPattern.microTick), isTrue);
    });

    test('base ± step clamps into 0–100 on both routes', () async {
      current = telemetry(volume: 98, potFound: true);
      await press(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent.single.payload, <String, dynamic>{'percent': 100});

      ws.sent.clear();
      current = telemetry(sysVolume: 3, potFound: false);
      await press(LogicalKeyboardKey.audioVolumeDown);
      expect(ws.sent.single.payload, <String, dynamic>{'percent': 0});
    });

    test('system route without a sys_volume base sends nothing', () async {
      current = telemetry(potFound: false); // no base to step from (cold start)
      await press(LogicalKeyboardKey.audioVolumeUp);
      expect(ws.sent, isEmpty);
      expect(port.emitted(HapticPattern.microTick), isTrue,
          reason: 'press still gives local wall feedback');
    });
  });

  group('HUD badge (§4.2 step 4, §8)', () {
    test('badge reflects the applied step and hides exactly after 700 ms',
        () {
      fakeAsync((FakeAsync async) {
        simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
        async.flushMicrotasks();
        expect(hijack.hudValue.value, 45);

        async.elapse(const Duration(milliseconds: 699));
        expect(hijack.hudValue.value, 45, reason: 'still visible at 699 ms');

        async.elapse(const Duration(milliseconds: 1));
        expect(hijack.hudValue.value, isNull, reason: 'hidden at 700 ms');
      });
    });
  });

  group('settings persistence (§8, §10 keys)', () {
    test('enabled/step/hold/seek survive an app restart', () async {
      hijack.settings = const VolumeHijackSettings(
        enabled: false,
        stepPct: 7,
        holdThreshold: Duration(milliseconds: 750),
        seekStepSec: 15,
      );
      await pumpEventQueue(); // flush the best-effort write

      expect(prefs.getBool(kHijackEnabledPrefKey), isFalse);
      expect(prefs.getInt(kHijackStepPctPrefKey), 7);
      expect(prefs.getInt(kHijackHoldMsPrefKey), 750);
      expect(prefs.getInt(kHijackSeekSecPrefKey), 15);

      final VolumeButtonHijack reloaded = VolumeButtonHijack(
        ws: ws,
        udp: UdpSender.instance,
        telemetry: () => current,
        haptics: engine,
        isPaired: () => paired,
        nowSec: () => fakeNowSec,
        preferences: prefs,
      );
      expect(
        reloaded.settings,
        const VolumeHijackSettings(
          enabled: false,
          stepPct: 7,
          holdThreshold: Duration(milliseconds: 750),
          seekStepSec: 15,
        ),
      );
      expect(reloaded.settings.stepPct, 7);
    });

    test('default settings when nothing persisted yet', () {
      final VolumeButtonHijack reloaded = VolumeButtonHijack(
        ws: ws,
        udp: UdpSender.instance,
        telemetry: () => current,
        haptics: engine,
        isPaired: () => paired,
        nowSec: () => fakeNowSec,
        preferences: prefs,
      );
      expect(reloaded.settings.enabled, isTrue);
      expect(reloaded.settings.stepPct, kHijackStepDefaultPct);
      expect(reloaded.settings.holdThreshold,
          const Duration(milliseconds: kHijackHoldDefaultMs));
      expect(reloaded.settings.seekStepSec, kHijackSeekDefaultSec);
    });

    test('corrupt persisted values clamp instead of breaking the gate',
        () async {
      await prefs.setInt(kHijackStepPctPrefKey, 0);
      await prefs.setInt(kHijackHoldMsPrefKey, 10);
      await prefs.setInt(kHijackSeekSecPrefKey, 99999);
      final VolumeHijackSettings loaded =
          VolumeHijackSettings.fromPreferences(prefs);
      expect(loaded.stepPct, 1);
      expect(loaded.holdThreshold.inMilliseconds, 100);
      expect(loaded.seekStepSec, 3600);
    });
  });
}
