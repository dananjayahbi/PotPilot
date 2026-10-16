// Doc 45: Netflix-style in-app movie library browser — the Movie Library tab.
//
// On first open the browser pages through Doc 03 §5.5 `CMD_MEDIA/LIST_MEDIA`
// (`limit: 200`, `offset: 0,200,…` until `offset >= total`) into an
// in-memory cache; search/sort are therefore instant, purely client-side
// operations with zero PC round-trips (§4.2). Refresh sends a real
// `RESCAN_MEDIA` round-trip, shows the queued ack and re-queries ~2 s later.
// A single tap fires `LAUNCH_MEDIA {path}` and the card flips to "Now
// Playing" only when Doc 33 telemetry `file_title` confirms the launch
// (never optimistic guesswork, §4.3).
//
// Transport: Doc 31's `WsClient` behind the injectable [LibrarySocket] seam
// (pattern: Doc 33's `TelemetrySocket`). Data: Doc 20's frozen wire record
// (`name`/`path`/`size_bytes`/`modified_at`/`has_subs`). Visuals: Doc 29
// OLED tokens only. Sort chip persistence uses the `library_sort`
// `shared_preferences` key owned by this doc (§6/§10).
//
// Correlation guard (§4.1): every request carries a locally-built envelope
// `id`; replies for superseded requests are dropped latest-wins. Doc 31's
// `send()` restamps the wire uuid internally, so the production transport
// reports `null` (unknown wire id) and the guard falls back to the reply's
// echoed `offset` + single-flight-per-action awaiting — the id-exact path
// runs whenever the transport preserves ids (test doubles).

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';

/// Page size of the `LIST_MEDIA` walk (§4.2; Doc 03 limit max = 200).
const int kLibraryPageSize = 200;

/// Debounce before a typed query hits the in-memory cache (§4.2.2).
const Duration kLibrarySearchDebounce = Duration(milliseconds: 200);

/// Settle delay between the `RESCAN_MEDIA` ack and the re-query (§4.2.4).
const Duration kLibraryRescanRequeryDelay = Duration(seconds: 2);

/// Reply timeout for index fetches — a miss is treated as PC-offline.
const Duration kLibraryFetchTimeout = Duration(seconds: 5);

/// Reply timeout for `RESCAN_MEDIA` / `LAUNCH_MEDIA` acks (§7).
const Duration kLibraryAckTimeout = Duration(seconds: 2);

/// Telemetry confirmation window after a launch ack (§4.3.3).
const Duration kLibraryConfirmTimeout = Duration(seconds: 2);

/// Double-tap coalescing window for the same path (§7).
const int kLibraryLaunchCoalesceMs = 1000;

/// Above this many entries the browser flips to server-side query mode
/// so phone memory and WS payloads stay bounded (§4.2.3).
const int kLibraryServerQueryThreshold = 5000;

/// `shared_preferences` key persisting the last selected sort chip (§6/§10).
const String kLibrarySortPrefsKey = 'library_sort';

/// Sort modes for the browser (client-side reorder only; no wire `sort`).
enum LibrarySort {
  /// Alphabetical, case-insensitive (chip: "Title A–Z").
  titleAsc,

  /// Largest file first (chip: "Biggest").
  sizeDesc,

  /// Most recently modified first (chip: "Newest").
  recentDesc,
}

/// Human label per sort chip (§4.4).
String librarySortLabel(LibrarySort sort) {
  switch (sort) {
    case LibrarySort.titleAsc:
      return 'Title A–Z';
    case LibrarySort.sizeDesc:
      return 'Biggest';
    case LibrarySort.recentDesc:
      return 'Newest';
  }
}

/// One indexed movie row (mirrors Doc 20's scanner record; the wire `name`
/// is the filename stem, matching Doc 33's `file_title` for confirmations).
class MovieEntry {
  const MovieEntry({
    required this.path,
    required this.title,
    required this.sizeBytes,
    required this.modified,
    required this.hasSrt,
  });

  /// Parses Doc 20's frozen `MediaEntryJSON` record (§5).
  factory MovieEntry.fromJson(Map<String, dynamic> json) {
    return MovieEntry(
      path: json['path'] as String,
      title: json['name'] as String,
      sizeBytes: (json['size_bytes'] as num).toInt(),
      modified: DateTime.fromMillisecondsSinceEpoch(
        (json['modified_at'] as num).toInt() * 1000,
      ),
      hasSrt: json['has_subs'] as bool,
    );
  }

  /// Absolute PC path, e.g. `D:\Movies\Inception (2010).mkv`.
  final String path;

  /// Filename minus extension (Doc 20's stem).
  final String title;

  /// File size from Doc 20's index.
  final int sizeBytes;

  /// Last-modified from Doc 20's index.
  final DateTime modified;

  /// Companion `.srt` presence flag from Doc 20.
  final bool hasSrt;

  @override
  bool operator ==(Object other) =>
      other is MovieEntry &&
      other.path == path &&
      other.title == title &&
      other.sizeBytes == sizeBytes &&
      other.modified == modified &&
      other.hasSrt == hasSrt;

  @override
  int get hashCode => Object.hash(path, title, sizeBytes, modified, hasSrt);

  @override
  String toString() =>
      'MovieEntry($title, $sizeBytes, ${hasSrt ? 'srt' : 'no-subs'})';
}

