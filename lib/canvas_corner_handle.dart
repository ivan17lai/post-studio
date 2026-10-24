import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// A corner dot with an unscaled touch target in the canvas overlay.
class CanvasCornerHandle extends StatefulWidget {
  const CanvasCornerHandle({
    super.key,
    required this.visible,
    required this.direction,
    required this.photoSize,
    required this.color,
    required this.onStart,
    required this.onScale,
    required this.onEnd,
  });
  final bool visible;
  final Offset direction;
  final Size photoSize;
  final Color color;
  final VoidCallback onStart, onEnd;
  final ValueChanged<double> onScale;

  @override
  State<CanvasCornerHandle> createState() => _CanvasCornerHandleState();
}

class _CanvasCornerHandleState extends State<CanvasCornerHandle> {
  final _portal = OverlayPortalController();
  bool _dragging = false;
  Offset _start = Offset.zero;
  Offset _vector = Offset.zero;

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  void _end() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    child: const SizedBox.shrink(),
    overlayChildBuilder: (context, info) {
      if (!widget.visible && !_dragging) return const SizedBox.shrink();
      final corner = MatrixUtils.transformPoint(
        info.childPaintTransform,
        Offset.zero,
      );
      final bounds = Offset.zero & info.overlaySize;
      if ((!_dragging && !bounds.inflate(0.5).contains(corner)) ||
          info.overlaySize.shortestSide < 52) {
        return const SizedBox.shrink();
      }
      final center = Offset(
        corner.dx.clamp(26, info.overlaySize.width - 26),
        corner.dy.clamp(26, info.overlaySize.height - 26),
      );
      return Positioned(
        left: center.dx - 26,
        top: center.dy - 26,
        width: 52,
        height: 52,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (details) {
            _dragging = true;
            _start = details.globalPosition;
            _vector =
                MatrixUtils.transformPoint(
                  info.childPaintTransform,
                  Offset(
                    widget.direction.dx * widget.photoSize.width,
                    widget.direction.dy * widget.photoSize.height,
                  ),
                ) -
                corner;
            widget.onStart();
          },
          onPanUpdate: (details) {
            final delta = details.globalPosition - _start;
            final length = _vector.distanceSquared;
            if (length == 0) return;
            widget.onScale(
              (1 + (delta.dx * _vector.dx + delta.dy * _vector.dy) / length)
                  .clamp(0.01, 100),
            );
          },
          onPanEnd: (_) => _end(),
          onPanCancel: _end,
          child: Center(
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: widget.color, width: 2),
              ),
            ),
          ),
        ),
      );
    },
  );
}
