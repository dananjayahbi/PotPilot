import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/storage/connection_cache.dart';
import '../core/theme/oled_theme.dart';
import '../main.dart';
import 'ws_client.dart';

export '../core/storage/connection_cache.dart'
    show PcHostRecord, kUdpPort, kWsPort;

/// Service type browsed/validated during pairing (frozen contract).
const String kMdnsServiceType = '_potpilot._tcp.local.';

/// Token regex — 32 lowercase hex = 128-bit pairing token (uppercase input
/// is lowercased before matching, Docs 03/15/17).
const String kTokenHexRegex = r'^[0-9a-f]{32}$';

/// Handshake budget per candidate IP (Doc 31 constant, mirrored here).
const Duration kConnectTimeout = Duration(seconds: 5);

/// One-shot mDNS resolution budget (Doc 32 §5).
const Duration kMdnsResolveTimeout = Duration(seconds: 3);

/// Periodic mDNS refresh browse (keeps DHCP changes flowing).
const Duration kMdnsRefreshInterval = Duration(seconds: 30);

final RegExp _tokenPattern = RegExp(kTokenHexRegex);
final RegExp _ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

bool _isValidIpv4(String value) {
  if (!_ipv4Pattern.hasMatch(value)) {
    return false;
  }
  for (final String part in value.split('.')) {
    if (int.parse(part) > 255) {
      return false;
    }
  }
  return true;
}

String _lower(String value) => value.toLowerCase();

String _stripLocal(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'\.local\.?$'), '');

// ---------------------------------------------------------------------------
// QR pairing payload (Doc 17 §5 — consumed, never defined here)
// ---------------------------------------------------------------------------

/// Decoded, immutable QR pairing payload — keys frozen by Doc 17 §5:
/// `{"v":1,"host":"…","ips":["…"],"udp":50505,"ws":50506,"token":"<32 hex>"}`.
@immutable
class PcPairingPayload {
  const PcPairingPayload({
    required this.version,
    required this.hostname,
    required this.ipv4s,
    required this.udpPort,
    required this.wsPort,
    required this.tokenHex,
  });

  static const Set<String> _keys = <String>{'v', 'host', 'ips', 'udp', 'ws', 'token'};

  /// From `"v"`; must equal 1.
  final int version;

  /// From `"host"` — PC NetBIOS name.
  final String hostname;

  /// From `"ips"` — candidate LAN IPv4s, tried in order.
  final List<String> ipv4s;

  /// From `"udp"` (must equal 50505).
  final int udpPort;

  /// From `"ws"` (must equal 50506).
  final int wsPort;

  /// From `"token"` — 32 hex chars; lowercased on consumption.
  final String tokenHex;

  /// Parses raw QR text — tolerates bare JSON or a `potpilot://pair?…`
  /// wrapper containing the same JSON. Returns null on malformed input.
  static PcPairingPayload? tryParse(String raw) {
    final Object? data = _decodeJson(raw) ?? _decodeWrapper(raw);
    if (data is! Map<String, dynamic>) {
      return null;
    }
    if (data.length != _keys.length ||
        data.keys.any((String key) => !_keys.contains(key))) {
      return null;
    }
    final Object? version = data['v'];
    final Object? host = data['host'];
    final Object? ips = data['ips'];
    final Object? udp = data['udp'];
    final Object? ws = data['ws'];
    final Object? token = data['token'];
    if (version is! int ||
        host is! String ||
        udp is! int ||
        ws is! int ||
        token is! String ||
        ips is! List ||
        ips.any((Object? ip) => ip is! String)) {
      return null;
    }
    return PcPairingPayload(
      version: version,
      hostname: host,
      ipv4s: List<String>.of(ips.cast<String>()),
      udpPort: udp,
      wsPort: ws,
      tokenHex: token,
    );
  }