/// One page of results for a LIST_MEDIA request.
class LibraryPage {
  const LibraryPage({
    required this.items,
    required this.total,
    required this.offset,
  });

  /// Parses the `LIST_MEDIA_RESULT` payload (§5; `folders`/`limit` are
  /// consumed separately by [LibraryNotifier]).
  factory LibraryPage.fromJson(Map<String, dynamic> json) {
    final List<dynamic> raw =
        json['items'] as List<dynamic>? ?? const <dynamic>[];
    return LibraryPage(
      items: raw
          .map((dynamic entry) =>
              MovieEntry.fromJson(entry as Map<String, dynamic>))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }

  /// Entries of this page.
  final List<MovieEntry> items;

  /// Total matches before paging.
  final int total;

  /// Echoed request offset.
  final int offset;
}

/// Minimal transport seam over Doc 31's `WsClient` so this feature (and its
/// tests) depend on send + two streams only — mirrors Doc 33's socket seam.
abstract class LibrarySocket {
  /// Current Doc 31 connection state (offline checks before sending).
  WsConnectionState get state;

  /// Broadcast stream of connection-state transitions (reconnect hook §7).
  Stream<WsConnectionState> get stateChanges;

  /// Broadcast stream of every decoded inbound envelope.
  Stream<WsMessage> get envelopes;

  /// Sends one envelope; returns it if the transport put it on the wire
  /// with the *same* `id`, or `null` when the transport restamps ids.
  ///
  /// Doc 31's `WsClient.send()` builds its own uuid per frame, so the
  /// production adapter reports `null` (see class doc). Test doubles that
  /// serialize the given envelope verbatim return it, enabling id-exact
  /// correlation (§4.1).
  Future<WsMessage?> send(WsMessage message);
}

/// Production seam over the Doc 31 singleton.
class WsClientLibrarySocket implements LibrarySocket {
  const WsClientLibrarySocket(this.client);

  /// The Doc 31 singleton (or any client instance).
  final WsClient client;

  @override
  WsConnectionState get state => client.state;

  @override
  Stream<WsConnectionState> get stateChanges => client.stateChanges;

  @override
  Stream<WsMessage> get envelopes => client.envelopes;

  @override
  Future<WsMessage?> send(WsMessage message) async {
    await client.send(message.type, message.action, message.payload);
    return null; // Doc 31 stamps its own uuid — wire id not observable.
  }
}

/// App-scoped transport; tests override this provider with a fake.
final Provider<LibrarySocket> librarySocketProvider =
    Provider<LibrarySocket>((Ref ref) {
  return WsClientLibrarySocket(WsClient.instance);
});

/// True when live telemetry says [title] is currently playing: the WS
/// session is alive, `file_title` matches the entry's stem, and
/// `potplayer_found` (Doc 33 extras) is not an explicit `false`.
bool libraryNowPlaying(TelemetryState state, String title) {
  if (!state.isConnected || state.fileTitle != title) {
    return false;
  }
  return state.extras['potplayer_found'] != false;
}

/// Fetch is unreachable: WS not connected, or no reply before timeout.
class _LibraryOffline implements Exception {
  const _LibraryOffline();

  @override
  String toString() => 'LibraryOffline';
}

/// Request was superseded by a newer one for the same action (§4.1).
class _LibrarySuperseded implements Exception {
  const _LibrarySuperseded();

  @override
  String toString() => 'LibrarySuperseded';
}

/// The PC answered with an `<ACTION>_ERROR` envelope (Doc 03 §5.8).
class _LibraryReplyError implements Exception {
  const _LibraryReplyError(this.code, this.message);

  /// Doc 03 §5.8 error code (4005 = media/folder not found).
  final int code;

  /// PC-provided message, if any.
  final String message;

  @override
  String toString() => 'LibraryReplyError($code): $message';
}

/// One in-flight request awaiting its reply (correlation guard §4.1).
class _PendingRequest {
  _PendingRequest({required this.matchOffset, required this.completer});

  /// Expected `offset` echoed by `LIST_MEDIA_RESULT` (page correlation;
  /// `null` for actions without an offset echo).
  final int? matchOffset;

  /// Request id as seen on the wire — `null` while unknown (Doc 31
  /// restamping) or before `send()` completes.
  String? expectedId;

  /// Completes with the reply envelope, or errors superseded/offline.
  final Completer<WsMessage> completer;
}

/// Everything one paged fetch produced — applied atomically (§7).
class _FetchOutcome {
  const _FetchOutcome({
    required this.seq,
    required this.items,
    required this.total,
    required this.folders,
    required this.path,
    required this.query,
  });

  /// Fetch generation that produced it (latest-wins check on apply).
  final int seq;

  /// All pages' entries in request order.
  final List<MovieEntry> items;

  /// Server-reported total matches.
  final int total;

  /// `folders[]` of the last reply.
  final List<String> folders;

  /// Scope path of the fetch (`null` = index root).
  final String? path;

  /// Query the fetch ran with.
  final String query;
}

/// Riverpod notifier: fetches, caches, filters and launches library entries.
class LibraryNotifier extends AsyncNotifier<List<MovieEntry>> {
  late LibrarySocket _socket;
  late SharedPreferences _prefs;

