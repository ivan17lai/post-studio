import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How exported pages treat HDR data.
enum HdrExportMode {
  /// Plain SDR JPEG — no gain map is attached.
  off,

  /// Gain maps from Ultra HDR sources are preserved; SDR content stays neutral.
  on,

  /// Like [on], but SDR images additionally get a synthesized highlight boost.
  enhanced;

  /// Wire value understood by the native page renderer.
  String get payloadValue => switch (this) {
    HdrExportMode.off => 'off',
    HdrExportMode.on => 'on',
    HdrExportMode.enhanced => 'enhanced',
  };
}

/// Device-side Ultra HDR capabilities reported by the platform.
class HdrCapabilities {
  const HdrCapabilities({
    required this.supportsGainmap,
    required this.apiLevel,
    required this.windowColorModeHdr,
  });

  static const HdrCapabilities unsupported = HdrCapabilities(
    supportsGainmap: false,
    apiLevel: 0,
    windowColorModeHdr: false,
  );

  final bool supportsGainmap;
  final int apiLevel;
  final bool windowColorModeHdr;
}

/// Dart-side gateway to the native Ultra HDR support (Android 14+).
///
/// Every method degrades gracefully on other platforms or older Android
/// versions, so callers can use it unconditionally.
class UltraHdr {
  UltraHdr._();

  static const MethodChannel _channel = MethodChannel('igapp/hdr');

  static HdrCapabilities? _cachedCapabilities;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<HdrCapabilities> capabilities() async {
    final cached = _cachedCapabilities;
    if (cached != null) {
      return cached;
    }
    if (!_isAndroid) {
      return _cachedCapabilities = HdrCapabilities.unsupported;
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      final caps = HdrCapabilities(
        supportsGainmap: raw?['supportsGainmap'] as bool? ?? false,
        apiLevel: (raw?['apiLevel'] as num?)?.toInt() ?? 0,
        windowColorModeHdr: raw?['windowColorModeHdr'] as bool? ?? false,
      );
      return _cachedCapabilities = caps;
    } on PlatformException {
      return _cachedCapabilities = HdrCapabilities.unsupported;
    } on MissingPluginException {
      return _cachedCapabilities = HdrCapabilities.unsupported;
    }
  }

  /// Whether [path] is an Ultra HDR image this device can actually use.
  static Future<bool> isUltraHdrFile(String path) async {
    if (!_isAndroid || path.isEmpty) {
      return false;
    }
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'inspectImage',
        <String, dynamic>{'path': path},
      );
      return info?['isUltraHdr'] as bool? ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Switches the Android window between HDR and default color mode so gain
  /// map images actually light up beyond SDR white. No-op elsewhere.
  static Future<void> setWindowHdrColorMode(bool enabled) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('setHdrColorMode', <String, dynamic>{
        'enabled': enabled,
      });
      final cached = _cachedCapabilities;
      if (cached != null) {
        _cachedCapabilities = HdrCapabilities(
          supportsGainmap: cached.supportsGainmap,
          apiLevel: cached.apiLevel,
          windowColorModeHdr: enabled && cached.supportsGainmap,
        );
      }
    } on PlatformException {
      // Ignore: the device simply keeps its current color mode.
    } on MissingPluginException {
      // Ignore: not running against the native host (e.g. tests).
    }
  }
}
