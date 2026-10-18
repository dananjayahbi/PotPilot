import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reserved `pp.*` key namespace (Doc 34). No other module may read or write
/// these keys directly; all access funnels through [ConnectionCache].
abstract final class CacheKeys {
  /// JSON array of [PcHostRecord] objects (schema v1).
  static const String hostsV1 = 'pp.hosts.v1';

  /// Id of the active [PcHostRecord] or `''` when none.
  static const String activeHostId = 'pp.active_host_id';

  /// JSON object of [TrackpadProfile] fields (schema v1).
  static const String trackpadProfileV1 = 'pp.trackpad.profile.v1';

  /// One of [kStartupTabIds].
  static const String startupTab = 'pp.startup_tab';

  /// Screen brightness 0.05–1.0 applied to the controller app window
  /// (round-6 display setting; double as string).
  static const String brightness = 'pp.display.brightness';

  /// Every key owned by this doc; used by [ConnectionCache.clearAll].
  static const List<String> all = <String>[
    hostsV1,
    activeHostId,
    trackpadProfileV1,
    startupTab,
    brightness,
  ];
}

/// Startup tab ids owned by the Doc 05 navigation shell.
const List<String> kStartupTabIds = <String>['deck', 'trackpad', 'library'];

/// Defensive cap: only the most-recently-connected hosts are retained.
const int kMaxHosts = 5;

/// Per-host IPv4 cap (DHCP churn guard); newest-first order preserved.
const int kMaxIpsPerHost = 4;

/// Frozen contract ports (Docs 03/15/17) — not user-tunable.
const int kUdpPort = 50505;
const int kWsPort = 50506;

final RegExp _tokenHexPattern = RegExp(r'^[0-9a-fA-F]{32}$');

/// Persisted record of one paired PC (JSON round-trippable, schema v1).
///
/// Identity is [hostname]-derived: `id = sha1(lowercase hostname)[0..16]`.
/// The constructor intentionally performs **no** validation — frozen-contract
/// checks (`ArgumentError`) happen at the [ConnectionCache] API boundary.
@immutable
class PcHostRecord {
  PcHostRecord({
    required this.hostname,
    required List<String> ipv4s,
    this.udpPort = kUdpPort,
    this.wsPort = kWsPort,
    required this.tokenHex,
    required this.lastConnectedAt,
  }) : ipv4s = List<String>.unmodifiable(ipv4s),
       id = idForHostname(hostname);

  const PcHostRecord._internal({
    required this.id,
    required this.hostname,
    required this.ipv4s,
    required this.udpPort,
    required this.wsPort,
    required this.tokenHex,
    required this.lastConnectedAt,
  });

  /// Stable record identity: first 16 hex chars of SHA-1 over the
  /// lowercased hostname (Doc 34 §10).
  static String idForHostname(String hostname) =>
      _sha1Hex(utf8.encode(hostname.trim().toLowerCase())).substring(0, 16);

  /// Stable identity (sha1 of lowercase [hostname], short hash).
  final String id;

  /// PC NetBIOS name.
  final String hostname;

  /// Known LAN IPv4s (QR + mDNS updates), most-recent first.
  final List<String> ipv4s;

  /// Frozen 50505.
  final int udpPort;

  /// Frozen 50506.
  final int wsPort;

  /// 128-bit pairing token, 32 hex chars; canonical lowercase.
  final String tokenHex;