  /// Full-index (or scoped) cache — swapped atomically per fetch.
  final List<MovieEntry> _cache = <MovieEntry>[];

  List<String> _folders = const <String>[];
  String? _scopePath;
  String _query = '';
  LibrarySort _sort = LibrarySort.titleAsc;
  bool _serverQueryMode = false;
  bool _offline = false;
  bool _refreshing = false;
  bool _rescanQueued = false;
  bool _buildDone = false;
  int _fetchSeq = 0;

  String? _launchingPath;
  String? _lastLaunchPath;
  int _lastLaunchAtMs = 0;
  Future<bool>? _inflightLaunch;
  String? _inflightPath;
  Completer<bool>? _confirm;
  String? _confirmTitle;
  String? _notice;

  Timer? _debounce;
  final Set<String> _seenReplyIds = <String>{};
  final Map<String, _PendingRequest> _pending = <String, _PendingRequest>{};
  StreamSubscription<WsMessage>? _envelopeSub;
  StreamSubscription<WsConnectionState>? _stateSub;

  /// Injectable clock for the launch-coalescing window (tests).
  int Function()? nowMsOverride;

  // -------------------------------------------------------------- public

  /// Current search query (applied after the 200 ms debounce).
  String get query => _query;

  /// Active client-side sort chip.
  LibrarySort get sort => _sort;

  /// True while the WS state (or fetch) says the PC is unreachable.
  bool get offline => _offline;

  /// True from `refresh()` start until the re-query lands.
  bool get refreshing => _refreshing;

  /// True after `RESCAN_MEDIA_RESULT {"ok":true,"queued":true}` (§4.2.4).
  bool get rescanQueued => _rescanQueued;

  /// True once the server reported > 5000 entries (§4.2.3).
  bool get serverQueryMode => _serverQueryMode;

  /// Sub-folder names of the current scope (`folders[]`, §5).
  List<String> get folders => List<String>.unmodifiable(_folders);

  /// Absolute path of the current folder scope; `null` = index root.
  String? get folderPath => _scopePath;

  /// Absolute path of the card currently in its optimistic launch state.
  String? get launchingPath => _launchingPath;

  /// One-shot message for the next awaited action (screen shows snackbars).
  String? takeNotice() {
    final String? message = _notice;
    _notice = null;
    return message;
  }

  /// Re-fetches the full index from the PC (also used by pull-to-refresh).
  ///
  /// Performs the real `RESCAN_MEDIA` round-trip → queued ack → ~2 s
  /// settle → paged `LIST_MEDIA` re-query (§4.2.4). With `force:false` a
  /// populated cache is left untouched (load-if-missing semantics).
  Future<void> refresh({bool force = false}) async {
    if (!_buildDone || _refreshing) {
      return;
    }
    if (!force && _cache.isNotEmpty) {
      return;
    }
    if (_socket.state != WsConnectionState.connected) {
      _offline = true;
      _emit();
      return;
    }
    _refreshing = true;
    _emit();
    try {
      final WsMessage ack = await _sendRequest(
        action: Action.rescanMedia,
        payload: const <String, dynamic>{},
        timeout: kLibraryAckTimeout,
      );
      _throwIfError(ack);
      _rescanQueued = true;
      _emit();
      await Future<void>.delayed(kLibraryRescanRequeryDelay);
      final _FetchOutcome outcome = await _fetchAll(
        seq: ++_fetchSeq,
        path: _scopePath,
        query: _serverQueryMode ? _query : '',
      );
      // force: recovery may run from an AsyncError state (reconnect).
      _adopt(outcome, force: true);
    } on _LibrarySuperseded {
      return; // a newer fetch owns the state — silent latest-wins
    } on _LibraryOffline {
      _offline = true;
    } on _LibraryReplyError {
      return; // keep last-known cache; the queued-ack state simply ends
    } finally {
      if (_refreshing || _rescanQueued) {
        _refreshing = false;
        _rescanQueued = false;
        _emit();
      }
    }
  }

  /// Sets the local search query; filtering fires after the 200 ms debounce
  /// and never hits the PC in normal mode (§4.2.2). Above the 5 000-entry
  /// threshold the debounced query re-fetches with `payload.query` instead.
  void setQuery(String query) {
    _debounce?.cancel();
    _debounce = Timer(kLibrarySearchDebounce, () {
      _query = query;
      if (_serverQueryMode) {
        unawaited(_runScopedFetch(seq: ++_fetchSeq, query: query));
      } else {
        _emit();
      }
    });
  }

  /// Clears the search instantly (the no-match state's one-tap Clear, §7).
  void clearQuery() {
    _debounce?.cancel();
    _debounce = null;
    _query = '';
    if (_serverQueryMode) {
      unawaited(_runScopedFetch(seq: ++_fetchSeq, query: ''));
    } else {
      _emit();
    }
  }

  /// Sets the active sort mode (client-side reorder, no round-trip).
  void setSort(LibrarySort sort) {
    _sort = sort;
    unawaited(
      _prefs
          .setString(kLibrarySortPrefsKey, sort.name)
          .catchError((Object _) => false),
    );
    _emit();
  }

