// Doc 38 general timeline track (restored round 6, 2026-10-18): the
// quick, full-width seek bar at the TOP of the deck.  The bottom ruler
// (Doc 36 addendum) is the precision instrument; this track stays the
// fast general-purpose one — both drive the same [ScrubController].

import 'package:flutter/material.dart';

import '../../core/theme/oled_theme.dart';
import 'scrub_speed_hud.dart';

/// The draggable timeline track: rail + thumb painted by [_RailPainter],
/// horizontal-drag gestures (vertical hit-slop comes from Flutter's
/// horizontal recognizer, ~16 dp) forwarded to [dragController].
class ScrubTrack extends StatefulWidget {
  const ScrubTrack({
    super.key,
    required this.dragController,
    required this.preview,
  });

  final ScrubController dragController;
  final ScrubPreview preview;

  @override
  State<ScrubTrack> createState() => _ScrubTrackState();
}

class _ScrubTrackState extends State<ScrubTrack> {
  double _trackWidth = 1;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _trackWidth = constraints.maxWidth <= 0 ? 1 : constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (DragStartDetails details) =>
              widget.dragController.beginDrag(_trackWidth),
          onHorizontalDragUpdate: (DragUpdateDetails details) =>
              widget.dragController.updateDrag(details.primaryDelta ?? 0),
          onHorizontalDragEnd: (DragEndDetails details) =>
              widget.dragController.endDrag(),
          onHorizontalDragCancel: () => widget.dragController.cancelDrag(),
          child: SizedBox(
            height: 48, // comfortable gesture band around the 3 dp rail
            child: CustomPaint(
              size: Size.infinite, // fill the LayoutBuilder width
              painter: _RailPainter(widget.preview),
            ),
          ),
        );
      },
    );
  }
}

/// Rail (25 % amber) + elapsed fill (Doc 29 amber accent) + thumb
/// (14 dp, grows to 18 dp while dragging).
class _RailPainter extends CustomPainter {
  const _RailPainter(this.preview);

  final ScrubPreview preview;

  @override
  void paint(Canvas canvas, Size size) {
    final double midY = size.height / 2;
    const double railHeight = 3;
    const Radius radius = Radius.circular(railHeight / 2);
    final RRect track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, midY - railHeight / 2, size.width, railHeight),
      radius,
    );
    canvas.drawRRect(
      track,
      Paint()..color = AppColors.amber.withValues(alpha: 0.25),
    );

    if (preview.durationMs <= 0) {
      return; // zero/unknown duration: empty rail only (§7)
    }
    final double fraction = (preview.positionMs / preview.durationMs)
        .clamp(0.0, 1.0)
        .toDouble();
    if (fraction > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            0,
            midY - railHeight / 2,
            size.width * fraction,
            railHeight,
          ),
          radius,
        ),
        Paint()..color = AppColors.amber,
      );
    }

    final double thumbRadius = preview.dragging ? 9 : 7; // 18 dp / 14 dp
    final double minX = thumbRadius;
    final double maxX = size.width - thumbRadius;
    final double x = maxX <= minX
        ? size.width / 2
        : (size.width * fraction).clamp(minX, maxX);
    canvas.drawCircle(
      Offset(x, midY),
      thumbRadius,
      Paint()..color = AppColors.amber,
    );
  }

  @override
  bool shouldRepaint(_RailPainter oldDelegate) =>
      oldDelegate.preview != preview;
}
