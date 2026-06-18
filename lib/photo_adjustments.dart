import 'dart:math' as math;

/// Per-photo colour adjustments ("深度調整").
///
/// Every value is neutral at 0 and ranges -1..1 (the UI shows -100..100). The
/// adjustments compile down to a single 4x5 colour matrix ([toColorMatrix]) so
/// the exact same transform can be applied in three places:
///  - the Flutter editor canvas (`ColorFiltered` / `ColorFilter.matrix`),
///  - the native HDR preview (`ColorMatrixColorFilter` on the `ImageView`),
///  - the native exporter (`ColorMatrixColorFilter` on the draw `Paint`).
///
/// Keeping the matrix as the single source of truth (computed here, passed to
/// the native side as 20 floats) avoids the math drifting between platforms.
class PhotoAdjustments {
  const PhotoAdjustments({
    this.brightness = 0.0,
    this.contrast = 0.0,
    this.saturation = 0.0,
    this.highlights = 0.0,
    this.shadows = 0.0,
    this.temperature = 0.0,
    this.tint = 0.0,
  });

  /// Additive brightness. -1..1.
  final double brightness;

  /// Contrast around mid-grey. -1..1 (factor 0..2).
  final double contrast;

  /// Saturation. -1..1 (factor 0..2; -1 = greyscale).
  final double saturation;

  /// Highlights: brightens/darkens bright tones. -1..1. Non-linear (a
  /// luminance-weighted tone curve), so it is applied as a per-pixel pass on
  /// the native side rather than via [toColorMatrix].
  final double highlights;

  /// Shadows: lifts/deepens dark tones. -1..1. Same tone-curve treatment as
  /// [highlights].
  final double shadows;

  /// White balance warm/cool. -1 cool (more blue) .. 1 warm (more red).
  final double temperature;

  /// White balance green/magenta. -1 green .. 1 magenta.
  final double tint;

  static const PhotoAdjustments neutral = PhotoAdjustments();

  /// The linear (colour-matrix) part — everything except the tone curve.
  bool get hasMatrix =>
      brightness != 0.0 ||
      contrast != 0.0 ||
      saturation != 0.0 ||
      temperature != 0.0 ||
      tint != 0.0;

  /// The non-linear tone-curve part (highlights/shadows).
  bool get hasToneCurve => highlights != 0.0 || shadows != 0.0;

  bool get isNeutral => !hasMatrix && !hasToneCurve;

  PhotoAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? highlights,
    double? shadows,
    double? temperature,
    double? tint,
  }) {
    return PhotoAdjustments(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      highlights: highlights ?? this.highlights,
      shadows: shadows ?? this.shadows,
      temperature: temperature ?? this.temperature,
      tint: tint ?? this.tint,
    );
  }

  factory PhotoAdjustments.fromData(Object? raw) {
    if (raw is! Map) {
      return neutral;
    }
    double read(String key) {
      final v = (raw[key] as num?)?.toDouble() ?? 0.0;
      if (v.isNaN) return 0.0;
      return v.clamp(-1.0, 1.0).toDouble();
    }

    return PhotoAdjustments(
      brightness: read('brightness'),
      contrast: read('contrast'),
      saturation: read('saturation'),
      highlights: read('highlights'),
      shadows: read('shadows'),
      temperature: read('temperature'),
      tint: read('tint'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'highlights': highlights,
    'shadows': shadows,
    'temperature': temperature,
    'tint': tint,
  };

  /// Builds the composed 4x5 colour matrix (row-major, length 20) in the
  /// standard Android/Flutter convention: out = M · [R, G, B, A, 1], operating
  /// on the 0..255 range with the 5th column as an absolute offset.
  List<double> toColorMatrix() {
    var m = _identity;
    // saturation -> contrast -> temperature -> tint -> brightness (outermost).
    m = _mul(_saturationMatrix(saturation), m);
    m = _mul(_contrastMatrix(contrast), m);
    m = _mul(_temperatureMatrix(temperature), m);
    m = _mul(_tintMatrix(tint), m);
    m = _mul(_brightnessMatrix(brightness), m);
    return m;
  }

  // --- component matrices ---

  static const List<double> _identity = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  static List<double> _brightnessMatrix(double v) {
    final o = v.clamp(-1.0, 1.0) * 100.0;
    return <double>[
      1, 0, 0, 0, o, //
      0, 1, 0, 0, o, //
      0, 0, 1, 0, o, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> _contrastMatrix(double v) {
    final c = 1.0 + v.clamp(-1.0, 1.0);
    final t = 128.0 * (1.0 - c);
    return <double>[
      c, 0, 0, 0, t, //
      0, c, 0, 0, t, //
      0, 0, c, 0, t, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> _saturationMatrix(double v) {
    final s = 1.0 + v.clamp(-1.0, 1.0);
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1.0 - s) * lr;
    final sg = (1.0 - s) * lg;
    final sb = (1.0 - s) * lb;
    return <double>[
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> _temperatureMatrix(double v) {
    final k = v.clamp(-1.0, 1.0) * 0.3;
    final rGain = 1.0 + k;
    final bGain = 1.0 - k;
    return <double>[
      rGain, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, bGain, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> _tintMatrix(double v) {
    // tint > 0 = magenta (reduce green); < 0 = green.
    final gGain = 1.0 - v.clamp(-1.0, 1.0) * 0.3;
    return <double>[
      1, 0, 0, 0, 0, //
      0, gGain, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Multiplies two 4x5 colour matrices (each treated as 5x5 with an implicit
  /// last row [0,0,0,0,1]): result applies [b] first, then [a].
  static List<double> _mul(List<double> a, List<double> b) {
    double av(int r, int c) => r < 4 ? a[r * 5 + c] : (c == 4 ? 1.0 : 0.0);
    double bv(int r, int c) => r < 4 ? b[r * 5 + c] : (c == 4 ? 1.0 : 0.0);
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var sum = 0.0;
        for (var k = 0; k < 5; k++) {
          sum += av(r, k) * bv(k, c);
        }
        out[r * 5 + c] = sum;
      }
    }
    return out;
  }

  /// Rounds matrix entries to keep the serialized payload compact and stable.
  static List<double> roundMatrix(List<double> m) =>
      m.map((e) => (e * 10000).roundToDouble() / 10000).toList();
}

/// Convenience: largest absolute adjustment, for showing a "modified" dot.
double maxAdjustmentMagnitude(PhotoAdjustments a) {
  return <double>[
    a.brightness,
    a.contrast,
    a.saturation,
    a.highlights,
    a.shadows,
    a.temperature,
    a.tint,
  ].map((e) => e.abs()).fold(0.0, math.max);
}