  /// Launches [entry] on the PC via `CMD_MEDIA/LAUNCH_MEDIA`; returns false
  /// if offline (or when the ack / telemetry confirmation fails, §4.3).
  Future<bool> launch(MovieEntry entry) async {
    if (!_buildDone) {
      return false;
    }
    final Future<bool>? inflight = _inflightLaunch;
    if (inflight != null && _inflightPath == entry.path) {
      return inflight; // coalesced into the in-flight launch (§7)
    }
    final Future<bool> future = _performLaunch(entry);
    _inflightLaunch = future;
    _inflightPath = entry.path;
    try {
      return await future;
    } finally {
      if (identical(_inflightLaunch, future)) {
        _inflightLaunch = null;
        _inflightPath = null;
      }
    }
  }

  /// Navigates into a sub-folder (`folders[]` navigation). The child path is
  /// the current scope (or the index-root dir) + `\` + [name]; the PC
  /// validates it lies under a configured movie dir (4005 otherwise).
  Future<void> openFolder(String name) async {
    if (!_buildDone) {
      return;
    }
    final String? parent = _scopePath ?? _deriveRootPath();
    if (parent == null) {
      _notice = "Couldn't open folder (folder location ambiguous)";
      return;
    }
    await _runScopedFetch(seq: ++_fetchSeq, path: '$parent\\$name');
  }

  /// Returns to the index root scope (full re-query, no rescan).
  Future<void> goToRoot() async {
    if (!_buildDone || _scopePath == null) {
      return;
    }
    await _runScopedFetch(seq: ++_fetchSeq, path: null);
  }

  // ---------------------------------------------------------- lifecycle

  @override
  Future<List<MovieEntry>> build() async {
    _socket = ref.read(librarySocketProvider);
    _envelopeSub = _socket.envelopes.listen(_onEnvelope);
    _stateSub = _socket.stateChanges.listen(_onConnectionState);
    ref.listen<TelemetryState>(
      telemetryProvider,
      (TelemetryState? previous, TelemetryState next) => _onTelemetry(next),
    );
    ref.onDispose(() {
      _envelopeSub?.cancel();
      _stateSub?.cancel();
      _debounce?.cancel();
      final Completer<bool>? confirm = _confirm;
      if (confirm != null && !confirm.isCompleted) {
        confirm.complete(false);
      }
    });
    _prefs = await SharedPreferences.getInstance();
    final String? stored = _prefs.getString(kLibrarySortPrefsKey);
    for (final LibrarySort sort in LibrarySort.values) {
      if (sort.name == stored) {
        _sort = sort;
      }
    }
    try {
      final _FetchOutcome outcome = await _fetchAll(
        seq: ++_fetchSeq,
        path: null,
        query: '',
      );
      _buildDone = true;
      _adopt(outcome, silent: true);
      return List<MovieEntry>.unmodifiable(_visibleList());
    } catch (error) {
      _buildDone = true;
      if (error is _LibraryOffline) {
        _offline = true;
      }
      rethrow;
    }
  }

  // ------------------------------------------------------- correlation

  /// Sends one `CMD_MEDIA` request and awaits its `_RESULT`/`_ERROR` reply
  /// under the correlation guard: a new request for the same action
  /// supersedes the previous one (latest-wins), duplicate reply ids are
  /// dropped, id-exact replies are enforced when the transport reports the
  /// wire envelope, and `LIST_MEDIA` pages are matched by echoed `offset`.
  Future<WsMessage> _sendRequest({
    required String action,
    required Map<String, dynamic> payload,
    required Duration timeout,
    int? matchOffset,
  }) async {
    if (_socket.state != WsConnectionState.connected) {
      throw const _LibraryOffline();
    }
    final WsMessage request = buildMessage(
      type: typeCmdMedia,
      action: action,
      payload: payload,
    );
    final _PendingRequest? previous = _pending.remove(action);
    if (previous != null && !previous.completer.isCompleted) {
      previous.completer.completeError(const _LibrarySuperseded());
    }
    final _PendingRequest pending = _PendingRequest(
      matchOffset: matchOffset,
      completer: Completer<WsMessage>(),
    );
    _pending[action] = pending;
    final Timer timer = Timer(timeout, () {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(const _LibraryOffline());
      }
    });
    try {
      final WsMessage? wire = await _socket.send(request);
      pending.expectedId = wire?.id;
      return await pending.completer.future;
    } finally {
      timer.cancel();
      if (identical(_pending[action], pending)) {
        _pending.remove(action);
      }
    }
  }

  /// Routes inbound `CMD_MEDIA` replies to the awaiting request (§4.1).
  void _onEnvelope(WsMessage envelope) {
    if (envelope.type != typeCmdMedia) {
      return;
    }
    final String? requestAction = _requestActionOf(envelope.action);
    if (requestAction == null) {
      return;
    }
    final _PendingRequest? pending = _pending[requestAction];
    if (pending == null) {
      return; // late reply for a settled/superseded request — dropped
    }
    if (!_seenReplyIds.add(envelope.id)) {
      return; // duplicate reply id — dropped
    }
    if (_seenReplyIds.length > 64) {
      _seenReplyIds.remove(_seenReplyIds.first); // bounded insertion-order LRU
    }
    if (pending.expectedId != null && pending.expectedId != envelope.id) {
      return; // reply for a superseded request id — dropped (latest-wins)
    }
    final Object? offset = envelope.payload['offset'];
    if (pending.matchOffset != null &&
        offset is num &&
        offset.toInt() != pending.matchOffset) {
      return; // wrong page (production path without observable wire ids)
    }
    if (!pending.completer.isCompleted) {
      pending.completer.complete(envelope);
    }
  }