  static Object? _decodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } on Object {
      return null;
    }
  }

  static Object? _decodeWrapper(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'potpilot') {
      return null;
    }
    // The wrapper hosts the same JSON in one of its query parts.
    if (uri.query.isNotEmpty) {
      final Object? direct = _decodeJson(uri.query);
      if (direct is Map<String, dynamic>) {
        return direct;
      }
    }
    final Map<String, String> params = Uri.splitQueryString(uri.query);
    for (final String value in params.values) {
      final Object? decoded = _decodeJson(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    }
    return null;
  }

  /// Order: version → ports → token → reachable IPv4 (Doc 32 §4.3).
  PairingFailure? validate() {
    if (version != 1) {
      return PairingFailure.unsupportedVersion;
    }
    if (udpPort != kUdpPort || wsPort != kWsPort) {
      return PairingFailure.wrongPorts;
    }
    if (!_tokenPattern.hasMatch(tokenHex.toLowerCase())) {
      return PairingFailure.badToken;
    }
    if (!ipv4s.any(_isValidIpv4)) {
      return PairingFailure.noReachableHost;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Pairing state machine types
// ---------------------------------------------------------------------------

enum PairingPhase { idle, scanning, validating, handshaking, persisting, paired, failed }

enum PairingFailure {
  cameraDenied,
  invalidQr,
  unsupportedVersion,
  wrongPorts,
  badToken,
  noReachableHost,
  authRejected,
  handshakeTimeout,
  storageError,
}

/// Immutable snapshot of the pairing flow, emitted on every transition.
@immutable
class PairingState {
  const PairingState({
    required this.phase,
    this.failure,
    this.pairedHost,
    this.attempt = 0,
  });

  final PairingPhase phase;
  final PairingFailure? failure;
  final PcHostRecord? pairedHost;
  final int attempt;
}

// ---------------------------------------------------------------------------
// Seams (test injection points)
// ---------------------------------------------------------------------------

/// Seam over Doc 31's `WsClient` for the pairing handshake.
abstract class PairingSocket {
  Future<void> connect({
    required String host,
    required String tokenHex,
    int port = kWsPort,
  });

  Future<void> disconnect();

  Stream<WsConnectionState> get stateChanges;
}

/// Adapter over the real singleton client (Doc 31 public API).
class WsClientPairingSocket implements PairingSocket {
  WsClientPairingSocket(this._client);

  final WsClient _client;

  @override
  Future<void> connect({
    required String host,
    required String tokenHex,
    int port = kWsPort,
  }) =>
      _client.connect(host: host, tokenHex: tokenHex, port: port);

  @override
  Future<void> disconnect() => _client.disconnect();

  @override
  Stream<WsConnectionState> get stateChanges => _client.stateChanges;
}

/// Seam over the `mobile_scanner` camera pipeline so the pairing state
/// machine is testable without a camera.
abstract class QrScanEngine {
  /// Requests camera permission and starts QR-only capture.
  /// Returns false when permission is denied or no camera is available.
  Future<bool> start();

  /// Stops capture (camera released); safe to call repeatedly.
  void stop();

  /// Decoded raw QR values, one event per detection.
  Stream<String> get rawCodes;

  /// Camera preview widget for the scanner screen.
  Widget buildPreview(BuildContext context);

  /// Releases platform resources.
  void dispose();
}

/// Real engine backed by `mobile_scanner` (QR format, manual start).
class MobileScannerQrEngine implements QrScanEngine {
  MobileScannerQrEngine()
    : _controller = MobileScannerController(
        autoStart: false,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );

  final MobileScannerController _controller;
  final StreamController<String> _codes = StreamController<String>.broadcast();
  StreamSubscription<BarcodeCapture>? _codeSub;
  bool _disposed = false;

  @override
  Future<bool> start() async {
    if (_disposed) {
      return false;
    }
    try {
      await _controller.start();
    } on Object catch (error) {
      debugPrint('pairing: camera start failed: $error');
      return false;
    }
    if (!_controller.value.isRunning) {
      return false;
    }
    _codeSub ??= _controller.barcodes.listen(_onCapture);
    return true;
  }

  void _onCapture(BarcodeCapture capture) {
    for (final Barcode barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw != null && raw.isNotEmpty && !_codes.isClosed) {
        _codes.add(raw);
      }
    }
  }

  @override
  void stop() {
    _codeSub?.cancel();
    _codeSub = null;
    if (!_disposed) {
      unawaited(_controller.stop().catchError((Object _) {}));
    }
  }

  @override
  Stream<String> get rawCodes => _codes.stream;

  @override
  Widget buildPreview(BuildContext context) =>
      MobileScanner(controller: _controller);

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _codeSub?.cancel();
    _codeSub = null;
    _controller.dispose();
    if (!_codes.isClosed) {
      _codes.close();
    }
  }
}

// ---------------------------------------------------------------------------
// Pairing controller
// ---------------------------------------------------------------------------

enum _HandshakeOutcome { connected, authRejected, timeout }

/// Drives scan → validate → handshake → persist → navigate;
/// one instance per app run.
class PairingController {
  PairingController({
    QrScanEngine? scanEngine,
    PairingSocket? socket,
    ConnectionCache? cache,
    MdnsAgentResolver? resolver,
    Future<void> Function()? onBindTelemetry,
    Duration connectTimeout = kConnectTimeout,
  }) : _engine = scanEngine ?? MobileScannerQrEngine(),
       _socketOverride = socket,
       _cache = cache ?? ConnectionCache.instance,
       _resolver = resolver ?? MdnsAgentResolver.instance,
       _onBindTelemetry = onBindTelemetry,
       _connectTimeout = connectTimeout;

  final QrScanEngine _engine;
  final PairingSocket? _socketOverride;
  final ConnectionCache _cache;
  final MdnsAgentResolver _resolver;
  final Future<void> Function()? _onBindTelemetry;
  final Duration _connectTimeout;

  final StreamController<PairingState> _states =
      StreamController<PairingState>.broadcast();
  final StreamController<String> _ipChanged = StreamController<String>.broadcast();

  PairingState _state = const PairingState(phase: PairingPhase.idle);
  PairingSocket? _socket;
  StreamSubscription<String>? _codeSub;
  StreamSubscription<MdnsAgentInfo>? _agentSub;
  bool _disposed = false;

  Stream<PairingState> get states => _states.stream;
  PairingState get state => _state;

  /// Emitted whenever live mDNS shows a new IPv4 for the active host —
  /// the signal Doc 31's client uses for a controlled reconnect (§4.7).
  Stream<String> get ipChanged => _ipChanged.stream;

  /// Live advertisements from the controller's (injected) resolver.
  Stream<MdnsAgentInfo> watchAgents() => _resolver.watchAgents();

  /// Camera preview for the scanner screen (the engine owns the scanner).
  Widget buildPreview(BuildContext context) => _engine.buildPreview(context);

  PairingSocket get _sock => _socket ??= _socketOverride ?? WsClientPairingSocket(WsClient.instance);

