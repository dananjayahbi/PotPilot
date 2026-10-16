// Doc 45 test plan: in-app movie library browser.
//
// Fake `LibrarySocket` + fake telemetry only — no real network. Covers the
// frozen `CMD_MEDIA` envelopes (paging offsets 0/200/…, rescans, launches),
// the §4.1 correlation guard, the 200 ms search debounce, launch
// confirmation/timeout flows, state rendering (empty/no-match/offline) and
// the 30-entry filter+sort matrix.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/library/movie_browser.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake Doc 31 transport: records every sent envelope and returns it
/// id-preserved (the id-exact correlation path of §4.1).
class _FakeLibrarySocket implements LibrarySocket {
  _FakeLibrarySocket({bool connected = true}) : _connected = connected;

  bool _connected;
  final List<WsMessage> sent = <WsMessage>[];
  final StreamController<WsConnectionState> _states =
      StreamController<WsConnectionState>.broadcast();
  final StreamController<WsMessage> _replies =
      StreamController<WsMessage>.broadcast();

  @override
  WsConnectionState get state =>
      _connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Stream<WsConnectionState> get stateChanges => _states.stream;

  @override
  Stream<WsMessage> get envelopes => _replies.stream;

  @override
  Future<WsMessage?> send(WsMessage message) async {
    sent.add(message);
    return message; // wire id == request id (unlike Doc 31's restamping)
  }

  void setConnected(bool value) {
    _connected = value;
    _states.add(state);
  }

  void push(WsMessage message) => _replies.add(message);

  /// Echoes a schema-valid `<ACTION>_RESULT` for [request] (Doc 03 §5.8).
  void replyTo(WsMessage request, {required Map<String, dynamic> payload}) {
    push(buildResult(request, payload: payload));
  }

  /// Echoes a schema-valid `<ACTION>_ERROR` for [request].
  void replyError(WsMessage request, {required int code, required String message}) {
    push(buildError(request, code: code, message: message));
  }

  int count(String action) =>
      sent.where((WsMessage message) => message.action == action).length;

  WsMessage last(String action) =>
      sent.lastWhere((WsMessage message) => message.action == action);

  Future<void> close() async {
    await _states.close();
    await _replies.close();
  }
}

/// Fake Doc 33 socket — frames are injected via `handleEnvelope`.
class _FakeTelemetrySocket implements TelemetrySocket {
  final StreamController<WsMessage> _envelopes =
      StreamController<WsMessage>.broadcast();
  final StreamController<WsConnectionState> _states =
      StreamController<WsConnectionState>.broadcast();

  @override
  Stream<WsMessage> get envelopes => _envelopes.stream;

  @override
  Stream<WsConnectionState> get stateChanges => _states.stream;

  Future<void> close() async {
    await _envelopes.close();
    await _states.close();
  }
}

/// One frozen Doc 20 `MediaEntryJSON` row (`name` = filename stem).
Map<String, dynamic> _wireItem({
  required String name,
  String? path,
  int sizeBytes = 1000000000,
  int modifiedAt = 1760500000,
  bool hasSubs = false,
}) {
  return <String, dynamic>{
    'name': name,
    'path': path ?? 'D:\\Movies\\$name.mkv',
    'size_bytes': sizeBytes,
    'modified_at': modifiedAt,
    'has_subs': hasSubs,
  };
}

/// Exact `LIST_MEDIA_RESULT` payload shape (§5).
Map<String, dynamic> _listPayload({
  required int total,
  required int offset,
  required List<Map<String, dynamic>> items,
  List<String> folders = const <String>[],
  int limit = kLibraryPageSize,
}) {
  return <String, dynamic>{
    'folders': folders,
    'items': items,
    'total': total,
    'offset': offset,
    'limit': limit,
  };
}

/// Full TELEMETRY_SYNC payload with the keys Doc 33 types (Doc 03 §5.6).
Map<String, dynamic> _telemetryPayload({
  String? fileTitle,
  bool potPlayerFound = true,
}) {
  return <String, dynamic>{
    'position_ms': 1000,
    'duration_ms': 600000,
    'is_playing': fileTitle != null,
    'speed': 1.0,
    'volume': 50,
    'file_title': fileTitle,
    'potplayer_found': potPlayerFound,
    'blackout_active': false,
    'brightness': 80,
    'sys_volume': 50,
    'sys_muted': false,
    'sleep_timer_active': false,
    'sleep_timer_mode': null,
    'sleep_timer_remaining_s': null,
  };
}

