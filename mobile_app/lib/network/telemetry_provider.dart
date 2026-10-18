import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ws_client.dart';
import 'ws_message_codec.dart';

/// TELEMETRY_SYNC cadence advertised by the PC agent (03 §5.6 /
/// `telemetryIntervalMs`); exported for consumers/UI tick alignment.
const Duration kTelemetryCadence = Duration(milliseconds: 250);

/// Canonical TELEMETRY_SYNC payload keys — frozen by 03 §5.6 (Doc 18 emits
/// identical names). Only these six map to typed [TelemetryState] fields;
/// every other snapshot key passes through [TelemetryState.extras].
abstract final class TelemetryKeys {
  static const String positionMs = 'position_ms';
  static const String durationMs = 'duration_ms';
  static const String isPlaying = 'is_playing';
  static const String speed = 'speed';
  static const String potPlayerVolume = 'volume';
  static const String fileTitle = 'file_title';

  /// Core wire keys handled above; the rest of the flat snapshot lands in
  /// `extras` untouched.
  static const Set<String> core = <String>{
    positionMs,
    durationMs,
    isPlaying,
    speed,
    potPlayerVolume,
    fileTitle,
  };
}

/// Immutable snapshot of PotPlayer + session telemetry; rebuilt (never
/// mutated) per frame. [extras] must be treated as read-only.
@immutable
class TelemetryState {
  const TelemetryState({
    required this.timestamp,
    required this.positionMs,
    required this.durationMs,
    required this.isPlaying,
    required this.speed,
    required this.potPlayerVolume,
    required this.fileTitle,
    required this.extras,
    required this.isConnected,
  });

  /// Unix seconds of the last accepted frame (never moves backwards).
  final int timestamp;

  /// Playback position in ms (normalized ≥ 0).
  final int positionMs;

  /// Total duration in ms (0 = unknown/none).
  final int durationMs;

  final bool isPlaying;

  /// Playback multiplier 0.2x – 4.0x.
  final double speed;

  /// PotPlayer internal mixer 0–100.
  final int potPlayerVolume;

  /// Basename w/o extension; null = idle.
  final String? fileTitle;

  /// Pass-through keys (brightness, blackout, sleep_timer_*, …) for
  /// Session-2 consumers — raw wire values, never normalized.
  final Map<String, Object?> extras;

  /// WS session alive (false ⇒ values are last-known).
  final bool isConnected;

  /// All-zero, disconnected, idle, empty extras.
  static const TelemetryState initial = TelemetryState(
    timestamp: 0,
    positionMs: 0,
    durationMs: 0,
    isPlaying: false,
    speed: 0.0,
    potPlayerVolume: 0,
    fileTitle: null,
    extras: <String, Object?>{},
    isConnected: false,
  );

  /// 0..1; 0 when [durationMs] == 0, capped at 1.0 when position overruns.
  double get progress {
    if (durationMs <= 0) {
      return 0.0;
    }
    if (positionMs >= durationMs) {
      return 1.0;
    }
    return positionMs / durationMs;
  }

  /// `"HH:MM:SS"`; `"--:--:--"` while no media is loaded.
  String get positionLabel =>
      durationMs <= 0 ? '--:--:--' : _formatClock(positionMs);

  /// `"HH:MM:SS"`; `"--:--:--"` while no media is loaded.
  String get durationLabel =>
      durationMs <= 0 ? '--:--:--' : _formatClock(durationMs);

  static String _formatClock(int ms) {
    final int total = ms ~/ 1000;
    final int hours = total ~/ 3600;
    final int minutes = (total ~/ 60) % 60;
    final int seconds = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }

  /// Used only by the notifier emit step; `null` fields keep their value
  /// (build a full [TelemetryState] to clear a nullable field).
  TelemetryState copyWith({
    int? timestamp,
    int? positionMs,
    int? durationMs,
    bool? isPlaying,
    double? speed,
    int? potPlayerVolume,
    String? fileTitle,
    Map<String, Object?>? extras,
    bool? isConnected,
  }) {
    return TelemetryState(
      timestamp: timestamp ?? this.timestamp,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      isPlaying: isPlaying ?? this.isPlaying,
      speed: speed ?? this.speed,
      potPlayerVolume: potPlayerVolume ?? this.potPlayerVolume,
      fileTitle: fileTitle ?? this.fileTitle,
      extras: extras ?? this.extras,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) {
      return true;
    }
    return other is TelemetryState &&
        other.timestamp == timestamp &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.isPlaying == isPlaying &&
        other.speed == speed &&
        other.potPlayerVolume == potPlayerVolume &&
        other.fileTitle == fileTitle &&
        other.isConnected == isConnected &&
        _deepEquals(other.extras, extras);
  }