  /// `LIST_MEDIA_RESULT` → `LIST_MEDIA`, `LAUNCH_MEDIA_ERROR` →
  /// `LAUNCH_MEDIA`; `null` for telemetry/greeting frames.
  String? _requestActionOf(String replyAction) {
    if (replyAction.endsWith(resultSuffix)) {
      return replyAction.substring(0, replyAction.length - resultSuffix.length);
    }
    if (replyAction.endsWith(errorSuffix)) {
      return replyAction.substring(0, replyAction.length - errorSuffix.length);
    }
    return null;
  }

  // ------------------------------------------------------------- fetch

  /// Pages `LIST_MEDIA` from [path] until `offset >= total`; throws
  /// [_LibraryOffline] when unreachable and [_LibrarySuperseded] when a
  /// newer fetch took over mid-walk.
  Future<_FetchOutcome> _fetchAll({
    required int seq,
    required String? path,
    required String query,
  }) async {
    final List<MovieEntry> items = <MovieEntry>[];
    List<String> folders = const <String>[];
    int total = 0;
    int offset = 0;
    while (true) {
      final Map<String, dynamic> payload = <String, dynamic>{
        'query': query,
        'offset': offset,
        'limit': kLibraryPageSize,
      };
      if (path != null) {
        payload['path'] = path;
      }
      final WsMessage reply = await _sendRequest(
        action: Action.listMedia,
        payload: payload,
        timeout: kLibraryFetchTimeout,
        matchOffset: offset,
      );
      _throwIfError(reply);
      if (seq != _fetchSeq) {
        throw const _LibrarySuperseded(); // latest-wins (§4.1)
      }
      final LibraryPage page = LibraryPage.fromJson(reply.payload);
      folders = (reply.payload['folders'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toList();
      items.addAll(page.items);
      total = page.total;
      if (total > kLibraryServerQueryThreshold) {
        break; // server-query mode: keep the memory cap (§4.2.3)
      }
      offset += kLibraryPageSize;
      if (offset >= total) {
        break;
      }
    }
    return _FetchOutcome(
      seq: seq,
      items: items,
      total: total,
      folders: folders,
      path: path,
      query: query,
    );
  }

  /// Scoped (folder / server-query) fetch — applies on success and stays
  /// silent when superseded; offline keeps the last-known cache (§7).
  Future<void> _runScopedFetch({
    required int seq,
    String? path,
    String query = '',
  }) async {
    try {
      final _FetchOutcome outcome = await _fetchAll(
        seq: seq,
        path: path,
        query: query,
      );
      _adopt(outcome, emit: true);
    } on _LibrarySuperseded {
      return;
    } on _LibraryOffline {
      _offline = true;
      _emit();
    } on _LibraryReplyError catch (error) {
      _notice = error.code == errorMediaNotFound
          ? 'Folder not found on PC'
          : "Couldn't open folder";
      _emit();
    }
  }

  /// Atomically swaps cache/scope/folders from a finished fetch (§7).
  /// [force] writes state even from an error/loading snapshot (recovery).
  void _adopt(
    _FetchOutcome outcome, {
    bool emit = false,
    bool silent = false,
    bool force = false,
  }) {
    if (outcome.seq != _fetchSeq) {
      return; // superseded before apply — latest-wins
    }
    _cache
      ..clear()
      ..addAll(outcome.items);
    _folders = outcome.folders;
    _scopePath = outcome.path;
    _serverQueryMode = outcome.total > kLibraryServerQueryThreshold;
    _offline = false;
    if (silent) {
      return;
    }
    if (force) {
      state = AsyncData<List<MovieEntry>>(
        List<MovieEntry>.unmodifiable(_visibleList()),
      );
      return;
    }
    if (emit) {
      _emit();
    }
  }

  /// Derives the index-root directory from cached item paths so folder
  /// chips can build absolute child paths (Doc 03 §5.5 requires them);
  /// a multi-root listing falls back to its lexicographically first dir —
  /// the PC still validates the result (4005 surfaces mismatches).
  String? _deriveRootPath() {
    if (_cache.isEmpty) {
      return null;
    }
    final List<String> dirs = <String>{
      for (final MovieEntry entry in _cache) _dirOf(entry.path),
    }.toList()..sort();
    return dirs.first;
  }

  /// Directory portion of a Windows-native absolute path (`D:\f.mkv` →
  /// `D:`, so a child joins as `D:\Name`).
  String _dirOf(String path) {
    final int cut = path.lastIndexOf(r'\');
    return cut > 0 ? path.substring(0, cut) : path;
  }

  // ------------------------------------------------------------ launch

  /// Full §4.3 launch flow: ack → telemetry confirmation (or error).
  Future<bool> _performLaunch(MovieEntry entry) async {
    _notice = null;
    if (_socket.state != WsConnectionState.connected) {
      _notice = 'PC offline — launch unavailable';
      return false;
    }
    final int now = nowMsOverride?.call() ??
        DateTime.now().millisecondsSinceEpoch;
    if (_lastLaunchPath == entry.path &&
        now - _lastLaunchAtMs < kLibraryLaunchCoalesceMs) {
      return true; // double-tap coalesced — one LAUNCH_MEDIA (§7)
    }
    _lastLaunchPath = entry.path;
    _lastLaunchAtMs = now;
    _launchingPath = entry.path;
    _emit();
    try {
      final WsMessage reply = await _sendRequest(
        action: Action.launchMedia,
        payload: <String, dynamic>{'path': entry.path},
        timeout: kLibraryAckTimeout,
      );
      if (_isErrorReply(reply)) {
        final int code = _errorCode(reply);
        if (code == errorMediaNotFound) {
          _notice = 'File not found on PC';
          unawaited(refresh(force: true)); // auto re-index (§7)
        } else {
          _notice = _errorMessage(reply) ?? 'Launch failed on PC';
        }
        return false;
      }
      final bool confirmed = await _awaitConfirmation(entry.title);
      if (!confirmed) {
        _notice = 'Launch not confirmed — check PotPlayer';
        return false;
      }
      return true;
    } on _LibrarySuperseded {
      _notice = 'Launch superseded by a newer action';
      return false;
    } on _LibraryOffline {
      _notice = 'PC not responding — launch failed';
      _offline = true;
      _emit();
      return false;
    } finally {
      if (_launchingPath == entry.path) {
        _launchingPath = null;
      }
      _emit();
    }
  }

  /// Waits up to 2 s for telemetry `file_title` to confirm [title] (§4.3.3).
  Future<bool> _awaitConfirmation(String title) async {
    if (libraryNowPlaying(ref.read(telemetryProvider), title)) {
      return true;
    }
    final Completer<bool> completer = Completer<bool>();
    _confirm?.complete(false); // supersede a stale waiter, if any
    _confirm = completer;
    _confirmTitle = title;
    final Timer timer = Timer(kLibraryConfirmTimeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      if (identical(_confirm, completer)) {
        _confirm = null;
        _confirmTitle = null;
      }
    }
  }

  /// Completes the pending launch confirmation on a matching telemetry tick.
  void _onTelemetry(TelemetryState state) {
    final Completer<bool>? confirm = _confirm;
    final String? title = _confirmTitle;
    if (confirm == null || confirm.isCompleted || title == null) {
      return;
    }
    if (libraryNowPlaying(state, title)) {
      confirm.complete(true);
    }
  }

  // ---------------------------------------------------------- connection

  /// Doc 31 reconnect hook: banner flips immediately; a reconnect
  /// auto-refetches the index (§7).
  void _onConnectionState(WsConnectionState connection) {
    if (connection == WsConnectionState.connected) {
      _offline = false;
      if (_buildDone) {
        unawaited(refresh(force: true));
      }
      _emit();
    } else if (!_offline) {
      _offline = true;
      _emit();
    }
  }

  // ------------------------------------------------------------- state

  /// Visible list = cache filtered by [query], ordered by [sort] (both
  /// purely client-side, §4.2.2). Always a fresh list instance so Riverpod
  /// notifies on every emit.
  List<MovieEntry> _visibleList() {
    Iterable<MovieEntry> visible = _cache;
    if (_query.isNotEmpty) {
      final String needle = _query.toLowerCase();
      visible = visible.where(
        (MovieEntry entry) => entry.title.toLowerCase().contains(needle),
      );
    }
    final List<MovieEntry> list = visible.toList();
    list.sort(_compare);
    return list;
  }

  /// Total order for the three sort chips — ties break on title then path so
  /// duplicate titles stay deterministic (§7).
  int _compare(MovieEntry a, MovieEntry b) {
    switch (_sort) {
      case LibrarySort.titleAsc:
        final int primary =
            a.title.toLowerCase().compareTo(b.title.toLowerCase());
        if (primary != 0) {
          return primary;
        }
        return a.path.compareTo(b.path);
      case LibrarySort.sizeDesc:
        if (a.sizeBytes != b.sizeBytes) {
          return b.sizeBytes.compareTo(a.sizeBytes);
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      case LibrarySort.recentDesc:
        if (a.modified != b.modified) {
          return b.modified.compareTo(a.modified);
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }
  }

  /// Publishes a fresh state snapshot (no-op until the first build lands;
  /// error states keep their panel until a fetch replaces them).
  void _emit() {
    if (!_buildDone || state.valueOrNull == null) {
      return;
    }
    state = AsyncData<List<MovieEntry>>(
      List<MovieEntry>.unmodifiable(_visibleList()),
    );
  }

  /// Converts an `_ERROR` reply into [_LibraryReplyError] or returns.
  void _throwIfError(WsMessage reply) {
    if (_isErrorReply(reply)) {
      throw _LibraryReplyError(_errorCode(reply), _errorMessage(reply) ?? '');
    }
  }

  bool _isErrorReply(WsMessage reply) => reply.action.endsWith(errorSuffix);

  int _errorCode(WsMessage reply) {
    final Object? code = reply.payload['code'];
    return code is int ? code : 0;
  }

  String? _errorMessage(WsMessage reply) {
    final Object? message = reply.payload['message'];
    return message is String && message.isNotEmpty ? message : null;
  }
}

/// Provider consumed by the Movie Library tab of the root shell.
final AsyncNotifierProvider<LibraryNotifier, List<MovieEntry>>
    libraryProvider =
    AsyncNotifierProvider<LibraryNotifier, List<MovieEntry>>(
  LibraryNotifier.new,
);

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// The browser screen widget (search bar + sort chips + grid + states).
class MovieBrowserScreen extends ConsumerWidget {
  const MovieBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<MovieEntry>> library = ref.watch(libraryProvider);
    final LibraryNotifier notifier = ref.read(libraryProvider.notifier);
    final (String?, bool, Object?) telemetry = ref.watch(
      telemetryProvider.select(
        (TelemetryState state) => (
          state.fileTitle,
          state.isConnected,
          state.extras['potplayer_found'],
        ),
      ),
    );

    bool nowPlaying(MovieEntry entry) =>
        telemetry.$1 == entry.title && telemetry.$2 && telemetry.$3 != false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Movie Library'),
        actions: <Widget>[
          IconButton(
            key: const Key('library_refresh_button'),
            tooltip: 'Refresh library',
            onPressed: () => unawaited(notifier.refresh(force: true)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (notifier.offline && library.hasValue) const _OfflineBanner(),
          _SearchBar(
            onChanged: notifier.setQuery,
            query: notifier.query,
          ),
          _SortChips(
            sort: notifier.sort,
            onSelected: notifier.setSort,
          ),
          if (notifier.refreshing)
            _RescanningRow(rescanQueued: notifier.rescanQueued),
          if (notifier.folders.isNotEmpty || notifier.folderPath != null)
            _FolderRow(notifier: notifier),
          Expanded(
            // Pull-to-refresh sends the real RESCAN_MEDIA round-trip (§4.2.4).
            child: RefreshIndicator(
              color: AppColors.amber,
              backgroundColor: AppColors.surfaceHigh,
              onRefresh: () => notifier.refresh(force: true),
              child: _buildBody(context, ref, library, notifier, nowPlaying),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<MovieEntry>> library,
    LibraryNotifier notifier,
    bool Function(MovieEntry entry) nowPlaying,
  ) {
    if (library.isLoading && library.valueOrNull == null) {
      return const _SkeletonGrid();
    }
    if (library.hasError && library.valueOrNull == null) {
      final bool offline = notifier.offline;
      return _StatusPanel(
        message: offline ? 'PC offline — Retry' : "Couldn't load the library — Retry",
        actionLabel: 'Retry',
        actionKey: const Key('library_retry_button'),
        onAction: () => unawaited(notifier.refresh(force: true)),
      );
    }
    final List<MovieEntry> entries =
        library.valueOrNull ?? const <MovieEntry>[];
    if (entries.isEmpty) {
      if (notifier.query.isNotEmpty) {
        return _StatusPanel(
          message: "No titles match '${notifier.query}'",
          actionLabel: 'Clear',
          actionKey: const Key('library_clear_button'),
          onAction: notifier.clearQuery,
        );
      }
      return _StatusPanel(
        message:
            'No movie folders yet — set them in the PotPilot PC dashboard',
        actionLabel: 'Refresh',
        actionKey: const Key('library_empty_refresh_button'),
        onAction: () => unawaited(notifier.refresh(force: true)),
      );
    }
    return GridView.builder(
      key: const Key('library_grid'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int index) {
        final MovieEntry entry = entries[index];
        return _MovieCard(
          key: ValueKey<String>('library_card_${entry.path}'),
          entry: entry,
          nowPlaying: nowPlaying(entry),
          launching: notifier.launchingPath == entry.path,
          onTap: () async {
            final ScaffoldMessengerState messenger =
                ScaffoldMessenger.of(context);
            final bool ok = await notifier.launch(entry);
            if (ok) {
              return;
            }
            messenger.showSnackBar(
              _librarySnackBar(
                notifier.takeNotice() ?? 'Launch failed on PC',
              ),
            );
          },
        );
      },
    );
  }
}

/// Floating error snackbar in the OLED night palette.
SnackBar _librarySnackBar(String message) {
  return SnackBar(
    content: Text(
      message,
      style: AppTypography.bodySmall.copyWith(color: AppColors.onAccent),
    ),
    backgroundColor: AppColors.crimsonDim,
    behavior: SnackBarBehavior.floating,
  );
}

/// Amber-dim "Offline — retrying…" banner above the search bar (§7).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('library_offline_banner'),
      width: double.infinity,
      color: AppColors.crimsonDim,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        'Offline — retrying…',
        textAlign: TextAlign.center,
        style: AppTypography.label.copyWith(color: AppColors.onAccent),
      ),
    );
  }
}

/// Debounced search field with an amber cursor (§4.4); the text editing
/// state lives here so provider rebuilds never clobber typing.
class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.onChanged, required this.query});

  final ValueChanged<String> onChanged;

  /// Mirrored notifier query — an external clear (`Clear` button) resets
  /// the field text, user typing never gets clobbered.
  final String query;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void didUpdateWidget(_SearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query.isEmpty &&
        oldWidget.query.isNotEmpty &&
        _controller.text.isNotEmpty) {
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          border: Border.all(color: AppColors.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: TextField(
          key: const Key('library_search_field'),
          controller: _controller,
          onChanged: widget.onChanged,
          style: AppTypography.bodySmall,
          cursorColor: AppColors.amber,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: 'Search titles…',
            hintStyle: AppTypography.bodySmall
                .copyWith(color: AppColors.textTertiary),
            prefixIcon: const Icon(
              Icons.search,
              size: 18,
              color: AppColors.textTertiary,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }
}

/// The three client-side sort chips (§4.4).
class _SortChips extends StatelessWidget {
  const _SortChips({required this.sort, required this.onSelected});

  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: <Widget>[
          for (final LibrarySort option in LibrarySort.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _sortChip(option),
            ),
        ],
      ),
    );
  }

  Widget _sortChip(LibrarySort option) {
    final bool selected = option == sort;
    return ChoiceChip(
      key: Key('library_sort_${option.name}'),
      label: Text(
        librarySortLabel(option),
        style: AppTypography.label.copyWith(
          color: selected ? AppColors.onAccent : AppColors.textSecondary,
        ),
      ),
      selected: selected,
      showCheckmark: false,
      selectedColor: AppColors.amberDim,
      backgroundColor: AppColors.surface,
      side: const BorderSide(color: AppColors.outline),
      onSelected: (_) => onSelected(option),
    );
  }
}

/// "Rescanning library…" status row shown while a refresh round-trip runs
/// (queued-ack state §4.2.4).
class _RescanningRow extends StatelessWidget {
  const _RescanningRow({required this.rescanQueued});

  final bool rescanQueued;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('library_refresh_status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.amber,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            rescanQueued ? 'Rescanning library…' : 'Refreshing library…',
            style: AppTypography.label.copyWith(color: AppColors.amber),
          ),
        ],
      ),
    );
  }
}

