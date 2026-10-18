import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/haptics/haptic_engine.dart';
import 'core/storage/connection_cache.dart';
import 'core/theme/oled_theme.dart';
import 'features/deck/potplayer_deck.dart';
import 'features/library/movie_browser.dart';
import 'features/settings/display_settings_card.dart' show applyBrightness;
import 'features/trackpad/keyboard_trigger_overlay.dart';
import 'features/trackpad/virtual_trackpad.dart';
import 'hardware_hooks/call_autopause_hook.dart';
import 'hardware_hooks/volume_button_hijack.dart';
import 'network/pairing_scanner.dart';
import 'network/udp_rebind.dart';
import 'network/udp_sender.dart';
import 'network/ws_client.dart';

/// Entry point: system chrome, then the Doc 34 bootstrap - the connection
/// cache (and Doc 42's prefs instance) is awaited before the first frame so
/// the Session 3 gate below can route pairing vs shell synchronously.
/// Providers stay lazy (Doc 33); a storage failure degrades to the shell
/// without pairing instead of crashing it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
    await ConnectionCache.instance.init(injected: prefs);
    // Round-6 DISPLAY: restore the saved controller brightness before the
    // first frame so launch never flashes the previous value (guarded —
    // missing platform channels in tests degrade silently).
    await applyBrightness(ConnectionCache.instance.brightness);
  } on Object catch (error) {
    debugPrint('main: storage bootstrap failed: $error');
  }
  runApp(PotPilotApp(bootstrapPrefs: prefs));
}

/// Root MaterialApp: dark-only, pitch-black scaffold; wraps the tree in a
/// [ProviderScope] that wires Doc 42's haptic engine app-wide and delegates
/// home to the Session 3 [SessionGate] (pairing screen -> [AppShell]).
class PotPilotApp extends StatelessWidget {
  const PotPilotApp({super.key, this.bootstrapPrefs});

  /// Doc 42 prefs fetched by [main]; injected into the haptic engine so its
  /// unwired-StateError fallback (§7) never fires at the composition root.
  /// Null in widget tests (where [main] never runs) - the engine then
  /// self-loads asynchronously instead.
  final SharedPreferences? bootstrapPrefs;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: <Override>[
        hapticEngineProvider.overrideWith(
          (Ref ref) => HapticEngine(preferences: bootstrapPrefs),
        ),
      ],
      child: MaterialApp(
        title: 'PotPilot',
        debugShowCheckedModeBanner: false,
        theme: buildOledTheme(),
        themeMode: ThemeMode.dark,
        home: const SessionGate(),
      ),
    );
  }
}

/// Canonical tab order; index == NavigationBar destination index.
enum AppTab {
  deck,
  trackpad,
  library,
}