  void _emit(
    PairingPhase phase,
    PairingFailure? failure, {
    PcHostRecord? pairedHost,
    int? attempt,
  }) {
    if (_disposed || _states.isClosed) {
      return;
    }
    _state = PairingState(
      phase: phase,
      failure: failure,
      pairedHost: pairedHost,
      attempt: attempt ?? _state.attempt,
    );
    _states.add(_state);
  }

  /// Camera preview + QR decode loop; denied camera ⇒ failed/cameraDenied.
  Future<void> startScanning() async {
    final PairingPhase phase = _state.phase;
    if (phase == PairingPhase.handshaking ||
        phase == PairingPhase.persisting ||
        phase == PairingPhase.paired) {
      return;
    }
    _emit(PairingPhase.scanning, null);
    _ensureWatching();
    final bool granted;
    try {
      granted = await _engine.start();
    } on Object catch (error) {
      debugPrint('pairing: scanner start failed: $error');
      _emit(PairingPhase.failed, PairingFailure.cameraDenied);
      return;
    }
    if (!granted) {
      _emit(PairingPhase.failed, PairingFailure.cameraDenied);
      return;
    }
    await _codeSub?.cancel();
    _codeSub = _engine.rawCodes.listen(_onCode);
  }

  void stopScanning() {
    _codeSub?.cancel();
    _codeSub = null;
    _engine.stop();
    if (_state.phase == PairingPhase.scanning) {
      _emit(PairingPhase.idle, null);
    }
  }

  /// Failed → scanning (state machine, Doc 32 §4); restarts capture.
  void reset() {
    unawaited(startScanning().catchError((Object _) {}));
  }

  /// Validates [raw] and runs the full pairing sequence; fails fast into
  /// state.failed; re-entrancy guarded by the current phase.
  Future<void> pairFromQr(String raw) async {
    if (!_canStartAttempt()) {
      return;
    }
    _beginAttempt();
    final PcPairingPayload? payload = PcPairingPayload.tryParse(raw);
    if (payload == null) {
      _bounceFromValidation(PairingFailure.invalidQr);
      return;
    }
    final PairingFailure? failure = payload.validate();
    if (failure != null) {
      _bounceFromValidation(failure);
      return;
    }
    await _pair(
      hostname: payload.hostname,
      candidateIps: payload.ipv4s,
      tokenHex: payload.tokenHex.toLowerCase(),
    );
  }

  /// Re-pairs from a cached record (auto-connect at app start); same
  /// state machine, no camera involvement.
  Future<void> pairFromCache(PcHostRecord host) async {
    if (!_canStartAttempt()) {
      return;
    }
    _beginAttempt();
    final PcPairingPayload payload = PcPairingPayload(
      version: 1,
      hostname: host.hostname,
      ipv4s: host.ipv4s,
      udpPort: host.udpPort,
      wsPort: host.wsPort,
      tokenHex: host.tokenHex,
    );
    final PairingFailure? failure = payload.validate();
    if (failure != null) {
      _emit(PairingPhase.failed, failure);
      return;
    }
    await _pair(
      hostname: host.hostname,
      candidateIps: host.ipv4s,
      tokenHex: host.tokenHex.toLowerCase(),
    );
  }

  /// No-camera pairing: mDNS discovery + pasted 32-hex token (Doc 32 §7).
  Future<void> pairManual({
    required String hostname,
    required List<String> ipv4s,
    required String tokenHex,
  }) async {
    if (!_canStartAttempt()) {
      return;
    }
    _beginAttempt();
    final PcPairingPayload payload = PcPairingPayload(
      version: 1,
      hostname: hostname,
      ipv4s: ipv4s,
      udpPort: kUdpPort,
      wsPort: kWsPort,
      tokenHex: tokenHex,
    );
    final PairingFailure? failure = payload.validate();
    if (failure != null) {
      _bounceFromValidation(failure);
      return;
    }
    await _pair(
      hostname: hostname,
      candidateIps: ipv4s,
      tokenHex: tokenHex.toLowerCase(),
    );
  }

  bool _canStartAttempt() {
    final PairingPhase phase = _state.phase;
    if (phase == PairingPhase.validating ||
        phase == PairingPhase.handshaking ||
        phase == PairingPhase.persisting ||
        phase == PairingPhase.paired) {
      return false; // re-entrancy guard (double QR frames, §7)
    }
    return !_disposed;
  }

  void _beginAttempt() {
    _emit(PairingPhase.validating, null, attempt: _state.attempt + 1);
  }

  void _bounceFromValidation(PairingFailure failure) {
    _emit(PairingPhase.failed, failure);
    _emit(PairingPhase.scanning, failure);
  }

  Future<void> _pair({
    required String hostname,
    required List<String> candidateIps,
    required String tokenHex,
  }) async {
    _emit(PairingPhase.handshaking, null);
    _engine.stop();

    try {
      final String? connectedIp = await _handshake(
        hostname: hostname,
        candidateIps: candidateIps,
        tokenHex: tokenHex,
      );
      if (connectedIp == null) {
        return; // failure already emitted
      }

      _emit(PairingPhase.persisting, null);
      final PcHostRecord record = PcHostRecord(
        hostname: hostname,
        ipv4s: <String>[
          connectedIp,
          for (final String ip in candidateIps)
            if (_isValidIpv4(ip) && ip != connectedIp) ip,
        ],
        tokenHex: tokenHex,
        lastConnectedAt: DateTime.now(),
      );
      try {
        await _cache.saveHost(record);
        await _cache.setActiveHost(record.id);
      } on Object catch (error) {
        debugPrint('pairing: cache write failed: $error');
        await _safeDisconnect();
        _emit(PairingPhase.failed, PairingFailure.storageError);
        return;
      }

      try {
        await _onBindTelemetry?.call();
      } on Object catch (error) {
        // Telemetry binds lazily on first read anyway — non-fatal.
        debugPrint('pairing: telemetry bind hook failed: $error');
      }
      _emit(PairingPhase.paired, null, pairedHost: record);
    } on Object catch (error) {
      debugPrint('pairing: unexpected failure: $error');
      await _safeDisconnect();
      _emit(PairingPhase.failed, PairingFailure.handshakeTimeout);
    }
  }

