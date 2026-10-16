// Doc 31: resilient PotPilot WebSocket client with auto-reconnect.
//
// Transport is `web_socket_channel` (IOWebSocketChannel) against the PC
// agent's ws://<ip>:50506/?auth=<32-hex> endpoint (Doc 03 §4.2 — the token
// rides the upgrade URL; HTTP 401 rejects before the upgrade, so there is no
// in-band AUTH frame). All frame build/parse goes through Doc 03's owned
// codec (`ws_message_codec.dart`). mDNS resolution is injected/owned by
// Doc 32 (`MdnsAgentResolver`); cache persistence by Doc 34.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/storage/connection_cache.dart';
import 'pairing_scanner.dart';
import 'ws_message_codec.dart';

export 'ws_message_codec.dart' show WsMessage;

/// Fixed TCP port of the PC agent WebSocket server (frozen contract).
const int kWsDefaultPort = wsPort;

/// Service type browsed during mDNS fallback (frozen contract).
const String kMdnsServiceType = '_potpilot._tcp.local.';

/// First reconnect delay; doubles per attempt up to [kBackoffMax].
const Duration kBackoffInitial = Duration(milliseconds: 500);

/// Exponential growth factor between attempts.
const double kBackoffMultiplier = 2.0;

/// Reconnect delay ceiling (jitter still applies).
const Duration kBackoffMax = Duration(seconds: 15);

/// +/- jitter ratio applied to every computed delay (spreads reconnects).
const double kJitterRatio = 0.20;

/// Client WS-level ping interval (03 §4.2; server idle-closes after 30 s).
const Duration kPingInterval = Duration(seconds: 15);

/// Max silence from the PC before the link is declared half-open (03 §4.3
/// promises inbound frames every <=250 ms; 5 s = 20 missed ticks).
const Duration kLivenessTimeout = Duration(seconds: 5);

/// Per-attempt WebSocket upgrade timeout.
const Duration kConnectTimeout = Duration(seconds: 5);

/// Consecutive failures on one IP before the mDNS lookup is attempted once.
const int kMdnsFallbackAfter = 3;

/// Bounded best-effort outbound queue (oldest dropped on overflow).
const int kSendQueueCapacity = 32;

/// Connection state machine states (Doc 31 §4).
enum WsConnectionState { idle, connecting, connected, backoff, authRejected, closed }

/// Envelope type is owned by Doc 03's Dart codec (`ws_message_codec.dart`);
/// Doc 31 streams the codec's `WsMessage` (id/type/action/payload/timestamp).
typedef WsEnvelope = WsMessage;

final RegExp _tokenHexPattern = RegExp(r'^[0-9a-f]{32}$');

// dart:io surfaces the upgrade status in the WebSocketException message
// ("... was not upgraded to websocket, HTTP status code: 401").
final RegExp _auth401Pattern = RegExp(r'HTTP status code:\s*401\b');

double _secureJitter() => Random.secure().nextDouble();

/// Resilient PotPilot WebSocket client (singleton, auto-reconnecting).
class WsClient {
  WsClient({
    Future<String?> Function()? mdnsLookup,
    double Function()? jitterSource,
  })  : _mdnsLookup = mdnsLookup,
        _jitter = jitterSource ?? _secureJitter;

  static final WsClient _instance = WsClient();

  /// Process-wide singleton.
  static WsClient get instance => _instance;

  final Future<String?> Function()? _mdnsLookup;
  final double Function() _jitter;

  final StreamController<WsEnvelope> _envelopes =
      StreamController<WsEnvelope>.broadcast();
  final StreamController<WsConnectionState> _stateChanges =
      StreamController<WsConnectionState>.broadcast();

  WsConnectionState _state = WsConnectionState.idle;

  /// Bumped whenever a session begins or ends; stale async callbacks and
  /// stream events compare against it before touching state.
  int _session = 0;

  String _host = '';
  int _port = kWsDefaultPort;
  String _tokenHex = '';

  WebSocketChannel? _channel;
  int _attempt = 0;
  bool _mdnsFallbackDone = false;
  Timer? _backoffTimer;
  Timer? _watchdog;
  StreamSubscription<MdnsAgentInfo>? _agentWatch;
  String? _pairedServiceName;
  Future<void>? _connectInFlight;

  final Queue<WsMessage> _outbox = Queue<WsMessage>();

  int _malformedFrames = 0;
  int _persistFailures = 0;
  Duration? _lastBackoffDelay;

