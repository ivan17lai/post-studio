import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// Distances in unscaled canvas coordinates. Move neighbours only far enough
/// to clear the visible side space, and shrink the joining gap with that space.
({double gap, double hiddenDistance}) singlePageRevealGeometry({
  required double screenWidth,
  required double pageWidth,
  required double scale,
}) {
  final sideSpace = ((screenWidth - pageWidth * scale) / 2).clamp(
    0.0,
    double.infinity,
  );
  return (
    gap: sideSpace.clamp(0.0, 8.0) / scale,
    hiddenDistance: sideSpace / scale,
  );
}

/// Progress-driven with a gently eased retreat from the midpoint. Reversing
/// the swipe follows the exact same path, without an independent animation.
double singlePageRevealOffset({
  required double position,
  required int pageIndex,
  required double gap,
  required double hiddenDistance,
}) {
  final anchor = position.round();
  final retreat = (1 - 2 * (position - anchor).abs()).clamp(0.0, 1.0);
  // Start 35% slower than linear, but still reach the original resting offset.
  final hiddenAmount = retreat * (0.65 + 0.35 * retreat);
  return (pageIndex - position) * gap +
      (pageIndex - anchor) * (hiddenDistance - gap) * hiddenAmount;
}

/// The main page snaps normally. Only outward neighbour offsets ease after
/// release; direct dragging and the incoming/current page remain immediate.
class SinglePageReveal extends StatefulWidget {
  const SinglePageReveal({
    super.key,
    required this.controller,
    required this.touchActive,
    required this.pageIndex,
    required this.gap,
    required this.hiddenDistance,
    required this.child,
  });
  final PageController controller;
  final ValueListenable<bool> touchActive;
  final int pageIndex;
  final double gap;
  final double hiddenDistance;
  final Widget child;

  @override
  State<SinglePageReveal> createState() => _SinglePageRevealState();
}

class _SinglePageRevealState extends State<SinglePageReveal> {
  double? _previousTarget;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, widget.touchActive]),
    child: widget.child,
    builder: (context, child) {
      final position =
          widget.controller.hasClients &&
              widget.controller.position.hasContentDimensions
          ? widget.controller.page ?? widget.controller.initialPage.toDouble()
          : widget.controller.initialPage.toDouble();
      final scrollGap = (widget.pageIndex - position) * widget.gap;
      final target =
          singlePageRevealOffset(
            position: position,
            pageIndex: widget.pageIndex,
            gap: widget.gap,
            hiddenDistance: widget.hiddenDistance,
          ) -
          scrollGap;
      final previous = _previousTarget ?? target;
      final retreating =
          target != 0 &&
          target.abs() >= previous.abs() &&
          (previous == 0 || previous.sign == target.sign);
      _previousTarget = target;
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: target, end: target),
        duration: !widget.touchActive.value && retreating
            ? const Duration(milliseconds: 600)
            : Duration.zero,
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, extra, child) => Transform.translate(
          offset: Offset(scrollGap + extra, 0),
          child: child,
        ),
      );
    },
  );
}
