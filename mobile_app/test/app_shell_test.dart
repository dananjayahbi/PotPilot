import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/trackpad/virtual_trackpad.dart';
import 'package:potpilot_remote/main.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Fake telemetry socket — one `potplayer_found: false` frame pushed via
/// `notifier.handleEnvelope` drives the deck's closed caption below the
/// status-bar inset (same harness shape as the deck suites).
class _FakeSocket implements TelemetrySocket {
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

/// Shell suite (Doc 05 section 9): 3 destinations in order, IndexedStack
/// child switching with per-tab element retention, AppTab index alignment,
/// PopScope back-press behavior, and the setTab programmatic bridge.
///
/// Note: placeholders hold no state by contract (Doc 05 section 4.4), so
/// state retention is asserted as Element-instance survival across two
/// round-trips - any stateful descendant of a retained element survives
/// with it, which is exactly what IndexedStack guarantees.
void main() {
  const ValueKey<String> deckKey = ValueKey<String>('app_shell_tab_deck');
  const ValueKey<String> trackpadKey =
      ValueKey<String>('app_shell_tab_trackpad');

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const PotPilotApp());
    await tester.pumpAndSettle();
  }

  Finder navLabel(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );

  Finder tabSlot(ValueKey<String> key) =>
      find.byKey(key, skipOffstage: false);

  IndexedStack stackOf(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byType(IndexedStack));

  PopScope popScopeOf(WidgetTester tester) => tester.widget<PopScope>(
        find.descendant(
          of: find.byType(AppShell),
          // PopScope is generic (PopScope<T>); match by `is` so the finder
          // works regardless of the inferred type argument.
          matching: find.byWidgetPredicate(
            (Widget widget) => widget is PopScope,
            description: 'PopScope',
          ),
        ),
      );

  test('AppTab indices match NavigationBar destination order', () {
    expect(AppTab.values.length, 3);
    expect(AppTab.deck.index, 0);
    expect(AppTab.trackpad.index, 1);
    expect(AppTab.library.index, 2);
  });

  testWidgets(
    'renders three NavigationBar destinations in canonical order',
    (WidgetTester tester) async {
      await pumpApp(tester);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(IndexedStack), findsOneWidget);
      expect(stackOf(tester).children.length, 3);
      expect(stackOf(tester).index, AppTab.deck.index);

      final List<String> labels = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.byType(Text),
            ),
          )
          .map((Text widget) => widget.data ?? '')
          .toList();
      expect(labels, <String>['Deck', 'Trackpad', 'Library']);
    },
  );

  testWidgets(
    'tapping destinations switches IndexedStack child and retains '
    'per-tab elements across two round-trips',
    (WidgetTester tester) async {
      await pumpApp(tester);

      // Round-trip 1: deck -> trackpad -> deck.
      final Element deckBefore = tester.element(tabSlot(deckKey));
      await tester.tap(navLabel('Trackpad'));
      await tester.pumpAndSettle();
      expect(stackOf(tester).index, AppTab.trackpad.index);
      expect(
        find.descendant(
          of: find.byType(IndexedStack),
          matching: find.byType(VirtualTrackpad, skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      final Element trackpadBefore = tester.element(tabSlot(trackpadKey));

      await tester.tap(navLabel('Deck'));
      await tester.pumpAndSettle();
      expect(stackOf(tester).index, AppTab.deck.index);
      expect(
        identical(deckBefore, tester.element(tabSlot(deckKey))),
        isTrue,
        reason: 'Deck tab element must survive the round-trip so that any '
            'stateful descendant keeps its state.',
      );

      // Round-trip 2: deck -> trackpad again.
      await tester.tap(navLabel('Trackpad'));
      await tester.pumpAndSettle();
      expect(stackOf(tester).index, AppTab.trackpad.index);
      expect(
        identical(trackpadBefore, tester.element(tabSlot(trackpadKey))),
        isTrue,
        reason: 'Trackpad tab element must survive the second round-trip.',
      );
    },
  );

  testWidgets(
    'PopScope lets back exit on deck and pops non-deck tabs to deck first',
    (WidgetTester tester) async {
      await pumpApp(tester);

      // Deck tab: system back exits the app.
      expect(popScopeOf(tester).canPop, isTrue);

      // Non-deck tab: back is intercepted and returns to deck.
      await tester.tap(navLabel('Trackpad'));
      await tester.pumpAndSettle();
      expect(popScopeOf(tester).canPop, isFalse);

      popScopeOf(tester).onPopInvokedWithResult?.call(false, null);
      await tester.pumpAndSettle();
      expect(stackOf(tester).index, AppTab.deck.index);
      expect(popScopeOf(tester).canPop, isTrue);
    },
  );

  testWidgets(
    'AppShell.of(context).setTab switches tabs programmatically',
    (WidgetTester tester) async {
      await pumpApp(tester);

      final BuildContext navContext =
          tester.element(find.byType(NavigationBar));
      AppShell.of(navContext).setTab(AppTab.library);
      await tester.pumpAndSettle();

      expect(stackOf(tester).index, AppTab.library.index);
      expect(find.byType(NavigationBar), findsOneWidget);

      final BuildContext stackContext =
          tester.element(find.byType(IndexedStack));
      AppShell.of(stackContext).setTab(AppTab.deck);
      await tester.pumpAndSettle();

      expect(stackOf(tester).index, AppTab.deck.index);
    },
  );

  testWidgets(
    'deck closed caption renders below the status-bar inset while the '
    'background stays full-bleed (shell top SafeArea)',
    (WidgetTester tester) async {
      // Status-bar / notch inset: content must clear it; the dark
      // background keeps bleeding behind it (pad content, not paint).
      // FakeViewPadding feeds the view in physical px — 48 logical at the
      // default test DPR (3.0) is 144 physical.
      tester.view.padding = FakeViewPadding(
        top: 48 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.reset);

      final _FakeSocket socket = _FakeSocket();
      addTearDown(socket.close);
      final TelemetryNotifier notifier = TelemetryNotifier(socket);
      notifier.bind();
      notifier.handleEnvelope(
        WsMessage(
          id: '00000000-0000-4000-8000-000000000009',
          type: typeTelemetrySync,
          action: actionFullState,
          payload: <String, dynamic>{
            'position_ms': 0,
            'duration_ms': 0,
            'is_playing': false,
            'potplayer_found': false,
          },
          // Future-second freshness (deck suites' convention): the
          // staleness clock must not trip during the test run.
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            // Same wiring PotPilotApp applies at the composition root —
            // the shell suite pumps AppShell under its own scope here.
            hapticEngineProvider.overrideWith(
              (Ref ref) => HapticEngine(preferences: null),
            ),
            telemetryProvider.overrideWith((ref) => notifier),
          ],
          child: MaterialApp(
            theme: buildOledTheme(),
            home: const AppShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder caption = find.byKey(const Key('deck_closed_caption'));
      expect(caption, findsOneWidget);
      expect(
        tester.getTopLeft(caption).dy,
        greaterThanOrEqualTo(48.0),
        reason: "'Pot player closed' must clear the status-bar/notch inset",
      );

      // The Scaffold still paints from y=0 — only children are padded.
      expect(tester.getTopLeft(find.byType(Scaffold)).dy, 0.0);
      final SafeArea safe = tester.widget<SafeArea>(
        find.ancestor(of: caption, matching: find.byType(SafeArea)),
      );
      expect(safe.top, isTrue);
      expect(
        safe.bottom,
        isFalse,
        reason: 'bottom stays full-bleed; only top content is padded',
      );
    },
  );
}
