import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';

/// Displays an image preserving its Ultra HDR gain map, with live per-image
/// "deep adjust" parameters.
///
/// On Android (HDR enabled) this embeds a native `ImageView` via **hybrid
/// composition** so the gain map's HDR headroom reaches the screen. Adjustment
/// parameters (HDR brightness, colour matrix, highlights/shadows, HDR/SDR view)
/// are pushed over a per-view [MethodChannel] after creation, so changing a
/// slider updates the existing view in place — no platform-view recreation, no
/// flicker. The platform view is only rebuilt when the path or crop changes.
///
/// Everywhere else (or HDR disabled) it falls back to a Flutter [Image].
class HdrImageView extends StatefulWidget {
  const HdrImageView({
    required this.path,
    this.fit = BoxFit.fill,
    this.sourceAspectRatio = 0.0,
    this.cropOffsetX = 0.0,
    this.cropOffsetY = 0.0,
    this.cropScale = 1.0,
    this.hdrBrightness = 1.0,
    this.colorMatrix,
    this.highlights = 0.0,
    this.shadows = 0.0,
    this.hdrView = true,
    super.key,
  });

  final String path;
  final BoxFit fit;
  final double sourceAspectRatio;
  final double cropOffsetX;
  final double cropOffsetY;
  final double cropScale;
  final double hdrBrightness;
  final List<double>? colorMatrix;
  final double highlights;
  final double shadows;

  /// When false, the native view drops the gain map and shows the SDR base —
  /// the live "HDR/SDR view" toggle.
  final bool hdrView;

  @override
  State<HdrImageView> createState() => _HdrImageViewState();
}

class _HdrImageViewState extends State<HdrImageView> {
  static const String _viewType = 'igapp/hdr_image_view';
  MethodChannel? _channel;

  bool get _useNativeHdr =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      AppSettingsController.instance.hdrEnabled;

  Map<String, dynamic> _adjustParams() => <String, dynamic>{
    'hdrBrightness': widget.hdrBrightness,
    'colorMatrix': (widget.colorMatrix != null && widget.colorMatrix!.length == 20)
        ? widget.colorMatrix
        : null,
    'highlights': widget.highlights,
    'shadows': widget.shadows,
    'hdrView': widget.hdrView,
  };

  @override
  void didUpdateWidget(HdrImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.hdrBrightness != widget.hdrBrightness ||
        oldWidget.highlights != widget.highlights ||
        oldWidget.shadows != widget.shadows ||
        oldWidget.hdrView != widget.hdrView ||
        !listEquals(oldWidget.colorMatrix, widget.colorMatrix);
    if (changed) {
      _channel?.invokeMethod<void>('setParams', _adjustParams());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_useNativeHdr) {
      return Image.file(File(widget.path), fit: widget.fit, gaplessPlayback: true);
    }

    final hasCrop = widget.sourceAspectRatio > 0;
    final creationParams = <String, dynamic>{
      'path': widget.path,
      'fit': widget.fit == BoxFit.contain ? 'contain' : 'fill',
      ..._adjustParams(),
      if (hasCrop) 'sourceAspectRatio': widget.sourceAspectRatio,
      if (hasCrop) 'cropOffsetX': widget.cropOffsetX,
      if (hasCrop) 'cropOffsetY': widget.cropOffsetY,
      if (hasCrop) 'cropScale': widget.cropScale,
    };

    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (params) {
        _channel = MethodChannel('igapp/hdr_image_view/${params.id}');
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener(
          params.onPlatformViewCreated,
        );
        controller.create();
        return controller;
      },
    );
  }
}
