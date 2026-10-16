// Doc 36 (deck redesign): the two reusable key renderers — [DeckButton]
// (one tactile key: OLED chrome, disabled styling, semantics) and
// [DeckGrid] (a data-driven 4-column row of [DeckKeySpec] cells). Both
// are pure presentation: gating and dispatch stay with the deck root.

import 'package:flutter/material.dart';

import '../../core/theme/oled_theme.dart';
import 'deck_actions.dart';

/// Shared OLED chrome (surface fill, 1-pt hairline, crimson primary
/// variant, dimmed disabled state) for deck keys and key-like controls.
class DeckButtonChrome extends StatelessWidget {
  const DeckButtonChrome({
    super.key,
    required this.enabled,
    required this.onPressed,
    required this.child,
    this.emphasis = false,
    this.semanticLabel,
  });

  final bool enabled;
  final VoidCallback onPressed;

  /// Content already composed and centered.
  final Widget child;

  /// Primary-action styling: crimson fill while enabled (Play/Pause).
  final bool emphasis;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bool filled = emphasis && enabled;
    return Material(
      color: filled ? AppColors.crimson : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: filled
            ? BorderSide.none
            : BorderSide(
                color: enabled
                    ? AppColors.outline
                    : AppColors.outline.withValues(alpha: 0.4),
              ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        enableFeedback: false,
        highlightColor: filled ? AppColors.crimsonDim : AppColors.surfaceHigh,
        child: semanticLabel == null
            ? child
            : Semantics(label: semanticLabel, child: child),
      ),
    );
  }
}

/// Single tactile key: [DeckButton] chrome + label/icon composition.
/// Disabled keys are silent rejects (Doc 42 owns haptics — feedback fires
/// from the controller only on an actual dispatch).
class DeckButton extends StatelessWidget {
  const DeckButton({
    super.key,
    required this.spec,
    required this.enabled,
    required this.onPressed,
    this.text,
    this.icon,
    this.iconSize,
    this.fontSize,
    this.stacked = false,
    this.emphasis = false,
    this.accent = false,
    this.semanticLabel,
  });

  final DeckKeySpec spec;
  final bool enabled;
  final VoidCallback onPressed;

  /// Overrides [DeckKeySpec.label]; `null` + [icon] renders icon-only
  /// (Play/Pause), `null` without [icon] falls back to the spec label.
  final String? text;
  final IconData? icon;
  final double? iconSize;
  final double? fontSize;

  /// Icon above the label (transport buttons) instead of beside it.
  final bool stacked;

  /// Primary-action styling (crimson fill while enabled).
  final bool emphasis;

  /// Tint the icon with the amber playback accent.
  final bool accent;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final String? label =
        text ?? (icon == null ? spec.label : null); // icon-only if no text
    final bool onCrimson = emphasis && enabled;
    final Color fg = enabled
        ? (onCrimson ? AppColors.onAccent : AppColors.textPrimary)
        : AppColors.textTertiary;
    final Color iconColor =
        accent && enabled && !onCrimson ? AppColors.amber : fg;
    final double resolvedIconSize = iconSize ?? 20;
    final double resolvedFontSize = fontSize ??
        (icon == null ? (spec.span >= 2 ? 30.0 : 15.0) : 13.0);
    final TextStyle style = AppTypography.label.copyWith(
      fontSize: resolvedFontSize,
      height: 1.1,
      fontWeight: emphasis ? FontWeight.w600 : FontWeight.w500,
      color: fg,
    );

    final Widget content;
    if (icon != null && label != null) {
      final List<Widget> parts = <Widget>[
        Icon(icon, size: resolvedIconSize, color: iconColor),
        stacked
            ? const SizedBox(height: 4)
            : const SizedBox(width: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ];
      content = stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: parts,
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: parts,
            );
    } else if (icon != null) {
      content = Icon(icon, size: resolvedIconSize, color: iconColor);
    } else {
      content = Text(
        label!,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    return DeckButtonChrome(
      enabled: enabled,
      onPressed: onPressed,
      emphasis: emphasis,
      semanticLabel: semanticLabel,
      child: Center(child: content),
    );
  }
}

/// Responsive N-column grid materialising a [DeckKeySpec] row (§3): four
/// logical columns with 8 dp gutters; `span` widens a cell.
class DeckGrid extends StatelessWidget {
  const DeckGrid({
    super.key,
    required this.specs,
    required this.onTap,
    this.enabled,
    this.iconFor,
    this.rowHeight = 48,
  });

  final List<DeckKeySpec> specs;
  final ValueChanged<DeckAction> onTap;
  final bool Function(DeckAction action)? enabled;
  final IconData? Function(DeckKeySpec spec)? iconFor;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    const double gutter = 8;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double colWidth = (constraints.maxWidth - 3 * gutter) / 4;
        final List<Widget> children = <Widget>[];
        for (int i = 0; i < specs.length; i++) {
          final DeckKeySpec spec = specs[i];
          final double width =
              colWidth * spec.span + gutter * (spec.span - 1);
          children.add(
            Padding(
              padding: EdgeInsets.only(
                right: i == specs.length - 1 ? 0 : gutter,
              ),
              child: SizedBox(
                width: width,
                height: rowHeight,
                child: DeckButton(
                  key: deckKeyFor(spec.action),
                  spec: spec,
                  text: spec.label,
                  icon: iconFor?.call(spec),
                  enabled: enabled?.call(spec.action) ?? true,
                  onPressed: () => onTap(spec.action),
                ),
              ),
            ),
          );
        }
        return Row(children: children);
      },
    );
  }
}