  @override
  int get hashCode => Object.hash(
        timestamp,
        positionMs,
        durationMs,
        isPlaying,
        speed,
        potPlayerVolume,
        fileTitle,
        isConnected,
        _deepHash(extras),
      );

  static bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) {
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) {
        return false;
      }
      for (final Object? key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) {
        return false;
      }
      for (int i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) {
          return false;
        }
      }
      return true;
    }
    return a == b;
  }

  static int _deepHash(Object? value) {
    if (value is Map) {
      int acc = 0;
      for (final MapEntry<Object?, Object?> entry
          in value.entries.cast<MapEntry<Object?, Object?>>()) {
        acc ^= Object.hash(_deepHash(entry.key), _deepHash(entry.value));
      }
      return acc;
    }
    if (value is List) {
      int acc = 0;
      for (final Object? element in value) {
        acc ^= _deepHash(element);
      }
      return acc;
    }
    return value?.hashCode ?? 0;
  }
}

/// Minimal read-only seam over Doc 31's `WsClient` so this notifier (and its
/// tests) depend only on the two streams, not on the transport itself.
abstract class TelemetrySocket {
  /// Broadcast stream of every successfully decoded envelope from the PC.
  Stream<WsMessage> get envelopes;

  /// Broadcast stream of connection-state transitions.
  Stream<WsConnectionState> get stateChanges;
}

/// Adapter over the real singleton client (Doc 31 public API).
class WsClientTelemetrySocket implements TelemetrySocket {
  const WsClientTelemetrySocket(this.client);

  final WsClient client;

  @override
  Stream<WsMessage> get envelopes => client.envelopes;

  @override
  Stream<WsConnectionState> get stateChanges => client.stateChanges;
}

/// Turns `TELEMETRY_SYNC` envelopes into reactive, type-safe UI state
/// (Doc 33). Telemetry is read-only: this notifier never sends.
class TelemetryNotifier extends StateNotifier<TelemetryState> {
  TelemetryNotifier(
    this._socket, {
    TelemetryState initial = TelemetryState.initial,
  }) : super(initial);

  final TelemetrySocket _socket;

  /// Action-aware accumulated snapshot: `FULL_STATE` replaces it wholesale,
  /// `STATE_DELTA` merges present keys only (explicit `null` is a value).
  final Map<String, dynamic> _snapshot = <String, dynamic>{};

  StreamSubscription<WsMessage>? _envelopesSub;
  StreamSubscription<WsConnectionState>? _statesSub;
  bool _bound = false;
  int _parseErrors = 0;

  /// Malformed telemetry fields observed since construction (debug
  /// overlay counter, Doc 33 §7). Frame never throws.
  int get parseErrors => _parseErrors;

  /// Public read of the current snapshot (exposes StateNotifier's
  /// protected `state` for non-provider readers such as tests).
  TelemetryState get snapshot => state;

  /// Subscribes to the socket's envelopes + stateChanges; idempotent,
  /// called by the provider body.
  void bind() {
    if (_bound) {
      return;
    }
    _bound = true;
    _envelopesSub = _socket.envelopes.listen(handleEnvelope);
    _statesSub = _socket.stateChanges.listen(_onConnectionState);
  }

  void _onConnectionState(WsConnectionState connection) {
    if (connection == WsConnectionState.backoff ||
        connection == WsConnectionState.authRejected ||
        connection == WsConnectionState.closed) {
      markDisconnected();
    }
    // `connected` does NOT force isConnected=true — only an actual
    // TELEMETRY_SYNC frame does (Doc 33 §4.9).
  }

  /// Sets [TelemetryState.isConnected] to false on WS loss, keeping
  /// last-known telemetry values; idempotent.
  void markDisconnected() {
    if (!mounted) {
      return;
    }
    if (state.isConnected) {
      state = state.copyWith(isConnected: false);
    }
  }

  /// Handles ONE decoded envelope; non-telemetry envelopes are ignored
  /// (cheap O(1) filter).
  void handleEnvelope(WsMessage envelope) {
    if (!mounted) {
      return;
    }
    if (envelope.type != typeTelemetrySync) {
      return;
    }

    if (envelope.action == actionStateDelta) {
      _snapshot.addAll(envelope.payload);
    } else {
      // FULL_STATE — and any unknown action, defensively — replaces the
      // whole snapshot; omitted keys are genuinely gone (Doc 33 §4.2).
      _snapshot
        ..clear()
        ..addAll(envelope.payload);
    }

    final TelemetryState next = _derive(envelope.timestamp);
    if (next != state) {
      state = next; // equal-state suppression: no redundant rebuilds
    }
  }

