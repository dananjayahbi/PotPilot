// Doc 30: fire-and-forget UDP datagram sender for the PotPilot input stream.
//
// Byte-level packing, the auth XOR fold, and the seek (high, low) split are
// owned by the Doc 02 codec (`udp_packet_codec.dart`); this file adds a
// conformance-locked reuse fast path (zero per-packet allocations), the
// 120 Hz move-delta coalescer, a monotonic uint16 sequence counter, and a
// consecutive-error circuit breaker. Guaranteed commands ride WebSocket
// (Doc 31) — UDP never retries.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'udp_packet_codec.dart';

/// Fixed UDP destination port for the PC agent input stream (frozen contract).
const int kUdpDefaultPort = udpPort;

/// Hard cap on mouse-move datagrams emitted per second.
const int kMaxMovePacketsPerSecond = 120;

/// Fixed packet size in bytes — mirrors codec `packetSize` (Doc 02).
const int kUdpPacketSize = packetSize;

/// Interval between move flushes: 1000 ms / 120 Hz ~= 8.33 ms.
const Duration kMoveFlushInterval = Duration(microseconds: 8333);

/// Consecutive `SocketException`s tolerated before the circuit breaker trips
/// and the sender becomes `!isReady` (caller may re-`configure()`).
const int kUdpErrorBreakerThreshold = 32;

/// Packet type byte (Byte 0) values — mirror of 02_binary_udp_protocol_spec.md.
/// Values reference the Doc 02 registry directly so they can never drift.
abstract final class UdpPacketType {
  static const int mouseMove = PacketType.mouseMove; // arg1=dx, arg2=dy
  static const int scroll = PacketType.mouseScroll; // arg1=vertical, arg2=horizontal
  static const int button = PacketType.mouseButton; // arg1=buttonId, arg2=state
  static const int scrub = PacketType.scrubSeek; // arg1=secHigh, arg2=secLow
}

/// Mouse button ids carried in arg1 of button packets.
abstract final class MouseButton {
  static const int left = ButtonId.left;
  static const int right = ButtonId.right;
  static const int middle = ButtonId.middle;
}

/// Button actions carried in arg2 of button packets.
abstract final class ButtonAction {
  static const int down = ButtonState.down;
  static const int up = ButtonState.up;
  static const int click = ButtonState.click;
}

const int _i16Min = -32768;
const int _i16Max = 32767;
const int _scrubMax = 0x7FFFFFFF;

final RegExp _tokenHexPattern = RegExp(r'^[0-9a-f]{32}$');

int _clampI16(int value) {
  if (value < _i16Min) {
    return _i16Min;
  }
  if (value > _i16Max) {
    return _i16Max;
  }
  return value;
}