/// Horizontal folder-chip row: back-to-root chip when nested + every
/// `folders[]` entry of the current scope (§4.1/§5).
class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.notifier});

  final LibraryNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: <Widget>[
          if (notifier.folderPath != null)
            _folderChip(
              context: context,
              label: '‹ Library',
              chipKey: const Key('library_root_chip'),
              onTap: notifier.goToRoot,
            ),
          for (final String folder in notifier.folders)
            _folderChip(
              context: context,
              label: folder,
              chipKey: ValueKey<String>('library_folder_$folder'),
              onTap: () => notifier.openFolder(folder),
            ),
        ],
      ),
    );
  }

  Widget _folderChip({
    required BuildContext context,
    required String label,
    required Key chipKey,
    required Future<void> Function() onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        key: chipKey,
        onTap: () async {
          final ScaffoldMessengerState messenger =
              ScaffoldMessenger.of(context);
          await onTap();
          final String? notice = notifier.takeNotice();
          if (notice != null) {
            messenger.showSnackBar(_librarySnackBar(notice));
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: AppTypography.label.copyWith(color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Static skeleton cards for the first fetch (§4.4 — no shimmer timers).
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      key: const Key('library_skeleton_grid'),
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.72,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: List<Widget>.generate(
        6,
        (int index) => Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

/// Distinct empty / no-match / offline panels with working actions (§7).
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.message,
    required this.actionLabel,
    required this.actionKey,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final Key actionKey;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: actionKey,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.crimsonDim,
                foregroundColor: AppColors.onAccent,
              ),
              onPressed: onAction,
              child: Text(actionLabel, style: AppTypography.label),
            ),
          ],
        ),
      ),
    );
  }
}

