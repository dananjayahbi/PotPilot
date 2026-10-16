// Doc 37 — Full PC keyboard sheet.
//
// Dark QWERTY overlay exposing the keys a phone IME cannot send (Esc, Tab,
// Win, Alt+F4, F1–F12, arrow cluster) plus live text forwarding to the PC.
// Frozen protocol surface (Doc 03 §5.4): `CMD_KEY` only — `SEND_KEY`,
// `SEND_COMBO`, `SEND_TEXT`. The freeze has no `KEY_REPEAT`, so hold-repeat
// is client-driven re-dispatch of `SEND_KEY` at 25 Hz (400 ms delay, 40 ms
// cadence = Windows typematic feel).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Hold duration before the first repeat tick (Windows typematic delay).
const Duration kKeyboardRepeatDelay = Duration(milliseconds: 400);

/// Repeat cadence once engaged — 40 ms ⇒ ≈25 `SEND_KEY`/s (Doc 37 §5: the
/// freeze has no dedicated repeat action).
const Duration kKeyboardRepeatInterval = Duration(milliseconds: 40);

/// Consecutive printable taps coalesce into one `SEND_TEXT` when they land
/// inside this window (Doc 37 §4.3).
const Duration kKeyboardCoalesceDelay = Duration(milliseconds: 50);

/// Max characters per `SEND_TEXT` envelope — batches are chunked so no
/// envelope ever exceeds this (Doc 37 §7; Doc 03 caps text at 4096).
const int kKeyboardChunkChars = 64;

/// Live echo line keeps only the last N forwarded chars (Doc 37 §4.2).
const int kKeyboardEchoChars = 40;

/// Pointer travel beyond this many dp cancels the press — no dispatch
/// (prevents stray Esc from scroll gestures, Doc 37 §7).
const double kKeyboardPressCancelDp = 10;

/// Pressed accent fill stays lit this long after release (Doc 37 §4 table).
const Duration kKeyboardKeyFlash = Duration(milliseconds: 80);

/// Sheet occupies ~45 % of the screen height (Doc 37 §4.2).
const double kKeyboardSheetHeightFactor = 0.45;

/// Keycap geometry: 34 × 44 dp default, 44 dp touch height (Doc 37 §4).
const double kKeyCapWidth = 34;
const double kKeyCapHeight = 44;

/// F-row key count (Esc + F1–F12).
const int kFRowKeyCount = 13;

/// Keys that re-dispatch `SEND_KEY` on the 25 Hz hold-repeat cadence.
/// F-keys are explicitly not repeatable (Doc 37 §10); Home/End/PgUp/PgDn
/// repeat alongside the arrows per the §5 protocol table.
const Set<SpecialKey> kRepeatableKeys = <SpecialKey>{
  SpecialKey.backspace,
  SpecialKey.enter,
  SpecialKey.arrowUp,
  SpecialKey.arrowDown,
  SpecialKey.arrowLeft,
  SpecialKey.arrowRight,
  SpecialKey.home,
  SpecialKey.end,
  SpecialKey.pageUp,
  SpecialKey.pageDown,
};

/// One physical key: printable char or named special key (Doc 37 §3).
enum SpecialKey {
  esc,
  tab,
  win,
  altF4,
  backspace,
  enter,
  shift,
  ctrl,
  alt,
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  f7,
  f8,
  f9,
  f10,
  f11,
  f12,
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  home,
  end,
  pageUp,
  pageDown,
}

/// Latched (one-shot) modifier state carried into the next key press
/// (Doc 37 §3). Win has its own latch — holding the Win key arms it —
/// because it doubles as a standalone Start-menu key (§4.5).
enum Modifier { shift, ctrl, alt }