/// 30-entry matrix fixture: distinct sizes ascending by index, distinct
/// modified dates descending by index, every third entry has an SRT.
const List<String> _matrixTitles = <String>[
  'Inception (2010)',
  'amelie (2001)',
  'INTERSTELLAR (2014)',
  'Zulu (2008)',
  'Amélie (2001)',
  'the matrix (1999)',
  'Heat (1995)',
  'Se7en (1995)',
  '3:10 to Yuma (2007)',
  'Up (2009)',
  'Roma (2018)',
  'Dune (2021)',
  'Dune: Part Two (2024)',
  'Moonlight (2016)',
  'Parasite (2019)',
  'Gravity (2013)',
  'Arrival (2016)',
  'Blade Runner 2049 (2017)',
  'Coco (2017)',
  '1917 (2019)',
  'Tenet (2020)',
  'Tenet Extended (2020)',
  'Joker (2019)',
  'Ford v Ferrari (2019)',
  'Whiplash (2014)',
  'La La Land (2016)',
  'Drive (2011)',
  'Bronson (2008)',
  'Oldboy (2003)',
  'Memories (2003)',
];

List<Map<String, dynamic>> _matrixFixture() {
  return List<Map<String, dynamic>>.generate(_matrixTitles.length, (int i) {
    return _wireItem(
      name: _matrixTitles[i],
      path: 'D:\\Movies\\${_matrixTitles[i]}.mkv',
      sizeBytes: (i + 1) * 500000000,
      modifiedAt: 1700000000 + (_matrixTitles.length - 1 - i) * 86400,
      hasSubs: i % 3 == 0,
    );
  });
}

