import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@JS('postStudioMedia.attach')
external _HdrSurface _attach(JSObject element, JSAny? options);
extension type _HdrSurface(JSObject _) implements JSObject {
  external void update(JSAny? options);
  external void dispose();
}

/// Only the image pixels use a browser surface. All controls and geometry stay in Flutter.
class HdrImageView extends StatefulWidget {
  const HdrImageView({
    required this.path,
    this.fit = BoxFit.fill,
    this.sourceAspectRatio = 0,
    this.cropOffsetX = 0,
    this.cropOffsetY = 0,
    this.cropScale = 1,
    this.hdrBrightness = 1,
    this.colorMatrix,
    this.highlights = 0,
    this.shadows = 0,
    this.hdrView = true,
    super.key,
  });
  final String path;
  final BoxFit fit;
  final double sourceAspectRatio,
      cropOffsetX,
      cropOffsetY,
      cropScale,
      hdrBrightness,
      highlights,
      shadows;
  final List<double>? colorMatrix;
  final bool hdrView;
  @override
  State<HdrImageView> createState() => _HdrImageViewState();
}

class _HdrImageViewState extends State<HdrImageView> {
  _HdrSurface? _surface;
  JSAny? get _options => <String, dynamic>{
    'path': widget.path,
    'fit': widget.fit == BoxFit.contain ? 'contain' : 'fill',
    'sourceAspectRatio': widget.sourceAspectRatio,
    'cropOffsetX': widget.cropOffsetX,
    'cropOffsetY': widget.cropOffsetY,
    'cropScale': widget.cropScale,
    'hdrBrightness': widget.hdrBrightness,
    'colorMatrix': widget.colorMatrix,
    'highlights': widget.highlights,
    'shadows': widget.shadows,
    'hdrView': widget.hdrView,
  }.jsify();
  @override
  void didUpdateWidget(HdrImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path == widget.path &&
        oldWidget.fit == widget.fit &&
        oldWidget.sourceAspectRatio == widget.sourceAspectRatio &&
        oldWidget.cropOffsetX == widget.cropOffsetX &&
        oldWidget.cropOffsetY == widget.cropOffsetY &&
        oldWidget.cropScale == widget.cropScale &&
        oldWidget.hdrBrightness == widget.hdrBrightness &&
        oldWidget.highlights == widget.highlights &&
        oldWidget.shadows == widget.shadows &&
        oldWidget.hdrView == widget.hdrView &&
        listEquals(oldWidget.colorMatrix, widget.colorMatrix)) {
      return;
    }
    _surface?.update(_options);
  }

  @override
  void dispose() {
    _surface?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'div',
    isVisible: true,
    onElementCreated: (element) =>
        _surface = _attach(element as JSObject, _options),
  );
}