/// Standard Win32 VK codes for the special keys (Doc 37 §5 — consumed,
/// not invented; Doc 07 injects them via `KEYBDINPUT`). Shift/Ctrl/Alt
/// latch instead of dispatching; Alt+F4 is a self-contained combo.
const Map<SpecialKey, int> kSpecialKeyVks = <SpecialKey, int>{
  SpecialKey.esc: 27,
  SpecialKey.tab: 9,
  SpecialKey.win: 91, // VK_LWIN (Start menu on a plain tap)
  SpecialKey.backspace: 8,
  SpecialKey.enter: 13,
  SpecialKey.f1: 112,
  SpecialKey.f2: 113,
  SpecialKey.f3: 114,
  SpecialKey.f4: 115,
  SpecialKey.f5: 116,
  SpecialKey.f6: 117,
  SpecialKey.f7: 118,
  SpecialKey.f8: 119,
  SpecialKey.f9: 120,
  SpecialKey.f10: 121,
  SpecialKey.f11: 122,
  SpecialKey.f12: 123,
  SpecialKey.arrowUp: 38,
  SpecialKey.arrowDown: 40,
  SpecialKey.arrowLeft: 37,
  SpecialKey.arrowRight: 39,
  SpecialKey.home: 36,
  SpecialKey.end: 35,
  SpecialKey.pageUp: 33,
  SpecialKey.pageDown: 34,
};

/// VK codes for the printable punctuation/space chars so Ctrl/Alt + char
/// can go out as `SEND_COMBO` (US-QWERTY layout, Doc 37 §10 assumption).
const Map<String, int> kCharVks = <String, int>{
  ' ': 32,
  '`': 192,
  '-': 189,
  '=': 187,
  '[': 219,
  ']': 221,
  '\\': 220,
  ';': 186,
  "'": 222,
  ',': 188,
  '.': 190,
  '/': 191,
};

/// US-QWERTY Shift translation for non-letters (Doc 37 §10: Shift+digit
/// punctuation is forwarded as `SEND_TEXT` with the already-translated
/// character).
const Map<String, String> kShiftedPunct = <String, String>{
  '`': '~',
  '1': '!',
  '2': '@',
  '3': '#',
  '4': '\$',
  '5': '%',
  '6': '^',
  '7': '&',
  '8': '*',
  '9': '(',
  '0': ')',
  '-': '_',
  '=': '+',
  '[': '{',
  ']': '}',
  '\\': '|',
  ';': ':',
  "'": '"',
  ',': '<',
  '.': '>',
  '/': '?',
};

/// F-row: Esc + F1–F12 (Doc 37 §4 key page map; horizontally scrollable
/// below 360 dp portrait width).
const List<KeySpec> fRow = <KeySpec>[
  KeySpec(label: 'Esc', special: SpecialKey.esc),
  KeySpec(label: 'F1', special: SpecialKey.f1),
  KeySpec(label: 'F2', special: SpecialKey.f2),
  KeySpec(label: 'F3', special: SpecialKey.f3),
  KeySpec(label: 'F4', special: SpecialKey.f4),
  KeySpec(label: 'F5', special: SpecialKey.f5),
  KeySpec(label: 'F6', special: SpecialKey.f6),
  KeySpec(label: 'F7', special: SpecialKey.f7),
  KeySpec(label: 'F8', special: SpecialKey.f8),
  KeySpec(label: 'F9', special: SpecialKey.f9),
  KeySpec(label: 'F10', special: SpecialKey.f10),
  KeySpec(label: 'F11', special: SpecialKey.f11),
  KeySpec(label: 'F12', special: SpecialKey.f12),
];