Uint8List _hexToBytes(String lowerHex32) {
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(lowerHex32.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

/// Fire-and-forget UDP sender singleton for PotPilot input datagrams.
class UdpSender {
  UdpSender._();

  static final UdpSender _instance = UdpSender._();

  /// Process-wide singleton.
  static UdpSender get instance => _instance;

  // Reused pack buffer: created once, written and sent from on every call so
  // the hot path performs zero per-packet allocations. `RawDatagramSocket.send`
  // copies synchronously before returning (locked in by the buffer-reuse test),
  // so overwriting the same view on the next pack is safe.
  final ByteData _buf = ByteData(kUdpPacketSize);
  late final Uint8List _view = _buf.buffer.asUint8List(0, kUdpPacketSize);

  RawDatagramSocket? _socket;
  InternetAddress? _addr;
  int _port = kUdpDefaultPort;
  int _authByte = 0;
  int _seq = 0;
  bool _isReady = false;

  int _dropped = 0;
  int _ioErrors = 0;
  int _consecutiveErrors = 0;

  // Move coalescer accumulators.
  int _accDx = 0;
  int _accDy = 0;
  Timer? _flushTimer;

  /// Test seam: when set, packed datagrams are delivered here instead of the
  /// real socket. [bytes] is the reused pack view — copy it if retained.
  @visibleForTesting
  void Function(Uint8List bytes)? sendSink;

  /// Binds the socket to [host]:[port] (defaults 50505) and derives the auth
  /// byte from the 32-hex [tokenHex] pairing token (uppercased input is
  /// canonicalized to lowercase per Docs 03/15/17).
  ///
  /// Throws [ArgumentError] synchronously when [tokenHex] is not 32 hex chars.
  Future<void> configure({
    required String host,
    required String tokenHex,
    int port = kUdpDefaultPort,
  }) async {
    final canonicalToken = tokenHex.toLowerCase();
    if (!_tokenHexPattern.hasMatch(canonicalToken)) {
      throw ArgumentError.value(
        tokenHex,
        'tokenHex',
        'must be exactly 32 hex characters',
      );
    }
    final authByte = xorAuthByte(_hexToBytes(canonicalToken));
    final address = await _resolveHost(host);

    final old = _socket;
    _socket = null;
    _isReady = false;
    old?.close();

    _stopFlushTimer();
    _accDx = 0;
    _accDy = 0;

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _addr = address;
    _port = port;
    _authByte = authByte;
    _seq = 0;
    _consecutiveErrors = 0;
    _socket = socket;
    _isReady = true;
  }

  /// True once configured and socket open; false after [close] or a fatal
  /// socket error (circuit breaker).
  bool get isReady => _isReady;

  /// Current sequence counter (inspection/tests only).
  int get sequence => _seq;

  /// Test seam: injects the sequence counter (e.g. wrap-around tests).
  @visibleForTesting
  set sequence(int value) => _seq = value & 0xFFFF;

  /// Test seam: packets silently dropped while `!isReady`.
  @visibleForTesting
  int get droppedCount => _dropped;

  /// Test seam: total swallowed `SocketException`s.
  @visibleForTesting
  int get ioErrorCount => _ioErrors;

  /// Test seam: the session auth byte derived from the pairing token.
  @visibleForTesting
  int get authByte => _authByte;

  /// Queues relative cursor delta; coalesced and flushed at <=120 Hz.
  void sendMove(int dx, int dy) {
    if (!_isReady) {
      _dropped++;
      return;
    }
    var remX = dx;
    var remY = dy;
    while (remX != 0 || remY != 0) {
      final nextX = _accDx + remX;
      final nextY = _accDy + remY;
      final fits = nextX >= _i16Min && nextX <= _i16Max && nextY >= _i16Min && nextY <= _i16Max;
      if (fits) {
        _accDx = nextX;
        _accDy = nextY;
        break;
      }
      if (_accDx != 0 || _accDy != 0) {
        // Flush first so a flick splits into consecutive in-range packets
        // instead of wrapping/truncating.
        _flushMove();
        continue;
      }
      // Accumulator drained but the remainder still exceeds int16: take a
      // full-width chunk now and loop for the tail.
      final takeX = _clampI16(remX);
      final takeY = _clampI16(remY);
      _accDx = takeX;
      _accDy = takeY;
      remX -= takeX;
      remY -= takeY;
    }
    _ensureFlushTimer();
  }

  /// Flushes pending move first, then sends one scroll datagram immediately.
  void sendScroll(int verticalDelta, int horizontalDelta) {
    flush();
    _sendPacket(
      UdpPacketType.scroll,
      _clampI16(verticalDelta),
      _clampI16(horizontalDelta),
    );
  }

  /// Flushes pending move first, then sends one button datagram
  /// ([ButtonAction.down]/[ButtonAction.up]/[ButtonAction.click]).
  void sendButton(int buttonId, int action) {
    flush();
    _sendPacket(UdpPacketType.button, buttonId, action);
  }

  /// Flushes pending move first, then seeks to an absolute target in seconds.
  /// Out-of-range targets are clamped: negatives -> 0, >= 2^31 -> 0x7FFFFFFF.
  void sendScrub(int targetSeconds) {
    flush();
    final clamped = targetSeconds < 0
        ? 0
        : (targetSeconds > _scrubMax ? _scrubMax : targetSeconds);
    final parts = splitSeekSeconds(clamped);
    _sendPacket(UdpPacketType.scrub, parts.high, parts.low);
  }

  /// Forces an immediate flush of accumulated move deltas (no-op when idle).
  void flush() => _flushMove();

  /// Cancels timers and closes the socket; sender becomes `!isReady`.
  Future<void> close() async {
    _stopFlushTimer();
    _accDx = 0;
    _accDy = 0;
    _isReady = false;
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  Future<InternetAddress> _resolveHost(String host) async {
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      return parsed;
    }
    final lookups = await InternetAddress.lookup(host);
    for (final address in lookups) {
      if (address.type == InternetAddressType.IPv4) {
        return address;
      }
    }
    if (lookups.isNotEmpty) {
      return lookups.first;
    }
    throw ArgumentError.value(host, 'host', 'could not resolve to an address');
  }

  // Fast path — equivalence with the codec `packPacket()` is asserted by
  // test (every golden vector + random in-range fields), not promised by
  // convention. Host byte order must NOT be used — the wire is always
  // little-endian.
  Uint8List _pack(int type, int arg1, int arg2) {
    _buf.setUint8(0, type);
    _buf.setUint8(1, _authByte);
    _buf.setInt16(2, arg1, Endian.little);
    _buf.setInt16(4, arg2, Endian.little);
    _buf.setUint16(6, _seq, Endian.little);
    return _view; // same backing bytes every call; send() copies before return
  }

  /// Packs into the reused view, sends, and advances the sequence counter on
  /// success. Swallows `SocketException`s (UDP is lossy by design), counts
  /// them, and trips the circuit breaker after
  /// [kUdpErrorBreakerThreshold] consecutive failures.
  bool _sendPacket(int packetType, int arg1, int arg2) {
    if (!_isReady) {
      _dropped++;
      return false;
    }
    final bytes = _pack(packetType, arg1, arg2);
    try {
      final sink = sendSink;
      if (sink != null) {
        sink(bytes);
      } else {
        _socket!.send(bytes, _addr!, _port);
      }
      _seq = (_seq + 1) & 0xFFFF;
      _consecutiveErrors = 0;
      return true;
    } on SocketException {
      _ioErrors++;
      _consecutiveErrors++;
      if (_consecutiveErrors >= kUdpErrorBreakerThreshold) {
        _tripBreaker();
      }
      return false;
    }
  }

  void _tripBreaker() {
    _isReady = false;
    _stopFlushTimer();
    _accDx = 0;
    _accDy = 0;
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  void _flushMove() {
    if (_accDx == 0 && _accDy == 0) {
      _stopFlushTimer();
      return;
    }
    final dx = _accDx;
    final dy = _accDy;
    _accDx = 0;
    _accDy = 0;
    _sendPacket(UdpPacketType.mouseMove, dx, dy);
    if (_accDx == 0 && _accDy == 0) {
      _stopFlushTimer();
    }
  }

  void _ensureFlushTimer() {
    if (!_isReady || _flushTimer != null) {
      return;
    }
    _flushTimer = Timer.periodic(kMoveFlushInterval, (_) => _flushMove());
  }

  void _stopFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
