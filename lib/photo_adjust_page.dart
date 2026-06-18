import 'dart:io';

import 'package:flutter/material.dart';

import 'app_strings.dart';
import 'photo_adjustments.dart';

/// Full-screen single-photo adjustment page ("深度調整").
///
/// Live preview uses a Flutter [ColorFiltered] over the SDR base so dragging is
/// smooth; the same matrix (via [PhotoAdjustments.toColorMatrix]) is what the
/// canvas and exporter apply, so what is tuned here is what ships — the only
/// difference is the editor canvas / export additionally keep HDR headroom.
///
/// Returns the new [PhotoAdjustments] on 完成, or null on 取消.
class PhotoAdjustPage extends StatefulWidget {
  const PhotoAdjustPage({
    required this.imagePath,
    required this.initial,
    super.key,
  });

  final String imagePath;
  final PhotoAdjustments initial;

  @override
  State<PhotoAdjustPage> createState() => _PhotoAdjustPageState();
}

class _PhotoAdjustPageState extends State<PhotoAdjustPage> {
  late PhotoAdjustments _adj = widget.initial;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final matrix = _adj.toColorMatrix();

    return Scaffold(
      backgroundColor: const Color(0xFF0C0C0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C0C0E),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          strings.t('deepAdjust'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: _adj.isNeutral
                ? null
                : () => setState(() => _adj = PhotoAdjustments.neutral),
            child: Text(
              strings.t('reset'),
              style: TextStyle(
                color: _adj.isNeutral ? Colors.white24 : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_adj),
            child: Text(
              strings.t('done'),
              style: const TextStyle(
                color: Color(0xFF8EC5FF),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(matrix),
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFF16171B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AdjustSlider(
                    label: strings.t('adjBrightness'),
                    value: _adj.brightness,
                    onChanged: (v) =>
                        setState(() => _adj = _adj.copyWith(brightness: v)),
                  ),
                  _AdjustSlider(
                    label: strings.t('adjContrast'),
                    value: _adj.contrast,
                    onChanged: (v) =>
                        setState(() => _adj = _adj.copyWith(contrast: v)),
                  ),
                  _AdjustSlider(
                    label: strings.t('adjSaturation'),
                    value: _adj.saturation,
                    onChanged: (v) =>
                        setState(() => _adj = _adj.copyWith(saturation: v)),
                  ),
                  _AdjustSlider(
                    label: strings.t('adjTemperature'),
                    value: _adj.temperature,
                    onChanged: (v) =>
                        setState(() => _adj = _adj.copyWith(temperature: v)),
                  ),
                  _AdjustSlider(
                    label: strings.t('adjTint'),
                    value: _adj.tint,
                    onChanged: (v) =>
                        setState(() => _adj = _adj.copyWith(tint: v)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdjustSlider extends StatelessWidget {
  const _AdjustSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final display = (value * 100).round();
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: const Color(0xFF8EC5FF),
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: const Color(0x338EC5FF),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.clamp(-1.0, 1.0),
              min: -1.0,
              max: 1.0,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '$display',
            textAlign: TextAlign.end,
            style: TextStyle(
              color: display == 0 ? Colors.white38 : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