/// The main QWERTY block (Doc 37 §4 key page map, portrait 360 dp).
const List<List<KeySpec>> qwertyRows = <List<KeySpec>>[
  <KeySpec>[
    KeySpec(label: '`', char: '`'),
    KeySpec(label: '1', char: '1'),
    KeySpec(label: '2', char: '2'),
    KeySpec(label: '3', char: '3'),
    KeySpec(label: '4', char: '4'),
    KeySpec(label: '5', char: '5'),
    KeySpec(label: '6', char: '6'),
    KeySpec(label: '7', char: '7'),
    KeySpec(label: '8', char: '8'),
    KeySpec(label: '9', char: '9'),
    KeySpec(label: '0', char: '0'),
    KeySpec(label: '-', char: '-'),
    KeySpec(label: '=', char: '='),
    KeySpec(label: '⌫', special: SpecialKey.backspace, repeatable: true),
  ],
  <KeySpec>[
    KeySpec(label: 'Tab', special: SpecialKey.tab),
    KeySpec(label: 'q', char: 'q'),
    KeySpec(label: 'w', char: 'w'),
    KeySpec(label: 'e', char: 'e'),
    KeySpec(label: 'r', char: 'r'),
    KeySpec(label: 't', char: 't'),
    KeySpec(label: 'y', char: 'y'),
    KeySpec(label: 'u', char: 'u'),
    KeySpec(label: 'i', char: 'i'),
    KeySpec(label: 'o', char: 'o'),
    KeySpec(label: 'p', char: 'p'),
    KeySpec(label: '[', char: '['),
    KeySpec(label: ']', char: ']'),
    KeySpec(label: '\\', char: '\\'),
  ],
  <KeySpec>[
    KeySpec(label: 'Shift', special: SpecialKey.shift),
    KeySpec(label: 'a', char: 'a'),
    KeySpec(label: 's', char: 's'),
    KeySpec(label: 'd', char: 'd'),
    KeySpec(label: 'f', char: 'f'),
    KeySpec(label: 'g', char: 'g'),
    KeySpec(label: 'h', char: 'h'),
    KeySpec(label: 'j', char: 'j'),
    KeySpec(label: 'k', char: 'k'),
    KeySpec(label: 'l', char: 'l'),
    KeySpec(label: ';', char: ';'),
    KeySpec(label: "'", char: "'"),
    KeySpec(label: 'Enter', special: SpecialKey.enter, repeatable: true),
  ],
  <KeySpec>[
    KeySpec(label: 'Ctrl', special: SpecialKey.ctrl),
    KeySpec(label: 'Win', special: SpecialKey.win),
    KeySpec(label: 'Alt', special: SpecialKey.alt),
    KeySpec(label: 'Space', char: ' ', span: 4),
    KeySpec(label: 'Alt+F4', special: SpecialKey.altF4),
  ],
];

/// Nav cluster: arrows + Home/End/PgUp/PgDn (Doc 37 §4 key page map).
const List<KeySpec> navRow = <KeySpec>[
  KeySpec(label: '◀', special: SpecialKey.arrowLeft, repeatable: true),
  KeySpec(label: '▲', special: SpecialKey.arrowUp, repeatable: true),
  KeySpec(label: '▼', special: SpecialKey.arrowDown, repeatable: true),
  KeySpec(label: '▶', special: SpecialKey.arrowRight, repeatable: true),
  KeySpec(label: 'Home', special: SpecialKey.home, repeatable: true),
  KeySpec(label: 'End', special: SpecialKey.end, repeatable: true),
  KeySpec(label: 'PgUp', special: SpecialKey.pageUp, repeatable: true),
  KeySpec(label: 'PgDn', special: SpecialKey.pageDown, repeatable: true),
];

/// One keycap in the layout grid (char, special, span, repeatable flag —
/// Doc 37 §3).
class KeySpec {
  const KeySpec({
    required this.label,
    this.char,
    this.special,
    this.span = 1,
    this.repeatable = false,
  });

  /// Visible keycap text.
  final String label;

  /// Printable character (null for special keys).
  final String? char;

  /// Named special key (null for printable chars).
  final SpecialKey? special;

  /// Row width in flex units (Space spans 4 per the §4 page map).
  final int span;

  /// Whether this key participates in the 25 Hz hold-repeat cadence.
  final bool repeatable;

  /// Stable identity used for widget keys: `kbd_<id>`.
  String get id {
    if (special != null) {
      return special!.name;
    }
    if (char != null && char!.trim().isNotEmpty) {
      return char!;
    }
    return label.toLowerCase();
  }
}

/// Active press bookkeeping for the hold-repeat state machine.
class _RepeatHold {
  Timer? delay;
  Timer? periodic;
  bool engaged = false;
}