  /// Test seam: overrides one-shot `Timer` creation (fake clock in tests).
  @visibleForTesting
  Timer Function(Duration duration, void Function(Timer timer))? timerFactory;

  /// Test seam: invoked instead of Doc 34 cache writes after an mDNS IP swap.
  @visibleForTesting
  Future<void> Function(String newIp)? ipPersistOverride;

  /// Test seam: overrides the live mDNS agent stream while connected.
  @visibleForTesting
  Stream<MdnsAgentInfo> Function()? mdnsWatchOverride;

  /// Test seam: dropped/undecodable inbound frames since construction.
  @visibleForTesting
  int get malformedFrames => _malformedFrames;

  /// Test seam: failed Doc 34 persistence attempts (best-effort writes).
  @visibleForTesting
  int get persistFailures => _persistFailures;

  /// Test seam: the delay of the most recently scheduled reconnect.
  @visibleForTesting
  Duration? get lastBackoffDelay => _lastBackoffDelay;

  /// Test seam: current consecutive-failure count (0 once connected).
  @visibleForTesting
  int get attempt => _attempt;

  /// Broadcast stream of every successfully decoded envelope from the PC.
  Stream<WsEnvelope> get envelopes => _envelopes.stream;

  /// Broadcast stream of connection-state transitions.
  Stream<WsConnectionState> get stateChanges => _stateChanges.stream;

  /// Current connection state.
  WsConnectionState get state => _state;

  /// Opens `ws://host:port/?auth=<tokenHex>` (port defaults 50506); HTTP 401
  /// => [WsConnectionState.authRejected]; keeps retrying until [disconnect].
  /// A second call while already connecting returns the in-flight future.
  Future<void> connect({
    required String host,
    required String tokenHex,
    int port = kWsDefaultPort,
  }) {
    final String canonical = tokenHex.toLowerCase();
    if (!_tokenHexPattern.hasMatch(canonical)) {
      throw ArgumentError.value(
        tokenHex,
        'tokenHex',
        'must be exactly 32 hex characters',
      );
    }
    if (_state == WsConnectionState.connecting && _connectInFlight != null) {
      return _connectInFlight!;
    }
    if (_state == WsConnectionState.connected && _channel != null) {
      return Future<void>.value();
    }
    _host = host;
    _port = port;
    _tokenHex = canonical;
    final Future<void> future =
        _beginConnect().whenComplete(() => _connectInFlight = null);
    _connectInFlight = future;
    return future;
  }