void main() {
  late _FakeLibrarySocket socket;
  late _FakeTelemetrySocket telemetrySocket;
  late TelemetryNotifier telemetry;
  late List<Override> overrides;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = _FakeLibrarySocket();
    telemetrySocket = _FakeTelemetrySocket();
    telemetry = TelemetryNotifier(telemetrySocket);
    telemetry.bind();
    overrides = <Override>[
      librarySocketProvider.overrideWithValue(socket),
      telemetryProvider.overrideWith((Ref ref) => telemetry),
    ];
  });

  tearDown(() async {
    await telemetrySocket.close();
    await socket.close();
  });

  // ------------------------------------------------------------ helpers

  /// Doc 03 §5.1 schema check: parses back cleanly with identical fields.
  void expectValidEnvelope(WsMessage message) {
    final WsMessage parsed = parseMessage(jsonEncode(message.toJson()));
    expect(parsed.id, message.id);
    expect(parsed.type, message.type);
    expect(parsed.action, message.action);
    expect(parsed.timestamp, isA<int>());
    expect(parsed.payload, isA<Map<String, dynamic>>());
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const MovieBrowserScreen(),
        ),
      ),
    );
    await tester.pump(); // drain build() → first LIST_MEDIA sent
  }

  LibraryNotifier notifierOf(WidgetTester tester) {
    final BuildContext context = tester.element(find.byType(MovieBrowserScreen));
    return ProviderScope.containerOf(context).read(libraryProvider.notifier);
  }

  /// Answers the last `LIST_MEDIA` request with [items].
  Future<void> replyList(
    WidgetTester tester, {
    required int total,
    required List<Map<String, dynamic>> items,
    List<String> folders = const <String>[],
    WsMessage? to,
  }) async {
    final WsMessage request = to ?? socket.last('LIST_MEDIA');
    socket.replyTo(
      request,
      payload: _listPayload(
        total: total,
        offset: request.payload['offset'] as int,
        items: items,
        folders: folders,
        limit: request.payload['limit'] as int,
      ),
    );
    await tester.pump(); // route reply + complete the fetch chain
    await tester.pump(); // render the resulting frame
  }

  Future<void> loadIndex(
    WidgetTester tester, {
    required List<Map<String, dynamic>> items,
    List<String> folders = const <String>[],
    int? total,
  }) async {
    await replyList(
      tester,
      total: total ?? items.length,
      items: items,
      folders: folders,
    );
  }

  Future<void> pushTelemetry(
    WidgetTester tester, {
    String? fileTitle,
    bool potPlayerFound = true,
  }) async {
    telemetry.handleEnvelope(
      buildTelemetryFull(_telemetryPayload(
        fileTitle: fileTitle,
        potPlayerFound: potPlayerFound,
      )),
    );
    await tester.pump();
  }

  /// Lets a visible SnackBar finish its entrance, auto-dismiss (4 s
  /// duration timer) and remove itself so no timers leak past the test.
  Future<void> flushSnackbars(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300)); // entrance → arm
    await tester.pump(const Duration(milliseconds: 4100)); // timer fires
    await tester.pump(); // dismiss begins
    await tester.pump(const Duration(milliseconds: 400)); // exit anim
    await tester.pump(); // removal frame
  }

  Future<ProviderContainer> makeContainer() async {
    final ProviderContainer container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    container.listen(
      libraryProvider,
      (AsyncValue<List<MovieEntry>>? previous,
          AsyncValue<List<MovieEntry>> next) {},
    );
    return container;
  }

  List<String> titlesOf(ProviderContainer container) {
    final List<MovieEntry>? entries = container.read(libraryProvider).value;
    return entries == null
        ? const <String>[]
        : entries.map((MovieEntry entry) => entry.title).toList();
  }

  // --------------------------------------------------------------- test

  group('models & frozen envelope schema (§3/§5, AC6)', () {
    test('MovieEntry/LibraryPage parse Doc 20 wire records exactly', () {
      final LibraryPage page = LibraryPage.fromJson(
        _listPayload(
          total: 2,
          offset: 0,
          items: <Map<String, dynamic>>[
            _wireItem(
              name: 'Amélie (2001)',
              path: 'D:\\Movies\\Amélie (2001).mkv',
              sizeBytes: 1234,
              modifiedAt: 1760500000,
              hasSubs: true,
            ),
            _wireItem(name: 'Inception (2010)'),
          ],
        ),
      );
      expect(page.total, 2);
      expect(page.offset, 0);
      expect(page.items, hasLength(2));
      final MovieEntry first = page.items.first;
      expect(first.title, 'Amélie (2001)'); // unicode passes through raw
      expect(first.path, 'D:\\Movies\\Amélie (2001).mkv');
      expect(first.sizeBytes, 1234);
      expect(first.modified,
          DateTime.fromMillisecondsSinceEpoch(1760500000 * 1000));
      expect(first.hasSrt, isTrue);
      expect(page.items.last.hasSrt, isFalse);
    });

    testWidgets('all six §5 envelopes validate against Doc 03 §5.1', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      expect(socket.sent, hasLength(1));

      // 1) LIST_MEDIA request.
      final WsMessage listReq = socket.last('LIST_MEDIA');
      expect(listReq.type, typeCmdMedia);
      expect(listReq.action, Action.listMedia);
      expect(listReq.payload, <String, dynamic>{
        'query': '',
        'offset': 0,
        'limit': kLibraryPageSize,
      });
      expectValidEnvelope(listReq);

      // 2) LIST_MEDIA_RESULT reply.
      final WsMessage listReply = buildResult(
        listReq,
        payload: _listPayload(
          total: 1,
          offset: 0,
          items: <Map<String, dynamic>>[
            _wireItem(name: 'Inception (2010)'),
          ],
        ),
      );
      expectValidEnvelope(listReply);
      socket.push(listReply);
      await tester.pump();

      // 3) RESCAN_MEDIA request + 4) RESCAN_MEDIA_RESULT reply.
      final Future<void> refresh = notifierOf(tester).refresh(force: true);
      await tester.pump();
      final WsMessage rescanReq = socket.last('RESCAN_MEDIA');
      expect(rescanReq.type, typeCmdMedia);
      expect(rescanReq.action, Action.rescanMedia);
      expect(rescanReq.payload, <String, dynamic>{});
      expectValidEnvelope(rescanReq);
      final WsMessage rescanReply =
          buildResult(rescanReq, payload: <String, dynamic>{'ok': true, 'queued': true});
      expectValidEnvelope(rescanReply);
      socket.push(rescanReply);
      await tester.pump();
      await tester.pump(kLibraryRescanRequeryDelay);
      await replyList(
        tester,
        total: 1,
        items: <Map<String, dynamic>>[_wireItem(name: 'Inception (2010)')],
      );
      await refresh;

      // 5) LAUNCH_MEDIA request + 6) LAUNCH_MEDIA_RESULT reply.
      final LibraryNotifier notifier = notifierOf(tester);
      final MovieEntry entry = notifierOf(tester)
          .state
          .requireValue
          .singleWhere((MovieEntry entry) => entry.title == 'Inception (2010)');
      final Future<bool> launched = notifier.launch(entry);
      await tester.pump();
      final WsMessage launchReq = socket.last('LAUNCH_MEDIA');
      expect(launchReq.type, typeCmdMedia);
      expect(launchReq.action, Action.launchMedia);
      expect(launchReq.payload, <String, dynamic>{
        'path': 'D:\\Movies\\Inception (2010).mkv',
      });
      expectValidEnvelope(launchReq);
      final WsMessage launchReply = buildResult(launchReq);
      expect(launchReply.action, 'LAUNCH_MEDIA_RESULT');
      expect(launchReply.payload, <String, dynamic>{'ok': true});
      expectValidEnvelope(launchReply);
      socket.push(launchReply);
      await tester.pump();
      await pushTelemetry(tester, fileTitle: 'Inception (2010)');
      expect(await launched, isTrue);
      expect(socket.count('LIST_MEDIA'), 2);
      expect(socket.count('RESCAN_MEDIA'), 1);
      expect(socket.count('LAUNCH_MEDIA'), 1);
    });
  });

  group('paged full-index fetch (§4.2, AC1)', () {
    testWidgets('500-file index pages offsets 0/200/400 with exact payloads',
        (WidgetTester tester) async {
      await pumpScreen(tester);
      expect(find.byKey(const Key('library_skeleton_grid')), findsOneWidget);

      final List<Map<String, dynamic>> all = List<Map<String, dynamic>>.generate(
        500,
        (int i) => _wireItem(
          name: i == 0 ? 'Amélie (2001)' : 'Movie ${i.toString().padLeft(3, '0')}',
          path: i == 0
              ? 'D:\\Movies\\Amélie (2001).mkv'
              : 'D:\\Movies\\Movie ${i.toString().padLeft(3, '0')}.mkv',
        ),
      );
      for (final int offset in <int>[0, 200, 400]) {
        expect(socket.last('LIST_MEDIA').payload, <String, dynamic>{
          'query': '',
          'offset': offset,
          'limit': kLibraryPageSize,
        });
        await replyList(
          tester,
          total: 500,
          items: all.sublist(offset, offset + 200 > 500 ? 500 : offset + 200),
        );
      }

      final LibraryNotifier notifier = notifierOf(tester);
      final List<MovieEntry> entries = notifier.state.requireValue;
      expect(entries, hasLength(500));
      expect(entries.first.title, 'Amélie (2001)'); // title-asc first
      expect(socket.count('LIST_MEDIA'), 3); // exactly 3 pages, no extras
      expect(
        socket.sent.where((WsMessage m) => m.type == typeCmdMedia),
        hasLength(3),
      );
      for (final WsMessage message in socket.sent) {
        expectValidEnvelope(message);
      }
      expect(find.byKey(const Key('library_skeleton_grid')), findsNothing);
    });

    testWidgets('empty index renders the dedicated empty state (AC7)', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(tester, items: <Map<String, dynamic>>[]);
      expect(
        find.text(
            'No movie folders yet — set them in the PotPilot PC dashboard'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('library_grid')), findsNothing);

      await tester.tap(find.byKey(const Key('library_empty_refresh_button')));
      await tester.pump();
      expect(socket.count('RESCAN_MEDIA'), 1); // working Refresh action
      // Let the unanswered ack time out so no timer leaks past the test.
      await tester.pump(kLibraryAckTimeout + const Duration(milliseconds: 50));
      await tester.pump();
    });
  });

  group('correlation guard (§4.1, §7)', () {
    testWidgets('superseded and duplicate replies are dropped (latest-wins)',
        (WidgetTester tester) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Root Film')],
        folders: <String>['Sub'],
      );
      expect(socket.count('LIST_MEDIA'), 1);

      final LibraryNotifier notifier = notifierOf(tester);
      // Two folder opens in flight: the second supersedes the first's
      // LIST_MEDIA request (single-flight per action).
      final Future<void> first = notifier.openFolder('Sub');
      await tester.pump();
      final WsMessage reqA = socket.last('LIST_MEDIA');
      expect(reqA.payload['path'], 'D:\\Movies\\Sub');

      final Future<void> second = notifier.openFolder('Other');
      await tester.pump();
      final WsMessage reqB = socket.last('LIST_MEDIA');
      expect(reqB.payload['path'], 'D:\\Movies\\Other');
      expect(reqB.id, isNot(reqA.id));
      expect(socket.count('LIST_MEDIA'), 3);

      // Late reply for the superseded id → dropped, nothing new sent.
      socket.replyTo(
        reqA,
        payload: _listPayload(
          total: 1,
          offset: 0,
          items: <Map<String, dynamic>>[_wireItem(name: 'STALE')],
        ),
      );
      await tester.pump();
      expect(socket.count('LIST_MEDIA'), 3);
      expect(notifier.state.requireValue.single.title, 'Root Film');
      expect(notifier.folderPath, isNull);

      // Duplicate reply with the same id → dropped again.
      socket.replyTo(
        reqA,
        payload: _listPayload(
          total: 1,
          offset: 0,
          items: <Map<String, dynamic>>[_wireItem(name: 'STALE AGAIN')],
        ),
      );
      await tester.pump();
      expect(socket.count('LIST_MEDIA'), 3);
      expect(notifier.state.requireValue.single.title, 'Root Film');

      // The live request's reply is accepted atomically.
      await replyList(
        tester,
        total: 1,
        items: <Map<String, dynamic>>[
          _wireItem(name: 'Fresh', path: 'D:\\Movies\\Other\\Fresh.mkv'),
        ],
        to: reqB,
      );
      await second;
      await first; // superseded fetch finishes silently (no throw)
      expect(notifier.state.requireValue.single.title, 'Fresh');
      expect(notifier.folderPath, 'D:\\Movies\\Other');

      // Back to root: the follow-up LIST_MEDIA carries no `path` key.
      final Future<void> back = notifier.goToRoot();
      await tester.pump();
      final WsMessage rootReq = socket.last('LIST_MEDIA');
      expect(rootReq.payload.containsKey('path'), isFalse);
      expect(rootReq.payload['offset'], 0);
      await replyList(
        tester,
        total: 1,
        items: <Map<String, dynamic>>[_wireItem(name: 'Root Film')],
        to: rootReq,
      );
      await back;
      expect(notifier.folderPath, isNull);
      expect(notifier.state.requireValue.single.title, 'Root Film');
    });
  });

  group('search debounce & filtering (§4.2, AC2)', () {
    testWidgets('3 fast keystrokes → one filter pass, zero PC calls', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = await makeContainer();
      await tester.pump();
      await replyList(tester, total: 30, items: _matrixFixture());
      final LibraryNotifier notifier = container.read(libraryProvider.notifier);
      expect(titlesOf(container), hasLength(30));

      int emissions = 0;
      container.listen(
        libraryProvider,
        (AsyncValue<List<MovieEntry>>? previous,
            AsyncValue<List<MovieEntry>> next) {
          emissions++;
        },
      );
      final int baseline = emissions;
      final int requests = socket.count('LIST_MEDIA');

      // Three rapid keystrokes stay inside one debounce (deadline = last
      // keystroke + 200 ms = t0 + 300 ms).
      notifier.setQuery('i');
      await tester.pump(const Duration(milliseconds: 50));
      notifier.setQuery('in');
      await tester.pump(const Duration(milliseconds: 50));
      notifier.setQuery('incept');
      await tester.pump(const Duration(milliseconds: 100)); // t = 200
      expect(emissions, baseline); // debounce still holding
      expect(socket.count('LIST_MEDIA'), requests); // zero PC calls

      await tester.pump(const Duration(milliseconds: 110)); // t = 310 → fired
      expect(emissions, baseline + 1); // exactly one filter pass
      expect(titlesOf(container), <String>['Inception (2010)']);
      expect(socket.count('LIST_MEDIA'), requests); // still zero PC calls
    });

    testWidgets('typing filters the grid without a PC round-trip (AC2)', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await replyList(
        tester,
        total: 2,
        items: <Map<String, dynamic>>[
          _wireItem(name: 'Inception (2010)'),
          _wireItem(name: 'Whiplash (2014)'),
        ],
      );
      expect(find.text('Inception (2010)'), findsOneWidget);
      expect(find.text('Whiplash (2014)'), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('library_search_field')), 'inception');
      await tester.pump(kLibrarySearchDebounce + const Duration(milliseconds: 50));
      expect(socket.count('LIST_MEDIA'), 1); // no round-trip
      expect(find.text('Inception (2010)'), findsOneWidget);
      expect(find.text('Whiplash (2014)'), findsNothing);

      // No-match state + one-tap clear (§7).
      await tester.enterText(
          find.byKey(const Key('library_search_field')), 'zzzzzz');
      await tester.pump(kLibrarySearchDebounce + const Duration(milliseconds: 50));
      expect(find.text("No titles match 'zzzzzz'"), findsOneWidget);
      expect(socket.count('LIST_MEDIA'), 1);

      await tester.tap(find.byKey(const Key('library_clear_button')));
      await tester.pump();
      expect(find.text("No titles match 'zzzzzz'"), findsNothing);
      expect(find.text('Inception (2010)'), findsOneWidget);
      expect(socket.count('LIST_MEDIA'), 1);
    });
  });

  group('sort chips & 30-entry matrix (AC3)', () {
    testWidgets('three client-side sorts, case-insensitive filter, SRT flag',
        (WidgetTester tester) async {
      final ProviderContainer container = await makeContainer();
      await tester.pump();
      await replyList(tester, total: 30, items: _matrixFixture());
      final LibraryNotifier notifier = container.read(libraryProvider.notifier);

      // Default: Title A–Z, case-insensitive with exact anchors.
      expect(notifier.sort, LibrarySort.titleAsc);
      List<String> titles = titlesOf(container);
      expect(titles.first, '1917 (2019)');
      expect(titles.last, 'Zulu (2008)');
      final List<String> expectedAsc = List<String>.of(titles)
        ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(titles, expectedAsc); // pure case-insensitive ordering

      // Biggest first — strictly nonincreasing sizes.
      notifier.setSort(LibrarySort.sizeDesc);
      await tester.pump();
      List<MovieEntry> entries = container.read(libraryProvider).requireValue;
      expect(entries.first.title, 'Memories (2003)'); // 15 GB
      expect(entries.last.title, 'Inception (2010)'); // 0.5 GB
      for (int i = 1; i < entries.length; i++) {
        expect(entries[i - 1].sizeBytes >= entries[i].sizeBytes, isTrue);
      }

      // Newest first — strictly nonincreasing modified dates.
      notifier.setSort(LibrarySort.recentDesc);
      await tester.pump();
      entries = container.read(libraryProvider).requireValue;
      expect(entries.first.title, 'Inception (2010)');
      expect(entries.last.title, 'Memories (2003)');
      for (int i = 1; i < entries.length; i++) {
        expect(entries[i - 1].modified.isBefore(entries[i].modified), isFalse);
      }

      // Case-insensitive substring filter (uppercase needle).
      notifier.setQuery('INCEPTION');
      await tester.pump(kLibrarySearchDebounce + const Duration(milliseconds: 50));
      expect(titlesOf(container), <String>['Inception (2010)']);
      expect(socket.count('LIST_MEDIA'), 1); // still no round-trip

      // Multi-match + instant clear.
      notifier.setQuery('dune');
      await tester.pump(kLibrarySearchDebounce + const Duration(milliseconds: 50));
      expect(
        titlesOf(container),
        <String>['Dune: Part Two (2024)', 'Dune (2021)']
          ..sort((String a, String b) =>
              a.toLowerCase().compareTo(b.toLowerCase())),
      );
      notifier.clearQuery();
      await tester.pump();
      expect(titlesOf(container), hasLength(30));
      expect(socket.count('LIST_MEDIA'), 1); // whole matrix, no PC calls
    });

    testWidgets('SRT badge, size/date subtitle and chip wiring', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[
          _wireItem(
            name: 'With Subs',
            path: 'D:\\Movies\\With Subs.mkv',
            sizeBytes: 13314398617,
            modifiedAt: 1760500000,
            hasSubs: true,
          ),
          _wireItem(
            name: 'No Subs',
            path: 'D:\\Movies\\No Subs.mkv',
            sizeBytes: 1000000000,
            hasSubs: false,
          ),
        ],
      );

      // Formatting helpers (§4.4 subtitle).
      expect(formatLibrarySize(13314398617), '12.4 GB');
      expect(formatLibrarySize(1000000000), '954 MB');
      expect(formatLibraryDate(DateTime(2010, 7, 16)), '2010-07-16');

      final Finder withSubs =
          find.byKey(const ValueKey<String>('library_card_D:\\Movies\\With Subs.mkv'));
      final Finder noSubs =
          find.byKey(const ValueKey<String>('library_card_D:\\Movies\\No Subs.mkv'));
      expect(withSubs, findsOneWidget);
      expect(noSubs, findsOneWidget);
      expect(
        find.descendant(of: withSubs, matching: find.text('SRT')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: noSubs, matching: find.text('SRT')),
        findsNothing,
      );
      final String expectedSubtitle =
          '12.4 GB · ${formatLibraryDate(DateTime.fromMillisecondsSinceEpoch(1760500000 * 1000))}';
      expect(
        find.descendant(of: withSubs, matching: find.text(expectedSubtitle)),
        findsOneWidget,
      );

      // Sort chip tap flips the notifier + persists under `library_sort`.
      await tester.tap(find.byKey(const Key('library_sort_sizeDesc')));
      await tester.pump();
      expect(notifierOf(tester).sort, LibrarySort.sizeDesc);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kLibrarySortPrefsKey), 'sizeDesc');
    });

    testWidgets('persisted sort chip restores on open', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kLibrarySortPrefsKey: 'sizeDesc',
      });
      socket = _FakeLibrarySocket();
      telemetrySocket = _FakeTelemetrySocket();
      telemetry = TelemetryNotifier(telemetrySocket);
      telemetry.bind();
      overrides = <Override>[
        librarySocketProvider.overrideWithValue(socket),
        telemetryProvider.overrideWith((Ref ref) => telemetry),
      ];
      await pumpScreen(tester);
      await loadIndex(tester, total: 30, items: _matrixFixture());
      expect(notifierOf(tester).sort, LibrarySort.sizeDesc);
      final List<MovieEntry> entries = notifierOf(tester).state.requireValue;
      expect(entries.first.title, 'Memories (2003)');
      expect(entries.last.title, 'Inception (2010)');
    });
  });

  group('pull-to-refresh rescan flow (§4.2.4, AC8)', () {
    testWidgets('RESCAN round-trip → queued ack → re-query shows new file', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Old Film')],
      );
      expect(find.text('Old Film'), findsOneWidget);

      await tester.fling(
        find.byKey(const Key('library_grid')),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      for (int i = 0; i < 20 && socket.count('RESCAN_MEDIA') == 0; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(socket.count('RESCAN_MEDIA'), 1); // real pull-to-refresh send
      expectValidEnvelope(socket.last('RESCAN_MEDIA'));

      // Queued ack surfaces before the ~2 s re-query.
      socket.replyTo(
        socket.last('RESCAN_MEDIA'),
        payload: <String, dynamic>{'ok': true, 'queued': true},
      );
      await tester.pump();
      expect(notifierOf(tester).rescanQueued, isTrue);
      expect(find.text('Rescanning library…'), findsOneWidget);
      await tester.pump(kLibraryRescanRequeryDelay);
      expect(socket.count('LIST_MEDIA'), 2);

      // Re-query shows a file added on the PC while the app was open.
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[
          _wireItem(name: 'Old Film'),
          _wireItem(name: 'Added While Open (2026)'),
        ],
      );
      expect(find.text('Added While Open (2026)'), findsOneWidget);
      expect(find.text('Rescanning library…'), findsNothing);
      expect(notifierOf(tester).rescanQueued, isFalse);
      await tester.pump(const Duration(milliseconds: 300)); // indicator dismiss
    });
  });

  group('launch flow (§4.3, AC4/AC5)', () {
    testWidgets('tap launches exact unicode path; telemetry confirms', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[
          _wireItem(
            name: 'Amélie (2001)',
            path: 'D:\\Movies\\Amélie (2001).mkv',
          ),
        ],
      );

      await tester.tap(
        find.byKey(
            const ValueKey<String>('library_card_D:\\Movies\\Amélie (2001).mkv')),
      );
      await tester.pump();
      expect(socket.count('LAUNCH_MEDIA'), 1);
      expect(
        socket.last('LAUNCH_MEDIA').payload,
        <String, dynamic>{'path': 'D:\\Movies\\Amélie (2001).mkv'},
      ); // path only — no extra keys
      expectValidEnvelope(socket.last('LAUNCH_MEDIA'));
      expect(find.text('Launching…'), findsOneWidget); // optimistic UI

      socket.replyTo(socket.last('LAUNCH_MEDIA'),
          payload: <String, dynamic>{'ok': true});
      await tester.pump();
      expect(find.text('Launching…'), findsOneWidget); // awaiting telemetry

      // Next TELEMETRY_SYNC ≤ 250 ms confirms → "Now Playing" (AC5).
      await pushTelemetry(tester, fileTitle: 'Amélie (2001)');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Now Playing'), findsOneWidget);
      expect(find.text('Launching…'), findsNothing);
      expect(find.byType(SnackBar), findsNothing); // no false error
      expect(socket.count('LAUNCH_MEDIA'), 1);
    });

    testWidgets('double-tap coalesces to one LAUNCH_MEDIA (§7)', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Inception (2010)')],
      );
      final Finder card = find.byKey(
          const ValueKey<String>('library_card_D:\\Movies\\Inception (2010).mkv'));

      await tester.tap(card);
      await tester.pump();
      await tester.tap(card); // second tap while in flight
      await tester.pump();
      expect(socket.count('LAUNCH_MEDIA'), 1);

      socket.replyTo(socket.last('LAUNCH_MEDIA'),
          payload: <String, dynamic>{'ok': true});
      await tester.pump();
      await pushTelemetry(tester, fileTitle: 'Inception (2010)');
      await tester.pump();
      expect(find.text('Now Playing'), findsOneWidget);

      // A third tap inside the 1 s window is absorbed too.
      await tester.tap(card);
      await tester.pump();
      expect(socket.count('LAUNCH_MEDIA'), 1);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('2 s without telemetry confirmation → error snackbar', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Inception (2010)')],
      );
      await tester.tap(find.byKey(
          const ValueKey<String>('library_card_D:\\Movies\\Inception (2010).mkv')));
      await tester.pump();
      socket.replyTo(socket.last('LAUNCH_MEDIA'),
          payload: <String, dynamic>{'ok': true});
      await tester.pump();
      expect(find.text('Launching…'), findsOneWidget);

      await tester.pump(kLibraryConfirmTimeout);
      await tester.pump();
      expect(find.text('Launch not confirmed — check PotPlayer'), findsOneWidget);
      expect(find.text('Launching…'), findsNothing); // card reverts
      await flushSnackbars(tester);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('launch error 4005 → snackbar + auto refresh (§7)', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Ghost Film')],
      );
      await tester.tap(find.byKey(
          const ValueKey<String>('library_card_D:\\Movies\\Ghost Film.mkv')));
      await tester.pump();
      socket.replyError(
        socket.last('LAUNCH_MEDIA'),
        code: errorMediaNotFound,
        message: 'no such file',
      );
      await tester.pump();
      expect(find.text('File not found on PC'), findsOneWidget);
      expect(socket.count('RESCAN_MEDIA'), 1); // auto refresh(force:true)

      socket.replyTo(
        socket.last('RESCAN_MEDIA'),
        payload: <String, dynamic>{'ok': true, 'queued': true},
      );
      await tester.pump();
      await tester.pump(kLibraryRescanRequeryDelay);
      expect(socket.count('LIST_MEDIA'), 2);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Ghost Film')], // gone
      );
      await flushSnackbars(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Ghost Film'), findsOneWidget);
    });

    testWidgets('offline tap → immediate false + snackbar, no envelope', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Inception (2010)')],
      );
      socket.setConnected(false);
      await tester.pump();
      expect(find.text('Offline — retrying…'), findsOneWidget); // banner §7
      expect(find.text('Inception (2010)'), findsOneWidget); // list kept

      await tester.tap(find.byKey(
          const ValueKey<String>('library_card_D:\\Movies\\Inception (2010).mkv')));
      await tester.pump();
      expect(socket.count('LAUNCH_MEDIA'), 0);
      expect(find.text('PC offline — launch unavailable'), findsOneWidget);
      await flushSnackbars(tester);
    });
  });

  group('state rendering (§7, AC7)', () {
    testWidgets('offline initial load renders retry; reconnect auto-refetches',
        (WidgetTester tester) async {
      socket = _FakeLibrarySocket(connected: false);
      overrides = <Override>[
        librarySocketProvider.overrideWithValue(socket),
        telemetryProvider.overrideWith((Ref ref) => telemetry),
      ];
      await pumpScreen(tester);
      expect(socket.sent, isEmpty); // never queues while down
      expect(find.text('PC offline — Retry'), findsOneWidget);

      await tester.tap(find.byKey(const Key('library_retry_button')));
      await tester.pump();
      expect(socket.count('RESCAN_MEDIA'), 0); // still offline → no send

      socket.setConnected(true);
      await tester.pump();
      expect(socket.count('RESCAN_MEDIA'), 1); // auto-refetch (§7)
      socket.replyTo(
        socket.last('RESCAN_MEDIA'),
        payload: <String, dynamic>{'ok': true, 'queued': true},
      );
      await tester.pump();
      await tester.pump(kLibraryRescanRequeryDelay);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Recovered Film')],
      );
      expect(find.text('Recovered Film'), findsOneWidget);
      expect(find.text('PC offline — Retry'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(const Key('library_grid')), findsOneWidget);
    });

    testWidgets('mid-session disconnect keeps list + banner, reconnect restores',
        (WidgetTester tester) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Kept Film')],
      );
      socket.setConnected(false);
      await tester.pump();
      expect(find.text('Offline — retrying…'), findsOneWidget);
      expect(find.text('Kept Film'), findsOneWidget); // last-known cache

      socket.setConnected(true);
      await tester.pump();
      socket.replyTo(
        socket.last('RESCAN_MEDIA'),
        payload: <String, dynamic>{'ok': true, 'queued': true},
      );
      await tester.pump();
      await tester.pump(kLibraryRescanRequeryDelay);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Kept Film')],
      );
      expect(find.text('Offline — retrying…'), findsNothing);
      expect(find.text('Kept Film'), findsOneWidget);
    });
  });

  group('app-scoped state & server-query mode (AC3, §4.2.3)', () {
    testWidgets('state survives tab switches without refetching (AC3)', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester);
      await loadIndex(
        tester,
        items: <Map<String, dynamic>>[_wireItem(name: 'Persistent Film')],
      );
      expect(socket.count('LIST_MEDIA'), 1);

      // Simulate the tab switch: screen unmounts, provider stays app-scoped.
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      await tester.pump();
      await pumpScreen(tester);
      expect(find.text('Persistent Film'), findsOneWidget);
      expect(socket.count('LIST_MEDIA'), 1); // no refetch — state kept
    });

    testWidgets('total > 5000 flips to server-side query mode (§4.2.3)', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = await makeContainer();
      await tester.pump();
      await replyList(
        tester,
        total: 6000,
        items: List<Map<String, dynamic>>.generate(
          kLibraryPageSize,
          (int i) => _wireItem(name: 'Huge ${i.toString().padLeft(3, '0')}'),
        ),
      );
      final LibraryNotifier notifier = container.read(libraryProvider.notifier);
      expect(notifier.serverQueryMode, isTrue);
      expect(container.read(libraryProvider).requireValue,
          hasLength(kLibraryPageSize)); // memory capped at one page

      // Debounced typing now re-fetches with payload.query (bounded WS).
      notifier.setQuery('dune');
      await tester.pump(kLibrarySearchDebounce);
      expect(socket.count('LIST_MEDIA'), 2);
      expect(socket.last('LIST_MEDIA').payload, <String, dynamic>{
        'query': 'dune',
        'offset': 0,
        'limit': kLibraryPageSize,
      });
      await replyList(
        tester,
        total: 1,
        items: <Map<String, dynamic>>[_wireItem(name: 'Dune (2021)')],
      );
      expect(titlesOf(container), <String>['Dune (2021)']);
    });
  });
}