/// Owns the outgoing text buffer, latched modifiers, and hold-repeat
/// timers (Doc 37 §3). Dispatch respects the Doc 31 connection gate: key
/// envelopes are dropped offline while printable text queues (flushed on
/// reconnect); repeat timers are force-stopped the moment the socket
/// leaves `connected`.
class KeyboardController extends ChangeNotifier {
  KeyboardController({
    WsClient? client,
    Future<void> Function(HapticPattern pattern)? playHaptic,
  }) : _client = client ?? WsClient.instance,
       _playHaptic = playHaptic ?? _noHaptics {
    _stateSub = _client.stateChanges.listen(_onConnectionState);
  }

  final WsClient _client;
  final Future<void> Function(HapticPattern pattern) _playHaptic;
  StreamSubscription<WsConnectionState>? _stateSub;

  bool _shiftLatched = false;
  bool _ctrlLatched = false;
  bool _altLatched = false;
  bool _winLatched = false;

  String _pendingText = '';
  Timer? _coalesceTimer;
  final Map<SpecialKey, _RepeatHold> _holds = <SpecialKey, _RepeatHold>{};

  /// Doc 31 seam; tests inject a fake client here.
  WsClient get client => _client;

  /// Doc 31 connected gate — key dispatch respects it (text queues instead).
  bool get connected => _client.state == WsConnectionState.connected;

  /// Characters waiting in the 50 ms coalesce window (drives the queued
  /// "queued N chars" pill while offline).
  int get pendingChars => _pendingText.length;

  /// True while a [startRepeat] press for [key] has engaged (first repeat
  /// dispatched, or Win latched). The sheet uses this to decide whether a
  /// finger-lift still owes a one-shot tap dispatch.
  bool repeatEngaged(SpecialKey key) => _holds[key]?.engaged ?? false;

  /// Whether the one-shot latch for [key] (Shift/Ctrl/Alt/Win) is armed.
  bool latchedFor(SpecialKey key) => switch (key) {
    SpecialKey.shift => _shiftLatched,
    SpecialKey.ctrl => _ctrlLatched,
    SpecialKey.alt => _altLatched,
    SpecialKey.win => _winLatched,
    _ => false,
  };

  /// Forwards one printable character via `SEND_TEXT`. Latched modifiers
  /// alter the emitted character (Shift+a → `A`, then unlatch) or promote
  /// it to a `SEND_COMBO` with the char's VK (Ctrl/Alt/Win, §4.3).
  void tapChar(String ch) {
    if (ch.isEmpty) {
      return;
    }
    _cue(HapticPattern.microTick);
    if (_ctrlLatched || _altLatched || _winLatched) {
      final int? vk = connected ? _charVk(ch) : null;
      if (vk != null) {
        _flushPending(); // buffered typing precedes the combo
        _sendCombo(vk, _activeModifiers());
        clearLatches();
        notifyListeners();
        return;
      }
      // No VK (emoji / exotic punct) or offline: degrade to queued text.
      clearLatches();
      notifyListeners();
    }
    String out = ch;
    if (_shiftLatched) {
      out = _applyShift(ch);
      _shiftLatched = false;
    }
    _pendingText += out;
    notifyListeners();
    if (_pendingText.length >= kKeyboardChunkChars) {
      _flushPending(); // 64-char cap: never exceed one envelope's budget
    } else {
      _coalesceTimer ??= Timer(kKeyboardCoalesceDelay, _onCoalesce);
    }
  }

  /// Maps [key] to its Win32 VK code (§5 table) and dispatches `SEND_KEY`
  /// (or `SEND_COMBO` when modifiers are latched / self-contained like
  /// Alt+F4). Shift/Ctrl/Alt toggle their latch instead of dispatching.
  void tapSpecial(SpecialKey key) {
    final Modifier? latch = switch (key) {
      SpecialKey.shift => Modifier.shift,
      SpecialKey.ctrl => Modifier.ctrl,
      SpecialKey.alt => Modifier.alt,
      _ => null,
    };
    if (latch != null) {
      latchModifier(latch);
      _cue(HapticPattern.microTick);
      return;
    }
    if (!connected) {
      return; // key envelopes are never queued (only the char buffer is)
    }
    _flushPending(); // typing order ahead of this key event
    if (key == SpecialKey.altF4) {
      // Self-contained: ignores and does not consume any latches (§4.6).
      _sendCombo(115, const <String>['ALT']); // F4 VK = 115
      _cue(HapticPattern.microTick);
      return;
    }
    final int? vk = kSpecialKeyVks[key];
    if (vk == null) {
      return;
    }
    final List<String> modifiers = _activeModifiers(
      includeWin: key != SpecialKey.win,
    );
    if (modifiers.isEmpty) {
      _sendKey(vk);
    } else {
      _sendCombo(vk, modifiers);
      clearLatches(); // consumed by this press
    }
    _cue(
      key == SpecialKey.enter || key == SpecialKey.esc
          ? HapticPattern.heavyThud
          : HapticPattern.microTick,
    );
    notifyListeners();
  }

