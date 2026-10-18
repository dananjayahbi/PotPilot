// Round-5 Settings: the trackpad cursor-speed control edits the
// persisted TrackpadProfile (Doc 34 key) through ConnectionCache's
// write-through, and the header gear navigates into this screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/deck/deck_header_row.dart';
import 'package:potpilot_remote/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ConnectionCache.instance.init();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOledTheme(),
        home: const SettingsScreen(),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders the trackpad section with the default speed badge',
      (WidgetTester tester) async {
    await pumpSettings(tester);
    expect(find.text('TRACKPAD'), findsOneWidget);
    expect(find.text('Cursor speed'), findsOneWidget);
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('settings_cursor_speed')))
          .value,
      1.0,
    );
    expect(find.text('1.00\u00d7'), findsOneWidget);
  });

  testWidgets('DISPLAY card renders; drag previews the badge, release '
      'persists the saved brightness', (WidgetTester tester) async {
    await pumpSettings(tester);
    expect(find.text('DISPLAY'), findsOneWidget);
    expect(find.text('Screen brightness'), findsOneWidget);
    expect(
      tester.widget<Slider>(find.byKey(const Key('settings_brightness'))).value,
      1.0,
    );
    expect(find.text('100%'), findsOneWidget);
    expect(ConnectionCache.instance.brightness, 1.0);

    final Slider slider =
        tester.widget<Slider>(find.byKey(const Key('settings_brightness')));
    slider.onChanged!(0.4);
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);
    expect(ConnectionCache.instance.brightness, 1.0); // preview only

    slider.onChangeEnd!(0.4);
    await tester.pump();
    expect(ConnectionCache.instance.brightness, 0.4);

    // Re-open: the saved value is what the card restores.
    await pumpSettings(tester);
    expect(
      tester.widget<Slider>(find.byKey(const Key('settings_brightness'))).value,
      0.4,
    );
  });

  testWidgets('slider preview updates the badge; release persists the profile',
      (WidgetTester tester) async {
    await pumpSettings(tester);

    final Slider slider =
        tester.widget<Slider>(find.byKey(const Key('settings_cursor_speed')));
    slider.onChanged!(2.45);
    await tester.pump();
    expect(find.text('2.45\u00d7'), findsOneWidget);
    // Preview only — not persisted until the drag releases.
    expect(ConnectionCache.instance.trackpadProfile.sensitivity, 1.0);

    slider.onChangeEnd!(2.45);
    await tester.pump();
    expect(ConnectionCache.instance.trackpadProfile.sensitivity, 2.45);
  });

  testWidgets('quick presets save immediately and move the slider',
      (WidgetTester tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settings_speed_fast')));
    await tester.pump();
    expect(ConnectionCache.instance.trackpadProfile.sensitivity, 1.6);
    expect(find.text('1.60\u00d7'), findsOneWidget);
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('settings_cursor_speed')))
          .value,
      1.6,
    );

    await tester.tap(find.byKey(const Key('settings_speed_max')));
    await tester.pump();
    expect(ConnectionCache.instance.trackpadProfile.sensitivity, 3.0);

    await tester.tap(find.byKey(const Key('settings_speed_slow')));
    await tester.pump();
    expect(ConnectionCache.instance.trackpadProfile.sensitivity, 0.6);
  });

  testWidgets('the deck header gear pushes the Settings screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const Scaffold(
            body: DeckHeaderRow(
              fileTitle: 'Interstellar.mp4',
              volumeEnabled: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('deck_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byKey(const Key('settings_cursor_speed')), findsOneWidget);
  });
}
