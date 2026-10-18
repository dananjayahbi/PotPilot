// Round 6 (2026-10-18) - Doc 30 §167 correction: the UDP sender used to be
// configured exactly once (pair time) with a *permanent* circuit breaker,
// while Doc 31's WS client re-resolves IP changes and self-heals on its
// own.  Result: after any Wi-Fi/agent blip or PC IP change, every 0x04
// scrub preview (and trackpad packet) was dropped silently for the rest
// of the app run - the video only moved on finger *release* (the WS
// SEEK), which is exactly the "live scrub feels dead" bug.
//
// This watcher re-runs the idempotent configure() on every WS `connected
// transition, which both clears a tripped breaker and adopts the host IP
// that [WsClient]'s _persistIp already keeps fresh in Doc 34's cache.

import 'dart:async';

import '../core/storage/connection_cache.dart';
import 'ws_client.dart';

/// Subscribes to a WS state stream and re-binds UDP on every (re)connect.
///
/// Components are injected so the unit test drives states without sockets:
///   * [states]     - normally [WsClient.instance.stateChanges];
///   * [resolveHost] - normally `ConnectionCache.instance.activeHost`
///     (fresh IP: the WS client persists mDNS/refreshed addresses there);
///   * [configure]  - normally SessionGate's serialized `_configureUdp`.
class UdpRebindWatcher {
  UdpRebindWatcher({
    required Stream<WsConnectionState> states,
    required PcHostRecord? Function() resolveHost,
    required Future<void> Function(PcHostRecord host) configure,
    WsConnectionState initialState = WsConnectionState.idle,
  }) : _states = states,
       _resolveHost = resolveHost,
       _configure = configure,
       _initialState = initialState;

  final Stream<WsConnectionState> _states;
  final PcHostRecord? Function() _resolveHost;
  final Future<void> Function(PcHostRecord host) _configure;
  final WsConnectionState _initialState;

  StreamSubscription<WsConnectionState>? _sub;

  /// Starts listening; idempotent.  An already-connected initial state
  /// fires immediately (the broadcast stream only carries transitions).
  void start() {
    if (_sub != null) {
      return;
    }
    if (_initialState == WsConnectionState.connected) {
      _onState(WsConnectionState.connected);
    }
    _sub = _states.listen(_onState);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  void _onState(WsConnectionState state) {
    if (state != WsConnectionState.connected) {
      return; // backoff/authRejected/closed: nothing to re-bind yet
    }
    final PcHostRecord? host = _resolveHost();
    if (host == null || host.ipv4s.isEmpty) {
      return; // no persisted record yet - the pair-time bootstrap owns it
    }
    unawaited(_configure(host));
  }
}
