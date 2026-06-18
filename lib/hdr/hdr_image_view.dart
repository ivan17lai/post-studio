import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';

/// Displays an image preserving its Ultra HDR gain map.
///
/// On Android (with the global HDR setting enabled) this embeds a native
/// `ImageView` whose bitmap keeps the gain map, so HDR photos render with real
/// highlight headroom. Everywhere else — or when the user disabled HDR — it
/// falls back to a regular Flutter [Image] showing the SDR base rendition.
///
/// The native view is added via **hybrid composition**
/// ([PlatformViewsService.initExpensiveAndroidView]) rather than the default
/// texture-layer path. The texture-layer path copies the platform view into a
/// Flutter GL texture that is only 8-bit SDR, which tonemaps/clips the HDR
/// highlights away. Hybrid composition keeps the `ImageView` as a real Android
/// view in the hierarchy, so — with the window in HDR color mode — its gain-map
/// output reaches the screen with true HDR headroom.
///
/// When [sourceAspectRatio] > 0, the native view applies the same crop geometry
/// as Flutter's `_CroppedImageFile` using an image matrix, so the visible
/// region matches what the user set while still preserving HDR.
class HdrImageView extends StatelessWidget {
  const HdrImageView({
    required this.path,
    this.fit = BoxFit.fill,
    this.sourceAspectRatio = 0.0,
    this.cropOffsetX = 0.0,
    this.cropOffsetY = 0.0,
    this.cropScale = 1.0,
    super.key,
  });

  final String path;
  final BoxFit fit;

  /// The natural aspect ratio of the source image (width / height).
  /// Pass a positive value to enable crop-aware matrix positioning.
  final double sourceAspectRatio;
  final double cropOffsetX;
  final double cropOffsetY;
  final double cropScale;

  static const String _viewType = 'igapp/hdr_image_view';

  @override
  Widget build(BuildContext context) {
    final useNativeHdr =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        AppSettingsController.instance.hdrEnabled;
    if (!useNativeHdr) {
      return Image.file(File(path), fit: fit, gaplessPlayback: true);
    }

    final hasCrop = sourceAspectRatio > 0;
    final creationParams = <String, dynamic>{
      'path': path,
      'fit': fit == BoxFit.contain ? 'contain' : 'fill',
      if (hasCrop) 'sourceAspectRatio': sourceAspectRatio,
      if (hasCrop) 'cropOffsetX': cropOffsetX,
      if (hasCrop) 'cropOffsetY': cropOffsetY,
      if (hasCrop) 'cropScale': cropScale,
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