/// Persistent 3-tab shell; body hosted in [IndexedStack] to preserve tab
/// state so switching tabs never resets scroll/gesture state.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Programmatic tab access for descendants (e.g. QR pairing -> Deck,
  /// Doc 32). Call as `AppShell.of(context).setTab(AppTab.deck)`.
  static AppShellController of(BuildContext context) {
    final AppShellController? controller = context
        .dependOnInheritedWidgetOfExactType<_AppShellScope>()
        ?.controller;
    assert(
      controller != null,
      'AppShell.of() called from outside the AppShell subtree.',
    );
    return controller!;
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

/// Public handle exposed by [AppShell.of] so features can switch tabs
/// without reaching into the private shell state.
class AppShellController {
  AppShellController(this._setTab);

  final void Function(AppTab tab) _setTab;

  /// Switches the shell to [tab] (e.g. QR pairing -> Deck, Doc 32).
  void setTab(AppTab tab) => _setTab(tab);
}

class _AppShellScope extends InheritedWidget {
  const _AppShellScope({required this.controller, required super.child});

  final AppShellController controller;

  @override
  bool updateShouldNotify(_AppShellScope oldWidget) =>
      controller != oldWidget.controller;
}

class _AppShellState extends State<AppShell> {
  int _index = AppTab.deck.index;
  late final AppShellController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AppShellController(setTab);
  }

  /// Moves the shell to [tab]; no-op when that tab is already selected.
  void setTab(AppTab tab) {
    if (_index == tab.index) {
      return;
    }
    setState(() {
      _index = tab.index;
    });
  }

  void _onDestinationSelected(int i) => setTab(AppTab.values[i]);

  @override
  Widget build(BuildContext context) {
    return _AppShellScope(
      controller: _controller,
      child: PopScope(
        // System back on non-deck tabs pops to deck first; on deck it
        // exits the app (no accidental kill mid-session).
        canPop: _index == AppTab.deck.index,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (!didPop && mounted) {
            setState(() {
              _index = AppTab.deck.index;
            });
          }
        },
        child: Scaffold(body: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    final Widget tabs = IndexedStack(
      index: _index,
      children: const <Widget>[
        _DeckPlaceholder(key: ValueKey<String>('app_shell_tab_deck')),
        _TrackpadPlaceholder(key: ValueKey<String>('app_shell_tab_trackpad')),
        _LibraryPlaceholder(key: ValueKey<String>('app_shell_tab_library')),
      ],
    );
    return Column(
      children: <Widget>[
        // Top inset only: tab content clears the status bar / notch while
        // the Scaffold keeps painting full-bleed behind it (SafeArea pads
        // children, never the background — the OLED look stays).
        Expanded(
          child: SafeArea(
            top: true,
            bottom: false,
            child: tabs,
          ),
        ),
        NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _onDestinationSelected,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Deck',
            ),
            NavigationDestination(
              icon: Icon(Icons.touch_app_outlined),
              selectedIcon: Icon(Icons.touch_app),
              label: 'Trackpad',
            ),
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library),
              label: 'Library',
            ),
          ],
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------------
// WIRING (Session 3)
// Session 3 (Wave 3.A) fills this region: the three placeholder classes
// below mount the real tab screens (Deck -> Doc 36, Trackpad -> Doc 35,
// Library -> Doc 45), and [SessionGate] routes cold
// start - Doc 32 pairing screen until a session pairs (fresh QR scan or
// Doc 34 cached-record auto-connect), then the persistent [AppShell].
// First pairing bootstraps UDP (Doc 32), the volume-button hijack
// (Doc 43 attach) and call auto-pause (Doc 44 start). setTab / AppShell.of
// / PopScope / navigation wiring outside this region stay untouched.
// (Dart forces imports to the top of the file; feature code lives here.)
// --------------------------------------------------------------------------

/// Cold-start gate (Doc 32): fresh installs see the pairing screen until
/// `onPaired` fires; a cached Doc 34 record auto-connects through the same
/// screen (handshake progress shown), and [AppShell] takes over once paired.
/// When storage never initialized - widget tests or a failed bootstrap -
/// the shell renders directly: pairing cannot persist a host then, and
/// keeping tests on this path leaves hooks, sockets and the camera out of
/// the shell suite.
class SessionGate extends ConsumerStatefulWidget {
  const SessionGate({super.key});

  @override
  ConsumerState<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends ConsumerState<SessionGate> {
  PairingController? _pairing;
  bool _showShell = false;
  bool _sessionWired = false;
  UdpRebindWatcher? _udpRebind;
  Future<void> _udpConfigTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    final ConnectionCache cache = ConnectionCache.instance;
    if (!cache.isReady) {
      // main() awaits init() in production; this branch only runs when
      // storage failed or in widget tests (main() never runs there).
      _showShell = true;
      return;
    }
    _pairing = PairingController();
    // Round-6 fix (Doc 30 §167): UDP used to bind once at pair time and
    // never recover from the permanent circuit breaker / a PC IP change.
    // Every WS (re)connect now re-runs the idempotent configure() so a
    // blip that heals TCP also heals UDP (live scrubs, trackpad moves).
    _udpRebind = UdpRebindWatcher(
      states: WsClient.instance.stateChanges,
      resolveHost: () => ConnectionCache.instance.activeHost,
      configure: _configureUdp,
      initialState: WsClient.instance.state,
    )..start();
    final PcHostRecord? cached = cache.activeHost;
    if (cached != null) {
      unawaited(_autoConnect(cached));
    }
  }

  @override
  void dispose() {
    _udpRebind?.dispose();
    _pairing?.dispose();
    super.dispose();
  }

  /// Doc 32 cached-record reconnect; failures surface as the pairing
  /// screen's failure state (retry / manual token), never as a crash.
  Future<void> _autoConnect(PcHostRecord host) async {
    try {
      await _pairing!.pairFromCache(host);
    } on Object catch (error) {
      debugPrint('SessionGate: cached pairing failed: $error');
    }
  }

  /// Doc 32: point the UDP sender at the paired record (the persisted
  /// host's connected IP sits first in `ipv4s`).  Serialized through
  /// [_udpConfigTail] so a pair-time bootstrap and a WS reconnect event
  /// can never interleave two binds (the loser would leak a socket).
  Future<void> _configureUdp(PcHostRecord host) {
    final Future<void> next = _udpConfigTail.then((_) async {
      try {
        await UdpSender.instance.configure(
          host: host.ipv4s.first,
          tokenHex: host.tokenHex,
          port: host.udpPort,
        );
      } on Object catch (error) {
        debugPrint('SessionGate: UDP configure failed: $error');
      }
    });
    _udpConfigTail = next;
    return next;
  }

  /// Doc 44 startup: permission probe degrades to "granted" when the
  /// platform channel is unavailable; the subscription is idempotent.
  Future<void> _startCallHook() async {
    try {
      await ref.read(callAutopauseHookProvider).start();
    } on Object catch (error) {
      debugPrint('SessionGate: call hook start failed: $error');
    }
  }

  /// One-shot session bootstrap from Doc 32's `onPaired`: UDP, then the
  /// idempotent Doc 43 attach + Doc 44 start, then reveal the shell
  /// (fresh [AppShell] starts on the deck tab - the default `onPaired`
  /// transition, re-expressed from outside the shell).
  void _onPaired() {
    if (!mounted || _showShell) {
      return;
    }
    final PcHostRecord? host = _pairing?.state.pairedHost;
    if (host != null && host.ipv4s.isNotEmpty) {
      unawaited(_configureUdp(host));
    }
    if (!_sessionWired) {
      _sessionWired = true;
      ref.read(volumeHijackProvider).attach();
      unawaited(_startCallHook());
    }
    setState(() {
      _showShell = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showShell) {
      return const AppShell();
    }
    return PairingScannerScreen(
      controller: _pairing!,
      // The screen's default onPaired assumes it sits inside AppShell; the
      // gate mounts it outside, so swap the shell in here (Doc 32).
      onPaired: (_) => _onPaired(),
    );
  }
}

class _DeckPlaceholder extends StatelessWidget {
  const _DeckPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const PotPlayerDeck();
  }
}

class _TrackpadPlaceholder extends StatelessWidget {
  const _TrackpadPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? child) {
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: VirtualTrackpad(
                sender: UdpSender.instance,
                haptics: HapticHooks.fromEngine(
                  ref.watch(hapticEngineProvider),
                ),
              ),
            ),
            // Round 6: phone-keyboard trigger zone (top-right; taps here
            // never reach the trackpad below).
            const Positioned(
              top: 8,
              right: 8,
              child: KeyboardTriggerOverlay(),
            ),
          ],
        );
      },
    );
  }
}

class _LibraryPlaceholder extends StatelessWidget {
  const _LibraryPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const MovieBrowserScreen();
  }
}

// --------------------------------------------------------------------------
// end WIRING (Session 3)
// --------------------------------------------------------------------------