  /// Toggles a one-shot modifier latch (visual underline until consumed).
  void latchModifier(Modifier m) {
    switch (m) {
      case Modifier.shift:
        _shiftLatched = !_shiftLatched;
      case Modifier.ctrl:
        _ctrlLatched = !_ctrlLatched;
      case Modifier.alt:
        _altLatched = !_altLatched;
    }
    notifyListeners();
  }

  /// Starts hold-repeat bookkeeping for [key]: after [kKeyboardRepeatDelay]
  /// the first `SEND_KEY` fires (repeatable keys), then repeats every
  /// [kKeyboardRepeatInterval] until [stopRepeat]. Win latches instead of
  /// repeating so the next key becomes `SEND_COMBO … WIN` (§4.5).
  void startRepeat(SpecialKey key) {
    if (!connected || _holds.containsKey(key)) {
      return;
    }
    final _RepeatHold hold = _RepeatHold();
    _holds[key] = hold;
    hold.delay = Timer(kKeyboardRepeatDelay, () {
      if (!identical(_holds[key], hold)) {
        return;
      }
      if (key == SpecialKey.win) {
        _winLatched = true;
        hold.engaged = true;
        _cue(HapticPattern.microTick);
        notifyListeners();
        return;
      }
      if (!kRepeatableKeys.contains(key)) {
        return; // non-repeatable: the release path dispatches the tap
      }
      hold.engaged = true;
      _dispatchRepeat(key, first: true);
      hold.periodic = Timer.periodic(kKeyboardRepeatInterval, (Timer timer) {
        if (!identical(_holds[key], hold)) {
          timer.cancel();
          return;
        }
        _dispatchRepeat(key);
      });
    });
  }

  /// Stops auto-repeat for [key]; no dispatch if the press was a tap (the
  /// sheet's release path issues the one-shot `SEND_KEY` itself).
  void stopRepeat(SpecialKey key) {
    final _RepeatHold? hold = _holds.remove(key);
    hold?.delay?.cancel();
    hold?.periodic?.cancel();
  }

  /// Stops every active hold — used on disconnect (Doc 37 §7) and when the
  /// sheet closes / the backdrop dismisses mid-repeat.
  void stopAllRepeats() {
    for (final SpecialKey key in _holds.keys.toList(growable: false)) {
      stopRepeat(key);
    }
  }

  /// Clears all one-shot latches — no phantom Ctrl can stay stuck (§4.6 /
  /// §7). Called on consumption and on sheet close.
  void clearLatches() {
    _shiftLatched = false;
    _ctrlLatched = false;
    _altLatched = false;
    _winLatched = false;
    notifyListeners();
  }

