import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

class _PhotoScaleRecognizer extends ScaleGestureRecognizer {
  final _touches = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _touches.add(event.pointer);
    super.addAllowedPointer(event);
    // Claim a two-finger gesture before a horizontal page drag reaches slop.
    if (_touches.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touches.remove(event.pointer);
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _touches.clear();
    super.didStopTrackingLastPointer(pointer);
  }
}

/// One finger moves the photo; two fingers scale it. After a pinch, lifting
/// one finger must not accidentally turn the remaining finger into a drag.
class PhotoGestureSurface extends StatefulWidget {
  const PhotoGestureSurface({
    super.key,
    required this.child,
    required this.onStart,
    required this.onMove,
    required this.onPinch,
    required this.onEnd,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
  });
  final Widget child;
  final VoidCallback onStart;
  final ValueChanged<Offset> onMove;
  final ValueChanged<double> onPinch;
  final ValueChanged<bool> onEnd;
  final VoidCallback? onTap, onDoubleTap, onLongPress;

  @override
  State<PhotoGestureSurface> createState() => _PhotoGestureSurfaceState();
}

class _PhotoGestureSurfaceState extends State<PhotoGestureSurface> {
  final _touches = <int>{};
  bool _pinched = false;
  bool _active = false;
  int _pointers = 0;
  double _segmentScale = 1;
  double _segmentValue = 1;
  double _value = 1;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => _touches.add(event.pointer),
    onPointerUp: _releasePointer,
    onPointerCancel: _releasePointer,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.onLongPress,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          _PhotoScaleRecognizer:
              GestureRecognizerFactoryWithHandlers<_PhotoScaleRecognizer>(
                _PhotoScaleRecognizer.new,
                (recognizer) => recognizer
                  ..onStart = _onStart
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd,
              ),
        },
        child: widget.child,
      ),
    ),
  );

  void _releasePointer(PointerEvent event) {
    _touches.remove(event.pointer);
    if (_touches.isEmpty) _finish();
  }

  void _finish() {
    if (!_active) return;
    _active = false;
    widget.onEnd(_pinched);
  }

  void _onStart(ScaleStartDetails details) {
    if (!_active) {
      _active = true;
      _pinched = false;
      _value = 1;
      widget.onStart();
    }
    _pinched = _pinched || details.pointerCount >= 2;
    _pointers = details.pointerCount;
    _segmentScale = 1;
    _segmentValue = _value;
  }

  void _onUpdate(ScaleUpdateDetails details) {
    if (_pointers != details.pointerCount) {
      _pointers = details.pointerCount;
      _segmentScale = details.scale;
      _segmentValue = _value;
    }
    if (_pointers >= 2) {
      _pinched = true;
      if (_segmentScale <= 0) return;
      _value = _segmentValue * details.scale / _segmentScale;
      widget.onPinch(_value);
    } else if (!_pinched) {
      final box = context.findRenderObject()! as RenderBox;
      final delta =
          box.globalToLocal(details.focalPoint) -
          box.globalToLocal(details.focalPoint - details.focalPointDelta);
      widget.onMove(delta);
    }
  }

  void _onEnd(ScaleEndDetails details) {
    if (details.pointerCount != 0) return;
    _finish();
  }
}
