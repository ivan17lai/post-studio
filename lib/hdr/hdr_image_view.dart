import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';

/// Displays an image preserving its Ultra HDR gain map.
///
/// On Android (with the global HDR setting enabled) this embeds a native
/// `ImageView` whose bitmap keeps the gain map, so HDR photos render with real
/// highlight headroom. Everywhere else — or when the user disabled HDR — it
/// falls back to a regular Flutter [Image] showing the SDR base rendition.
class HdrImageView extends StatelessWidget {
  const HdrImageView({required this.path, this.fit = BoxFit.fill, super.key});

  final String path;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final useNativeHdr =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        AppSettingsController.instance.hdrEnabled;
    if (useNativeHdr) {
      return AndroidView(
        viewType: 'igapp/hdr_image_view',
        creationParams: <String, dynamic>{
          'path': path,
          'fit': fit == BoxFit.contain ? 'contain' : 'fill',
        },
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return Image.file(File(path), fit: fit, gaplessPlayback: true);
  }
}