  /// Human-readable latch summary for the status strip, e.g. `Ctrl+Shift`
  /// or `` when nothing is armed.
  String describeLatched() {
    final List<String> parts = <String>[];
    if (_ctrlLatched) {
      parts.add('Ctrl');
    }
    if (_altLatched) {
      parts.add('Alt');
    }
    if (_shiftLatched) {
      parts.add('Shift');
    }
    if (_winLatched) {
      parts.add('Win');
    }
    return parts.join('+');
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _stateSub = null;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    stopAllRepeats();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _onConnectionState(WsConnectionState state) {
    if (state == WsConnectionState.connected) {
      _flushPending(); // queued chars flush on reconnect (§7), once
    } else {
      stopAllRepeats(); // force-stop repeats offline; nothing replays later
    }
    notifyListeners();
  }

  void _onCoalesce() {
    _coalesceTimer = null;
    _flushPending();
  }

  void _flushPending() {
    if (_pendingText.isEmpty || !connected) {
      return;
    }
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    final String buffer = _pendingText;
    _pendingText = '';
    for (int i = 0; i < buffer.length; i += kKeyboardChunkChars) {
      final int end = math.min(i + kKeyboardChunkChars, buffer.length);
      _client.send(
        typeCmdKey,
        Action.sendText,
        <String, dynamic>{'text': buffer.substring(i, end)},
      );
    }
    notifyListeners();
  }

  void _dispatchRepeat(SpecialKey key, {bool first = false}) {
    if (!connected) {
      return;
    }
    _flushPending();
    final int? vk = kSpecialKeyVks[key];
    if (vk == null) {
      return;
    }
    _sendKey(vk); // same envelope re-sent — no KEY_REPEAT in the freeze
    if (first) {
      _cue(
        key == SpecialKey.enter || key == SpecialKey.esc
            ? HapticPattern.heavyThud
            : HapticPattern.microTick,
      );
    }
  }

  void _sendKey(int vk) {
    _client.send(typeCmdKey, Action.sendKey, <String, dynamic>{'vk': vk});
  }

  void _sendCombo(int vk, List<String> modifiers) {
    _client.send(
      typeCmdKey,
      Action.sendCombo,
      <String, dynamic>{'vk': vk, 'modifiers': modifiers},
    );
  }

  /// Modifiers in a fixed dedup-free order (max 4, no dupes — §5).
  List<String> _activeModifiers({bool includeWin = true}) {
    final List<String> modifiers = <String>[];
    if (_ctrlLatched) {
      modifiers.add('CTRL');
    }
    if (_altLatched) {
      modifiers.add('ALT');
    }
    if (_shiftLatched) {
      modifiers.add('SHIFT');
    }
    if (includeWin && _winLatched) {
      modifiers.add('WIN');
    }
    return modifiers;
  }

  void _cue(HapticPattern pattern) {
    try {
      _playHaptic(pattern);
    } on Object {
      // Haptics are best-effort; a failed cue must never block a keystroke.
    }
  }

  /// Win32 VK for a printable char (letters use their uppercase ASCII VK),
  /// or null when the char has no US-QWERTY VK mapping.
  int? _charVk(String ch) {
    if (ch.length != 1) {
      return null;
    }
    final String upper = ch.toUpperCase();
    if (upper.length == 1) {
      final int code = upper.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        return code; // A–Z
      }
      if (code >= 48 && code <= 57) {
        return code; // 0–9
      }
    }
    return kCharVks[ch];
  }

  /// Client-side US-QWERTY Shift translation (letters upper-cased, digit
  /// row punctuation shifted; everything else passes through).
  String _applyShift(String ch) {
    if (ch.length != 1) {
      return ch;
    }
    final int code = ch.codeUnitAt(0);
    if (code >= 97 && code <= 122) {
      return ch.toUpperCase();
    }
    return kShiftedPunct[ch] ?? ch;
  }

  static Future<void> _noHaptics(HapticPattern pattern) async {}
}