  /// When this record last completed a pairing/connection (ISO-8601 on disk).
  final DateTime lastConnectedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'hostname': hostname,
        'ipv4s': ipv4s,
        'udpPort': udpPort,
        'wsPort': wsPort,
        'tokenHex': tokenHex,
        'lastConnectedAt': lastConnectedAt.toIso8601String(),
      };

  /// Rebuilds a record from persisted JSON; throws on any type violation
  /// (callers wrap per-entry in `try` so one corrupt row cannot sink the rest).
  static PcHostRecord fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? hostname = json['hostname'];
    final Object? ips = json['ipv4s'];
    final Object? udp = json['udpPort'];
    final Object? ws = json['wsPort'];
    final Object? token = json['tokenHex'];
    final Object? last = json['lastConnectedAt'];
    if (hostname is! String || hostname.isEmpty) {
      throw const FormatException('hostname must be a non-empty string');
    }
    if (ips is! List || ips.any((Object? ip) => ip is! String)) {
      throw const FormatException('ipv4s must be a list of strings');
    }
    if (udp is! int || ws is! int) {
      throw const FormatException('ports must be integers');
    }
    if (token is! String) {
      throw const FormatException('tokenHex must be a string');
    }
    if (last is! String) {
      throw const FormatException('lastConnectedAt must be an ISO-8601 string');
    }
    return PcHostRecord._internal(
      id: id is String && id.isNotEmpty ? id : idForHostname(hostname),
      hostname: hostname,
      ipv4s: List<String>.of(ips.cast<String>()),
      udpPort: udp,
      wsPort: ws,
      tokenHex: token,
      lastConnectedAt: DateTime.parse(last),
    );
  }

  /// Copy with optional overrides; a changed [hostname] recomputes [id].
  PcHostRecord copyWith({
    String? hostname,
    List<String>? ipv4s,
    int? udpPort,
    int? wsPort,
    String? tokenHex,
    DateTime? lastConnectedAt,
  }) {
    return PcHostRecord(
      hostname: hostname ?? this.hostname,
      ipv4s: ipv4s ?? this.ipv4s,
      udpPort: udpPort ?? this.udpPort,
      wsPort: wsPort ?? this.wsPort,
      tokenHex: tokenHex ?? this.tokenHex,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PcHostRecord &&
      other.id == id &&
      other.hostname == hostname &&
      other.udpPort == udpPort &&
      other.wsPort == wsPort &&
      other.tokenHex == tokenHex &&
      other.lastConnectedAt.isAtSameMomentAs(lastConnectedAt) &&
      listEquals(other.ipv4s, ipv4s);

  @override
  int get hashCode => Object.hash(
        id,
        hostname,
        udpPort,
        wsPort,
        tokenHex,
        lastConnectedAt.microsecondsSinceEpoch,
      );
}

/// Trackpad feel parameters consumed by Doc 35's velocity/scroll math.
@immutable
class TrackpadProfile {
  const TrackpadProfile({
    this.sensitivity = 1.0,
    this.accelerationGain = 2.0,
    this.accelerationThreshold = 0.8,
    this.scrollMultiplier = 1.0,
  });

  /// Linear gain on cursor deltas — range [0.2, 3.0].
  final double sensitivity;

  /// Extra gain at high velocity — range [1.0, 4.0].
  final double accelerationGain;

  /// px/ms where acceleration kicks in — finite, ≥ 0.
  final double accelerationThreshold;

  /// Gain on two-finger scroll — range [0.2, 3.0].
  final double scrollMultiplier;

  /// Doc 34 §5 golden defaults.
  static const TrackpadProfile defaults = TrackpadProfile();

  /// Doc 34 §3 field ranges (lo, hi); threshold uses [0, infinity).
  static const Map<String, (double, double)> ranges =
      <String, (double, double)>{
        'sensitivity': (0.2, 3.0),
        'accelerationGain': (1.0, 4.0),
        'accelerationThreshold': (0.0, double.infinity),
        'scrollMultiplier': (0.2, 3.0),
      };

  /// Throws [ArgumentError] when any field is outside its §3 range.
  void _validate() {
    final Map<String, double> values = <String, double>{
      'sensitivity': sensitivity,
      'accelerationGain': accelerationGain,
      'accelerationThreshold': accelerationThreshold,
      'scrollMultiplier': scrollMultiplier,
    };
    for (final MapEntry<String, double> entry in values.entries) {
      final (double lo, double hi) = ranges[entry.key]!;
      final double v = entry.value;
      if (v.isNaN || v.isInfinite || v < lo || v > hi) {
        throw ArgumentError.value(
          v,
          entry.key,
          'outside TrackpadProfile range [$lo, $hi]',
        );
      }
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sensitivity': sensitivity,
        'accelerationGain': accelerationGain,
        'accelerationThreshold': accelerationThreshold,
        'scrollMultiplier': scrollMultiplier,
      };

  /// Field-level fallback: missing/garbage field ⇒ default for that field
  /// only; out-of-range numbers are clamped into their §3 range.
  static TrackpadProfile fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) {
      final Object? value = json[key];
      if (value is! num || value.isNaN || value.isInfinite) {
        return fallback;
      }
      final (double lo, double hi) = ranges[key]!;
      return value.toDouble().clamp(lo, hi).toDouble();
    }

    return TrackpadProfile(
      sensitivity: read('sensitivity', defaults.sensitivity),
      accelerationGain: read('accelerationGain', defaults.accelerationGain),
      accelerationThreshold:
          read('accelerationThreshold', defaults.accelerationThreshold),
      scrollMultiplier: read('scrollMultiplier', defaults.scrollMultiplier),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackpadProfile &&
      other.sensitivity == sensitivity &&
      other.accelerationGain == accelerationGain &&
      other.accelerationThreshold == accelerationThreshold &&
      other.scrollMultiplier == scrollMultiplier;

  @override
  int get hashCode => Object.hash(
        sensitivity,
        accelerationGain,
        accelerationThreshold,
        scrollMultiplier,
      );
}

/// Write-through async cache with synchronous in-memory reads (singleton).
///
/// `init()` loads every `pp.*` key once; each `save*` mutates memory first,
/// then persists. Persistence failures surface as errors on the returned
/// `Future` while memory stays consistent (the next successful write heals).
class ConnectionCache {
  ConnectionCache._();

  static final ConnectionCache instance = ConnectionCache._();

  /// Test/DI constructor so tests can build isolated instances.
  @visibleForTesting
  ConnectionCache.forTest();

  /// Schema-version migrations: version → run sequentially at init when
  /// higher versions appear. Only v1 exists today (Doc 34 §4).
  static final Map<int, Future<void> Function(SharedPreferences)>
  _migrations = <int, Future<void> Function(SharedPreferences)>{};

  SharedPreferences? _prefs;
  bool _ready = false;
  List<PcHostRecord> _hosts = <PcHostRecord>[];
  String _activeHostId = '';
  TrackpadProfile _trackpadProfile = TrackpadProfile.defaults;
  String _startupTab = 'deck';
  double _brightness = 1.0;

  bool get isReady => _ready;

  void _ensureReady() {
    if (!_ready) {
      throw StateError('ConnectionCache.init() not completed');
    }
  }

  /// Loads persisted state into memory; MUST be awaited once at app start
  /// (main()). Re-running reloads from the same backing store.
  Future<void> init({SharedPreferences? injected}) async {
    _ready = false;
    final SharedPreferences prefs =
        injected ?? await SharedPreferences.getInstance();
    _prefs = prefs;

    // Sequential schema migrations for versions above v1 (none yet).
    final List<int> versions = _migrations.keys.toList()..sort();
    for (final int version in versions) {
      if (version > 1) {
        await _migrations[version]!(prefs);
      }
    }

    _hosts = _loadHosts(prefs);
    _activeHostId = prefs.getString(CacheKeys.activeHostId) ?? '';
    if (_activeHostId.isNotEmpty &&
        !_hosts.any((PcHostRecord h) => h.id == _activeHostId)) {
      // Dangling id ⇒ clear (self-heal on next write).
      _activeHostId = '';
    }
    _trackpadProfile = _loadProfile(prefs);
    _startupTab = _loadStartupTab(prefs);
    _brightness = _loadBrightness(prefs);
    _ready = true;
  }

  List<PcHostRecord> _loadHosts(SharedPreferences prefs) {
    final String? raw = prefs.getString(CacheKeys.hostsV1);
    if (raw == null) {
      return <PcHostRecord>[];
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Corrupt container: skip the whole set; next saveHost self-heals.
      return <PcHostRecord>[];
    }
    if (decoded is! List) {
      return <PcHostRecord>[];
    }
    final List<PcHostRecord> loaded = <PcHostRecord>[];
    int skipped = 0;
    for (final Object? entry in decoded) {
      if (entry is! Map<String, dynamic>) {
        skipped++;
        continue;
      }
      try {
        loaded.add(PcHostRecord.fromJson(entry));
      } on Object {
        skipped++;
      }
    }
    if (skipped > 0) {
      debugPrint('ConnectionCache: skipped $skipped corrupt host record(s)');
    }
    return _sortedDesc(loaded);
  }

  TrackpadProfile _loadProfile(SharedPreferences prefs) {
    final String? raw = prefs.getString(CacheKeys.trackpadProfileV1);
    if (raw == null) {
      return TrackpadProfile.defaults;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return TrackpadProfile.defaults;
      }
      return TrackpadProfile.fromJson(decoded);
    } on FormatException {
      return TrackpadProfile.defaults;
    }
  }

  String _loadStartupTab(SharedPreferences prefs) {
    final String raw = prefs.getString(CacheKeys.startupTab) ?? 'deck';
    return kStartupTabIds.contains(raw) ? raw : 'deck';
  }

  /// Corrupt / out-of-range values fall back to the current system default
  /// (1.0 — the settings screen clamps to `kBrightnessMin`..1.0 anyway).
  double _loadBrightness(SharedPreferences prefs) {
    final String? raw = prefs.getString(CacheKeys.brightness);
    if (raw == null) {
      return 1.0;
    }
    final double? parsed = double.tryParse(raw);
    if (parsed == null || parsed.isNaN || parsed < 0.05 || parsed > 1.0) {
      return 1.0;
    }
    return parsed;
  }

  static List<PcHostRecord> _sortedDesc(List<PcHostRecord> hosts) {
    final List<PcHostRecord> sorted = List<PcHostRecord>.of(hosts);
    sorted.sort((PcHostRecord a, PcHostRecord b) =>
        b.lastConnectedAt.compareTo(a.lastConnectedAt));
    return sorted;
  }

  // -- hosts -----------------------------------------------------------------

  /// Sorted by [PcHostRecord.lastConnectedAt] desc, ≤ [kMaxHosts].
  List<PcHostRecord> get hosts {
    _ensureReady();
    return List<PcHostRecord>.unmodifiable(_hosts);
  }

  PcHostRecord? get activeHost {
    _ensureReady();
    for (final PcHostRecord host in _hosts) {
      if (host.id == _activeHostId) {
        return host;
      }
    }
    return null;
  }

  /// Upsert by id (hostname-derived): token rotation replaces the old record
  /// atomically. Enforces [kMaxHosts] LRU cap and trims [PcHostRecord.ipv4s]
  /// to [kMaxIpsPerHost].
  Future<void> saveHost(PcHostRecord host) {
    _ensureReady();
    _validateHost(host);
    // Canonical lowercase token per Docs 03/15/17.
    final PcHostRecord trimmed = host.copyWith(
      tokenHex: host.tokenHex.toLowerCase(),
      ipv4s: host.ipv4s.take(kMaxIpsPerHost).toList(growable: false),
    );
    final List<PcHostRecord> next = List<PcHostRecord>.of(_hosts)
      ..removeWhere((PcHostRecord h) => h.id == trimmed.id)
      ..add(trimmed);
    var sorted = _sortedDesc(next);
    if (sorted.length > kMaxHosts) {
      final List<PcHostRecord> evicted = sorted.sublist(kMaxHosts);
      sorted = sorted.sublist(0, kMaxHosts);
      if (evicted.any((PcHostRecord h) => h.id == _activeHostId)) {
        // Active record evicted ⇒ fall back to the newest (Doc 34 §7).
        _activeHostId = sorted.isNotEmpty ? sorted.first.id : '';
      }
    }
    _hosts = sorted;
    return _persistHosts();
  }

  /// Replaces a record's IPv4 list (mDNS/DHCP updates); trims to
  /// [kMaxIpsPerHost], newest first. Unknown id ⇒ no-op.
  Future<void> updateHostIps(String id, List<String> ipv4s) {
    _ensureReady();
    final int index = _hosts.indexWhere((PcHostRecord h) => h.id == id);
    if (index < 0) {
      return Future<void>.value();
    }
    final List<PcHostRecord> next = List<PcHostRecord>.of(_hosts);
    next[index] = next[index].copyWith(
      ipv4s: ipv4s.take(kMaxIpsPerHost).toList(growable: false),
    );
    _hosts = next;
    return _persistHosts();
  }

  Future<void> setActiveHost(String id) {
    _ensureReady();
    if (!_hosts.any((PcHostRecord h) => h.id == id)) {
      throw ArgumentError.value(id, 'id', 'no such paired host');
    }
    _activeHostId = id;
    return _prefs!
        .setString(CacheKeys.activeHostId, id)
        .then<void>((bool ok) => _requirePersisted(ok, CacheKeys.activeHostId));
  }

  /// Removes a host; clears the active pointer if it pointed here.
  Future<void> removeHost(String id) {
    _ensureReady();
    if (!_hosts.any((PcHostRecord h) => h.id == id)) {
      return Future<void>.value();
    }
    _hosts = _hosts.where((PcHostRecord h) => h.id != id).toList();
    if (_activeHostId == id) {
      _activeHostId = '';
      _prefs!.setString(CacheKeys.activeHostId, '');
    }
    return _persistHosts();
  }

  Future<void> _persistHosts() {
    return _prefs!
        .setString(
          CacheKeys.hostsV1,
          jsonEncode(_hosts.map((PcHostRecord h) => h.toJson()).toList()),
        )
        .then<void>((bool ok) => _requirePersisted(ok, CacheKeys.hostsV1));
  }

  static void _requirePersisted(bool ok, String key) {
    if (!ok) {
      throw StateError('failed to persist $key');
    }
  }

  static void _validateHost(PcHostRecord host) {
    if (host.udpPort != kUdpPort) {
      throw ArgumentError.value(
        host.udpPort,
        'udpPort',
        'frozen contract port must be $kUdpPort',
      );
    }
    if (host.wsPort != kWsPort) {
      throw ArgumentError.value(
        host.wsPort,
        'wsPort',
        'frozen contract port must be $kWsPort',
      );
    }
    if (!_tokenHexPattern.hasMatch(host.tokenHex)) {
      throw ArgumentError.value(
        host.tokenHex,
        'tokenHex',
        'must be exactly 32 hex characters',
      );
    }
    if (host.hostname.trim().isEmpty) {
      throw ArgumentError.value(host.hostname, 'hostname', 'must not be empty');
    }
  }

  // -- trackpad --------------------------------------------------------------

  /// Defaults until persisted.
  TrackpadProfile get trackpadProfile {
    _ensureReady();
    return _trackpadProfile;
  }

  /// Validates every field against its §3 range (throws [ArgumentError]).
  Future<void> saveTrackpadProfile(TrackpadProfile profile) {
    _ensureReady();
    profile._validate();
    _trackpadProfile = profile;
    return _prefs!
        .setString(
          CacheKeys.trackpadProfileV1,
          jsonEncode(profile.toJson()),
        )
        .then<void>(
          (bool ok) => _requirePersisted(ok, CacheKeys.trackpadProfileV1),
        );
  }

  // -- shell -----------------------------------------------------------------

  /// One of [kStartupTabIds]; persisted garbage falls back to `'deck'`.
  String get startupTab {
    _ensureReady();
    return kStartupTabIds.contains(_startupTab) ? _startupTab : 'deck';
  }

  Future<void> saveStartupTab(String tabId) {
    _ensureReady();
    if (!kStartupTabIds.contains(tabId)) {
      throw ArgumentError.value(tabId, 'tabId', 'unknown startup tab id');
    }
    _startupTab = tabId;
    return _prefs!
        .setString(CacheKeys.startupTab, tabId)
        .then<void>((bool ok) => _requirePersisted(ok, CacheKeys.startupTab));
  }

  // -- display ---------------------------------------------------------------

  /// Controller-screen brightness in 0.05–1.0 (round-6 DISPLAY setting);
  /// 1.0 until the user changes it.
  double get brightness {
    _ensureReady();
    return _brightness;
  }

  Future<void> saveBrightness(double value) {
    _ensureReady();
    if (value.isNaN || value < 0.05 || value > 1.0) {
      throw ArgumentError.value(
        value,
        'value',
        'brightness must be within 0.05..1.0',
      );
    }
    _brightness = value;
    return _prefs!
        .setString(CacheKeys.brightness, value.toStringAsFixed(3))
        .then<void>((bool ok) => _requirePersisted(ok, CacheKeys.brightness));
  }

  /// Wipes the `pp.*` namespace (un-pair everything); unrelated app prefs
  /// are never touched.
  Future<void> clearAll() {
    _ensureReady();
    final SharedPreferences prefs = _prefs!;
    _hosts = <PcHostRecord>[];
    _activeHostId = '';
    _trackpadProfile = TrackpadProfile.defaults;
    _startupTab = 'deck';
    _brightness = 1.0;
    final Iterable<String> ppKeys =
        prefs.getKeys().where((String k) => k.startsWith('pp.'));
    return Future.wait(<Future<Object?>>[
      for (final String key in ppKeys) prefs.remove(key),
    ]).then<void>((_) {});
  }
}

// ---------------------------------------------------------------------------
// Hand-rolled SHA-1 (Doc 34: `id = sha1(hostname) short-hash`; the pubspec is
// frozen to six runtime deps, so `crypto` cannot be added).
// ---------------------------------------------------------------------------

int _rotl32(int x, int n) => ((x << n) | (x >> (32 - n))).toUnsigned(32);

String _sha1Hex(List<int> message) {
  final List<int> data = List<int>.of(message);
  final int bitLength = data.length * 8;
  data.add(0x80);
  while (data.length % 64 != 56) {
    data.add(0);
  }
  // 64-bit big-endian bit length; inputs here are tiny (< 2^32 bits).
  data.addAll(<int>[
    0,
    0,
    0,
    0,
    (bitLength >> 24) & 0xff,
    (bitLength >> 16) & 0xff,
    (bitLength >> 8) & 0xff,
    bitLength & 0xff,
  ]);

  int h0 = 0x67452301;
  int h1 = 0xefcdab89;
  int h2 = 0x98badcfe;
  int h3 = 0x10325476;
  int h4 = 0xc3d2e1f0;

  for (int offset = 0; offset < data.length; offset += 64) {
    final List<int> w = List<int>.filled(80, 0);
    for (int i = 0; i < 16; i++) {
      w[i] = ((data[offset + i * 4] << 24) |
              (data[offset + i * 4 + 1] << 16) |
              (data[offset + i * 4 + 2] << 8) |
              data[offset + i * 4 + 3])
          .toUnsigned(32);
    }
    for (int i = 16; i < 80; i++) {
      w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    int a = h0;
    int b = h1;
    int c = h2;
    int d = h3;
    int e = h4;

    for (int i = 0; i < 80; i++) {
      int f;
      final int k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      final int temp = (f.toUnsigned(32) +
              _rotl32(a, 5) +
              e +
              k +
              w[i])
          .toUnsigned(32);
      e = d;
      d = c;
      c = _rotl32(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a).toUnsigned(32);
    h1 = (h1 + b).toUnsigned(32);
    h2 = (h2 + c).toUnsigned(32);
    h3 = (h3 + d).toUnsigned(32);
    h4 = (h4 + e).toUnsigned(32);
  }

  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return hex(h0) + hex(h1) + hex(h2) + hex(h3) + hex(h4);
}
