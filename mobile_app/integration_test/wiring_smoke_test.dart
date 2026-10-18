// Doc 46 §9 — app-launch/pairing/telemetry wiring smoke on a real device.
//
// Cold app start -> seed + pair from the cached host (Doc 34, no camera) ->
// first TELEMETRY_SYNC frame within 2 s -> all root tabs (Deck / Trackpad /
// Library) render. Requires a reachable PC agent:
//
//   flutter test integration_test/wiring_smoke_test.dart -d <device> \
//     --dart-define=PC_HOST=<lan-ip> --dart-define=PC_TOKEN=<32-hex>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/main.dart';
import 'package:potpilot_remote/network/pairing_scanner.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String pcHost = String.fromEnvironment('PC_HOST');
  const String pcToken = String.fromEnvironment('PC_TOKEN');

  testWidgets(
    'wiring smoke: cold start, cached pairing, telemetry < 2 s, tabs render',
    (WidgetTester tester) async {
      // 1. Seed the Doc 34 connection cache as if this phone paired before.
      final ConnectionCache cache = ConnectionCache.instance;
      await cache.init();
      final PcHostRecord record = PcHostRecord(
        hostname: 'potpilot-e2e',
        ipv4s: const <String>[pcHost],
        tokenHex: pcToken,
        lastConnectedAt: DateTime.now(),
      );
      await cache.saveHost(record);
      await cache.setActiveHost(record.id);

      // 2. Cold app start (no pumpAndSettle: sibling tabs may animate forever).
      await tester.pumpWidget(const PotPilotApp());
      await tester.pump(const Duration(milliseconds: 250));

      // 3. Root tabs render: NavigationBar labels in canonical order.
      for (final String label in const <String>[
        'Deck',
        'Trackpad',
        'Library',
      ]) {
        expect(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: 'root tab "$label" must render',
        );
      }

      // 4. Pairing from the cached host — no camera, no QR (Doc 34).
      final PairingController controller = PairingController();
      try {
        await controller
            .pairFromCache(cache.activeHost!)
            .timeout(const Duration(seconds: 15));
        expect(
          controller.state.phase,
          PairingPhase.paired,
          reason: 'pairing from cache failed: ${controller.state.failure}',
        );

        // 5. First telemetry frame within 2 s of the paired handshake.
        final WsMessage telemetry = await WsClient.instance.envelopes
            .firstWhere(
              (WsMessage message) => message.type == typeTelemetrySync,
            )
            .timeout(const Duration(seconds: 2));
        expect(telemetry.action, anyOf('STATE_DELTA', 'FULL_STATE'));
        expect(telemetry.payload, isNotEmpty);
      } finally {
        controller.dispose();
      }
    },
    skip: pcHost.isEmpty || pcToken.isEmpty,
  );
}