  /// Preference order: last-known cache IP → candidate IPs → mDNS (§4.4).
  Future<String?> _handshake({
    required String hostname,
    required List<String> candidateIps,
    required String tokenHex,
  }) async {
    final List<String> candidates = <String>[];
    for (final String ip in <String>[
      ..._lastKnownIps(hostname),
      ...candidateIps,
    ]) {
      if (_isValidIpv4(ip) && !candidates.contains(ip)) {
        candidates.add(ip);
      }
    }

    for (final String ip in candidates) {
      await _safeDisconnect();
      final _HandshakeOutcome outcome =
          await _tryCandidate(ip: ip, tokenHex: tokenHex);
      if (outcome == _HandshakeOutcome.connected) {
        return ip;
      }
      if (outcome == _HandshakeOutcome.authRejected) {
        await _safeDisconnect();
        _emit(PairingPhase.failed, PairingFailure.authRejected);
        return null;
      }
    }

    // Fall back to mDNS resolution of the paired PC.
    final String? mdnsIp = await _resolveViaMdns();
    if (mdnsIp == null || !_isValidIpv4(mdnsIp)) {
      _emit(PairingPhase.failed, PairingFailure.noReachableHost);
      return null;
    }
    await _safeDisconnect();
    final _HandshakeOutcome outcome =
        await _tryCandidate(ip: mdnsIp, tokenHex: tokenHex);
    if (outcome == _HandshakeOutcome.connected) {
      return mdnsIp;
    }
    await _safeDisconnect();
    if (outcome == _HandshakeOutcome.authRejected) {
      _emit(PairingPhase.failed, PairingFailure.authRejected);
    } else {
      _emit(PairingPhase.failed, PairingFailure.handshakeTimeout);
    }
    return null;
  }

  List<String> _lastKnownIps(String hostname) {
    if (!_cache.isReady) {
      return const <String>[];
    }
    for (final PcHostRecord host in _cache.hosts) {
      if (_lower(host.hostname) == _lower(hostname)) {
        return host.ipv4s;
      }
    }
    return const <String>[];
  }

  Future<String?> _resolveViaMdns() async {
    try {
      return await _resolver.resolveHost(timeout: kMdnsResolveTimeout);
    } on Object catch (error) {
      debugPrint('pairing: mDNS resolve failed: $error');
      return null;
    }
  }

  /// Races `connected` / `authRejected` against [kConnectTimeout] for one
  /// candidate IP; the transport keeps retrying on its own (Doc 31), so the
  /// caller owns the deadline.
  Future<_HandshakeOutcome> _tryCandidate({
    required String ip,
    required String tokenHex,
  }) async {
    final Completer<_HandshakeOutcome> completer = Completer<_HandshakeOutcome>();
    StreamSubscription<WsConnectionState>? sub;
    Timer? timer;
    void settle(_HandshakeOutcome outcome) {
      if (!completer.isCompleted) {
        completer.complete(outcome);
      }
    }

    sub = _sock.stateChanges.listen((WsConnectionState connection) {
      if (connection == WsConnectionState.connected) {
        settle(_HandshakeOutcome.connected);
      } else if (connection == WsConnectionState.authRejected) {
        settle(_HandshakeOutcome.authRejected);
      }
    });
    timer = Timer(_connectTimeout, () => settle(_HandshakeOutcome.timeout));

    try {
      final Future<void> pending = _sock.connect(
        host: ip,
        tokenHex: tokenHex,
        port: kWsPort,
      );
      unawaited(pending.catchError((Object _) {
        // Transport errors surface through stateChanges/timeout.
      }));
    } on Object catch (error) {
      debugPrint('pairing: connect threw for $ip: $error');
    }

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      timer.cancel();
    }
  }

  Future<void> _safeDisconnect() async {
    try {
      await _sock.disconnect();
    } on Object catch (error) {
      debugPrint('pairing: disconnect failed: $error');
    }
  }

  void _onCode(String raw) {
    final PairingPhase phase = _state.phase;
    if (phase != PairingPhase.scanning && phase != PairingPhase.idle) {
      return; // re-entrancy guard: feed each frame once
    }
    unawaited(
      pairFromQr(raw).catchError((Object error) {
        debugPrint('pairing: pairing attempt crashed: $error');
        _emit(PairingPhase.failed, PairingFailure.handshakeTimeout);
      }),
    );
  }

  // -- live mDNS (§4.7) ------------------------------------------------------

  void _ensureWatching() {
    _agentSub ??= _resolver.watchAgents().listen(_onAgentInfo);
    unawaited(_resolver.start().catchError((Object _) {}));
  }

  void _onAgentInfo(MdnsAgentInfo info) {
    if (!_cache.isReady) {
      return;
    }
    final PcHostRecord? active = _cache.activeHost;
    if (active == null) {
      return;
    }
    if (_lower(info.hostname) != _lower(active.hostname) &&
        _lower(info.serviceName) != _lower(active.hostname)) {
      return; // other agents never touch the active record
    }
    if (active.ipv4s.isNotEmpty && active.ipv4s.first == info.ipv4) {
      return; // unchanged
    }
    final List<String> merged = <String>[
      info.ipv4,
      for (final String ip in active.ipv4s)
        if (ip != info.ipv4) ip,
    ];
    try {
      unawaited(_cache.updateHostIps(active.id, merged));
    } on Object catch (error) {
      debugPrint('pairing: IP rewrite failed: $error');
    }
    if (!_ipChanged.isClosed) {
      _ipChanged.add(info.ipv4);
    }
  }

  /// Cancels every subscription and stream; the controller is single-use.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _codeSub?.cancel();
    _agentSub?.cancel();
    _codeSub = null;
    _agentSub = null;
    _engine.dispose();
    _ipChanged.close();
    _states.close();
  }
}