/// One title card: mono-truncated 2-line title, size · date subtitle, SRT
/// badge, optimistic "Launching…" overlay and telemetry-confirmed "Now
/// Playing" ring (§4.3/§4.4).
class _MovieCard extends StatelessWidget {
  const _MovieCard({
    super.key,
    required this.entry,
    required this.nowPlaying,
    required this.launching,
    required this.onTap,
  });

  final MovieEntry entry;
  final bool nowPlaying;
  final bool launching;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(
            color: nowPlaying ? AppColors.amber : AppColors.outline,
            width: nowPlaying ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(10),
        child: Stack(
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmall.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFamilyFallback: const <String>[
                      'Roboto Mono',
                      'monospace',
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  '${formatLibrarySize(entry.sizeBytes)} · '
                  '${formatLibraryDate(entry.modified)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label
                      .copyWith(color: AppColors.textTertiary),
                ),
                if (nowPlaying)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.play_circle_fill,
                          size: 12,
                          color: AppColors.amber,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Now Playing',
                          style: AppTypography.label
                              .copyWith(color: AppColors.amber),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (entry.hasSrt)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    border: Border.all(color: AppColors.amberDim),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'SRT',
                    style: AppTypography.label.copyWith(
                      fontSize: 10,
                      color: AppColors.amber,
                    ),
                  ),
                ),
              ),
            if (launching)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.scrim,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.amber,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Launching…',
                        style: AppTypography.label
                            .copyWith(color: AppColors.onAccent),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Compact byte size, e.g. `12.4 GB` / `842 MB` / `512 KB`.
String formatLibrarySize(int bytes) {
  const int kb = 1024;
  const int mb = kb * 1024;
  const int gb = mb * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(1)} GB';
  }
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(0)} MB';
  }
  if (bytes >= kb) {
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}

/// `yyyy-MM-dd` date stamp for card subtitles.
String formatLibraryDate(DateTime date) {
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