  /// Extracts typed fields from [_snapshot] with per-field fallback +
  /// normalization; malformed values are dropped (counted once) so the
  /// field keeps its previous value until a valid update arrives.
  TelemetryState _derive(int frameTimestamp) {
    final TelemetryState prev = state;

    // Staleness clock: frame timestamp if sane, else local epoch; never
    // moves backwards (rewound PC clock after restart, §4.10).
    final int localNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int effective = frameTimestamp >= 1 ? frameTimestamp : localNow;
    final int timestamp = effective > prev.timestamp ? effective : prev.timestamp;

    int positionMs = prev.positionMs;
    int durationMs = prev.durationMs;
    bool isPlaying = prev.isPlaying;
    double speed = prev.speed;
    int potPlayerVolume = prev.potPlayerVolume;
    String? fileTitle = prev.fileTitle;

    if (_snapshot.containsKey(TelemetryKeys.positionMs)) {
      final Object? value = _snapshot[TelemetryKeys.positionMs];
      if (value is int) {
        // 03 "none" (-1) and any negative normalize to 0.
        positionMs = value < 0 ? 0 : value;
      } else {
        _malformed(TelemetryKeys.positionMs);
      }
    }

    if (_snapshot.containsKey(TelemetryKeys.durationMs)) {
      final Object? value = _snapshot[TelemetryKeys.durationMs];
      if (value is int) {
        durationMs = value < 0 ? 0 : value;
      } else {
        _malformed(TelemetryKeys.durationMs);
      }
    }

    if (_snapshot.containsKey(TelemetryKeys.isPlaying)) {
      final Object? value = _snapshot[TelemetryKeys.isPlaying];
      if (value is bool) {
        isPlaying = value;
      } else {
        _malformed(TelemetryKeys.isPlaying);
      }
    }

    if (_snapshot.containsKey(TelemetryKeys.speed)) {
      final Object? value = _snapshot[TelemetryKeys.speed];
      if (value is num &&
          !value.isNaN &&
          !value.isInfinite &&
          value >= 0.2 &&
          value <= 4.0) {
        speed = value.toDouble();
      } else {
        // Out of range / NaN / null / wrong type ⇒ keep previous (§4.5).
        _malformed(TelemetryKeys.speed);
      }
    }

    if (_snapshot.containsKey(TelemetryKeys.potPlayerVolume)) {
      final Object? value = _snapshot[TelemetryKeys.potPlayerVolume];
      if (value is int) {
        // Out-of-range mixer values clamp into [0, 100].
        potPlayerVolume = value < 0 ? 0 : (value > 100 ? 100 : value);
      } else {
        _malformed(TelemetryKeys.potPlayerVolume);
      }
    }

    if (_snapshot.containsKey(TelemetryKeys.fileTitle)) {
      final Object? value = _snapshot[TelemetryKeys.fileTitle];
      if (value == null) {
        fileTitle = null; // explicit null = idle, applied (§4.4)
      } else if (value is String) {
        if (value.trim().isNotEmpty) {
          fileTitle = value; // whitespace-only ⇒ keep previous (§7)
        }
      } else {
        _malformed(TelemetryKeys.fileTitle);
      }
    }

    final Map<String, Object?> extras = <String, Object?>{
      for (final MapEntry<String, dynamic> entry in _snapshot.entries)
        if (!TelemetryKeys.core.contains(entry.key))
          entry.key: entry.value,
    };

    return TelemetryState(
      timestamp: timestamp,
      positionMs: positionMs,
      durationMs: durationMs,
      isPlaying: isPlaying,
      speed: speed,
      potPlayerVolume: potPlayerVolume,
      fileTitle: fileTitle,
      extras: Map<String, Object?>.unmodifiable(extras),
      isConnected: true, // receiving telemetry implies a live pipe (§4.7)
    );
  }

  void _malformed(String key) {
    _parseErrors++;
    // Drop the poison so it is counted once, not re-flagged every tick;
    // the field falls back to the previous value until fixed.
    _snapshot.remove(key);
  }

  @override
  void dispose() {
    _envelopesSub?.cancel();
    _statesSub?.cancel();
    _envelopesSub = null;
    _statesSub = null;
    super.dispose();
  }
}

/// The app-wide telemetry source of truth. App-lifetime (`autoDispose`
/// defaults to false) — consumed by deck/HUD/volume surfaces.
final StateNotifierProvider<TelemetryNotifier, TelemetryState>
telemetryProvider =
    StateNotifierProvider<TelemetryNotifier, TelemetryState>((ref) {
      final TelemetryNotifier notifier = TelemetryNotifier(
        WsClientTelemetrySocket(WsClient.instance),
      );
      notifier.bind();
      return notifier;
    });