// ---------------------------------------------------------------------------
// mDNS subsystem — the app's single resolver (Doc 32 §6)
// ---------------------------------------------------------------------------

/// One discovered/updated agent advertisement.
@immutable
class MdnsAgentInfo {
  const MdnsAgentInfo({
    required this.serviceName,
    required this.hostname,
    required this.ipv4,
    required this.udpPort,
    required this.wsPort,
  });

  final String serviceName;
  final String hostname;
  final String ipv4;
  final int udpPort;
  final int wsPort;

  /// Frozen ports respected; a mismatching TXT marks the info untrusted —
  /// usable for IP discovery only (Doc 32 §10).
  bool get trusted => udpPort == kUdpPort && wsPort == kWsPort;

  @override
  bool operator ==(Object other) =>
      other is MdnsAgentInfo &&
      other.serviceName == serviceName &&
      other.hostname == hostname &&
      other.ipv4 == ipv4 &&
      other.udpPort == udpPort &&
      other.wsPort == wsPort;

  @override
  int get hashCode => Object.hash(serviceName, hostname, ipv4, udpPort, wsPort);
}

/// Transport seam: raw multicast socket + Android MulticastLock.
abstract class MdnsBackend {
  /// Acquires platform resources (multicast lock, socket, group join).
  Future<void> open();

  /// Releases platform resources; safe to call repeatedly.
  Future<void> close();

  /// Sends one DNS query to 224.0.0.251:5353.
  Future<void> send(List<int> query);

  /// Raw DNS messages received from the multicast group.
  Stream<List<int>> get responses;
}

/// Default backend: `dart:io` multicast + a MethodChannel into Android's
/// WifiManager (the CHANGE_WIFI_MULTICAST_STATE permission is owned by
/// Doc 05's manifest; the native handler is a manual integration step).
class MulticastMdnsBackend implements MdnsBackend {
  static const MethodChannel _lockChannel =
      MethodChannel('potpilot/multicast_lock');
  static final InternetAddress _group = InternetAddress('224.0.0.251');
  static const int _mdnsPort = 5353;

  RawDatagramSocket? _socket;
  final StreamController<List<int>> _responses =
      StreamController<List<int>>.broadcast();
  StreamSubscription<RawSocketEvent>? _socketSub;
  bool _lockHeld = false;

  @override
  Future<void> open() async {
    if (_socket != null) {
      return;
    }
    try {
      await _lockChannel.invokeMethod<void>('acquire');
      _lockHeld = true;
    } on Object catch (error) {
      // Best-effort: some devices receive multicast without the lock.
      debugPrint('mDNS: MulticastLock unavailable ($error)');
    }
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _mdnsPort,
      reuseAddress: true,
    );
    socket.joinMulticast(_group);
    _socket = socket;
    _socketSub = socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read || _responses.isClosed) {
        return;
      }
      final Datagram? datagram = socket.receive();
      if (datagram != null) {
        _responses.add(datagram.data);
      }
    });
  }

  @override
  Future<void> close() async {
    if (_lockHeld) {
      try {
        await _lockChannel.invokeMethod<void>('release');
      } on Object catch (error) {
        debugPrint('mDNS: MulticastLock release failed ($error)');
      }
      _lockHeld = false;
    }
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
  }

  @override
  Future<void> send(List<int> query) async {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) {
      return;
    }
    socket.send(query, _group, _mdnsPort);
  }

  @override
  Stream<List<int>> get responses => _responses.stream;
}

/// Single mDNS implementation for the app: one-shot resolve + live stream.
class MdnsAgentResolver {
  MdnsAgentResolver({MdnsBackend? backend})
    : _backend = backend ?? MulticastMdnsBackend();

  /// App-wide instance used by pairing, WS fallback, and live updates.
  static final MdnsAgentResolver instance = MdnsAgentResolver();

  final MdnsBackend _backend;
  final StreamController<MdnsAgentInfo> _agents =
      StreamController<MdnsAgentInfo>.broadcast();
  final Map<String, MdnsAgentInfo> _known = <String, MdnsAgentInfo>{};
  final Map<String, String> _addressCache = <String, String>{};
  StreamSubscription<List<int>>? _responseSub;
  Timer? _refresh;
  Future<void>? _opening;
  bool _started = false;

  /// Begins browse (idempotent).
  Future<void> start() async {
    if (_started) {
      return;
    }
    final Future<void>? pending = _opening;
    if (pending != null) {
      return pending;
    }
    final Future<void> opening = _open();
    _opening = opening;
    try {
      await opening;
    } on Object {
      _opening = null;
      rethrow;
    }
  }

