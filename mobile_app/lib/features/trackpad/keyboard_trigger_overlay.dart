// Doc 37 companion (round 6, 2026-10-18): phone-OS-keyboard bridge for
// the trackpad screen — the "open keyboard" trigger zone from the user
// brief.  Tapping the chip focuses a hidden 1x1 [TextField], so Flutter's
// EditableText owns the IME connection (show/hide/composing/reconnect);
// every edit is diffed against the last sent value and forwarded through
// the shared [KeyboardController] (Doc 37): appends -> coalesced
// `SEND_TEXT`, deletions -> `SEND_KEY` backspaces, submit -> Enter.
//
// Design notes:
//   * The chip is the only hit-testable child of this Stack, so taps on
//     it never reach the trackpad underneath (no phantom cursor moves);
//   * the hidden field ignores pointers entirely — it is focused only
//     programmatically (`FocusNode.requestFocus`);
//   * the controller queues chars while WS is down (Doc 37 §7) but drops
//     key envelopes — same contract as the full keyboard sheet.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/oled_theme.dart';
import '../keyboard/full_keyboard.dart';

/// Self-contained trigger chip + hidden input bridge.  Callers position it
/// (the shell docks it top-right over the trackpad).
class KeyboardTriggerOverlay extends ConsumerStatefulWidget {
  const KeyboardTriggerOverlay({super.key});

  @override
  ConsumerState<KeyboardTriggerOverlay> createState() =>
      _KeyboardTriggerOverlayState();
}

class _KeyboardTriggerOverlayState
    extends ConsumerState<KeyboardTriggerOverlay> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'os_keyboard_bridge');
  final TextEditingController _text = TextEditingController();

  /// Local echo of everything already forwarded to the PC; the delta
  /// between this and the field's value drives the next dispatch.
  String _lastSent = '';

  @override
  void initState() {
    super.initState();
    // Rebuild on open/close so the chip flips its icon.
    _focusNode.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _text.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_focusNode.hasFocus) {
      _focusNode.unfocus(); // chip acts as close while the IME is up
    } else {
      _focusNode.requestFocus();
    }
  }

  /// Diffs [value] against the last forwarded state: removes the diverged
  /// suffix as backspaces, then appends the new runes one by one (the
  /// controller coalesces them into <=64-char `SEND_TEXT` envelopes).
  void _onChanged(String value) {
    final KeyboardController controller = ref.read(keyboardControllerProvider);
    final String old = _lastSent;
    if (value == old) {
      return;
    }
    int common = 0;
    final int limit = math.min(old.length, value.length);
    while (common < limit &&
        old.codeUnitAt(common) == value.codeUnitAt(common)) {
      common++;
    }
    final int removed = old.length - common;
    for (int i = 0; i < removed; i++) {
      controller.tapSpecial(SpecialKey.backspace);
    }
    for (final int rune in value.substring(common).runes) {
      controller.tapChar(String.fromCharCode(rune));
    }
    _lastSent = value;
  }

  /// Submit forwards Enter (search boxes, confirmed dialogs) and keeps the
  /// field focused — the IME's own action hides itself if it wants to.
  void _onSubmitted(String value) {
    ref.read(keyboardControllerProvider).tapSpecial(SpecialKey.enter);
  }

  @override
  Widget build(BuildContext context) {
    final KeyboardController controller = ref.read(keyboardControllerProvider);
    return Stack(
      children: <Widget>[
        // Hidden bridge: never pointer-hit (IgnorePointer + sits behind
        // the chip); focus is purely programmatic.
        IgnorePointer(
          child: SizedBox(
            width: 1,
            height: 1,
            child: TextField(
              key: const Key('trackpad_keyboard_input'),
              focusNode: _focusNode,
              controller: _text,
              onChanged: _onChanged,
              onSubmitted: _onSubmitted,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration.collapsed(hintText: ''),
            ),
          ),
        ),
        ListenableBuilder(
          // The controller is a ChangeNotifier; only this builder reacts
          // to connection flips (a plain provider watch would not).
          listenable: controller,
          builder: (BuildContext context, Widget? _) {
            final bool open = _focusNode.hasFocus;
            final bool connected = controller.connected;
            final Color fg = !connected
                ? AppColors.textTertiary
                : (open ? AppColors.crimson : AppColors.amber);
            return Semantics(
              button: true,
              label: open
                  ? 'Close phone keyboard'
                  : 'Open phone keyboard for the PC',
              child: Material(
                color: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: open ? AppColors.crimson : AppColors.outline,
                  ),
                ),
                child: InkWell(
                  key: const Key('trackpad_keyboard_trigger'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: _toggle,
                  child: SizedBox(
                    width: 48, // comfortable trigger zone (WCAG target)
                    height: 48,
                    child: Icon(
                      open ? Icons.keyboard_hide : Icons.keyboard,
                      size: 24,
                      color: fg,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