/// Module controller seam: widget tests override this with a real
/// controller wired to a fake Doc 31 client and fake Doc 42 haptics.
final Provider<KeyboardController> keyboardControllerProvider =
    Provider<KeyboardController>((ref) {
      final KeyboardController controller = KeyboardController(
        playHaptic: (HapticPattern pattern) async {
          try {
            await ref.read(hapticEngineProvider).play(pattern);
          } on Object {
            // Doc 42 engine is wired in main; haptics are best-effort and
            // must never block a keystroke.
          }
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Presenter: opens the modal bottom sheet over the current screen.
Future<void> showFullKeyboardSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.background, // pure #000000 (Doc 29)
    elevation: 0,
    isScrollControlled: true,
    builder: (BuildContext context) => const FullKeyboardSheet(),
  );
}

/// Root stateful widget rendering the keyboard from a declarative key map
/// (Doc 37 §3). Top strip: file-title caption + live 40-char echo line +
/// dismiss; below: F-row, QWERTY block, nav cluster.
class FullKeyboardSheet extends ConsumerStatefulWidget {
  const FullKeyboardSheet({super.key});

  @override
  ConsumerState<FullKeyboardSheet> createState() => _FullKeyboardSheetState();
}

class _FullKeyboardSheetState extends ConsumerState<FullKeyboardSheet> {
  late KeyboardController _controller;
  String _echo = '';

  @override
  void initState() {
    super.initState();
    _controller = ref.read(keyboardControllerProvider);
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    // Sheet close / backdrop dismiss during repeat: stop every hold and
    // clear latches so no phantom Ctrl survives on the PC (§7).
    _controller.stopAllRepeats();
    _controller.clearLatches();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _appendToEcho(String ch) {
    final String next = _echo + ch;
    setState(() {
      _echo = next.length <= kKeyboardEchoChars
          ? next
          : next.substring(next.length - kKeyboardEchoChars);
    });
  }

  void _handlePress(KeySpec spec) {
    final SpecialKey? special = spec.special;
    if (special != null) {
      _controller.startRepeat(special);
    }
  }

  void _handleRelease(KeySpec spec) {
    final SpecialKey? special = spec.special;
    if (special != null) {
      final bool engaged = _controller.repeatEngaged(special);
      _controller.stopRepeat(special);
      if (!engaged) {
        _controller.tapSpecial(special); // tap shorter than 400 ms
      }
      return;
    }
    final String? ch = spec.char;
    if (ch == null) {
      return;
    }
    _controller.tapChar(ch);
    _appendToEcho(ch);
  }

  void _handleCancel(KeySpec spec) {
    final SpecialKey? special = spec.special;
    if (special != null) {
      _controller.stopRepeat(special); // drag-off: press cancelled, nothing
    }
  }

  @override
  Widget build(BuildContext context) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight:
              MediaQuery.of(context).size.height * kKeyboardSheetHeightFactor,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(telemetry.fileTitle),
            _buildStatusStrip(),
            _buildFRow(),
            for (final List<KeySpec> row in qwertyRows) _buildRow(row),
            _buildRow(navRow),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String? fileTitle) {
    return Padding(
      key: const Key('kbd_header'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  fileTitle ?? '—',
                  key: const Key('kbd_caption'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              IconButton(
                key: const Key('kbd_dismiss'),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'Close',
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.close,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          Text(
            _echo,
            key: const Key('kbd_echo'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            style: AppTypography.label.copyWith(color: AppColors.amber),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusStrip() {
    final bool queued =
        _controller.pendingChars > 0 && !_controller.connected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: <Widget>[
          Text(
            _controller.describeLatched(),
            key: const Key('kbd_latch_status'),
            style: AppTypography.label.copyWith(
              color: AppColors.amber,
              fontSize: 11,
            ),
          ),
          const Spacer(),
          if (queued)
            Container(
              key: const Key('kbd_queue_pill'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.crimsonDim,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'queued ${_controller.pendingChars} chars',
                style: AppTypography.label.copyWith(fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double natural = constraints.maxWidth / kFRowKeyCount;
          // Portrait ≥360 dp: shrink to fit; below 360 dp: hold the 34 dp
          // minimum and let the row scroll horizontally (§7). Measured on
          // the screen width so the 2 dp row padding doesn't flip the branch.
          final bool narrow = MediaQuery.sizeOf(context).width < 360;
          final double keyWidth = narrow
              ? math.max(kKeyCapWidth, natural)
              : math.min(natural, 56);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final KeySpec spec in fRow)
                  SizedBox(
                    width: keyWidth,
                    child: _buildKeyCap(spec),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRow(List<KeySpec> specs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: <Widget>[
          for (final KeySpec spec in specs)
            Expanded(flex: spec.span, child: _buildKeyCap(spec)),
        ],
      ),
    );
  }

  Widget _buildKeyCap(KeySpec spec) {
    final SpecialKey? special = spec.special;
    return Padding(
      padding: const EdgeInsets.all(1.5),
      child: KeyCap(
        key: ValueKey<String>('kbd_${spec.id}'),
        spec: spec,
        enabled: _controller.connected,
        latched: special != null && _controller.latchedFor(special),
        onPress: () => _handlePress(spec),
        onRelease: () => _handleRelease(spec),
        onCancel: () => _handleCancel(spec),
      ),
    );
  }
}

/// A single keycap in the layout grid: press → (optional) repeat engage →
/// release dispatch, with >10 dp drag-off cancelling the press entirely
/// (Doc 37 §4 state machine). Accent fill lingers 80 ms after release.
class KeyCap extends StatefulWidget {
  const KeyCap({
    super.key,
    required this.spec,
    required this.enabled,
    required this.latched,
    required this.onPress,
    required this.onRelease,
    required this.onCancel,
  });

  final KeySpec spec;

  /// False while the Doc 31 socket is offline — greyed out, inert.
  final bool enabled;

  /// True while this key's modifier latch is armed (amber underline).
  final bool latched;

  /// Pointer went down on an enabled key.
  final VoidCallback onPress;

  /// Pointer lifted without travelling past the cancel threshold.
  final VoidCallback onRelease;

  /// Pointer cancelled or travelled > [kKeyboardPressCancelDp].
  final VoidCallback onCancel;

  @override
  State<KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<KeyCap> {
  int? _pointer;
  Offset? _origin;
  bool _movedOff = false;
  bool _pressed = false;
  Timer? _flash;

  @override
  void dispose() {
    _flash?.cancel();
    super.dispose();
  }

  void _handleDown(PointerDownEvent event) {
    if (!widget.enabled || _pointer != null) {
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _movedOff = false;
    _flash?.cancel();
    _flash = null;
    setState(() {
      _pressed = true;
    });
    widget.onPress();
  }

  void _handleMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _movedOff || _origin == null) {
      return;
    }
    if ((event.position - _origin!).distance > kKeyboardPressCancelDp) {
      _movedOff = true;
      widget.onCancel();
    }
  }

  void _handleUp(PointerUpEvent event) {
    if (_pointer != event.pointer) {
      return;
    }
    final bool cancelled = _movedOff;
    _pointer = null;
    _origin = null;
    _movedOff = false;
    if (!cancelled) {
      widget.onRelease();
    }
    _flashPressed();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pointer != event.pointer) {
      return;
    }
    _pointer = null;
    _origin = null;
    _movedOff = false;
    widget.onCancel();
    _flashPressed();
  }

  void _flashPressed() {
    _flash?.cancel();
    _flash = Timer(kKeyboardKeyFlash, () {
      _flash = null;
      if (mounted) {
        setState(() {
          _pressed = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled;
    final bool pressed = _pressed && enabled;
    final Color edgeColor = pressed ? AppColors.crimsonDim : AppColors.outline;
    final bool underline = widget.latched && !pressed && enabled;
    final Color background = !enabled
        ? AppColors.surfaceHigh
        : pressed
        ? AppColors.crimson
        : AppColors.surface;
    final Color foreground = !enabled
        ? AppColors.textTertiary
        : pressed
        ? AppColors.onAccent
        : widget.latched
        ? AppColors.amber
        : AppColors.textPrimary;
    final String label = widget.spec.label;
    final double fontSize = label.length >= 5
        ? 9
        : label.length > 2
        ? 11
        : 13;
    return Listener(
      onPointerDown: _handleDown,
      onPointerMove: _handleMove,
      onPointerUp: _handleUp,
      onPointerCancel: _handlePointerCancel,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: Container(
          alignment: Alignment.center,
          width: double.infinity,
          height: kKeyCapHeight,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
            border: Border(
              top: BorderSide(color: edgeColor),
              left: BorderSide(color: edgeColor),
              right: BorderSide(color: edgeColor),
              bottom: BorderSide(
                color: underline ? AppColors.amber : edgeColor,
                width: underline ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              height: 1.0,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}