  Future<void> _open() async {
    await _backend.open();
    _responseSub = _backend.responses.listen(_onResponse);
    _started = true;
    _sendQuery();
    _refresh?.cancel();
    _refresh = Timer.periodic(kMdnsRefreshInterval, (_) => _sendQuery());
  }

  void _sendQuery() {
    unawaited(
      _backend.send(buildDnsSdQuery(kMdnsServiceType)).catchError((Object _) {}),
    );
  }

  void _onResponse(List<int> data) {
    final List<MdnsAgentInfo> found = parseMdnsResponse(
      data,
      addressCache: _addressCache,
    );
    for (final MdnsAgentInfo info in found) {
      final MdnsAgentInfo? previous = _known[info.serviceName];
      if (previous == info) {
        continue; // no change → no emission
      }
      _known[info.serviceName] = info;
      if (!_agents.isClosed) {
        _agents.add(info);
      }
    }
  }

  /// Resolves the paired PC's current IPv4; null on timeout (3 s default).
  Future<String?> resolveHost({
    Duration timeout = kMdnsResolveTimeout,
  }) async {
    try {
      await start();
    } on Object catch (error) {
      debugPrint('mDNS: start failed ($error)');
      return null;
    }
    if (_known.isNotEmpty) {
      return _known.values.first.ipv4;
    }
    try {
      final MdnsAgentInfo info =
          await watchAgents().first.timeout(timeout);
      return info.ipv4;
    } on TimeoutException {
      return null;
    } on StateError {
      return null; // stream closed before any advertisement
    }
  }

  /// Live advertisements (initial browse results + changes) for all
  /// PotPilot agents. Call [start] first (pairing does this for you).
  Stream<MdnsAgentInfo> watchAgents() => _agents.stream;

  Future<void> stop() async {
    _refresh?.cancel();
    _refresh = null;
    await _responseSub?.cancel();
    _responseSub = null;
    _started = false;
    _opening = null;
    await _backend.close();
  }
}

// ---------------------------------------------------------------------------
// Minimal DNS-SD (PTR/SRV/TXT/A) codec — only what `_potpilot._tcp.local.`
// browsing needs; unknown records are ignored, never crashing the listener.
// ---------------------------------------------------------------------------

int _u16(List<int> data, int offset) =>
    (data[offset] << 8) | data[offset + 1];

/// Decodes a (possibly compressed) DNS name; returns the offset after the
/// name on the wire plus the decoded text, or null when malformed.
(int, String)? _decodeName(List<int> data, int start) {
  final StringBuffer out = StringBuffer();
  int pos = start;
  int? resume;
  int jumps = 0;
  while (true) {
    if (pos < 0 || pos >= data.length) {
      return null;
    }
    final int len = data[pos];
    if (len == 0) {
      pos += 1;
      break;
    }
    if ((len & 0xC0) == 0xC0) {
      if (pos + 1 >= data.length) {
        return null;
      }
      final int pointer = ((len & 0x3F) << 8) | data[pos + 1];
      resume ??= pos + 2;
      if (++jumps > 32) {
        return null;
      }
      pos = pointer;
      continue;
    }
    if (pos + 1 + len > data.length) {
      return null;
    }
    if (out.isNotEmpty) {
      out.write('.');
    }
    out.write(String.fromCharCodes(data, pos + 1, pos + 1 + len));
    pos += 1 + len;
  }
  return (resume ?? pos, out.toString());
}

