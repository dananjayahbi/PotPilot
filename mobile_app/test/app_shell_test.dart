import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/features/bed_mode/blind_gesture_pad.dart';
import 'package:potpilot_remote/features/trackpad/virtual_trackpad.dart';
import 'package:potpilot_remote/main.dart';

/// Shell suite (Doc 05 section 9): 4 destinations in order, IndexedStack
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
    expect(AppTab.values.length, 4);
    expect(AppTab.deck.index, 0);
    expect(AppTab.trackpad.index, 1);
    expect(AppTab.bedMode.index, 2);
    expect(AppTab.library.index, 3);
  });

  testWidgets(
    'renders four NavigationBar destinations in canonical order',
    (WidgetTester tester) async {
      await pumpApp(tester);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(IndexedStack), findsOneWidget);
      expect(stackOf(tester).children.length, 4);
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
      expect(labels, <String>['Deck', 'Trackpad', 'Bed Mode', 'Library']);
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

      // Bed Mode (bar hidden) also pops back to deck first.
      AppShell.of(tester.element(find.byType(IndexedStack)))
          .setTab(AppTab.bedMode);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(popScopeOf(tester).canPop, isFalse);

      popScopeOf(tester).onPopInvokedWithResult?.call(false, null);
      await tester.pumpAndSettle();
      expect(stackOf(tester).index, AppTab.deck.index);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );

  testWidgets(
    'AppShell.of(context).setTab switches tabs and hides the bar '
    'in Bed Mode',
    (WidgetTester tester) async {
      await pumpApp(tester);

      final BuildContext navContext =
          tester.element(find.byType(NavigationBar));
      AppShell.of(navContext).setTab(AppTab.bedMode);
      await tester.pumpAndSettle();

      // Bed Mode is a full-screen canvas: NavigationBar hidden.
      expect(find.byType(NavigationBar), findsNothing);
      expect(stackOf(tester).index, AppTab.bedMode.index);
      expect(
        find.descendant(
          of: find.byType(IndexedStack),
          matching: find.byType(BlindGesturePad, skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      // Only setTab can leave Bed Mode (no bar to tap).
      final BuildContext stackContext =
          tester.element(find.byType(IndexedStack));
      AppShell.of(stackContext).setTab(AppTab.deck);
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(stackOf(tester).index, AppTab.deck.index);
    },
  );
}