  /// Sends a `CMD_*` envelope; queues (capacity 32) while reconnecting,
  /// dropping the oldest on overflow. Frames are built by the Doc 03 codec
  /// (fresh UUIDv4 `id` + unix-seconds `timestamp`).
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final WsMessage message = buildMessage(
      type: type,
      action: action,
      payload: payload,
    );
    final WebSocketChannel? channel = _channel;
    if (_state == WsConnectionState.connected && channel != null) {
      channel.sink.add(jsonEncode(message.toJson()));
      return;
    }
    if (_outbox.length >= kSendQueueCapacity) {
      _outbox.removeFirst(); // staleness beats unbounded growth
    }
    _outbox.addLast(message);
  }

  /// Terminal disconnect: cancels backoff/heartbeat, closes socket, state ->
  /// [WsConnectionState.closed]. A later [connect] starts a fresh session.
  Future<void> disconnect() async {
    _session++;
    _cancelBackoffTimer();
    _teardownChannel();
    _connectInFlight = null;
    _outbox.clear();
    _setState(WsConnectionState.closed);
  }

  /// Pure backoff calculator exposed for unit tests: attempt >= 1 -> delay,
  /// exponential from [kBackoffInitial], capped at [kBackoffMax], scaled by
  /// +/- [kJitterRatio] from `jitter01` in [0, 1).
  static Duration computeBackoff(int attempt, double jitter01) {
    final int effectiveAttempt = attempt < 1 ? 1 : attempt;
    final double exp =
        (kBackoffInitial.inMilliseconds * pow(kBackoffMultiplier, effectiveAttempt - 1))
            .toDouble();
    final double capped =
        exp.clamp(0, kBackoffMax.inMilliseconds).toDouble();
    final double jitter = 1.0 + kJitterRatio * (jitter01 * 2 - 1);
    return Duration(milliseconds: (capped * jitter).round());
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _beginConnect() async {
    final int session = ++_session;
    _cancelBackoffTimer();
    _teardownChannel();
    _setState(WsConnectionState.connecting);
    final Uri url = Uri(
      scheme: 'ws',
      host: _host,
      port: _port,
      path: '/',
      queryParameters: <String, String>{'auth': _tokenHex},
    );
    try {
      final WebSocket ws = await _connectSocket(url);
      if (session != _session) {
        unawaited(ws.close(1001, 'superseded').catchError((Object _) {}));
        return;
      }
      ws.pingInterval = kPingInterval; // 15 s protocol-level heartbeat
      final WebSocketChannel channel = IOWebSocketChannel(ws);
      _channel = channel;
      _setState(WsConnectionState.connected);
      _attempt = 0;
      _mdnsFallbackDone = false;
      _pairedServiceName = null;
      _armWatchdog();
      _listen(channel, session);
      _flushOutbox(channel);
      _subscribeAgentWatch();
    } catch (error) {
      if (session != _session) {
        return;
      }
      if (_isAuthRejection(error)) {
        _setState(WsConnectionState.authRejected);
        return;
      }
      _scheduleReconnect();
    }
  }

  /// Races `WebSocket.connect` against a (fakeable) [kConnectTimeout] timer.
  Future<WebSocket> _connectSocket(Uri url) {
    final Completer<WebSocket> completer = Completer<WebSocket>();
    var settled = false;
    final Timer timeout = _timer(kConnectTimeout, (Timer _) {
      if (!settled) {
        settled = true;
        completer.completeError(
          TimeoutException('WebSocket connect timed out: $url'),
        );
      }
    });
    unawaited(WebSocket.connect(url.toString()).then(
      (WebSocket ws) {
        if (settled) {
          unawaited(
              ws.close(1011, 'connect superseded').catchError((Object _) {}));
          return;
        }
        settled = true;
        timeout.cancel();
        completer.complete(ws);
      },
      onError: (Object error) {
        if (settled) {
          return;
        }
        settled = true;
        timeout.cancel();
        completer.completeError(error);
      },
    ));
    return completer.future;
  }

  void _listen(WebSocketChannel channel, int session) {
    channel.stream.listen(
      (Object? data) {
        if (session != _session) {
          return;
        }
        _armWatchdog(); // any inbound frame resets the liveness watchdog
        final String? raw = _asText(data);
        if (raw == null) {
          return;
        }
        try {
          final WsMessage message = parseMessage(raw);
          if (!_envelopes.isClosed) {
            _envelopes.add(message);
          }
        } on FormatException {
          _malformedFrames++; // drop and keep the stream alive
        }
      },
      onError: (Object _) {
        if (session != _session) {
          return;
        }
        _forceReconnect();
      },
      onDone: () {
        if (session != _session) {
          return;
        }
        final int? code = channel.closeCode;
        _session++;
        _teardownChannel();
        if (code == closeCodeUnauthorized) {
          // Mid-session revocation (4401): terminal, no auto-retry.
          _setState(WsConnectionState.authRejected);
          return;
        }
        _scheduleReconnect();
      },
      cancelOnError: false,
    );
  }

  /// Ends the live session (watchdog expiry or stream error) and schedules a
  /// reconnect. The session bump makes any later done-event a no-op.
  void _forceReconnect() {
    _session++;
    _teardownChannel();
    _scheduleReconnect();
  }

  void _teardownChannel() {
    _cancelWatchdog();
    _unsubscribeAgentWatch();
    final WebSocketChannel? channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }
  }

  // ---------------------------------------------------------------------------
  // Backoff + mDNS fallback
  // ---------------------------------------------------------------------------

  void _scheduleReconnect() {
    _attempt++;
    _setState(WsConnectionState.backoff);
    if (_attempt == kMdnsFallbackAfter && !_mdnsFallbackDone) {
      _mdnsFallbackDone = true;
      final int generation = _session;
      unawaited(_tryMdnsFallback().then((bool swapped) {
        if (generation != _session || _state == WsConnectionState.closed) {
          return;
        }
        if (swapped) {
          _attempt = 1; // fresh IP gets a fresh failure budget
          _mdnsFallbackDone = false;
        }
        _armBackoffTimer();
      }));
      return;
    }
    _armBackoffTimer();
  }

  void _armBackoffTimer() {
    final int generation = _session;
    final Duration delay = computeBackoff(_attempt, _jitter());
    _lastBackoffDelay = delay;
    _cancelBackoffTimer();
    _backoffTimer = _timer(delay, (Timer _) {
      _backoffTimer = null;
      if (generation != _session) {
        return;
      }
      unawaited(_beginConnect());
    });
  }

  void _cancelBackoffTimer() {
    _backoffTimer?.cancel();
    _backoffTimer = null;
  }

  /// Exactly one lookup per 3 consecutive failures on one IP (Doc 31 §4.8).
  Future<bool> _tryMdnsFallback() async {
    String? ip;
    try {
      final Future<String?> Function()? lookup = _mdnsLookup;
      ip = lookup != null
          ? await lookup()
          : await MdnsAgentResolver.instance.resolveHost();
    } catch (_) {
      return false; // resolver unavailable -> keep backoffing at cap
    }
    if (ip == null || ip.isEmpty || ip == _host) {
      return false;
    }
    _host = ip;
    await _persistIp(ip);
    return true;
  }

  /// Writes the refreshed IP into Doc 34's active `PcHostRecord`.
  Future<void> _persistIp(String newIp) async {
    try {
      final Future<void> Function(String)? override = ipPersistOverride;
      if (override != null) {
        await override(newIp);
        return;
      }
      final ConnectionCache cache = ConnectionCache.instance;
      if (!cache.isReady) {
        return;
      }
      final PcHostRecord? active = cache.activeHost;
      if (active == null) {
        return;
      }
      final List<String> others = active.ipv4s
          .where((String candidate) => candidate != newIp)
          .toList();
      await cache.updateHostIps(active.id, <String>[newIp, ...others]);
    } catch (_) {
      _persistFailures++; // best-effort: never break reconnecting on prefs
    }
  }

  // ---------------------------------------------------------------------------
  // Liveness watchdog
  // ---------------------------------------------------------------------------

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = _timer(kLivenessTimeout, (Timer _) {
      _watchdog = null;
      _forceReconnect(); // half-open TCP after AP roaming / silent death
    });
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  // ---------------------------------------------------------------------------
  // Live mDNS IP-change watch (Doc 32 resolver)
  // ---------------------------------------------------------------------------

  void _subscribeAgentWatch() {
    if (_agentWatch != null) {
      return;
    }
    final Stream<MdnsAgentInfo> Function()? override = mdnsWatchOverride;
    final Stream<MdnsAgentInfo>? stream = override != null
        ? override()
        : (_mdnsLookup == null ? MdnsAgentResolver.instance.watchAgents() : null);
    if (stream == null) {
      return;
    }
    _agentWatch = stream.listen(
      _onAgentInfo,
      onError: (Object _) {
        // Watch hiccups never disturb the live session.
      },
      onDone: () {
        _agentWatch = null;
      },
    );
  }

  void _unsubscribeAgentWatch() {
    _agentWatch?.cancel();
    _agentWatch = null;
  }

  void _onAgentInfo(MdnsAgentInfo info) {
    if (_state != WsConnectionState.connected) {
      return;
    }
    if (info.ipv4 == _host) {
      // Confirms which service name advertises our paired host.
      _pairedServiceName = info.serviceName;
      return;
    }
    if (_pairedServiceName != null && info.serviceName == _pairedServiceName) {
      _controlledReconnect(info.ipv4);
    }
  }

  /// Immediate session restart against a changed IP for the paired host.
  void _controlledReconnect(String newIp) {
    _session++;
    _teardownChannel();
    _cancelBackoffTimer();
    _host = newIp;
    _attempt = 0;
    _pairedServiceName = null;
    unawaited(_persistIp(newIp));
    unawaited(_beginConnect());
  }

  // ---------------------------------------------------------------------------
  // Outbound queue
  // ---------------------------------------------------------------------------

  void _flushOutbox(WebSocketChannel channel) {
    while (_outbox.isNotEmpty) {
      channel.sink.add(jsonEncode(_outbox.removeFirst().toJson()));
    }
  }

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------

  void _setState(WsConnectionState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    if (!_stateChanges.isClosed) {
      _stateChanges.add(next);
    }
  }

  bool _isAuthRejection(Object error) =>
      _auth401Pattern.hasMatch(error.toString());

  String? _asText(Object? data) {
    if (data is String) {
      return data;
    }
    if (data is List<int>) {
      return utf8.decode(data, allowMalformed: true);
    }
    return null;
  }

  Timer _timer(Duration duration, void Function(Timer) callback) {
    final Timer Function(Duration, void Function(Timer))? factory = timerFactory;
    if (factory != null) {
      return factory(duration, callback);
    }
    late final Timer timer;
    timer = Timer(duration, () => callback(timer));
    return timer;
  }
}