List<int> _encodeName(String name) {
  final BytesBuilder builder = BytesBuilder();
  for (final String label in name.split('.')) {
    if (label.isEmpty) {
      continue;
    }
    final List<int> bytes = label.codeUnits;
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
  return builder.takeBytes();
}

/// Builds the PTR browse query for [serviceType] (one question, no answers).
List<int> buildDnsSdQuery(String serviceType) {
  final BytesBuilder builder = BytesBuilder();
  builder.add(<int>[
    0, 0, // id
    0, 0, // flags: standard query
    0, 1, // qdcount
    0, 0, // ancount
    0, 0, // nscount
    0, 0, // arcount
  ]);
  builder.add(_encodeName(serviceType));
  builder.add(<int>[0, 12, 0, 1]); // type PTR, class IN
  return builder.takeBytes();
}

Map<String, String> _parseTxt(List<int> rdata) {
  final Map<String, String> result = <String, String>{};
  int pos = 0;
  while (pos < rdata.length) {
    final int len = rdata[pos];
    if (pos + 1 + len > rdata.length) {
      break;
    }
    final String entry =
        String.fromCharCodes(rdata, pos + 1, pos + 1 + len);
    final int eq = entry.indexOf('=');
    if (eq > 0) {
      result[entry.substring(0, eq)] = entry.substring(eq + 1);
    }
    pos += 1 + len;
  }
  return result;
}

/// Parses one DNS response datagram into PotPilot agent advertisements.
/// PTR owner must match [kMdnsServiceType]; A records for SRV targets
/// resolve the IPv4 (cross-packet cached via [addressCache]).
List<MdnsAgentInfo> parseMdnsResponse(
  List<int> data, {
  Map<String, String>? addressCache,
}) {
  if (data.length < 12) {
    return const <MdnsAgentInfo>[];
  }
  final int questions = _u16(data, 4);
  final int recordCount = _u16(data, 6) + _u16(data, 8) + _u16(data, 10);
  int pos = 12;
  for (int i = 0; i < questions; i++) {
    final (int, String)? name = _decodeName(data, pos);
    if (name == null || name.$1 + 4 > data.length) {
      return const <MdnsAgentInfo>[];
    }
    pos = name.$1 + 4;
  }

  final List<({String owner, int type, List<int> rdata})> records =
      <({String owner, int type, List<int> rdata})>[];
  for (int i = 0; i < recordCount; i++) {
    final (int, String)? name = _decodeName(data, pos);
    if (name == null || name.$1 + 10 > data.length) {
      break; // tolerate truncated tail
    }
    pos = name.$1;
    final int type = _u16(data, pos);
    final int dnsClass = _u16(data, pos + 2);
    final int rdLength = _u16(data, pos + 8);
    pos += 10;
    if (pos + rdLength > data.length) {
      break;
    }
    final List<int> rdata = data.sublist(pos, pos + rdLength);
    pos += rdLength;
    if ((dnsClass & 0x7FFF) == 1) {
      records.add((owner: name.$2, type: type, rdata: rdata));
    }
  }

  final String serviceKey = _norm(kMdnsServiceType);
  // A-record addresses are read through a map so repeated datagrams can
  // resolve each other; callers without a persistent cache still get
  // same-packet resolution via this local fallback.
  final Map<String, String> ipCache = addressCache ?? <String, String>{};
  final Map<String, ({int? port, String? target})> srv =
      <String, ({int? port, String? target})>{};
  final Map<String, Map<String, String>> txts =
      <String, Map<String, String>>{};
  final List<String> instances = <String>[];

  for (final ({String owner, int type, List<int> rdata}) record in records) {
    switch (record.type) {
      case 1: // A
        if (record.rdata.length == 4) {
          final String ip =
              '${record.rdata[0]}.${record.rdata[1]}.${record.rdata[2]}.${record.rdata[3]}';
          ipCache[_norm(record.owner)] = ip;
        }
      case 12: // PTR
        if (_norm(record.owner) == serviceKey) {
          final (int, String)? target = _decodeName(record.rdata, 0);
          if (target != null && target.$2.isNotEmpty) {
            instances.add(target.$2);
          }
        }
      case 16: // TXT
        txts[_norm(record.owner)] = _parseTxt(record.rdata);
      case 33: // SRV
        if (record.rdata.length >= 7) {
          final int port = (record.rdata[4] << 8) | record.rdata[5];
          final (int, String)? target = _decodeName(record.rdata, 6);
          if (target != null) {
            srv[_norm(record.owner)] = (port: port, target: target.$2);
          }
        }
      default:
        break; // unknown records ignored, never errors (§10)
    }
  }

  final List<MdnsAgentInfo> result = <MdnsAgentInfo>[];
  for (final String instance in instances) {
    final ({int? port, String? target})? service = srv[_norm(instance)];
    final Map<String, String> txt = txts[_norm(instance)] ?? const {};
    final String? target = service?.target;
    String? ip;
    if (target != null) {
      ip = ipCache[_norm(target)];
    }
    if (ip == null) {
      continue; // no A record yet → wait for the next datagram
    }
    final String? ver = txt['ver'];
    if (ver != null && ver != '1') {
      debugPrint('mDNS: agent advertises ver=$ver (IP discovery only)');
    }
    final int wsPort =
        service?.port ?? int.tryParse(txt['ws'] ?? '') ?? kWsPort;
    final int udpPort = int.tryParse(txt['udp'] ?? '') ?? kUdpPort;
    result.add(
      MdnsAgentInfo(
        serviceName: instance.split('.').first,
        hostname: target != null
            ? _stripLocal(target)
            : instance.split('.').first,
        ipv4: ip,
        udpPort: udpPort,
        wsPort: wsPort,
      ),
    );
  }
  return result;
}

String _norm(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'\.$'), '');

// ---------------------------------------------------------------------------
// Scanner screen
// ---------------------------------------------------------------------------

/// Full-screen QR onboarding (Doc 32); hands control to the Doc 05 shell's
/// deck tab exactly once when pairing completes.
class PairingScannerScreen extends StatefulWidget {
  const PairingScannerScreen({
    super.key,
    required this.controller,
    this.onPaired,
  });

  final PairingController controller;

  /// Invoked exactly once at [PairingPhase.paired]; defaults to
  /// `AppShell.of(context).setTab(AppTab.deck)` (pushReplacement-equivalent).
  final void Function(BuildContext context)? onPaired;

  @override
  State<PairingScannerScreen> createState() => _PairingScannerScreenState();
}

class _PairingScannerScreenState extends State<PairingScannerScreen> {
  StreamSubscription<PairingState>? _stateSub;
  StreamSubscription<MdnsAgentInfo>? _agentSub;
  final TextEditingController _tokenCtrl = TextEditingController();
  final List<MdnsAgentInfo> _agents = <MdnsAgentInfo>[];
  MdnsAgentInfo? _selectedAgent;
  bool _showManual = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.controller.states.listen(_onStateChanged);
    _agentSub = widget.controller.watchAgents().listen((MdnsAgentInfo info) {
      if (!mounted) {
        return;
      }
      setState(() {
        final int index = _agents.indexWhere(
          (MdnsAgentInfo a) => a.serviceName == info.serviceName,
        );
        if (index >= 0) {
          _agents[index] = info;
        } else {
          _agents.add(info);
        }
        if (_selectedAgent?.serviceName == info.serviceName) {
          _selectedAgent = info;
        }
      });
    });
    // No setState here (initState is mid-build); pairing may already be
    // done when the screen mounts, so only arm the navigation side effect.
    _maybeNavigateToDeck(widget.controller.state);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _agentSub?.cancel();
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _onStateChanged(PairingState state) {
    if (!mounted) {
      return;
    }
    _maybeNavigateToDeck(state);
    setState(() {});
  }

  /// Invokes the deck transition exactly once when phase becomes paired.
  void _maybeNavigateToDeck(PairingState state) {
    if (state.phase != PairingPhase.paired || _navigated) {
      return;
    }
    _navigated = true;
    widget.controller.stopScanning();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (widget.onPaired != null) {
        widget.onPaired!(context);
      } else {
        AppShell.of(context).setTab(AppTab.deck);
      }
    });
  }

  static const Map<PairingFailure, String> _failureMessages =
      <PairingFailure, String>{
        PairingFailure.cameraDenied:
            'Camera permission is needed to scan the pairing QR.',
        PairingFailure.invalidQr: 'That QR code is not a PotPilot pairing code.',
        PairingFailure.unsupportedVersion:
            'This QR code comes from an incompatible agent version.',
        PairingFailure.wrongPorts:
            'That QR code advertises non-standard ports. Fix the agent config.',
        PairingFailure.badToken: 'The pairing token is not 32 hex characters.',
        PairingFailure.noReachableHost:
            'No reachable PotPilot agent found. Is the PC awake on this Wi-Fi?',
        PairingFailure.authRejected: 'The PC rejected the token — re-pair from the PC dashboard.',
        PairingFailure.handshakeTimeout:
            'Could not reach the PC in time. Check the network and retry.',
        PairingFailure.storageError:
            'Could not save the pairing on this device. Retry.',
      };

  @override
  Widget build(BuildContext context) {
    final PairingState state = widget.controller.state;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (state.phase == PairingPhase.scanning)
              Positioned.fill(child: widget.controller.buildPreview(context)),
            Center(child: _buildBody(state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(PairingState state) {
    switch (state.phase) {
      case PairingPhase.idle:
        return _idleOrScanningControls(
          title: 'Pair with PotPlayer',
          hint: 'Scan the QR shown in the PotPilot dashboard on your PC.',
        );
      case PairingPhase.scanning:
        return Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (state.failure != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _failureMessages[state.failure] ?? 'Pairing failed.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.amber),
                ),
              ),
            _idleOrScanningControls(
              title: 'Scanning…',
              hint: 'Point the camera at the QR code on your PC.',
            ),
          ],
        );
      case PairingPhase.validating:
        return _progress('Validating QR…');
      case PairingPhase.handshaking:
        return _progress('Connecting to PC…');
      case PairingPhase.persisting:
        return _progress('Saving pairing…');
      case PairingPhase.paired:
        return const SizedBox.shrink();
      case PairingPhase.failed:
        if (state.failure == PairingFailure.cameraDenied) {
          return _rationale();
        }
        return _failureRetry(state.failure);
    }
  }

  Widget _progress(String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const CircularProgressIndicator(color: AppColors.crimson),
        const SizedBox(height: 16),
        Text(label, style: const TextStyle(color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _idleOrScanningControls({required String title, required String hint}) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => widget.controller.startScanning(),
            child: const Text('Scan QR'),
          ),
          TextButton(
            onPressed: () => setState(() => _showManual = !_showManual),
            child: const Text('Enter token manually'),
          ),
          if (_showManual) _manualPanel(),
        ],
      ),
    );
  }

  /// Permission-denied rationale + the no-camera mDNS/token path (§7).
  Widget _rationale() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.no_photography, color: AppColors.amber, size: 40),
          const SizedBox(height: 12),
          Text(
            _failureMessages[PairingFailure.cameraDenied]!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          const Text(
            'Enable camera access in system settings, or pair without a '
            'camera: discover the PC over the local network and paste the '
            '32-character token shown on the PC dashboard.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => widget.controller.reset(),
            child: const Text('Try again'),
          ),
          const SizedBox(height: 16),
          _manualPanel(),
        ],
      ),
    );
  }

  Widget _failureRetry(PairingFailure? failure) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.error_outline, color: AppColors.crimson, size: 40),
          const SizedBox(height: 12),
          Text(
            _failureMessages[failure] ?? 'Pairing failed.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => widget.controller.reset(),
            child: const Text('Try again'),
          ),
          const SizedBox(height: 16),
          _manualPanel(),
        ],
      ),
    );
  }

  Widget _manualPanel() {
    final bool tokenValid = RegExp(r'^[0-9a-fA-F]{32}$')
        .hasMatch(_tokenCtrl.text.trim());
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Manual pairing',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (_agents.isEmpty)
            const Text(
              'Waiting for PC discovery (mDNS)…',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
            )
          else
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final MdnsAgentInfo agent in _agents)
                  ChoiceChip(
                    label: Text(agent.hostname),
                    selected: _selectedAgent?.serviceName == agent.serviceName,
                    onSelected: (_) =>
                        setState(() => _selectedAgent = agent),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenCtrl,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Paste 32-character token',
              labelStyle: TextStyle(color: AppColors.textTertiary),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: (tokenValid && _selectedAgent != null)
                ? () => widget.controller.pairManual(
                    hostname: _selectedAgent!.hostname,
                    ipv4s: <String>[_selectedAgent!.ipv4],
                    tokenHex: _tokenCtrl.text.trim(),
                  )
                : null,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}
