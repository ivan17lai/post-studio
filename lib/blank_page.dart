import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'app_settings.dart';
import 'app_strings.dart';
import 'project_record.dart';
import 'theme_constants.dart';

enum PageDisplayMode { single, preview }

enum ExportQualityMode { igStandard1080, high2400 }

typedef _PreparedImageAsset = ({String displayPath, String originalPath});

const int _pageWhiteBackgroundColorValue = 0xFFFFFFFF;
const int _pageBlackBackgroundColorValue = 0xFF000000;
const int _igDarkBackgroundColorValue = 0xFF0C0F14;
const String _pageBackgroundColorPresetKey = 'backgroundColorPreset';
const String _pageBackgroundColorPresetWhite = 'white';
const String _pageBackgroundColorPresetBlack = 'black';
const String _pageBackgroundColorPresetIgBlack = 'ig_black';
const String _pageBackgroundColorPresetCustom = 'custom';
const double _cropScaleSliderMax = 14.0;

Color _pageBackgroundColorFromExtras(Map<String, dynamic> extras) {
  final colorValue =
      (extras['backgroundColorValue'] as num?)?.toInt() ??
      _pageWhiteBackgroundColorValue;
  return Color(colorValue);
}

double _cropScaleFromData(Map<String, dynamic> data) {
  final value = (data['cropScale'] as num?)?.toDouble() ?? 1.0;
  return value < 1 ? 1.0 : value;
}

double _cropScaleToSliderValue(double scale) {
  final safeScale = scale.clamp(1.0, _cropScaleSliderMax).toDouble();
  return 0.5 + ((safeScale - 1.0) / (_cropScaleSliderMax - 1.0) * 0.5);
}

double _cropScaleFromSliderValue(double value) {
  if (value <= 0.5) {
    return 1.0;
  }
  return 1.0 + ((value - 0.5) / 0.5 * (_cropScaleSliderMax - 1.0));
}

double _cropOffsetXFromData(Map<String, dynamic> data) {
  return (data['cropOffsetX'] as num?)?.toDouble() ?? 0.0;
}

double _cropOffsetYFromData(Map<String, dynamic> data) {
  return (data['cropOffsetY'] as num?)?.toDouble() ?? 0.0;
}

double _clampCropImageOffset(double value, double min, double max) {
  if (min >= max) {
    return 0;
  }
  return value.clamp(min, max).toDouble();
}

String _textContentFromData(Map<String, dynamic> data) {
  final text = data['text'] as String?;
  if (text == null || text.trim().isEmpty) {
    return 'Text';
  }
  return text;
}

double _textFontSizeRatioFromData(Map<String, dynamic> data) {
  final value = (data['fontSizeRatio'] as num?)?.toDouble() ?? 0.075;
  return value.clamp(0.025, 0.16).toDouble();
}

Color _textColorFromData(Map<String, dynamic> data) {
  return Color((data['colorValue'] as num?)?.toInt() ?? 0xFF111111);
}

int _textLineCount(String text) {
  return text.split('\n').length.clamp(1, 8);
}

double _textRenderedHeightRatio({
  required CanvasElement element,
  required ProjectPage page,
}) {
  final fontSizeRatio = _textFontSizeRatioFromData(element.data);
  final lineCount = _textLineCount(_textContentFromData(element.data));
  final height =
      fontSizeRatio * (page.aspectWidth / page.aspectHeight) * 1.24 * lineCount;
  return height.clamp(0.04, 0.9).toDouble();
}

SliderThemeData _lightControlSliderTheme(BuildContext context) {
  return SliderTheme.of(context).copyWith(
    trackHeight: 4,
    activeTrackColor: const Color(0xFFCFCFCF),
    inactiveTrackColor: const Color(0xFFE8E8E8),
    thumbColor: Colors.white,
    overlayColor: const Color(0x1A8F8F8F),
    valueIndicatorColor: const Color(0xFFE0E0E0),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
  );
}

SliderThemeData _positionControlSliderTheme(BuildContext context) {
  const trackColor = Color(0xFFD8D8D8);
  return SliderTheme.of(context).copyWith(
    trackHeight: 4,
    activeTrackColor: trackColor,
    inactiveTrackColor: trackColor,
    secondaryActiveTrackColor: trackColor,
    thumbColor: const Color(0xFF8F8F8F),
    overlayColor: const Color(0x1A8F8F8F),
    valueIndicatorColor: const Color(0xFFE0E0E0),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
  );
}

Uint8List _renderPageJpgBytes(Map<String, dynamic> payload) {
  const defaultWidth = 2400;
  const maxWidth = 6000;
  var exportWidth = (payload['exportWidth'] as num?)?.round() ?? defaultWidth;
  final imageBytesMap =
      (payload['images'] as Map<dynamic, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(key as String, value as Uint8List),
      );

  final elements = (payload['elements'] as List<dynamic>)
      .cast<Map<String, dynamic>>();

  if (!payload.containsKey('exportWidth')) {
    for (final element in elements) {
      if ((element['type'] as String?) != 'image') {
        continue;
      }

      final src = element['src'] as String? ?? '';
      final width = (element['width'] as num?)?.toDouble() ?? 0;
      if (src.isEmpty || width <= 0) {
        continue;
      }

      final imageBytes = imageBytesMap[src];
      if (imageBytes == null) {
        continue;
      }

      final sourceImage = img.decodeImage(imageBytes);
      if (sourceImage == null) {
        continue;
      }

      final candidateWidth = (sourceImage.width / width).ceil();
      if (candidateWidth > exportWidth) {
        exportWidth = candidateWidth;
      }
    }
  }

  exportWidth = exportWidth.clamp(defaultWidth, maxWidth);
  final aspectWidth = (payload['aspectWidth'] as num).toDouble();
  final aspectHeight = (payload['aspectHeight'] as num).toDouble();
  final exportHeight = (exportWidth * (aspectHeight / aspectWidth)).round();
  final canvas = img.Image(width: exportWidth, height: exportHeight);
  final backgroundColorValue =
      (payload['backgroundColor'] as num?)?.toInt() ?? 0xFFFFFFFF;
  img.fill(
    canvas,
    color: img.ColorRgba8(
      (backgroundColorValue >> 16) & 0xFF,
      (backgroundColorValue >> 8) & 0xFF,
      backgroundColorValue & 0xFF,
      (backgroundColorValue >> 24) & 0xFF,
    ),
  );

  for (final element in elements) {
    if ((element['type'] as String?) != 'image') {
      continue;
    }

    final src = element['src'] as String? ?? '';
    if (src.isEmpty) {
      continue;
    }

    final imageBytes = imageBytesMap[src];
    if (imageBytes == null) {
      continue;
    }

    final sourceImage = img.decodeImage(imageBytes);
    if (sourceImage == null) {
      continue;
    }

    final frameAspectRatio =
        ((element['aspectRatio'] as num?)?.toDouble()) ??
        (sourceImage.width / sourceImage.height);
    final targetWidth =
        (((element['width'] as num?)?.toDouble() ?? 0) * exportWidth)
            .round()
            .clamp(1, 20000);
    final targetHeight = (targetWidth / frameAspectRatio).round().clamp(
      1,
      20000,
    );
    final targetX = (((element['x'] as num?)?.toDouble() ?? 0) * exportWidth)
        .round();
    final targetY = (((element['y'] as num?)?.toDouble() ?? 0) * exportHeight)
        .round();
    _compositeClippedImage(
      canvas: canvas,
      sourceImage: sourceImage,
      frameAspectRatio: frameAspectRatio,
      targetX: targetX,
      targetY: targetY,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      interpolation: img.Interpolation.cubic,
      cropOffsetX: (element['cropOffsetX'] as num?)?.toDouble() ?? 0,
      cropOffsetY: (element['cropOffsetY'] as num?)?.toDouble() ?? 0,
      cropScale: (element['cropScale'] as num?)?.toDouble() ?? 1,
      borderRadiusRatio: (element['borderRadiusRatio'] as num?)?.toDouble() ?? 0,
    );
  }

  return Uint8List.fromList(img.encodeJpg(canvas, quality: 100));
}

img.Image _cropSourceToFrame({
  required img.Image sourceImage,
  required double frameAspectRatio,
  double cropOffsetX = 0,
  double cropOffsetY = 0,
  double cropScale = 1,
}) {
  final cropRect = _sourceCropRectForFrame(
    sourceWidth: sourceImage.width,
    sourceHeight: sourceImage.height,
    frameAspectRatio: frameAspectRatio,
    cropOffsetX: cropOffsetX,
    cropOffsetY: cropOffsetY,
    cropScale: cropScale,
  );
  return img.copyCrop(
    sourceImage,
    x: cropRect.x,
    y: cropRect.y,
    width: cropRect.width,
    height: cropRect.height,
  );
}

({int x, int y, int width, int height}) _sourceCropRectForFrame({
  required int sourceWidth,
  required int sourceHeight,
  required double frameAspectRatio,
  required double cropOffsetX,
  required double cropOffsetY,
  required double cropScale,
}) {
  final safeFrameAspectRatio = frameAspectRatio <= 0 ? 1.0 : frameAspectRatio;
  final sourceAspectRatio = sourceWidth / sourceHeight;
  final safeScale = cropScale < 1 ? 1.0 : cropScale;
  const frameHeight = 1.0;
  final frameWidth = safeFrameAspectRatio;
  var imageWidth = frameWidth;
  var imageHeight = frameHeight;

  if (sourceAspectRatio > safeFrameAspectRatio) {
    imageHeight = frameHeight;
    imageWidth = imageHeight * sourceAspectRatio;
  } else {
    imageWidth = frameWidth;
    imageHeight = imageWidth / sourceAspectRatio;
  }

  imageWidth *= safeScale;
  imageHeight *= safeScale;
  final left = _clampCropImageOffset(
    ((frameWidth - imageWidth) / 2) + (cropOffsetX * frameWidth),
    frameWidth - imageWidth,
    0,
  );
  final top = _clampCropImageOffset(
    ((frameHeight - imageHeight) / 2) + (cropOffsetY * frameHeight),
    frameHeight - imageHeight,
    0,
  );

  final cropX = ((-left / imageWidth) * sourceWidth).round();
  final cropY = ((-top / imageHeight) * sourceHeight).round();
  final cropWidth = ((frameWidth / imageWidth) * sourceWidth).round();
  final cropHeight = ((frameHeight / imageHeight) * sourceHeight).round();

  final safeCropWidth = cropWidth.clamp(1, sourceWidth);
  final safeCropHeight = cropHeight.clamp(1, sourceHeight);
  return (
    x: cropX.clamp(0, sourceWidth - safeCropWidth),
    y: cropY.clamp(0, sourceHeight - safeCropHeight),
    width: safeCropWidth,
    height: safeCropHeight,
  );
}

void _applyRoundCorners(img.Image image, double radius) {
  if (radius <= 0) return;
  final w = image.width;
  final h = image.height;
  final clampedRadius = radius.clamp(0.0, (w < h ? w : h) / 2.0);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var isOutside = false;
      if (x < clampedRadius && y < clampedRadius) {
        final dx = clampedRadius - x;
        final dy = clampedRadius - y;
        if (dx * dx + dy * dy > clampedRadius * clampedRadius) {
          isOutside = true;
        }
      } else if (x >= w - clampedRadius && y < clampedRadius) {
        final dx = x - (w - clampedRadius);
        final dy = clampedRadius - y;
        if (dx * dx + dy * dy > clampedRadius * clampedRadius) {
          isOutside = true;
        }
      } else if (x < clampedRadius && y >= h - clampedRadius) {
        final dx = clampedRadius - x;
        final dy = y - (h - clampedRadius);
        if (dx * dx + dy * dy > clampedRadius * clampedRadius) {
          isOutside = true;
        }
      } else if (x >= w - clampedRadius && y >= h - clampedRadius) {
        final dx = x - (w - clampedRadius);
        final dy = y - (h - clampedRadius);
        if (dx * dx + dy * dy > clampedRadius * clampedRadius) {
          isOutside = true;
        }
      }

      if (isOutside) {
        image.setPixel(x, y, img.ColorRgba8(0, 0, 0, 0));
      }
    }
  }
}

void _compositeClippedImage({
  required img.Image canvas,
  required img.Image sourceImage,
  required double frameAspectRatio,
  required int targetX,
  required int targetY,
  required int targetWidth,
  required int targetHeight,
  required img.Interpolation interpolation,
  double cropOffsetX = 0,
  double cropOffsetY = 0,
  double cropScale = 1,
  double borderRadiusRatio = 0,
}) {
  if (targetWidth <= 0 || targetHeight <= 0) {
    return;
  }

  final clippedLeft = targetX.clamp(0, canvas.width);
  final clippedTop = targetY.clamp(0, canvas.height);
  final clippedRight = (targetX + targetWidth).clamp(0, canvas.width);
  final clippedBottom = (targetY + targetHeight).clamp(0, canvas.height);

  final clippedWidth = clippedRight - clippedLeft;
  final clippedHeight = clippedBottom - clippedTop;
  if (clippedWidth <= 0 || clippedHeight <= 0) {
    return;
  }

  final croppedSource = _cropSourceToFrame(
    sourceImage: sourceImage,
    frameAspectRatio: frameAspectRatio,
    cropOffsetX: cropOffsetX,
    cropOffsetY: cropOffsetY,
    cropScale: cropScale,
  );
  final resizedImage = img.copyResize(
    croppedSource,
    width: targetWidth,
    height: targetHeight,
    interpolation: interpolation,
  );

  if (borderRadiusRatio > 0) {
    final radius = borderRadiusRatio * (targetWidth < targetHeight ? targetWidth : targetHeight);
    _applyRoundCorners(resizedImage, radius);
  }

  final cropX = (clippedLeft - targetX).clamp(0, targetWidth - 1);
  final cropY = (clippedTop - targetY).clamp(0, targetHeight - 1);
  final visibleImage = img.copyCrop(
    resizedImage,
    x: cropX,
    y: cropY,
    width: clippedWidth,
    height: clippedHeight,
  );

  img.compositeImage(canvas, visibleImage, dstX: clippedLeft, dstY: clippedTop);
}

Uint8List _renderSelectedPageJpgBytes(Map<String, dynamic> payload) {
  const defaultWidth = 2400;
  const maxWidth = 6000;
  final exportWidth =
      ((payload['exportWidth'] as num?)?.round() ?? defaultWidth).clamp(
        defaultWidth,
        maxWidth,
      );
  final imageBytesMap =
      (payload['images'] as Map<dynamic, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(key as String, value as Uint8List),
      );
  final decodedImageMap = <String, img.Image>{};

  for (final entry in imageBytesMap.entries) {
    final decoded = img.decodeImage(entry.value);
    if (decoded != null) {
      decodedImageMap[entry.key] = decoded;
    }
  }

  final pages = (payload['pages'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final targetPageIndex = (payload['targetPageIndex'] as num).toInt();
  final pagePayload = pages[targetPageIndex];
  final targetOriginalIndex =
      (pagePayload['originalIndex'] as num?)?.toInt() ?? targetPageIndex;
  final aspectWidth = (pagePayload['aspectWidth'] as num).toDouble();
  final aspectHeight = (pagePayload['aspectHeight'] as num).toDouble();
  final exportHeight = (exportWidth * (aspectHeight / aspectWidth)).round();
  final canvas = img.Image(width: exportWidth, height: exportHeight);
  final backgroundColorValue =
      (pagePayload['backgroundColor'] as num?)?.toInt() ?? 0xFFFFFFFF;
  img.fill(
    canvas,
    color: img.ColorRgba8(
      (backgroundColorValue >> 16) & 0xFF,
      (backgroundColorValue >> 8) & 0xFF,
      backgroundColorValue & 0xFF,
      (backgroundColorValue >> 24) & 0xFF,
    ),
  );

  for (
    var sourcePageIndex = 0;
    sourcePageIndex < pages.length;
    sourcePageIndex++
  ) {
    final sourcePage = pages[sourcePageIndex];
    final sourceOriginalIndex =
        (sourcePage['originalIndex'] as num?)?.toInt() ?? sourcePageIndex;
    final elements = (sourcePage['elements'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    for (final element in elements) {
      if ((element['type'] as String?) != 'image') {
        continue;
      }

      final allowCrossPage = element['allowCrossPage'] as bool? ?? true;
      if (!allowCrossPage && sourcePageIndex != targetPageIndex) {
        continue;
      }

      final src = element['src'] as String? ?? '';
      if (src.isEmpty) {
        continue;
      }

      final sourceImage = decodedImageMap[src];
      if (sourceImage == null) {
        continue;
      }

      final frameAspectRatio =
          ((element['aspectRatio'] as num?)?.toDouble()) ??
          (sourceImage.width / sourceImage.height);
      final targetWidth =
          (((element['width'] as num?)?.toDouble() ?? 0) * exportWidth)
              .round()
              .clamp(1, 20000);
      final targetHeight = (targetWidth / frameAspectRatio).round().clamp(
        1,
        20000,
      );
      final targetX =
          (((element['x'] as num?)?.toDouble() ?? 0) * exportWidth).round() +
          ((sourceOriginalIndex - targetOriginalIndex) * exportWidth);
      final targetY = (((element['y'] as num?)?.toDouble() ?? 0) * exportHeight)
          .round();

      _compositeClippedImage(
        canvas: canvas,
        sourceImage: sourceImage,
        frameAspectRatio: frameAspectRatio,
        targetX: targetX,
        targetY: targetY,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        interpolation: img.Interpolation.linear,
        cropOffsetX: (element['cropOffsetX'] as num?)?.toDouble() ?? 0,
        cropOffsetY: (element['cropOffsetY'] as num?)?.toDouble() ?? 0,
        cropScale: (element['cropScale'] as num?)?.toDouble() ?? 1,
        borderRadiusRatio: (element['borderRadiusRatio'] as num?)?.toDouble() ?? 0,
      );
    }
  }

  return Uint8List.fromList(img.encodeJpg(canvas, quality: 100));
}

int _previewImageCacheExtent(
  BuildContext context,
  double logicalWidth,
  double logicalHeight,
) {
  final pixelRatio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
  return (logicalWidth > logicalHeight ? logicalWidth : logicalHeight).isFinite
      ? ((logicalWidth > logicalHeight ? logicalWidth : logicalHeight) *
                pixelRatio)
            .round()
            .clamp(96, 768)
      : 512;
}

bool _shouldPaintCrossPageElement({
  required CanvasElement element,
  required int sourcePageIndex,
  required int targetPageIndex,
}) {
  if (sourcePageIndex == targetPageIndex || !element.allowCrossPage) {
    return false;
  }

  final aspectRatio = (element.data['aspectRatio'] as num?)?.toDouble();
  final elementHeight = aspectRatio != null && aspectRatio > 0
      ? element.width / aspectRatio
      : element.height;
  final left = (sourcePageIndex - targetPageIndex) + element.x;
  final right = left + element.width;
  final top = element.y;
  final bottom = top + elementHeight;

  return right > 0 && left < 1 && bottom > 0 && top < 1;
}

bool _shouldBuildPreviewPage({
  required int pageIndex,
  required int currentPageIndex,
}) {
  return (pageIndex - currentPageIndex).abs() <= 2;
}

bool _snapEnabledForElement(CanvasElement element) {
  return element.data['snapEnabled'] as bool? ?? true;
}

bool _snapFlagForElement(CanvasElement element, String key) {
  return element.data[key] as bool? ?? true;
}

enum _SnapGuideAxis { vertical, horizontal }

const Color _selectionChromeColor = Color(0xFFBDBDBD);
const double _canvasControlChromePadding = 9.0;

class _SnapGuide {
  const _SnapGuide({
    required this.axis,
    required this.value,
    this.start,
    this.end,
  });

  final _SnapGuideAxis axis;
  final double value;
  final double? start;
  final double? end;
}

class _SnapResult {
  const _SnapResult({
    required this.x,
    required this.y,
    this.guides = const <_SnapGuide>[],
  });

  final double x;
  final double y;
  final List<_SnapGuide> guides;
}

class _SnapTarget {
  const _SnapTarget({
    required this.value,
    required this.guideValue,
    required this.axis,
    this.guideStart,
    this.guideEnd,
  });

  final double value;
  final double guideValue;
  final _SnapGuideAxis axis;
  final double? guideStart;
  final double? guideEnd;
}

class BlankPage extends StatefulWidget {
  const BlankPage({
    super.key,
    required this.project,
    required this.onProjectChanged,
    this.initialImportedSourcePaths = const <String>[],
  });

  final ProjectRecord project;
  final Future<void> Function(ProjectRecord project) onProjectChanged;
  final List<String> initialImportedSourcePaths;

  @override
  State<BlankPage> createState() => _BlankPageState();
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.project,
    required this.currentPageIndex,
    required this.selectedBottomTab,
    required this.selectedElementId,
    required this.displayMode,
    required this.showPageBorder,
  });

  final ProjectRecord project;
  final int currentPageIndex;
  final String selectedBottomTab;
  final String? selectedElementId;
  final PageDisplayMode displayMode;
  final bool showPageBorder;
}

class _CompletedExportPage {
  const _CompletedExportPage({required this.pageNumber, required this.bytes});

  final int pageNumber;
  final Uint8List bytes;
}

class _BlankPageState extends State<BlankPage> {
  static const MethodChannel _galleryChannel = MethodChannel('igapp/gallery');
  static const String _tabPage = 'page';
  static const String _tabTemplate = 'template';
  static const String _tabElements = 'elements';
  static const String _tabImageSource = 'image_source';
  static const String _tabImagePosition = 'image_position';
  static const String _tabImageSettings = 'image_settings';
  static const String _tabTextPosition = 'text_position';
  static const String _tabTextSettings = 'text_settings';
  static const String _tabLayers = 'layers';
  static const double _singlePagePeekViewportFraction = 0.78;
  static const double _singlePagePeekGap = 8.0;
  int _currentPageIndex = 0;
  late ProjectRecord _project;
  bool _showPageBorder = false;
  bool _showPageSorter = false;
  bool _isExporting = false;
  bool _isPreparingImage = false;
  int _savingRequestCount = 0;
  PageDisplayMode _displayMode = PageDisplayMode.single;
  String _selectedBottomTab = _tabTemplate;
  String? _selectedElementId;
  String? _croppingElementId;
  String? _deleteArmedElementId;
  String? _selectedSorterPageId;
  late PageController _pageController;
  late final PageController _bottomTabPageController;
  final ScrollController _previewScrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey _exportRepaintKey = GlobalKey();
  final Map<String, Uint8List> _exportImageBytesCache = <String, Uint8List>{};
  final Map<String, Color> _customPageColorDrafts = <String, Color>{};
  List<_SnapGuide> _activeSnapGuides = const <_SnapGuide>[];
  bool _showSinglePageDivider = false;
  bool _singlePageDividerUpdateScheduled = false;
  bool? _pendingSinglePageDividerVisible;
  _EditorSnapshot? _lastSnapshot;
  bool _hasPendingElementUndoSnapshot = false;

  @override
  void initState() {
    super.initState();
    AppSettingsController.instance.addListener(_handleSettingsChanged);
    _project = widget.project.pages.isEmpty
        ? widget.project.copyWith(
            pages: <ProjectPage>[ProjectPage.initial()],
            pageCount: 1,
          )
        : widget.project.copyWith(pageCount: widget.project.pages.length);
    _pageController = _buildPageController();
    _bottomTabPageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_persistProject(_project));
      if (widget.initialImportedSourcePaths.isNotEmpty) {
        unawaited(_importSourcePaths(widget.initialImportedSourcePaths));
      }
    });
  }

  void _handleSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  PageController _buildPageController() {
    return PageController(
      initialPage: _currentPageIndex,
      viewportFraction: _pageControllerViewportFractionForState(),
    );
  }

  bool _hasTwoOptionRows(String tab) =>
      tab == _tabPage ||
      tab == _tabImagePosition ||
      tab == _tabImageSettings ||
      tab == _tabTextSettings;

  double _bottomPanelHeightForTab(String tab) {
    if (tab == _tabPage) {
      return 270.0;
    }
    if (tab == _tabImagePosition || tab == _tabTextPosition) {
      return 130.0;
    }
    if (tab == _tabImageSettings) {
      return 139.0;
    }
    if (tab == _tabTextSettings) {
      return 165.0;
    }
    if (tab == _tabLayers) {
      return 75.0;
    }
    return 75.0;
  }

  bool _isImageTab(String tab) =>
      tab == _tabElements ||
      tab == _tabLayers ||
      tab == _tabImagePosition ||
      tab == _tabImageSettings;

  bool _isTextTab(String tab) =>
      tab == _tabElements ||
      tab == _tabLayers ||
      tab == _tabTextPosition ||
      tab == _tabTextSettings;

  bool _isElementTab(String tab) {
    final selectedImage = _selectedImageElement;
    final selectedText = _selectedTextElement;
    if (selectedImage != null) {
      return _isImageTab(tab);
    }
    if (selectedText != null) {
      return _isTextTab(tab);
    }
    return tab == _tabElements;
  }

  bool _shouldUseSinglePagePeek({int? pageIndex, String? selectedTab}) {
    if (_displayMode != PageDisplayMode.single || _project.pages.isEmpty) {
      return false;
    }

    final resolvedPageIndex = (pageIndex ?? _currentPageIndex)
        .clamp(0, _project.pages.length - 1)
        .toInt();
    final page = _project.pages[resolvedPageIndex];
    return page.aspectHeight > page.aspectWidth &&
        _hasTwoOptionRows(selectedTab ?? _selectedBottomTab);
  }

  double _pageControllerViewportFractionForState() {
    if (_displayMode != PageDisplayMode.single) {
      return 0.78;
    }
    return _shouldUseSinglePagePeek() ? _singlePagePeekViewportFraction : 1.0;
  }

  void _refreshPageControllerViewportIfNeeded() {
    final viewportFraction = _pageControllerViewportFractionForState();
    if ((_pageController.viewportFraction - viewportFraction).abs() < 0.001) {
      return;
    }

    final oldController = _pageController;
    _pageController = PageController(
      initialPage: _currentPageIndex,
      viewportFraction: viewportFraction,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  Future<void> _persistProject(ProjectRecord updatedProject) async {
    _project = updatedProject.copyWith(pageCount: updatedProject.pages.length);
    if (mounted) {
      setState(() {
        _savingRequestCount += 1;
      });
    }
    try {
      await widget.onProjectChanged(_project);
    } finally {
      if (mounted) {
        setState(() {
          _savingRequestCount = (_savingRequestCount - 1).clamp(0, 999999);
        });
      }
    }
  }

  Future<void> _saveProject(ProjectRecord updatedProject) async {
    await _persistProject(updatedProject);
  }

  String _tabLabel(BuildContext context, String tabKey) {
    final strings = AppStrings.of(context);
    return switch (tabKey) {
      _tabPage => strings.t('page'),
      _tabTemplate => strings.t('template'),
      _tabElements =>
        _selectedImageElement == null
            ? strings.t('elements')
            : strings.t('replaceImage'),
      _tabImageSource => strings.t('imageSource'),
      _tabImagePosition => strings.t('imagePosition'),
      _tabImageSettings => strings.t('imageSettings'),
      _tabTextPosition => strings.t('textPosition'),
      _tabTextSettings => strings.t('text'),
      _tabLayers => strings.t('layers'),
      _ => tabKey,
    };
  }

  List<String> get _importedImagePaths {
    final rawList = _project.extras['importedImages'] as List<dynamic>?;
    if (rawList == null) {
      return const <String>[];
    }
    final paths = <String>[];
    for (final item in rawList) {
      if (item is String && item.isNotEmpty) {
        paths.add(item);
      } else if (item is Map) {
        final src = item['src'] as String?;
        if (src != null && src.isNotEmpty) {
          paths.add(src);
        }
      }
    }
    return paths;
  }

  Future<void> _saveProjectExtras(Map<String, dynamic> extras) async {
    await _saveProject(_project.copyWith(extras: extras));
  }

  Color _pageBackgroundColor(ProjectPage page) {
    return _pageBackgroundColorFromExtras(page.extras);
  }

  Color _customDraftColorForPage(ProjectPage page) {
    final draftColor = _customPageColorDrafts[page.id];
    if (draftColor != null) {
      return draftColor;
    }
    return Color(
      (page.extras['customBackgroundColorValue'] as num?)?.toInt() ??
          (page.extras['backgroundColorValue'] as num?)?.toInt() ??
          Colors.white.toARGB32(),
    );
  }

  double _elementRenderedHeight(
    CanvasElement element,
    ProjectPage page, {
    double? width,
  }) {
    if (element.type == 'text') {
      return _textRenderedHeightRatio(element: element, page: page);
    }
    final aspectRatio = (element.data['aspectRatio'] as num?)?.toDouble();
    final nextWidth = width ?? element.width;
    if (aspectRatio != null && aspectRatio > 0) {
      return nextWidth * (page.aspectWidth / page.aspectHeight) / aspectRatio;
    }
    return element.height;
  }

  double _sourceAspectRatioForElement(CanvasElement element) {
    return (element.data['originalAspectRatio'] as num?)?.toDouble() ??
        (element.data['aspectRatio'] as num?)?.toDouble() ??
        (element.width / element.height);
  }

  ({double x, double y}) _clampedCropOffsetForElement(
    CanvasElement element, {
    required double x,
    required double y,
    double? scale,
  }) {
    final frameAspectRatio =
        (element.data['aspectRatio'] as num?)?.toDouble() ??
        (element.width / element.height);
    final rawSourceAspectRatio = _sourceAspectRatioForElement(element);
    final sourceAspectRatio = rawSourceAspectRatio <= 0
        ? frameAspectRatio
        : rawSourceAspectRatio;
    final cropScale = scale ?? _cropScaleFromData(element.data);
    const frameHeight = 1.0;
    final frameWidth = frameAspectRatio <= 0 ? 1.0 : frameAspectRatio;
    var imageWidth = frameWidth;
    var imageHeight = frameHeight;

    if (sourceAspectRatio > frameWidth) {
      imageHeight = frameHeight;
      imageWidth = imageHeight * sourceAspectRatio;
    } else {
      imageWidth = frameWidth;
      imageHeight = imageWidth / sourceAspectRatio;
    }

    imageWidth *= cropScale < 1 ? 1.0 : cropScale;
    imageHeight *= cropScale < 1 ? 1.0 : cropScale;
    final minX = (frameWidth - imageWidth) / (2 * frameWidth);
    final maxX = -minX;
    final minY = (frameHeight - imageHeight) / (2 * frameHeight);
    final maxY = -minY;

    return (
      x: minX >= maxX ? 0.0 : x.clamp(minX, maxX).toDouble(),
      y: minY >= maxY ? 0.0 : y.clamp(minY, maxY).toDouble(),
    );
  }

  String _importedImageOriginalPath(String displayPath) {
    return _importedImageForPath(displayPath)?.originalPath ?? displayPath;
  }

  _PreparedImageAsset? _importedImageForPath(String path) {
    if (path.isEmpty) {
      return null;
    }
    final rawList = _project.extras['importedImages'] as List<dynamic>?;
    if (rawList == null) {
      return null;
    }

    for (final item in rawList) {
      if (item is String && item == path) {
        return (displayPath: item, originalPath: item);
      }
      if (item is Map) {
        final src = item['src'] as String?;
        final originalSrc = item['originalSrc'] as String? ?? src;
        if (src == null || src.isEmpty) {
          continue;
        }
        if (path == src || path == originalSrc) {
          return (displayPath: src, originalPath: originalSrc ?? src);
        }
      }
    }
    return null;
  }

  List<dynamic> _mergedImportedImages(Iterable<dynamic> additions) {
    final merged = <dynamic>[
      ...(_project.extras['importedImages'] as List<dynamic>? ?? const []),
      ...additions,
    ];
    final deduped = <dynamic>[];
    final seenPaths = <String>{};
    for (final item in merged) {
      if (item is String) {
        if (item.isNotEmpty && seenPaths.add(item)) {
          deduped.add(item);
        }
      } else if (item is Map) {
        final src = item['src'] as String? ?? '';
        final originalSrc = item['originalSrc'] as String? ?? '';
        final keys = <String>{src, originalSrc}
          ..removeWhere((path) => path.isEmpty);
        if (keys.isNotEmpty &&
            keys.every((path) => !seenPaths.contains(path))) {
          seenPaths.addAll(keys);
          deduped.add(item);
        }
      }
    }
    return deduped;
  }

  Future<void> _rememberPreparedImages(
    Iterable<_PreparedImageAsset> preparedImages,
  ) async {
    final additions = preparedImages
        .map(
          (image) => <String, dynamic>{
            'src': image.displayPath,
            'originalSrc': image.originalPath,
          },
        )
        .toList();
    if (additions.isEmpty) {
      return;
    }

    await _saveProjectExtras(<String, dynamic>{
      ..._project.extras,
      'importedImages': _mergedImportedImages(additions),
    });
  }

  Future<_PreparedImageAsset> _prepareImageAsset(
    String sourcePath, {
    bool managePreparingState = true,
  }) async {
    if (managePreparingState && mounted) {
      setState(() {
        _isPreparingImage = true;
      });
    }

    try {
      final result =
          await _galleryChannel.invokeMapMethod<String, dynamic>(
            'prepareImageAsset',
            <String, dynamic>{
              'sourcePath': sourcePath,
              'projectId': _project.id,
              'maxPreviewSide': 720,
            },
          ) ??
          <String, dynamic>{};

      final displayPath =
          result['displayPath'] as String? ??
          result['originalPath'] as String? ??
          sourcePath;
      final originalPath =
          result['originalPath'] as String? ??
          result['displayPath'] as String? ??
          sourcePath;
      return (displayPath: displayPath, originalPath: originalPath);
    } finally {
      if (managePreparingState && mounted) {
        setState(() {
          _isPreparingImage = false;
        });
      }
    }
  }

  Future<Uint8List?> _readImageBytesForExport(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  void _setExportProgress({
    required double progress,
    required String label,
    void Function(double progress, String label)? onProgress,
  }) {
    final clampedProgress = progress.clamp(0, 1).toDouble();
    onProgress?.call(clampedProgress, label);
  }

  void _storeUndoSnapshot() {
    _hasPendingElementUndoSnapshot = false;
    _lastSnapshot = _EditorSnapshot(
      project: _project,
      currentPageIndex: _currentPageIndex,
      selectedBottomTab: _selectedBottomTab,
      selectedElementId: _selectedElementId,
      displayMode: _displayMode,
      showPageBorder: _showPageBorder,
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _restoreLastStep() async {
    final snapshot = _lastSnapshot;
    if (snapshot == null) {
      return;
    }

    final oldController = _pageController;

    _lastSnapshot = null;
    _hasPendingElementUndoSnapshot = false;
    _project = snapshot.project.copyWith(
      pageCount: snapshot.project.pages.length,
    );
    _currentPageIndex = snapshot.currentPageIndex.clamp(
      0,
      _project.pages.length - 1,
    );
    _selectedBottomTab = snapshot.selectedBottomTab;
    _selectedElementId = snapshot.selectedElementId;
    _croppingElementId = null;
    _deleteArmedElementId = null;
    _displayMode = snapshot.displayMode;
    _showPageBorder = snapshot.showPageBorder;
    _pageController = _buildPageController();

    if (mounted) {
      setState(() {});
    }

    await widget.onProjectChanged(_project);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_displayMode == PageDisplayMode.single &&
          _pageController.hasClients) {
        _pageController.jumpToPage(_currentPageIndex);
      } else if (_displayMode == PageDisplayMode.preview) {
        _jumpPreviewToPage(_currentPageIndex);
      }
      _syncBottomTab();
      oldController.dispose();
    });
  }

  Future<void> _handleBack() async {
    Navigator.of(context).pop();
  }

  List<String> get _bottomTabs {
    if (_selectedImageElement != null) {
      return const <String>[
        _tabPage,
        _tabTemplate,
        _tabElements,
        _tabImagePosition,
        _tabImageSettings,
        _tabLayers,
      ];
    }
    if (_selectedTextElement != null) {
      return const <String>[
        _tabPage,
        _tabTemplate,
        _tabElements,
        _tabTextPosition,
        _tabTextSettings,
        _tabLayers,
      ];
    }
    return const <String>[_tabPage, _tabTemplate, _tabElements, _tabLayers];
  }

  CanvasElement? get _selectedElement {
    final selectedId = _selectedElementId;
    if (selectedId == null) {
      return null;
    }

    for (final page in _project.pages) {
      for (final element in page.elements) {
        if (element.id == selectedId) {
          return element;
        }
      }
    }
    return null;
  }

  CanvasElement? get _selectedImageElement {
    final element = _selectedElement;
    return element?.type == 'image' ? element : null;
  }

  CanvasElement? get _selectedTextElement {
    final element = _selectedElement;
    return element?.type == 'text' ? element : null;
  }

  void _syncBottomTab() {
    final tabs = _bottomTabs;
    if (!tabs.contains(_selectedBottomTab)) {
      if (mounted) {
        setState(() {
          _selectedBottomTab = tabs.last;
          _refreshPageControllerViewportIfNeeded();
        });
      } else {
        _selectedBottomTab = tabs.last;
        _refreshPageControllerViewportIfNeeded();
      }
    }
    final targetIndex = tabs.indexOf(_selectedBottomTab);
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(targetIndex);
    }
  }

  void _setSinglePageDividerVisible(bool isVisible) {
    if (_showSinglePageDivider == isVisible &&
        _pendingSinglePageDividerVisible == null) {
      return;
    }
    _pendingSinglePageDividerVisible = isVisible;
    if (_singlePageDividerUpdateScheduled) {
      return;
    }

    _singlePageDividerUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _singlePageDividerUpdateScheduled = false;
      final nextVisible = _pendingSinglePageDividerVisible;
      _pendingSinglePageDividerVisible = null;
      if (!mounted ||
          nextVisible == null ||
          _showSinglePageDivider == nextVisible) {
        return;
      }
      setState(() {
        _showSinglePageDivider = nextVisible;
      });
    });
  }

  void _changeBottomTab(String tab) {
    final tabs = _bottomTabs;
    final targetIndex = tabs.indexOf(tab);
    if (targetIndex == -1) {
      return;
    }

    final shouldClearSelection =
        _selectedElement != null && !_isElementTab(tab);

    setState(() {
      if (shouldClearSelection) {
        _selectedElementId = null;
      }
      _deleteArmedElementId = null;
      _selectedBottomTab = tab;
      _refreshPageControllerViewportIfNeeded();
    });

    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
      );
    }
  }

  void _clearSelectedElement() {
    final shouldFallbackToElements =
        _selectedBottomTab == _tabImagePosition ||
        _selectedBottomTab == _tabImageSettings ||
        _selectedBottomTab == _tabTextPosition ||
        _selectedBottomTab == _tabTextSettings;
    setState(() {
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      if (shouldFallbackToElements) {
        _selectedBottomTab = _tabElements;
      }
      _refreshPageControllerViewportIfNeeded();
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(
        shouldFallbackToElements ? 2 : _bottomTabs.indexOf(_selectedBottomTab),
      );
    }
  }

  Future<void> _addPage() async {
    _storeUndoSnapshot();
    final nextIndex = _project.pages.length + 1;
    final referencePage = _project.pages.isNotEmpty
        ? _project.pages[_currentPageIndex]
        : ProjectPage.initial();
    final newPages = List<ProjectPage>.from(_project.pages)
      ..add(
        ProjectPage.initial(nextIndex).copyWith(
          aspectWidth: referencePage.aspectWidth,
          aspectHeight: referencePage.aspectHeight,
        ),
      );

    final updatedProject = _project.copyWith(
      pages: newPages,
      pageCount: newPages.length,
    );

    await _saveProject(updatedProject);

    if (!mounted) {
      return;
    }

    setState(() {
      _currentPageIndex = newPages.length - 1;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabTemplate;
      _refreshPageControllerViewportIfNeeded();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_displayMode == PageDisplayMode.single &&
          _pageController.hasClients) {
        _pageController.animateToPage(
          _currentPageIndex,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
        );
      } else if (_displayMode == PageDisplayMode.preview) {
        _jumpPreviewToPage(_currentPageIndex);
      }
      _syncBottomTab();
    });
  }

  Future<void> _deleteCurrentPage() async {
    if (_displayMode == PageDisplayMode.preview) {
      return;
    }
    await _deletePageAtIndex(_currentPageIndex);
  }

  Future<void> _deletePageAtIndex(int pageIndex) async {
    final strings = AppStrings.of(context);
    if (pageIndex < 0 || pageIndex >= _project.pages.length) {
      return;
    }

    if (_project.pages.length <= 1) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('keepAtLeastOnePage'))));
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F4),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: Color(0xFF6F6F6F),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  strings.t('deletePage'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  strings.t('confirmDeleteCurrentPage'),
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Color(0xFF6A6A6A),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('cancel'),
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('deletePage'),
                        isPrimary: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    _storeUndoSnapshot();
    final deletedPageId = _project.pages[pageIndex].id;
    final updatedPages = List<ProjectPage>.from(_project.pages)
      ..removeAt(pageIndex);
    final nextIndex = _currentPageIndex > pageIndex
        ? _currentPageIndex - 1
        : _currentPageIndex >= updatedPages.length
        ? updatedPages.length - 1
        : _currentPageIndex;

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _currentPageIndex = nextIndex;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      if (deletedPageId == _selectedSorterPageId) {
        _selectedSorterPageId = null;
      }
      _selectedBottomTab = _tabTemplate;
      _showPageSorter = updatedPages.length > 1 && _showPageSorter;
      _refreshPageControllerViewportIfNeeded();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentPageIndex);
      }
      _syncBottomTab();
    });
  }

  void _togglePageSorter() {
    setState(() {
      _showPageSorter = !_showPageSorter;
      _selectedSorterPageId = null;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _activeSnapGuides = const <_SnapGuide>[];
    });
  }

  void _toggleSorterPageSelection(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _project.pages.length) {
      return;
    }

    final pageId = _project.pages[pageIndex].id;
    setState(() {
      _selectedSorterPageId = _selectedSorterPageId == pageId ? null : pageId;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _activeSnapGuides = const <_SnapGuide>[];
    });
  }

  void _moveSelectedSorterPage(int delta) {
    final selectedPageId = _selectedSorterPageId;
    if (selectedPageId == null) {
      return;
    }

    final oldIndex = _project.pages.indexWhere(
      (page) => page.id == selectedPageId,
    );
    if (oldIndex == -1) {
      setState(() {
        _selectedSorterPageId = null;
      });
      return;
    }

    final newIndex = (oldIndex + delta).clamp(0, _project.pages.length - 1);
    if (newIndex == oldIndex) {
      return;
    }
    _reorderPages(oldIndex, newIndex);
  }

  void _reorderPages(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _project.pages.length ||
        newIndex < 0 ||
        newIndex >= _project.pages.length) {
      return;
    }

    final targetIndex = newIndex;
    if (oldIndex == targetIndex) {
      return;
    }

    _storeUndoSnapshot();
    final currentPageId = _project.pages[_currentPageIndex].id;
    final updatedPages = List<ProjectPage>.from(_project.pages);
    final movedPage = updatedPages.removeAt(oldIndex);
    updatedPages.insert(targetIndex, movedPage);
    final nextCurrentIndex = updatedPages.indexWhere(
      (page) => page.id == currentPageId,
    );
    final updatedProject = _project.copyWith(
      pages: updatedPages,
      pageCount: updatedPages.length,
    );

    setState(() {
      _project = updatedProject;
      _currentPageIndex = nextCurrentIndex == -1
          ? targetIndex
          : nextCurrentIndex;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _activeSnapGuides = const <_SnapGuide>[];
      _refreshPageControllerViewportIfNeeded();
    });

    unawaited(_saveProject(updatedProject));
  }

  void _reorderElements(int oldIndex, int newIndex) {
    final currentPage = _project.pages[_currentPageIndex];
    if (oldIndex < 0 ||
        oldIndex >= currentPage.elements.length ||
        newIndex < 0 ||
        newIndex > currentPage.elements.length) {
      return;
    }
    if (oldIndex == newIndex || oldIndex == newIndex - 1) {
      return;
    }

    _storeUndoSnapshot();

    final updatedElements = List<CanvasElement>.from(currentPage.elements);
    final movedElement = updatedElements.removeAt(oldIndex);
    
    // Adjust target index after removal (since list visual order is reversed and newIndex represents the slot)
    final targetIndex = oldIndex < newIndex ? newIndex - 1 : newIndex;
    updatedElements.insert(targetIndex, movedElement);

    final updatedPage = currentPage.copyWith(elements: updatedElements);
    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;

    final updatedProject = _project.copyWith(
      pages: updatedPages,
      pageCount: updatedPages.length,
    );

    setState(() {
      _project = updatedProject;
    });

    unawaited(_saveProject(updatedProject));
  }

  Future<void> _requestAiPageSort() async {
    final settings = AppSettingsController.instance;
    final strings = AppStrings.of(context);
    if (_project.pages.length < 2) {
      return;
    }
    if (!settings.aiSortEnabled || !settings.hasGeminiApiKey) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('enableAiFirst'))));
      return;
    }

    setState(() {
      _isPreparingImage = true;
    });

    try {
      final order = await _requestGeminiPageOrder(settings.geminiApiKey);
      if (!mounted) {
        return;
      }
      setState(() {
        _isPreparingImage = false;
      });
      final accepted = await _showAiSortConfirmationDialog(order);
      if (accepted == true) {
        _applyPageOrder(order);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isPreparingImage = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('aiSortFailed'))));
    }
  }

  Future<List<int>> _requestGeminiPageOrder(String apiKey) async {
    await _primeExportImageCache();
    final pageIndexes = <int>[
      for (var i = 0; i < _project.pages.length; i++) i,
    ];
    final parts = <Map<String, dynamic>>[
      <String, String>{
        'text':
            'You are sorting pages for a social post carousel. Analyze the page thumbnails and return the best narrative order. Return ONLY JSON in this exact format: {"order":[1,2,3],"reason":"short reason"}. The order array must include every original page number exactly once, using 1-based page numbers.',
      },
    ];

    for (var listIndex = 0; listIndex < pageIndexes.length; listIndex++) {
      final pageNumber = pageIndexes[listIndex] + 1;
      final bytes = await _renderProjectPageInSetBytesForGallery(
        exportWidth: 360,
        pageIndexes: pageIndexes,
        targetListIndex: listIndex,
      );
      parts
        ..add(<String, String>{'text': 'Original page $pageNumber'})
        ..add(<String, dynamic>{
          'inlineData': <String, String>{
            'mimeType': 'image/jpeg',
            'data': base64Encode(bytes),
          },
        });
    }

    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$kGeminiSortModel:generateContent',
      <String, String>{'key': apiKey},
    );
    final response = await http
        .post(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{
            'contents': <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'parts': parts},
            ],
            'generationConfig': <String, dynamic>{
              'temperature': 0.2,
              'responseMimeType': 'application/json',
            },
          }),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Gemini request failed');
    }

    final responseData = jsonDecode(response.body) as Map<String, dynamic>;
    final text = _geminiTextFromResponse(responseData);
    return _parseAiSortOrder(text, _project.pages.length);
  }

  String _geminiTextFromResponse(Map<String, dynamic> data) {
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Missing Gemini candidates');
    }
    final content =
        (candidates.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    final text = parts
        ?.whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join('\n')
        .trim();
    if (text == null || text.isEmpty) {
      throw Exception('Missing Gemini text');
    }
    return text;
  }

  List<int> _parseAiSortOrder(String text, int pageCount) {
    var cleaned = text.trim();
    final fenced = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (fenced != null) {
      cleaned = fenced.group(1)!.trim();
    }
    final objectStart = cleaned.indexOf('{');
    final objectEnd = cleaned.lastIndexOf('}');
    if (objectStart != -1 && objectEnd > objectStart) {
      cleaned = cleaned.substring(objectStart, objectEnd + 1);
    }

    final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
    final rawOrder = decoded['order'] as List<dynamic>?;
    if (rawOrder == null) {
      throw Exception('Missing order');
    }
    final order = rawOrder.map((item) {
      if (item is num) {
        return item.toInt() - 1;
      }
      return int.parse('$item') - 1;
    }).toList();
    final unique = order.toSet();
    if (order.length != pageCount ||
        unique.length != pageCount ||
        unique.any((index) => index < 0 || index >= pageCount)) {
      throw Exception('Invalid order');
    }
    return order;
  }

  Future<bool?> _showAiSortConfirmationDialog(List<int> order) {
    final strings = AppStrings.of(context);
    final currentOrder = <int>[
      for (var i = 0; i < _project.pages.length; i++) i,
    ];
    final currentLabel = currentOrder.map((index) => '${index + 1}').join('  ');
    final nextLabel = order.map((index) => '${index + 1}').join('  ');
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F4),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.t('aiSortSuggestion'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 14),
                _AiSortOrderPreview(
                  title: strings.t('currentOrder'),
                  value: currentLabel,
                ),
                const SizedBox(height: 8),
                _AiSortOrderPreview(
                  title: strings.t('suggestedOrder'),
                  value: nextLabel,
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('cancel'),
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('accept'),
                        isPrimary: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _applyPageOrder(List<int> order) {
    if (order.length != _project.pages.length) {
      return;
    }
    final currentPageId = _project.pages[_currentPageIndex].id;
    final updatedPages = order.map((index) => _project.pages[index]).toList();
    final nextCurrentIndex = updatedPages.indexWhere(
      (page) => page.id == currentPageId,
    );
    final updatedProject = _project.copyWith(
      pages: updatedPages,
      pageCount: updatedPages.length,
    );

    _storeUndoSnapshot();
    setState(() {
      _project = updatedProject;
      _currentPageIndex = nextCurrentIndex == -1 ? 0 : nextCurrentIndex;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _activeSnapGuides = const <_SnapGuide>[];
      _refreshPageControllerViewportIfNeeded();
    });
    unawaited(_saveProject(updatedProject));
  }

  Future<bool> _confirmPageAspectChangeIfNeeded() async {
    final hasElements = _project.pages.any((page) => page.elements.isNotEmpty);
    if (!hasElements) {
      return true;
    }

    final strings = AppStrings.of(context);
    final title = strings.t('changePageRatio');
    final message = strings.t('changeRatioWarning');
    final continueLabel = strings.t('continueLabel');
    final shouldContinue = await showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F4),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    size: 22,
                    color: Color(0xFF6F6F6F),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Color(0xFF6A6A6A),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('cancel'),
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: continueLabel,
                        isPrimary: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    return shouldContinue == true;
  }

  Future<void> _updateCurrentPageAspect({
    required double aspectWidth,
    required double aspectHeight,
  }) async {
    final isSameAspect = _project.pages.every(
      (page) =>
          page.aspectWidth == aspectWidth && page.aspectHeight == aspectHeight,
    );
    if (isSameAspect) {
      return;
    }

    final shouldContinue = await _confirmPageAspectChangeIfNeeded();
    if (!shouldContinue) {
      return;
    }
    if (!mounted) {
      return;
    }

    _storeUndoSnapshot();
    final updatedPages = _project.pages
        .map(
          (page) => page.copyWith(
            aspectWidth: aspectWidth,
            aspectHeight: aspectHeight,
          ),
        )
        .toList();

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (mounted) {
      setState(() {
        _refreshPageControllerViewportIfNeeded();
      });
    }
  }

  Future<void> _updateCurrentPageColor(
    Color color, {
    required String preset,
  }) async {
    _storeUndoSnapshot();
    final currentPage = _project.pages[_currentPageIndex];
    final updatedPage = currentPage.copyWith(
      extras: <String, dynamic>{
        ...currentPage.extras,
        'backgroundColorValue': color.toARGB32(),
        _pageBackgroundColorPresetKey: preset,
      },
    );
    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;
    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );
  }

  Future<void> _updateCurrentPageCustomColor(Color color) async {
    _storeUndoSnapshot();
    final currentPage = _project.pages[_currentPageIndex];
    final updatedPage = currentPage.copyWith(
      extras: <String, dynamic>{
        ...currentPage.extras,
        'backgroundColorValue': color.toARGB32(),
        'customBackgroundColorValue': color.toARGB32(),
        _pageBackgroundColorPresetKey: _pageBackgroundColorPresetCustom,
      },
    );
    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;
    _customPageColorDrafts[currentPage.id] = color;
    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );
  }

  Future<void> _storeCurrentPageCustomColorDraft(Color color) async {
    final currentPage = _project.pages[_currentPageIndex];
    _customPageColorDrafts[currentPage.id] = color;
  }

  Future<void> _showCustomPageColorDialog() async {
    final currentPage = _project.pages[_currentPageIndex];
    final initialColor = _customDraftColorForPage(currentPage);
    var red = initialColor.r.toDouble();
    var green = initialColor.g.toDouble();
    var blue = initialColor.b.toDouble();
    Color latestDraftColor = initialColor;

    final pickedColor = await showDialog<Color>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final previewColor = Color.fromRGBO(
              red.round(),
              green.round(),
              blue.round(),
              1,
            );

            Widget sliderRow(
              String label,
              double value,
              ValueChanged<double> onChanged,
            ) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F1F1F),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        value.round().toString(),
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6A6A6A),
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 8,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: const Color(0xFF9A9A9A),
                      inactiveTrackColor: const Color(0xFFD8D8D8),
                      thumbColor: const Color(0xFF8A8A8A),
                      overlayColor: const Color(0x22000000),
                    ),
                    child: Slider(
                      value: value,
                      min: 0,
                      max: 255,
                      onChanged: (nextValue) {
                        onChanged(nextValue);
                        latestDraftColor = Color.fromRGBO(
                          red.round(),
                          green.round(),
                          blue.round(),
                          1,
                        );
                      },
                    ),
                  ),
                ],
              );
            }

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 28),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F4),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '自訂頁面色彩',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F1F1F),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      height: 64,
                      decoration: BoxDecoration(
                        color: previewColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFD8D8D8)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    sliderRow('R', red, (value) {
                      setDialogState(() {
                        red = value;
                      });
                    }),
                    sliderRow('G', green, (value) {
                      setDialogState(() {
                        green = value;
                      });
                    }),
                    sliderRow('B', blue, (value) {
                      setDialogState(() {
                        blue = value;
                      });
                    }),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _DialogActionButton(
                            label: '取消',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _DialogActionButton(
                            label: '確認',
                            isPrimary: true,
                            onTap: () {
                              Navigator.of(context).pop(previewColor);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    await _storeCurrentPageCustomColorDraft(latestDraftColor);

    if (pickedColor == null) {
      return;
    }

    await _updateCurrentPageCustomColor(pickedColor);
  }

  void _changeDisplayMode(PageDisplayMode mode) {
    if (_displayMode == mode) {
      return;
    }

    final oldController = _pageController;
    final currentPageIndex = _currentPageIndex;

    setState(() {
      _displayMode = mode;
      _showPageBorder = mode == PageDisplayMode.preview;
      _showSinglePageDivider = false;
      _pageController = _buildPageController();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_displayMode == PageDisplayMode.single &&
          _pageController.hasClients) {
        _pageController.jumpToPage(currentPageIndex);
      } else if (_displayMode == PageDisplayMode.preview) {
        _jumpPreviewToPage(currentPageIndex);
      }
      oldController.dispose();
    });
  }

  Future<void> _addImageElement() async {
    final currentPage = _project.pages[_currentPageIndex];
    final newElement = CanvasElement.image(pageId: currentPage.id);
    final updatedPage = currentPage.copyWith(
      elements: List<CanvasElement>.from(currentPage.elements)..add(newElement),
    );

    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedElementId = newElement.id;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabElements;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabElements));
    }
  }

  Future<void> _addTextElement() async {
    final currentPage = _project.pages[_currentPageIndex];
    final newElement = CanvasElement.text(pageId: currentPage.id);
    final updatedPage = currentPage.copyWith(
      elements: List<CanvasElement>.from(currentPage.elements)..add(newElement),
    );

    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedElementId = newElement.id;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabTextSettings;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(
        _bottomTabs.indexOf(_tabTextSettings),
      );
    }
  }

  Future<void> _addImageElementFromPath(String path) async {
    if (_selectedImageElement != null) {
      await _applyPathToSelectedImage(path);
      return;
    }

    final existingImport = _importedImageForPath(path);
    final preparedImage =
        existingImport ??
        await _prepareImageAsset(_importedImageOriginalPath(path));
    if (existingImport == null) {
      await _rememberPreparedImages([preparedImage]);
    }

    final size = await _decodeImageSize(preparedImage.displayPath);
    if (size == null || size.height == 0) {
      return;
    }

    final currentPage = _project.pages[_currentPageIndex];
    final aspectRatio = size.width / size.height;
    final newElement = CanvasElement.image(pageId: currentPage.id).copyWith(
      height: 0.36 / aspectRatio,
      data: <String, dynamic>{
        'src': preparedImage.displayPath,
        'originalSrc': preparedImage.originalPath,
        'aspectRatio': aspectRatio,
        'originalAspectRatio': aspectRatio,
      },
    );
    final updatedPage = currentPage.copyWith(
      elements: List<CanvasElement>.from(currentPage.elements)..add(newElement),
    );

    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedElementId = newElement.id;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabElements;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabElements));
    }
  }

  Future<void> _importSourcePaths(List<String> sourcePaths) async {
    if (sourcePaths.isEmpty) {
      return;
    }

    if (_selectedImageElement != null && sourcePaths.length == 1) {
      await _applyPathToSelectedImage(sourcePaths.first);
      return;
    }

    if (mounted) {
      setState(() {
        _isPreparingImage = true;
      });
    }

    try {
      final importedImages = <_PreparedImageAsset>[];
      final seenSourcePaths = <String>{};
      for (final path in sourcePaths) {
        if (path.isEmpty || !seenSourcePaths.add(path)) {
          continue;
        }
        final existingImport = _importedImageForPath(path);
        if (existingImport != null) {
          importedImages.add(existingImport);
          continue;
        }
        importedImages.add(
          await _prepareImageAsset(path, managePreparingState: false),
        );
      }

      if (importedImages.isEmpty) {
        return;
      }

      await _saveProjectExtras(<String, dynamic>{
        ..._project.extras,
        'importedImages': _mergedImportedImages(
          importedImages.map(
            (image) => <String, dynamic>{
              'src': image.displayPath,
              'originalSrc': image.originalPath,
            },
          ),
        ),
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPreparingImage = false;
        });
      }
    }
  }

  Future<void> _importImages() async {
    final strings = AppStrings.of(context);
    List<XFile> pickedFiles;
    try {
      pickedFiles = await _imagePicker.pickMultiImage();
    } on PlatformException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('imagePickerNotReady'))));
      return;
    }

    if (pickedFiles.isEmpty) {
      return;
    }

    await _importSourcePaths(pickedFiles.map((file) => file.path).toList());
  }

  Future<void> _pickImageForSelected() async {
    final strings = AppStrings.of(context);
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }

    XFile? picked;
    try {
      picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    } on PlatformException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('imagePickerNotReady'))));
      return;
    }

    if (picked == null) {
      return;
    }

    await _applyPathToSelectedImage(picked.path);
  }

  Future<void> _applyPathToSelectedImage(String path) async {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }

    final existingImport = _importedImageForPath(path);
    final preparedImage =
        existingImport ??
        await _prepareImageAsset(_importedImageOriginalPath(path));
    if (existingImport == null) {
      await _rememberPreparedImages([preparedImage]);
    }

    final size = await _decodeImageSize(preparedImage.displayPath);
    if (size == null || size.height == 0) {
      return;
    }

    final aspectRatio = size.width / size.height;
    final isFillSlot = selectedImage.data['templateSlot'] == 'fill';
    final hasTemplateSlot = selectedImage.data['templateSlot'] != null;
    final hasAspectPreset = selectedImage.data['aspectPreset'] != null;
    final shouldKeepFrame = (hasTemplateSlot || hasAspectPreset) && !isFillSlot;

    var width = selectedImage.width;
    var height = selectedImage.height;
    var x = selectedImage.x;
    var y = selectedImage.y;

    if (isFillSlot) {
      const pageAspect = 3.0 / 4.0;
      final targetRatio = aspectRatio / pageAspect;

      if (targetRatio > 1.0) {
        width = 1.0;
        height = pageAspect / aspectRatio;
      } else {
        height = 1.0;
        width = height * targetRatio;
      }
      x = (1.0 - width) / 2;
      y = (1.0 - height) / 2;
    } else if (!shouldKeepFrame) {
      width = selectedImage.width.clamp(0.12, 0.7);
      height = width / aspectRatio;

      if (height > 0.84) {
        height = 0.84;
        width = height * aspectRatio;
      }
    }

    final updatedElement = selectedImage.copyWith(
      x: x,
      y: y,
      width: width,
      height: height,
      data: <String, dynamic>{
        ...selectedImage.data,
        'src': preparedImage.displayPath,
        'originalSrc': preparedImage.originalPath,
        'cropOffsetX': 0.0,
        'cropOffsetY': 0.0,
        'cropScale': 1.0,
        'aspectRatio': isFillSlot
            ? aspectRatio
            : (shouldKeepFrame
                  ? ((selectedImage.data['aspectRatio'] as num?)?.toDouble() ??
                        aspectRatio)
                  : aspectRatio),
        'originalAspectRatio': aspectRatio,
      },
    );

    await _replaceElement(updatedElement, persist: true);

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedBottomTab = _tabElements;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabElements));
    }
  }

  Future<ui.Size?> _decodeImageSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final completer = Completer<ui.Size?>();
    ui.decodeImageFromList(bytes, (image) {
      completer.complete(
        ui.Size(image.width.toDouble(), image.height.toDouble()),
      );
    });
    return completer.future;
  }

  void _showImportedImagePreview(String imagePath) {
    if (imagePath.isEmpty) {
      return;
    }

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.58),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, animation, secondaryAnimation) {
        return _ImagePathPreviewDialog(imagePath: imagePath);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.86, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  bool _elementCrossesPageBoundary(CanvasElement element) {
    return element.allowCrossPage &&
        (element.x < 0 || (element.x + element.width) > 1);
  }

  void _selectElement(String? elementId) {
    if (elementId == null) {
      _clearSelectedElement();
      return;
    }
    if (_selectedElementId == elementId) {
      _clearSelectedElement();
      return;
    }

    CanvasElement? selectedElement;
    for (var pageIndex = 0; pageIndex < _project.pages.length; pageIndex++) {
      final page = _project.pages[pageIndex];
      for (
        var elementIndex = 0;
        elementIndex < page.elements.length;
        elementIndex++
      ) {
        final element = page.elements[elementIndex];
        if (element.id == elementId) {
          selectedElement = element;
          break;
        }
      }
      if (selectedElement != null) {
        break;
      }
    }

    setState(() {
      if (selectedElement != null &&
          _elementCrossesPageBoundary(selectedElement) &&
          _displayMode != PageDisplayMode.preview) {
        _displayMode = PageDisplayMode.preview;
        _showPageBorder = true;
      }
      _selectedElementId = elementId;
      if (_deleteArmedElementId != elementId) {
        _deleteArmedElementId = null;
      }
      if (_croppingElementId != null && _croppingElementId != elementId) {
        _croppingElementId = null;
      }
      final isValidTabForSelectedElement = selectedElement?.type == 'image'
          ? _isImageTab(_selectedBottomTab)
          : selectedElement?.type == 'text'
          ? _isTextTab(_selectedBottomTab)
          : _selectedBottomTab == _tabElements;
      if (_selectedBottomTab != _tabPage && !isValidTabForSelectedElement) {
        _selectedBottomTab = selectedElement?.type == 'text'
            ? _tabTextSettings
            : _tabElements;
      } else if (selectedElement?.type == 'text' &&
          _selectedBottomTab == _tabElements) {
        _selectedBottomTab = _tabTextSettings;
      } else if (selectedElement?.type == 'image' &&
          (_selectedBottomTab == _tabTextPosition ||
              _selectedBottomTab == _tabTextSettings)) {
        _selectedBottomTab = _tabElements;
      }
      _refreshPageControllerViewportIfNeeded();
    });
    if (selectedElement != null &&
        _elementCrossesPageBoundary(selectedElement)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpPreviewToPage(_currentPageIndex);
      });
    }
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(
        _bottomTabs.indexOf(_selectedBottomTab),
      );
    }
  }

  void _handleElementDoubleTap({
    required String pageId,
    required String elementId,
  }) {
    final element = _findElementById(elementId);

    if (_selectedElementId != elementId) {
      _selectElement(elementId);
    }
    if (element?.type == 'text') {
      unawaited(_showTextEditor(elementId));
      return;
    }
    unawaited(_fitElementToCanvas(pageId: pageId, elementId: elementId));
  }

  CanvasElement? _findElementById(String elementId, {String? type}) {
    for (final page in _project.pages) {
      for (final item in page.elements) {
        if (item.id == elementId && (type == null || item.type == type)) {
          return item;
        }
      }
    }
    return null;
  }

  Future<void> _replaceElement(
    CanvasElement updatedElement, {
    required bool persist,
  }) async {
    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == updatedElement.pageId,
    );
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final elementIndex = page.elements.indexWhere(
      (element) => element.id == updatedElement.id,
    );
    if (elementIndex == -1) {
      return;
    }

    final updatedElements = List<CanvasElement>.from(page.elements);
    updatedElements[elementIndex] = updatedElement;

    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[pageIndex] = page.copyWith(elements: updatedElements);

    final updatedProject = _project.copyWith(
      pages: updatedPages,
      pageCount: updatedPages.length,
    );

    setState(() {
      _project = updatedProject;
    });

    if (persist) {
      _hasPendingElementUndoSnapshot = false;
      await _saveProject(updatedProject);
    }
  }

  Future<void> _showTextEditor(String elementId) async {
    final element = _findElementById(elementId, type: 'text');
    if (element == null) {
      return;
    }

    final strings = AppStrings.of(context);
    final nextText = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(strings.t('editText')),
          content: _TextEditorField(
            initialText: _textContentFromData(element.data),
          ),
        );
      },
    );
    if (!mounted || nextText == null) {
      return;
    }

    final trimmedText = nextText.trim().isEmpty ? 'Text' : nextText.trim();
    final latestElement = _findElementById(elementId, type: 'text');
    if (latestElement == null ||
        _textContentFromData(latestElement.data) == trimmedText) {
      return;
    }
    _storeUndoSnapshot();
    await _replaceElement(
      latestElement.copyWith(
        data: <String, dynamic>{...latestElement.data, 'text': trimmedText},
      ),
      persist: true,
    );
  }

  Future<void> _updateSelectedTextColor(Color color) async {
    final selectedText = _selectedTextElement;
    if (selectedText == null) {
      return;
    }

    _storeUndoSnapshot();
    await _replaceElement(
      selectedText.copyWith(
        data: <String, dynamic>{
          ...selectedText.data,
          'colorValue': color.toARGB32(),
        },
      ),
      persist: true,
    );
  }

  void _updateSelectedTextSize(double fontSizeRatio, {required bool persist}) {
    final selectedText = _selectedTextElement;
    if (selectedText == null) {
      return;
    }
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }

    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == selectedText.pageId,
    );
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final updatedData = <String, dynamic>{
      ...selectedText.data,
      'fontSizeRatio': fontSizeRatio.clamp(0.025, 0.16).toDouble(),
    };
    final updatedElement = selectedText.copyWith(data: updatedData);
    final nextHeight = _textRenderedHeightRatio(
      element: updatedElement,
      page: page,
    );
    final maxY = (1 - nextHeight).clamp(0.0, 1.0);
    unawaited(
      _replaceElement(
        updatedElement.copyWith(
          height: nextHeight,
          y: updatedElement.y.clamp(0.0, maxY),
        ),
        persist: persist,
      ),
    );
  }

  void _updateElementPosition({
    required String pageId,
    required String elementId,
    required double x,
    required double y,
    required bool persist,
  }) {
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }
    final pageIndex = _project.pages.indexWhere((page) => page.id == pageId);
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final element = page.elements.firstWhere((item) => item.id == elementId);
    final maxX = (1 - element.width).clamp(0.0, 1.0);
    final maxY = (1 - _elementRenderedHeight(element, page)).clamp(0.0, 1.0);
    final rawX = _displayMode == PageDisplayMode.single
        ? x.clamp(0.0, maxX)
        : x.clamp(-0.95, 1.95);
    final rawY = y.clamp(0.0, maxY);
    final snappedPosition = _snapEnabledForElement(element)
        ? _snapElementPosition(
            pageIndex: pageIndex,
            page: page,
            element: element,
            x: rawX,
            y: rawY,
            maxX: maxX,
            maxY: maxY,
          )
        : _SnapResult(x: rawX, y: rawY);
    final updatedElement = element.copyWith(
      x: snappedPosition.x,
      y: snappedPosition.y,
    );

    final nextGuides = persist ? const <_SnapGuide>[] : snappedPosition.guides;
    if (_activeSnapGuides != nextGuides || _deleteArmedElementId == elementId) {
      setState(() {
        _activeSnapGuides = nextGuides;
        if (_deleteArmedElementId == elementId) {
          _deleteArmedElementId = null;
        }
      });
    }

    unawaited(_replaceElement(updatedElement, persist: persist));
  }

  _SnapResult _snapElementPosition({
    required int pageIndex,
    required ProjectPage page,
    required CanvasElement element,
    required double x,
    required double y,
    required double maxX,
    required double maxY,
  }) {
    const snapThreshold = 0.018;
    final snapPageEdges = _snapFlagForElement(element, 'snapPageEdges');
    final snapPageCenter = _snapFlagForElement(element, 'snapPageCenter');
    final snapImageLines = _snapFlagForElement(element, 'snapImageLines');
    final snapImageEdges = _snapFlagForElement(element, 'snapImageEdges');
    final elementHeight = _elementRenderedHeight(element, page);
    final xCandidates = <double>[x, x + element.width / 2, x + element.width];
    final yCandidates = <double>[y, y + elementHeight / 2, y + elementHeight];
    final xTargets = <_SnapTarget>[];
    final yTargets = <_SnapTarget>[];
    final xOffsets = <_SnapTarget>[];
    final yOffsets = <_SnapTarget>[];

    void addPageTarget(int targetPageIndex, double value) {
      final globalX = targetPageIndex + value;
      xTargets.add(
        _SnapTarget(
          value: globalX - pageIndex,
          guideValue: globalX,
          axis: _SnapGuideAxis.vertical,
        ),
      );
      yTargets.add(
        _SnapTarget(
          value: value,
          guideValue: value,
          axis: _SnapGuideAxis.horizontal,
        ),
      );
    }

    if (snapPageEdges) {
      addPageTarget(pageIndex, 0);
      addPageTarget(pageIndex, 1);
    }
    if (snapPageCenter) {
      addPageTarget(pageIndex, 0.5);
      addPageTarget(pageIndex, 0.25);
      addPageTarget(pageIndex, 0.75);
    }

    for (
      var otherPageIndex = 0;
      otherPageIndex < _project.pages.length;
      otherPageIndex++
    ) {
      final otherPage = _project.pages[otherPageIndex];
      final pageOffset = (otherPageIndex - pageIndex).toDouble();
      for (final other in otherPage.elements) {
        if (other.id == element.id || other.type != 'image') {
          continue;
        }

        final otherHeight = _elementRenderedHeight(other, otherPage);
        final otherLeft = pageOffset + other.x;
        final otherCenterX = otherLeft + other.width / 2;
        final otherRight = otherLeft + other.width;
        final otherTop = other.y;
        final otherCenterY = otherTop + otherHeight / 2;
        final otherBottom = otherTop + otherHeight;
        final elementTop = y;
        final elementBottom = y + elementHeight;
        final verticalGuideStart = elementTop < otherTop
            ? elementTop
            : otherTop;
        final verticalGuideEnd = elementBottom > otherBottom
            ? elementBottom
            : otherBottom;
        final elementGlobalLeft = pageIndex + x;
        final elementGlobalRight = elementGlobalLeft + element.width;
        final otherGlobalLeft = pageIndex + otherLeft;
        final otherGlobalRight = pageIndex + otherRight;
        final horizontalGuideStart = elementGlobalLeft < otherGlobalLeft
            ? elementGlobalLeft
            : otherGlobalLeft;
        final horizontalGuideEnd = elementGlobalRight > otherGlobalRight
            ? elementGlobalRight
            : otherGlobalRight;

        if (snapImageLines) {
          for (final value in <double>[otherLeft, otherCenterX, otherRight]) {
            xTargets.add(
              _SnapTarget(
                value: value,
                guideValue: pageIndex + value,
                axis: _SnapGuideAxis.vertical,
                guideStart: verticalGuideStart,
                guideEnd: verticalGuideEnd,
              ),
            );
          }
          for (final value in <double>[otherTop, otherCenterY, otherBottom]) {
            yTargets.add(
              _SnapTarget(
                value: value,
                guideValue: value,
                axis: _SnapGuideAxis.horizontal,
                guideStart: horizontalGuideStart,
                guideEnd: horizontalGuideEnd,
              ),
            );
          }
        }

        if (snapImageEdges) {
          xOffsets.addAll(<_SnapTarget>[
            _SnapTarget(
              value: otherLeft - element.width,
              guideValue: pageIndex + otherLeft,
              axis: _SnapGuideAxis.vertical,
              guideStart: verticalGuideStart,
              guideEnd: verticalGuideEnd,
            ),
            _SnapTarget(
              value: otherRight,
              guideValue: pageIndex + otherRight,
              axis: _SnapGuideAxis.vertical,
              guideStart: verticalGuideStart,
              guideEnd: verticalGuideEnd,
            ),
          ]);
          yOffsets.addAll(<_SnapTarget>[
            _SnapTarget(
              value: otherTop - elementHeight,
              guideValue: otherTop,
              axis: _SnapGuideAxis.horizontal,
              guideStart: horizontalGuideStart,
              guideEnd: horizontalGuideEnd,
            ),
            _SnapTarget(
              value: otherBottom,
              guideValue: otherBottom,
              axis: _SnapGuideAxis.horizontal,
              guideStart: horizontalGuideStart,
              guideEnd: horizontalGuideEnd,
            ),
          ]);
        }
      }
    }

    final xGuides = <_SnapGuide>[];
    var snappedX = x;
    var bestXDistance = snapThreshold;

    for (final target in xTargets) {
      for (final candidate in xCandidates) {
        final distance = (target.value - candidate).abs();
        if (distance < bestXDistance) {
          bestXDistance = distance;
          snappedX = x + (target.value - candidate);
          xGuides
            ..clear()
            ..add(_SnapGuide(
              axis: target.axis,
              value: target.guideValue,
              start: target.guideStart,
              end: target.guideEnd,
            ));
        }
      }
    }
    for (final target in xOffsets) {
      final distance = (target.value - x).abs();
      if (distance < bestXDistance) {
        bestXDistance = distance;
        snappedX = target.value;
        xGuides
          ..clear()
          ..add(_SnapGuide(
            axis: target.axis,
            value: target.guideValue,
            start: target.guideStart,
            end: target.guideEnd,
          ));
      }
    }

    // Equidistant horizontal spacing/boundaries snapping
    final hBoundaries = <double>[0.0, 1.0];
    for (final other in page.elements) {
      if (other.id != element.id && other.type == 'image') {
        hBoundaries.add(other.x);
        hBoundaries.add(other.x + other.width);
      }
    }
    final uniqueHBoundaries = hBoundaries.toSet().toList()..sort();
    for (var i = 0; i < uniqueHBoundaries.length; i++) {
      for (var j = i + 1; j < uniqueHBoundaries.length; j++) {
        final L = uniqueHBoundaries[i];
        final R = uniqueHBoundaries[j];
        final targetX = (L + R - element.width) / 2;
        final distance = (targetX - x).abs();
        if (distance < bestXDistance) {
          bestXDistance = distance;
          snappedX = targetX;
          xGuides
            ..clear()
            ..add(_SnapGuide(
              axis: _SnapGuideAxis.vertical,
              value: pageIndex + L,
            ))
            ..add(_SnapGuide(
              axis: _SnapGuideAxis.vertical,
              value: pageIndex + R,
            ))
            ..add(_SnapGuide(
              axis: _SnapGuideAxis.vertical,
              value: pageIndex + (L + R) / 2,
            ));
        }
      }
    }

    final yGuides = <_SnapGuide>[];
    var snappedY = y;
    var bestYDistance = snapThreshold;

    for (final target in yTargets) {
      for (final candidate in yCandidates) {
        final distance = (target.value - candidate).abs();
        if (distance < bestYDistance) {
          bestYDistance = distance;
          snappedY = y + (target.value - candidate);
          yGuides
            ..clear()
            ..add(_SnapGuide(
              axis: target.axis,
              value: target.guideValue,
              start: target.guideStart,
              end: target.guideEnd,
            ));
        }
      }
    }
    for (final target in yOffsets) {
      final distance = (target.value - y).abs();
      if (distance < bestYDistance) {
        bestYDistance = distance;
        snappedY = target.value;
        yGuides
          ..clear()
          ..add(_SnapGuide(
            axis: target.axis,
            value: target.guideValue,
            start: target.guideStart,
            end: target.guideEnd,
          ));
      }
    }

    // Equidistant vertical spacing/boundaries snapping
    final vBoundaries = <double>[0.0, 1.0];
    for (final other in page.elements) {
      if (other.id != element.id && other.type == 'image') {
        final otherHeight = _elementRenderedHeight(other, page);
        vBoundaries.add(other.y);
        vBoundaries.add(other.y + otherHeight);
      }
    }
    final uniqueVBoundaries = vBoundaries.toSet().toList()..sort();
    for (var i = 0; i < uniqueVBoundaries.length; i++) {
      for (var j = i + 1; j < uniqueVBoundaries.length; j++) {
        final T = uniqueVBoundaries[i];
        final B = uniqueVBoundaries[j];
        final targetY = (T + B - elementHeight) / 2;
        final distance = (targetY - y).abs();
        if (distance < bestYDistance) {
          bestYDistance = distance;
          snappedY = targetY;
          yGuides
            ..clear()
            ..add(_SnapGuide(
              axis: _SnapGuideAxis.horizontal,
              value: T,
            ))
            ..add(_SnapGuide(
              axis: _SnapGuideAxis.horizontal,
              value: B,
            ))
            ..add(_SnapGuide(
              axis: _SnapGuideAxis.horizontal,
              value: (T + B) / 2,
            ));
        }
      }
    }

    return _SnapResult(
      x: _displayMode == PageDisplayMode.single
          ? snappedX.clamp(0.0, maxX)
          : snappedX.clamp(-0.95, 1.95),
      y: snappedY.clamp(0.0, maxY),
      guides: <_SnapGuide>[
        ...xGuides,
        ...yGuides,
      ],
    );
  }

  void _updateElementSize({
    required String pageId,
    required String elementId,
    required double width,
    required bool persist,
  }) {
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }
    final pageIndex = _project.pages.indexWhere((page) => page.id == pageId);
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final element = page.elements.firstWhere((item) => item.id == elementId);
    final aspectRatio =
        (element.data['aspectRatio'] as num?)?.toDouble() ??
        (element.width / element.height);
    final maxAllowedWidth = _maxElementResizeWidth(
      page: page,
      element: element,
      aspectRatio: aspectRatio,
    );
    final nextWidth = width.clamp(0.08, maxAllowedWidth);
    final snapResult = _snapEnabledForElement(element)
        ? _snapElementSize(
            pageIndex: pageIndex,
            page: page,
            element: element,
            width: nextWidth,
          )
        : _SnapResult(x: element.x + nextWidth, y: element.y);
    final rawSnappedWidth = snapResult.x - element.x;
    final snappedWidth = rawSnappedWidth.clamp(0.08, maxAllowedWidth);
    final snapWasClamped = (rawSnappedWidth - snappedWidth).abs() > 0.0001;
    final nextHeight = _elementRenderedHeight(
      element,
      page,
      width: snappedWidth,
    );
    final maxX = (1 - snappedWidth).clamp(0.0, 1.0);
    final maxY = (1 - nextHeight).clamp(0.0, 1.0);
    final updatedElement = element.copyWith(
      width: snappedWidth,
      height: nextHeight,
      x: (_displayMode == PageDisplayMode.single
          ? element.x.clamp(0.0, maxX)
          : element.x),
      y: element.y.clamp(0.0, maxY),
      data: <String, dynamic>{...element.data, 'aspectRatio': aspectRatio},
    );

    final nextGuides = persist || snapWasClamped
        ? const <_SnapGuide>[]
        : snapResult.guides;
    if (_activeSnapGuides != nextGuides || _deleteArmedElementId == elementId) {
      setState(() {
        _activeSnapGuides = nextGuides;
        if (_deleteArmedElementId == elementId) {
          _deleteArmedElementId = null;
        }
      });
    }

    unawaited(_replaceElement(updatedElement, persist: persist));
  }

  double _maxElementResizeWidth({
    required ProjectPage page,
    required CanvasElement element,
    required double aspectRatio,
  }) {
    if (_displayMode != PageDisplayMode.single) {
      return 2.2;
    }

    final maxWidthByRight = (1 - element.x).clamp(0.08, 1.0).toDouble();
    final maxHeightByBottom = (1 - element.y).clamp(0.0, 1.0).toDouble();
    final maxWidthByBottom =
        (maxHeightByBottom *
                aspectRatio *
                (page.aspectHeight / page.aspectWidth))
            .clamp(0.08, 1.0)
            .toDouble();
    final maxWidth = maxWidthByRight < maxWidthByBottom
        ? maxWidthByRight
        : maxWidthByBottom;

    return maxWidth.clamp(0.08, 1.0).toDouble();
  }

  _SnapResult _snapElementSize({
    required int pageIndex,
    required ProjectPage page,
    required CanvasElement element,
    required double width,
  }) {
    const snapThreshold = 0.018;
    final snapPageEdges = _snapFlagForElement(element, 'snapPageEdges');
    final snapPageCenter = _snapFlagForElement(element, 'snapPageCenter');
    final snapImageLines = _snapFlagForElement(element, 'snapImageLines');
    final snapImageEdges = _snapFlagForElement(element, 'snapImageEdges');
    final frameAspectRatio =
        (element.data['aspectRatio'] as num?)?.toDouble() ??
        (element.width / element.height);
    final height = _elementRenderedHeight(element, page, width: width);
    final right = element.x + width;
    final bottom = element.y + height;
    final centerX = element.x + width / 2;
    final centerY = element.y + height / 2;
    final xTargets = <_SnapTarget>[];
    final yTargets = <_SnapTarget>[];

    void addPageTarget(int targetPageIndex, double value) {
      final globalX = targetPageIndex + value;
      xTargets.add(
        _SnapTarget(
          value: globalX - pageIndex,
          guideValue: globalX,
          axis: _SnapGuideAxis.vertical,
        ),
      );
      yTargets.add(
        _SnapTarget(
          value: value,
          guideValue: value,
          axis: _SnapGuideAxis.horizontal,
        ),
      );
    }

    if (snapPageEdges) {
      addPageTarget(pageIndex, 0);
      addPageTarget(pageIndex, 1);
    }
    if (snapPageCenter) {
      addPageTarget(pageIndex, 0.25);
      addPageTarget(pageIndex, 0.5);
      addPageTarget(pageIndex, 0.75);
    }

    for (
      var otherPageIndex = 0;
      otherPageIndex < _project.pages.length;
      otherPageIndex++
    ) {
      final otherPage = _project.pages[otherPageIndex];
      final pageOffset = (otherPageIndex - pageIndex).toDouble();
      for (final other in otherPage.elements) {
        if (other.id == element.id || other.type != 'image') {
          continue;
        }

        final otherHeight = _elementRenderedHeight(other, otherPage);
        final otherLeft = pageOffset + other.x;
        final otherCenterX = otherLeft + other.width / 2;
        final otherRight = otherLeft + other.width;
        final otherTop = other.y;
        final otherCenterY = otherTop + otherHeight / 2;
        final otherBottom = otherTop + otherHeight;
        final verticalGuideStart = element.y < otherTop ? element.y : otherTop;
        final verticalGuideEnd = bottom > otherBottom ? bottom : otherBottom;
        final elementGlobalLeft = pageIndex + element.x;
        final elementGlobalRight = pageIndex + right;
        final otherGlobalLeft = pageIndex + otherLeft;
        final otherGlobalRight = pageIndex + otherRight;
        final horizontalGuideStart = elementGlobalLeft < otherGlobalLeft
            ? elementGlobalLeft
            : otherGlobalLeft;
        final horizontalGuideEnd = elementGlobalRight > otherGlobalRight
            ? elementGlobalRight
            : otherGlobalRight;

        if (snapImageLines) {
          for (final value in <double>[otherLeft, otherCenterX, otherRight]) {
            xTargets.add(
              _SnapTarget(
                value: value,
                guideValue: pageIndex + value,
                axis: _SnapGuideAxis.vertical,
                guideStart: verticalGuideStart,
                guideEnd: verticalGuideEnd,
              ),
            );
          }
          for (final value in <double>[otherTop, otherCenterY, otherBottom]) {
            yTargets.add(
              _SnapTarget(
                value: value,
                guideValue: value,
                axis: _SnapGuideAxis.horizontal,
                guideStart: horizontalGuideStart,
                guideEnd: horizontalGuideEnd,
              ),
            );
          }
        }

        if (snapImageEdges) {
          xTargets.addAll(<_SnapTarget>[
            _SnapTarget(
              value: otherLeft,
              guideValue: pageIndex + otherLeft,
              axis: _SnapGuideAxis.vertical,
              guideStart: verticalGuideStart,
              guideEnd: verticalGuideEnd,
            ),
            _SnapTarget(
              value: otherRight,
              guideValue: pageIndex + otherRight,
              axis: _SnapGuideAxis.vertical,
              guideStart: verticalGuideStart,
              guideEnd: verticalGuideEnd,
            ),
          ]);
          yTargets.addAll(<_SnapTarget>[
            _SnapTarget(
              value: otherTop,
              guideValue: otherTop,
              axis: _SnapGuideAxis.horizontal,
              guideStart: horizontalGuideStart,
              guideEnd: horizontalGuideEnd,
            ),
            _SnapTarget(
              value: otherBottom,
              guideValue: otherBottom,
              axis: _SnapGuideAxis.horizontal,
              guideStart: horizontalGuideStart,
              guideEnd: horizontalGuideEnd,
            ),
          ]);
        }
      }
    }

    var snappedWidth = width;
    var bestDistance = snapThreshold;
    _SnapGuide? guide;

    for (final target in xTargets) {
      final rightDistance = (target.value - right).abs();
      if (rightDistance < bestDistance) {
        bestDistance = rightDistance;
        snappedWidth = target.value - element.x;
        guide = _SnapGuide(
          axis: target.axis,
          value: target.guideValue,
          start: target.guideStart,
          end: target.guideEnd,
        );
      }

      final centerDistance = (target.value - centerX).abs();
      if (centerDistance < bestDistance) {
        bestDistance = centerDistance;
        snappedWidth = (target.value - element.x) * 2;
        guide = _SnapGuide(
          axis: target.axis,
          value: target.guideValue,
          start: target.guideStart,
          end: target.guideEnd,
        );
      }
    }

    for (final target in yTargets) {
      final bottomDistance = (target.value - bottom).abs();
      if (bottomDistance < bestDistance) {
        bestDistance = bottomDistance;
        final snappedHeight = target.value - element.y;
        snappedWidth =
            snappedHeight *
            frameAspectRatio *
            (page.aspectHeight / page.aspectWidth);
        guide = _SnapGuide(
          axis: target.axis,
          value: target.guideValue,
          start: target.guideStart,
          end: target.guideEnd,
        );
      }

      final centerDistance = (target.value - centerY).abs();
      if (centerDistance < bestDistance) {
        bestDistance = centerDistance;
        final snappedHeight = (target.value - element.y) * 2;
        snappedWidth =
            snappedHeight *
            frameAspectRatio *
            (page.aspectHeight / page.aspectWidth);
        guide = _SnapGuide(
          axis: target.axis,
          value: target.guideValue,
          start: target.guideStart,
          end: target.guideEnd,
        );
      }
    }

    return _SnapResult(
      x: element.x + snappedWidth,
      y: element.y,
      guides: <_SnapGuide>[if (guide != null) guide],
    );
  }

  ({double value, double min, double max}) _imageSizeSliderRange(
    CanvasElement image,
  ) {
    const min = 0.08;
    var max = _displayMode == PageDisplayMode.single ? 1.0 : 2.2;
    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == image.pageId,
    );
    if (pageIndex != -1) {
      final page = _project.pages[pageIndex];
      final aspectRatio =
          (image.data['aspectRatio'] as num?)?.toDouble() ??
          (image.width / image.height);
      max = _maxElementResizeWidth(
        page: page,
        element: image,
        aspectRatio: aspectRatio > 0 ? aspectRatio : 1.0,
      );
    }
    if (max <= min) {
      max = min + 0.001;
    }
    return (value: image.width.clamp(min, max).toDouble(), min: min, max: max);
  }

  ({double width, double height}) _elementPositionPagePixelSize(
    CanvasElement element, {
    required double singleCanvasWidth,
    required double previewCanvasWidth,
  }) {
    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == element.pageId,
    );
    final page = pageIndex == -1
        ? _project.pages[_currentPageIndex]
        : _project.pages[pageIndex];
    final width = _displayMode == PageDisplayMode.single
        ? (singleCanvasWidth - (_canvasControlChromePadding * 2))
              .clamp(1.0, singleCanvasWidth)
              .toDouble()
        : previewCanvasWidth.clamp(1.0, double.infinity).toDouble();
    return (
      width: width,
      height: width * (page.aspectHeight / page.aspectWidth),
    );
  }

  ({
    double x,
    double y,
    double minX,
    double maxX,
    double minY,
    double maxY,
    double pixelStepX,
    double pixelStepY,
  })
  _elementPositionSliderRange(
    CanvasElement element, {
    required ({double width, double height}) pagePixelSize,
  }) {
    final minX = _displayMode == PageDisplayMode.single ? 0.0 : -0.95;
    var maxX = _displayMode == PageDisplayMode.single
        ? (1 - element.width).clamp(0.0, 1.0).toDouble()
        : 1.95;
    const minY = 0.0;
    var maxY = (1 - element.height).clamp(0.0, 1.0).toDouble();
    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == element.pageId,
    );
    if (pageIndex != -1) {
      final page = _project.pages[pageIndex];
      maxY = (1 - _elementRenderedHeight(element, page))
          .clamp(0.0, 1.0)
          .toDouble();
    }
    if (maxX <= minX) {
      maxX = minX + 0.001;
    }
    if (maxY <= minY) {
      maxY = minY + 0.001;
    }
    return (
      x: element.x.clamp(minX, maxX).toDouble(),
      y: element.y.clamp(minY, maxY).toDouble(),
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      pixelStepX: 1 / pagePixelSize.width.clamp(1.0, double.infinity),
      pixelStepY: 1 / pagePixelSize.height.clamp(1.0, double.infinity),
    );
  }

  void _updateSelectedImagePositionFromSlider({
    required double x,
    required double y,
    required bool persist,
  }) {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }
    _updateElementPosition(
      pageId: selectedImage.pageId,
      elementId: selectedImage.id,
      x: x,
      y: y,
      persist: persist,
    );
  }

  void _updateSelectedTextPositionFromSlider({
    required double x,
    required double y,
    required bool persist,
  }) {
    final selectedText = _selectedTextElement;
    if (selectedText == null) {
      return;
    }
    _updateElementPosition(
      pageId: selectedText.pageId,
      elementId: selectedText.id,
      x: x,
      y: y,
      persist: persist,
    );
  }

  void _updateSelectedImageSizeFromSlider(
    double width, {
    required bool persist,
  }) {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }
    _updateElementSize(
      pageId: selectedImage.pageId,
      elementId: selectedImage.id,
      width: width,
      persist: persist,
    );
  }

  void _updateSelectedImageBorderRadius(double ratio, {required bool persist}) {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }

    final updatedData = <String, dynamic>{
      ...selectedImage.data,
      'borderRadiusRatio': ratio.clamp(0.0, 0.5).toDouble(),
    };
    final updatedElement = selectedImage.copyWith(data: updatedData);
    unawaited(
      _replaceElement(
        updatedElement,
        persist: persist,
      ),
    );
  }

  void _startCroppingSelectedImage() {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }

    setState(() {
      _croppingElementId = selectedImage.id;
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabImageSettings;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(
        _bottomTabs.indexOf(_tabImageSettings),
      );
    }
  }

  void _finishCroppingSelectedImage() {
    if (_croppingElementId == null) {
      return;
    }
    setState(() {
      _croppingElementId = null;
    });
  }

  void _updateImageCropOffset({
    required String elementId,
    required double x,
    required double y,
    required bool persist,
  }) {
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }
    final element = _selectedImageElement;
    if (element == null || element.id != elementId) {
      return;
    }
    final clamped = _clampedCropOffsetForElement(element, x: x, y: y);
    final updatedElement = element.copyWith(
      data: <String, dynamic>{
        ...element.data,
        'cropOffsetX': clamped.x,
        'cropOffsetY': clamped.y,
        'cropScale': _cropScaleFromData(element.data),
      },
    );

    unawaited(_replaceElement(updatedElement, persist: persist));
  }

  void _updateImageCropScale({
    required String elementId,
    required double scale,
    required bool persist,
  }) {
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }
    final element = _selectedImageElement;
    if (element == null || element.id != elementId) {
      return;
    }
    final nextScale = scale.clamp(1.0, _cropScaleSliderMax).toDouble();
    final clamped = _clampedCropOffsetForElement(
      element,
      x: _cropOffsetXFromData(element.data),
      y: _cropOffsetYFromData(element.data),
      scale: nextScale,
    );
    final updatedElement = element.copyWith(
      data: <String, dynamic>{
        ...element.data,
        'cropOffsetX': clamped.x,
        'cropOffsetY': clamped.y,
        'cropScale': nextScale,
      },
    );

    unawaited(_replaceElement(updatedElement, persist: persist));
  }

  void _updateImageCropBounds({
    required String elementId,
    required double x,
    required double y,
    required double width,
    required double height,
    required double cropOffsetX,
    required double cropOffsetY,
    required double cropScale,
    required bool persist,
  }) {
    if (!persist && !_hasPendingElementUndoSnapshot) {
      _storeUndoSnapshot();
      _hasPendingElementUndoSnapshot = true;
    }
    final element = _selectedImageElement;
    if (element == null || element.id != elementId) {
      return;
    }

    final updatedElement = element.copyWith(
      x: x,
      y: y,
      width: width,
      height: height,
      data: <String, dynamic>{
        ...element.data,
        'aspectRatio': width / height,
        'aspectPreset': 'custom',
        'cropOffsetX': cropOffsetX,
        'cropOffsetY': cropOffsetY,
        'cropScale': cropScale,
      },
    );

    unawaited(_replaceElement(updatedElement, persist: persist));
  }

  Future<void> _nudgeSelectedImage(double dx, double dy) async {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }

    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == selectedImage.pageId,
    );
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final maxX = (1 - selectedImage.width).clamp(0.0, 1.0);
    final maxY = (1 - _elementRenderedHeight(selectedImage, page)).clamp(
      0.0,
      1.0,
    );
    final rawX = _displayMode == PageDisplayMode.single
        ? (selectedImage.x + dx).clamp(0.0, maxX)
        : (selectedImage.x + dx).clamp(-0.95, 1.95);
    final rawY = (selectedImage.y + dy).clamp(0.0, maxY);

    if (rawX == selectedImage.x && rawY == selectedImage.y) {
      return;
    }

    _storeUndoSnapshot();
    if (_activeSnapGuides.isNotEmpty ||
        _deleteArmedElementId == selectedImage.id) {
      setState(() {
        _activeSnapGuides = const <_SnapGuide>[];
        if (_deleteArmedElementId == selectedImage.id) {
          _deleteArmedElementId = null;
        }
      });
    }

    await _replaceElement(
      selectedImage.copyWith(x: rawX, y: rawY),
      persist: true,
    );
  }

  Future<void> _nudgeSelectedText(double dx, double dy) async {
    final selectedText = _selectedTextElement;
    if (selectedText == null) {
      return;
    }

    final pageIndex = _project.pages.indexWhere(
      (page) => page.id == selectedText.pageId,
    );
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final maxX = (1 - selectedText.width).clamp(0.0, 1.0);
    final maxY = (1 - _elementRenderedHeight(selectedText, page)).clamp(
      0.0,
      1.0,
    );
    final rawX = _displayMode == PageDisplayMode.single
        ? (selectedText.x + dx).clamp(0.0, maxX)
        : (selectedText.x + dx).clamp(-0.95, 1.95);
    final rawY = (selectedText.y + dy).clamp(0.0, maxY);

    if (rawX == selectedText.x && rawY == selectedText.y) {
      return;
    }

    _storeUndoSnapshot();
    if (_activeSnapGuides.isNotEmpty ||
        _deleteArmedElementId == selectedText.id) {
      setState(() {
        _activeSnapGuides = const <_SnapGuide>[];
        if (_deleteArmedElementId == selectedText.id) {
          _deleteArmedElementId = null;
        }
      });
    }

    await _replaceElement(
      selectedText.copyWith(x: rawX, y: rawY),
      persist: true,
    );
  }

  Future<void> _fitElementToCanvas({
    required String pageId,
    required String elementId,
  }) async {
    final pageIndex = _project.pages.indexWhere((page) => page.id == pageId);
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final elementIndex = page.elements.indexWhere(
      (item) => item.id == elementId,
    );
    if (elementIndex == -1) {
      return;
    }

    final element = page.elements[elementIndex];
    final imageAspectRatio =
        (element.data['originalAspectRatio'] as num?)?.toDouble() ??
        (element.data['aspectRatio'] as num?)?.toDouble() ??
        (element.width / element.height);
    if (imageAspectRatio <= 0) {
      return;
    }

    final pageAspectRatio = page.aspectWidth / page.aspectHeight;
    final fittedWidth = imageAspectRatio >= pageAspectRatio
        ? 1.0
        : (imageAspectRatio / pageAspectRatio).clamp(0.0, 1.0);
    final fittedHeight = imageAspectRatio >= pageAspectRatio
        ? (pageAspectRatio / imageAspectRatio).clamp(0.0, 1.0)
        : 1.0;

    _storeUndoSnapshot();
    await _replaceElement(
      element.copyWith(
        x: (1 - fittedWidth) / 2,
        y: (1 - fittedHeight) / 2,
        width: fittedWidth,
        height: fittedHeight,
        data: <String, dynamic>{
          ...element.data,
          'aspectRatio': imageAspectRatio,
          'aspectPreset': 'original',
        },
      ),
      persist: true,
    );
  }

  Future<void> _updateSelectedImageAspect(_ImageAspectOption option) async {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }

    final originalAspectRatio =
        (selectedImage.data['originalAspectRatio'] as num?)?.toDouble() ??
        (selectedImage.data['aspectRatio'] as num?)?.toDouble() ??
        1.0;
    final currentAspectRatio =
        (selectedImage.data['aspectRatio'] as num?)?.toDouble() ??
        originalAspectRatio;
    final nextAspectRatio = option.aspectRatio ?? originalAspectRatio;
    final currentHeight = selectedImage.width / currentAspectRatio;
    final nextHeight = selectedImage.width / nextAspectRatio;
    final centerY = selectedImage.y + (currentHeight / 2);
    final maxY = (1 - nextHeight).clamp(0.0, 1.0);
    final nextY = (centerY - (nextHeight / 2)).clamp(0.0, maxY);

    var updatedElement = selectedImage.copyWith(
      y: nextY,
      data: <String, dynamic>{
        ...selectedImage.data,
        'aspectRatio': nextAspectRatio,
        'originalAspectRatio': originalAspectRatio,
        'aspectPreset': option.key,
      },
    );
    final clampedCrop = _clampedCropOffsetForElement(
      updatedElement,
      x: _cropOffsetXFromData(updatedElement.data),
      y: _cropOffsetYFromData(updatedElement.data),
    );
    updatedElement = updatedElement.copyWith(
      data: <String, dynamic>{
        ...updatedElement.data,
        'cropOffsetX': clampedCrop.x,
        'cropOffsetY': clampedCrop.y,
      },
    );

    await _replaceElement(updatedElement, persist: true);
  }

  Future<bool> _confirmApplyTemplateIfNeeded(ProjectPage page) async {
    if (page.elements.isEmpty) {
      return true;
    }

    final strings = AppStrings.of(context);
    final shouldApply = await showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F4),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Icon(
                    Icons.layers_clear_rounded,
                    size: 21,
                    color: Color(0xFF6F6F6F),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  strings.t('applyTemplate'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  strings.t('applyTemplateWarning'),
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Color(0xFF6A6A6A),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('cancel'),
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('clearAndApply'),
                        isPrimary: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    return shouldApply == true;
  }

  Future<void> _applyTemplate(_TemplateOption option) async {
    final currentPage = _project.pages[_currentPageIndex];
    final shouldApply = await _confirmApplyTemplateIfNeeded(currentPage);
    if (!mounted || !shouldApply) {
      return;
    }

    _storeUndoSnapshot();

    final existingImages = currentPage.elements
        .where(
          (e) =>
              e.type == 'image' &&
              e.data['src'] != null &&
              (e.data['src'] as String).isNotEmpty,
        )
        .toList();
    final existingTexts = currentPage.elements
        .where((e) => e.type == 'text')
        .toList();

    final templateElements = option.buildElements(currentPage.id, currentPage);
    final updatedElements = <CanvasElement>[];

    int imgPtr = 0;
    for (final element in templateElements) {
      if (element.type == 'image' && imgPtr < existingImages.length) {
        final existingImg = existingImages[imgPtr];
        imgPtr++;

        final existingData = Map<String, dynamic>.from(existingImg.data);
        final src = existingData['src'] as String? ?? '';
        final originalSrc = existingData['originalSrc'] as String? ?? '';
        final originalAspect =
            existingData['originalAspectRatio'] as double? ??
            existingData['aspectRatio'] as double? ??
            1.0;

        final newData = Map<String, dynamic>.from(element.data);
        newData['src'] = src;
        newData['originalSrc'] = originalSrc;
        newData['originalAspectRatio'] = originalAspect;

        if (option.id == 'page_fill') {
          const pageAspect = 3.0 / 4.0;
          final targetRatio = originalAspect / pageAspect;

          double wNorm, hNorm;
          if (targetRatio > 1.0) {
            wNorm = 1.0;
            hNorm = pageAspect / originalAspect;
          } else {
            hNorm = 1.0;
            wNorm = hNorm * targetRatio;
          }

          final xCoord = (1.0 - wNorm) / 2;
          final yCoord = (1.0 - hNorm) / 2;

          newData['aspectRatio'] = originalAspect;
          newData.remove('aspectPreset');

          updatedElements.add(
            element.copyWith(
              x: xCoord,
              y: yCoord,
              width: wNorm,
              height: hNorm,
              data: newData,
            ),
          );
        } else {
          newData['aspectRatio'] = originalAspect;
          updatedElements.add(element.copyWith(data: newData));
        }
      } else {
        updatedElements.add(element);
      }
    }

    updatedElements.addAll(existingTexts);

    final updatedPage = currentPage.copyWith(
      elements: updatedElements,
      extras: <String, dynamic>{...currentPage.extras, 'templateId': option.id},
    );

    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[_currentPageIndex] = updatedPage;

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedElementId = null;
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabElements;
    });
    _syncBottomTab();
  }

  Future<void> _deleteElement({
    required String pageId,
    required String elementId,
  }) async {
    final pageIndex = _project.pages.indexWhere((page) => page.id == pageId);
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final updatedPages = List<ProjectPage>.from(_project.pages);
    updatedPages[pageIndex] = page.copyWith(
      elements: page.elements
          .where((element) => element.id != elementId)
          .toList(),
    );

    await _saveProject(
      _project.copyWith(pages: updatedPages, pageCount: updatedPages.length),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      if (_selectedElementId == elementId) {
        _selectedElementId = null;
        _croppingElementId = null;
        _selectedBottomTab = _tabElements;
      }
      if (_croppingElementId == elementId) {
        _croppingElementId = null;
      }
      if (_deleteArmedElementId == elementId) {
        _deleteArmedElementId = null;
      }
      _activeSnapGuides = const <_SnapGuide>[];
    });

    if (_bottomTabPageController.hasClients) {
      final targetIndex = _bottomTabs.indexOf(_selectedBottomTab);
      if (targetIndex != -1) {
        _bottomTabPageController.jumpToPage(targetIndex);
      }
    }
  }

  Future<void> _confirmDeleteElement({
    required String pageId,
    required String elementId,
  }) async {
    if (_deleteArmedElementId != elementId) {
      return;
    }

    _storeUndoSnapshot();
    await _deleteElement(pageId: pageId, elementId: elementId);
  }

  void _cancelDeleteElement(String elementId) {
    if (_deleteArmedElementId != elementId) {
      return;
    }

    setState(() {
      _deleteArmedElementId = null;
    });
  }

  void _requestDeleteElement({required String elementId}) {
    _selectElement(elementId);

    setState(() {
      _deleteArmedElementId = elementId;
      _activeSnapGuides = const <_SnapGuide>[];
    });
  }

  void _jumpPreviewToPage(int pageIndex) {
    if (!_previewScrollController.hasClients) {
      return;
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final pageWidth = screenWidth * 0.78;
    _previewScrollController.jumpTo(pageWidth * pageIndex);
  }

  void _goToPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _project.pages.length) {
      return;
    }

    setState(() {
      _currentPageIndex = pageIndex;
      _selectedElementId = null;
      _croppingElementId = null;
      _deleteArmedElementId = null;
      _selectedSorterPageId = null;
      _showPageSorter = false;
      _refreshPageControllerViewportIfNeeded();
    });

    if (_displayMode == PageDisplayMode.single) {
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          pageIndex,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
        );
      }
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpPreviewToPage(pageIndex);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBottomTab());
  }

  void _syncPreviewPageIndex() {
    if (!_previewScrollController.hasClients) {
      return;
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final pageWidth = screenWidth * 0.78;
    final pageIndex = (_previewScrollController.offset / pageWidth)
        .round()
        .clamp(0, _project.pages.length - 1);

    if (pageIndex != _currentPageIndex) {
      setState(() {
        _currentPageIndex = pageIndex;
      });
    }
  }

  Future<Directory> _resolveExportDirectory() async => Directory.systemTemp;

  Future<void> _exportCurrentPageAsJpg() async {
    final strings = AppStrings.of(context);
    if (_isExporting) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isExporting = true;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final boundary =
          _exportRepaintKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception(strings.t('exportCanvasNotFound'));
      }

      final uiImage = await boundary.toImage(pixelRatio: 6);
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception(strings.t('canvasConvertFailed'));
      }

      final pngBytes = byteData.buffer.asUint8List();
      final decodedImage = img.decodeImage(pngBytes);
      if (decodedImage == null) {
        throw Exception(strings.t('imageDecodeFailed'));
      }

      final jpgBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 100),
      );

      final exportDirectory = await _resolveExportDirectory();
      await exportDirectory.create(recursive: true);

      final safeProjectName = _project.name
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File(
        '${exportDirectory.path}${Platform.pathSeparator}${safeProjectName.isEmpty ? 'project' : safeProjectName}_page${_currentPageIndex + 1}_$timestamp.jpg',
      );

      await file.writeAsBytes(jpgBytes, flush: true);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            strings.t('exportedJpg', args: <String, String>{'path': file.path}),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.t('exportFailedTryAgain'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  String _buildGalleryExportName(int pageIndex) {
    final safeProjectName = _project.name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final baseName = safeProjectName.isEmpty ? 'project' : safeProjectName;
    return '${baseName}_${pageIndex + 1}';
  }

  Future<img.Image?> _loadExportSourceImage(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    final bytes = await file.readAsBytes();
    return img.decodeImage(bytes);
  }

  Future<int> _computePageExportWidth(ProjectPage page) async {
    const defaultWidth = 2400;
    const maxWidth = 6000;
    var exportWidth = defaultWidth;

    for (final element in page.elements) {
      if (element.type != 'image') {
        continue;
      }

      final src = element.data['src'] as String? ?? '';
      if (src.isEmpty || element.width <= 0) {
        continue;
      }

      final sourceImage = await _loadExportSourceImage(src);
      if (sourceImage == null) {
        continue;
      }

      final candidateWidth = (sourceImage.width / element.width).ceil();
      if (candidateWidth > exportWidth) {
        exportWidth = candidateWidth;
      }
    }

    return exportWidth.clamp(defaultWidth, maxWidth);
  }

  Future<img.Image> _renderProjectPageForGallery(ProjectPage page) async {
    final exportWidth = await _computePageExportWidth(page);
    final exportHeight = (exportWidth * (page.aspectHeight / page.aspectWidth))
        .round();
    final canvas = img.Image(width: exportWidth, height: exportHeight);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

    for (final element in page.elements) {
      if (element.type != 'image') {
        continue;
      }

      final src = element.data['src'] as String? ?? '';
      if (src.isEmpty) {
        continue;
      }

      final sourceImage = await _loadExportSourceImage(src);
      if (sourceImage == null) {
        continue;
      }

      final aspectRatio =
          (element.data['aspectRatio'] as num?)?.toDouble() ??
          (sourceImage.width / sourceImage.height);
      final targetWidth = (element.width * exportWidth).round().clamp(1, 20000);
      final targetHeight = (targetWidth / aspectRatio).round().clamp(1, 20000);
      final targetX = (element.x * exportWidth).round();
      final targetY = (element.y * exportHeight).round();
      final croppedSource = _cropSourceToFrame(
        sourceImage: sourceImage,
        frameAspectRatio: aspectRatio,
        cropOffsetX: _cropOffsetXFromData(element.data),
        cropOffsetY: _cropOffsetYFromData(element.data),
        cropScale: _cropScaleFromData(element.data),
      );

      final resizedImage = img.copyResize(
        croppedSource,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.cubic,
      );

      img.compositeImage(canvas, resizedImage, dstX: targetX, dstY: targetY);
    }

    return canvas;
  }

  Future<bool> _saveImageToGallery({
    required Uint8List bytes,
    required String name,
  }) async {
    final result = await _galleryChannel.invokeMethod<bool>(
      'saveJpgToGallery',
      <String, dynamic>{'bytes': bytes, 'name': name},
    );
    return result ?? false;
  }

  Future<void> _primeExportImageCache({
    void Function(double progress, String label)? onProgress,
  }) async {
    final strings = AppStrings.of(context);
    final imagePaths = <String>{};
    for (final page in _project.pages) {
      for (final element in page.elements) {
        if (element.type != 'image') {
          continue;
        }

        final src =
            element.data['originalSrc'] as String? ??
            element.data['src'] as String? ??
            '';
        if (src.isNotEmpty) {
          imagePaths.add(src);
        }
      }
    }

    if (imagePaths.isEmpty) {
      return;
    }

    final missingPaths = imagePaths
        .where((path) => !_exportImageBytesCache.containsKey(path))
        .toList();
    if (missingPaths.isEmpty) {
      return;
    }

    for (var i = 0; i < missingPaths.length; i++) {
      final path = missingPaths[i];
      _setExportProgress(
        progress: missingPaths.isEmpty ? 0 : (i / missingPaths.length) * 0.2,
        label: strings.t(
          'prepareImages',
          args: <String, String>{
            'current': '${i + 1}',
            'total': '${missingPaths.length}',
          },
        ),
        onProgress: onProgress,
      );

      try {
        final bytes = await _readImageBytesForExport(path);
        if (bytes != null && bytes.isNotEmpty) {
          _exportImageBytesCache[path] = bytes;
        }
      } catch (_) {
        // Skip unreadable files so export can continue for the rest.
      }
    }

    _setExportProgress(
      progress: 0.2,
      label: strings.t('prepareImagesDone'),
      onProgress: onProgress,
    );
  }

  int _computeVisibleExportWidth() {
    final mediaQuery = MediaQuery.of(context);
    final visibleWidth = mediaQuery.size.width - 24;
    final pixelRatio = mediaQuery.devicePixelRatio.clamp(1.0, 3.0);
    return (visibleWidth * pixelRatio).round().clamp(1080, 1440);
  }

  Future<Uint8List> _renderProjectPageBytesForGallery(
    ProjectPage page, {
    required int exportWidth,
  }) {
    final pageIndex = _project.pages.indexWhere((item) => item.id == page.id);
    if (pageIndex != -1 &&
        page.elements.any((element) => element.type == 'text')) {
      return _renderProjectPageInSetBytesWithFlutter(
        exportWidth: exportWidth,
        pageIndexes: <int>[pageIndex],
        targetListIndex: 0,
      );
    }

    final payload = <String, dynamic>{
      'exportWidth': exportWidth,
      'aspectWidth': page.aspectWidth,
      'aspectHeight': page.aspectHeight,
      'backgroundColor':
          (page.extras['backgroundColorValue'] as num?)?.toInt() ??
          Colors.white.value,
      'images': <String, Uint8List>{
        for (final element in page.elements)
          if (element.type == 'image')
            ...() {
              final src =
                  element.data['originalSrc'] as String? ??
                  element.data['src'] as String? ??
                  '';
              if (src.isEmpty) {
                return const <String, Uint8List>{};
              }
              final bytes = _exportImageBytesCache[src];
              if (bytes == null) {
                return const <String, Uint8List>{};
              }
              return <String, Uint8List>{src: bytes};
            }(),
      },
      'elements': page.elements
          .map(
            (element) => <String, dynamic>{
              'type': element.type,
              'x': element.x,
              'y': element.y,
              'width': element.width,
              'height': element.height,
              'src':
                  element.data['originalSrc'] as String? ??
                  element.data['src'] as String? ??
                  '',
              'aspectRatio': (element.data['aspectRatio'] as num?)?.toDouble(),
              'cropOffsetX': _cropOffsetXFromData(element.data),
              'cropOffsetY': _cropOffsetYFromData(element.data),
              'cropScale': _cropScaleFromData(element.data),
              'borderRadiusRatio': (element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0,
            },
          )
          .toList(),
    };

    return compute(_renderPageJpgBytes, payload);
  }

  bool _pageIndexesContainText(List<int> pageIndexes) {
    for (final pageIndex in pageIndexes) {
      if (_project.pages[pageIndex].elements.any(
        (element) => element.type == 'text',
      )) {
        return true;
      }
    }
    return false;
  }

  Future<ui.Image?> _decodeUiImageForExport(Uint8List bytes) {
    final completer = Completer<ui.Image?>();
    try {
      ui.decodeImageFromList(bytes, completer.complete);
    } catch (_) {
      completer.complete(null);
    }
    return completer.future;
  }

  Future<Uint8List> _renderProjectPageInSetBytesWithFlutter({
    required int exportWidth,
    required List<int> pageIndexes,
    required int targetListIndex,
  }) async {
    final targetOriginalIndex = pageIndexes[targetListIndex];
    final targetPage = _project.pages[targetOriginalIndex];
    final exportHeight =
        (exportWidth * (targetPage.aspectHeight / targetPage.aspectWidth))
            .round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final decodedImages = <ui.Image>[];

    canvas.drawRect(
      Rect.fromLTWH(0, 0, exportWidth.toDouble(), exportHeight.toDouble()),
      Paint()
        ..color = Color(
          (targetPage.extras['backgroundColorValue'] as num?)?.toInt() ??
              Colors.white.value,
        ),
    );

    try {
      for (
        var sourceListIndex = 0;
        sourceListIndex < pageIndexes.length;
        sourceListIndex++
      ) {
        final sourceOriginalIndex = pageIndexes[sourceListIndex];
        final sourcePage = _project.pages[sourceOriginalIndex];
        for (final element in sourcePage.elements) {
          if (sourceListIndex != targetListIndex) {
            if (!element.allowCrossPage) {
              continue;
            }
            final elementHeight = _elementRenderedHeight(element, sourcePage);
            final left =
                (sourceOriginalIndex - targetOriginalIndex) + element.x;
            final right = left + element.width;
            final top = element.y;
            final bottom = top + elementHeight;
            if (right <= 0 || left >= 1 || bottom <= 0 || top >= 1) {
              continue;
            }
          }

          final targetX =
              ((element.x + sourceOriginalIndex - targetOriginalIndex) *
                      exportWidth)
                  .roundToDouble();
          final targetY = (element.y * exportHeight).roundToDouble();

          if (element.type == 'image') {
            final src =
                element.data['originalSrc'] as String? ??
                element.data['src'] as String? ??
                '';
            final bytes = _exportImageBytesCache[src];
            if (bytes == null) {
              continue;
            }
            final sourceImage = await _decodeUiImageForExport(bytes);
            if (sourceImage == null) {
              continue;
            }
            decodedImages.add(sourceImage);

            final aspectRatio =
                (element.data['aspectRatio'] as num?)?.toDouble() ??
                (sourceImage.width / sourceImage.height);
            final targetWidth = (element.width * exportWidth)
                .round()
                .clamp(1, 20000)
                .toDouble();
            final targetHeight = (targetWidth / aspectRatio)
                .round()
                .clamp(1, 20000)
                .toDouble();
            final cropRect = _sourceCropRectForFrame(
              sourceWidth: sourceImage.width,
              sourceHeight: sourceImage.height,
              frameAspectRatio: aspectRatio,
              cropOffsetX: _cropOffsetXFromData(element.data),
              cropOffsetY: _cropOffsetYFromData(element.data),
              cropScale: _cropScaleFromData(element.data),
            );
            final borderRadiusRatio =
                (element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0;
            final double radius = borderRadiusRatio *
                (targetWidth < targetHeight ? targetWidth : targetHeight);
            if (radius > 0) {
              canvas.save();
              final rrect = RRect.fromRectAndRadius(
                Rect.fromLTWH(targetX, targetY, targetWidth, targetHeight),
                Radius.circular(radius),
              );
              canvas.clipRRect(rrect);
            }
            canvas.drawImageRect(
              sourceImage,
              Rect.fromLTWH(
                cropRect.x.toDouble(),
                cropRect.y.toDouble(),
                cropRect.width.toDouble(),
                cropRect.height.toDouble(),
              ),
              Rect.fromLTWH(targetX, targetY, targetWidth, targetHeight),
              Paint()..filterQuality = FilterQuality.high,
            );
            if (radius > 0) {
              canvas.restore();
            }
          } else if (element.type == 'text') {
            final text = _textContentFromData(element.data);
            final fontSize =
                _textFontSizeRatioFromData(element.data) * exportWidth;
            final maxWidth = (element.width * exportWidth)
                .round()
                .clamp(1, 20000)
                .toDouble();
            final textPainter = TextPainter(
              text: TextSpan(
                text: text,
                style: TextStyle(
                  color: _textColorFromData(element.data),
                  fontSize: fontSize,
                  height: 1.12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              textDirection: TextDirection.ltr,
              maxLines: _textLineCount(text),
            )..layout(maxWidth: maxWidth);
            final clipHeight = textPainter.height
                .clamp(1.0, exportHeight)
                .toDouble();
            canvas.save();
            canvas.clipRect(
              Rect.fromLTWH(targetX, targetY, maxWidth, clipHeight),
            );
            textPainter.paint(canvas, Offset(targetX, targetY));
            canvas.restore();
          }
        }
      }

      final picture = recorder.endRecording();
      final renderedImage = await picture.toImage(exportWidth, exportHeight);
      picture.dispose();
      try {
        final byteData = await renderedImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData == null) {
          throw StateError('Canvas conversion failed');
        }
        final decoded = img.decodeImage(byteData.buffer.asUint8List());
        if (decoded == null) {
          throw StateError('Image decode failed');
        }
        return Uint8List.fromList(img.encodeJpg(decoded, quality: 100));
      } finally {
        renderedImage.dispose();
      }
    } finally {
      for (final image in decodedImages) {
        image.dispose();
      }
    }
  }

  Future<Uint8List> _renderProjectPageInSetBytesForGallery({
    required int exportWidth,
    required List<int> pageIndexes,
    required int targetListIndex,
  }) async {
    if (_pageIndexesContainText(pageIndexes)) {
      return _renderProjectPageInSetBytesWithFlutter(
        exportWidth: exportWidth,
        pageIndexes: pageIndexes,
        targetListIndex: targetListIndex,
      );
    }

    final targetOriginalIndex = pageIndexes[targetListIndex];
    final usedImagePaths = <String>{};

    for (
      var sourceListIndex = 0;
      sourceListIndex < pageIndexes.length;
      sourceListIndex++
    ) {
      final sourceOriginalIndex = pageIndexes[sourceListIndex];
      final sourcePage = _project.pages[sourceOriginalIndex];
      for (final element in sourcePage.elements) {
        if (element.type != 'image') {
          continue;
        }

        if (sourceListIndex != targetListIndex) {
          if (!element.allowCrossPage) {
            continue;
          }

          final aspectRatio = (element.data['aspectRatio'] as num?)?.toDouble();
          final elementHeight = aspectRatio != null && aspectRatio > 0
              ? element.width / aspectRatio
              : element.height;
          final left = (sourceOriginalIndex - targetOriginalIndex) + element.x;
          final right = left + element.width;
          final top = element.y;
          final bottom = top + elementHeight;
          if (right <= 0 || left >= 1 || bottom <= 0 || top >= 1) {
            continue;
          }
        }

        final src =
            element.data['originalSrc'] as String? ??
            element.data['src'] as String? ??
            '';
        if (src.isNotEmpty && _exportImageBytesCache.containsKey(src)) {
          usedImagePaths.add(src);
        }
      }
    }

    final pagePayloads = pageIndexes
        .map(
          (pageIndex) => <String, dynamic>{
            'aspectWidth': _project.pages[pageIndex].aspectWidth,
            'aspectHeight': _project.pages[pageIndex].aspectHeight,
            'backgroundColor':
                (_project.pages[pageIndex].extras['backgroundColorValue']
                        as num?)
                    ?.toInt() ??
                Colors.white.value,
            'originalIndex': pageIndex,
            'elements': _project.pages[pageIndex].elements
                .map(
                  (element) => <String, dynamic>{
                    'type': element.type,
                    'x': element.x,
                    'y': element.y,
                    'width': element.width,
                    'height': element.height,
                    'allowCrossPage': element.allowCrossPage,
                    'src':
                        element.data['originalSrc'] as String? ??
                        element.data['src'] as String? ??
                        '',
                    'aspectRatio': (element.data['aspectRatio'] as num?)
                        ?.toDouble(),
                    'cropOffsetX': _cropOffsetXFromData(element.data),
                    'cropOffsetY': _cropOffsetYFromData(element.data),
                    'cropScale': _cropScaleFromData(element.data),
                    'borderRadiusRatio': (element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0,
                  },
                )
                .toList(),
          },
        )
        .toList();

    final payload = <String, dynamic>{
      'exportWidth': exportWidth,
      'targetPageIndex': targetListIndex,
      'images': <String, Uint8List>{
        for (final path in usedImagePaths) path: _exportImageBytesCache[path]!,
      },
      'pages': pagePayloads,
    };

    if (defaultTargetPlatform == TargetPlatform.android) {
      final result = await _galleryChannel.invokeMethod<Uint8List>(
        'renderPageToJpgNative',
        payload,
      );
      if (result != null) {
        return result;
      }
    }

    return compute(_renderSelectedPageJpgBytes, payload);
  }

  Future<void> _exportAllPagesToGallery({
    required bool reverseOrder,
    required ExportQualityMode qualityMode,
    required Set<int> selectedPageIndexes,
    void Function(double progress, String label)? onProgress,
    ValueChanged<_CompletedExportPage>? onCompletedPage,
  }) async {
    final strings = AppStrings.of(context);
    if (_isExporting) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isExporting = true;
    });

    try {
      await _primeExportImageCache(onProgress: onProgress);
      var successCount = 0;
      final selectedIndexes =
          selectedPageIndexes
              .where((index) => index >= 0 && index < _project.pages.length)
              .toList()
            ..sort();
      if (selectedIndexes.isEmpty) {
        return;
      }
      final totalPages = selectedIndexes.length;
      final exportWidth = switch (qualityMode) {
        ExportQualityMode.igStandard1080 => 1080,
        ExportQualityMode.high2400 => 2400,
      };
      final pageIndexes = reverseOrder
          ? selectedIndexes.reversed.toList()
          : selectedIndexes;

      for (var listIndex = 0; listIndex < pageIndexes.length; listIndex++) {
        final pageIndex = pageIndexes[listIndex];
        final exportIndex = listIndex + 1;
        _setExportProgress(
          progress: 0.25 + ((exportIndex - 1) / totalPages) * 0.3,
          label: strings.t('renderPages'),
          onProgress: onProgress,
        );
        final jpgBytes = await _renderProjectPageInSetBytesForGallery(
          exportWidth: exportWidth,
          pageIndexes: pageIndexes,
          targetListIndex: listIndex,
        );

        _setExportProgress(
          progress: 0.55 + ((exportIndex - 1) / totalPages) * 0.45,
          label: strings.t(
            'exportPageProgress',
            args: <String, String>{
              'current': '$exportIndex',
              'total': '$totalPages',
            },
          ),
          onProgress: onProgress,
        );

        final isSuccess = await _saveImageToGallery(
          bytes: jpgBytes,
          name: _buildGalleryExportName(pageIndex),
        );
        if (isSuccess) {
          successCount += 1;
          final completedPage = _CompletedExportPage(
            pageNumber: pageIndex + 1,
            bytes: jpgBytes,
          );
          onCompletedPage?.call(completedPage);
        }

        _setExportProgress(
          progress: 0.55 + (exportIndex / totalPages) * 0.45,
          label: strings.t(
            'exportPageDone',
            args: <String, String>{
              'current': '$exportIndex',
              'total': '$totalPages',
            },
          ),
          onProgress: onProgress,
        );
        await Future<void>.delayed(Duration.zero);
      }

      if (!mounted) {
        return;
      }

      if (successCount == pageIndexes.length) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.t('exportedToGallery'))));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.t('partialExportFailed'))),
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.t('exportFailedTryAgain'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _showExportDialog() async {
    if (_isExporting) {
      return;
    }

    final strings = AppStrings.of(context);
    var reverseOrder = true;
    var qualityMode = ExportQualityMode.igStandard1080;
    var exportStarted = false;
    var exportRunning = false;
    var exportDone = false;
    var dialogProgress = 0.0;
    var dialogProgressLabel = strings.t('prepareExport');
    var dialogCompletedPages = <_CompletedExportPage>[];
    var selectedExportPageIndexes = <int>{
      for (var i = 0; i < _project.pages.length; i++) i,
    };

    Future<void> startExport(
      StateSetter setDialogState,
      BuildContext dialogContext,
    ) async {
      if (exportRunning) {
        return;
      }

      setDialogState(() {
        exportStarted = true;
        exportRunning = true;
        exportDone = false;
        dialogProgress = 0;
        dialogProgressLabel = strings.t('prepareExport');
        dialogCompletedPages = <_CompletedExportPage>[];
      });

      await _exportAllPagesToGallery(
        reverseOrder: reverseOrder,
        qualityMode: qualityMode,
        selectedPageIndexes: selectedExportPageIndexes,
        onProgress: (progress, label) {
          if (!dialogContext.mounted) {
            return;
          }

          setDialogState(() {
            dialogProgress = progress;
            dialogProgressLabel = label;
          });
        },
        onCompletedPage: (page) {
          if (!dialogContext.mounted) {
            return;
          }

          setDialogState(() {
            dialogCompletedPages = <_CompletedExportPage>[
              ...dialogCompletedPages,
              page,
            ];
          });
        },
      );

      if (!dialogContext.mounted) {
        return;
      }

      setDialogState(() {
        exportRunning = false;
        exportDone = true;
        if (dialogProgress <= 0) {
          dialogProgress = 1;
        }
      });
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return PopScope(
              canPop: !exportRunning,
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 28),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F4F4),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '匯出',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F1F1F),
                        ),
                      ),
                      const SizedBox(height: 16),
                      IgnorePointer(
                        ignoring: exportStarted,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeInOut,
                          opacity: exportStarted ? 0.54 : 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ExportSelectionSummary(
                                totalCount: _project.pages.length,
                                selectedIndexes: selectedExportPageIndexes,
                                reverseOrder: reverseOrder,
                              ),
                              const SizedBox(height: 10),
                              _ExportPageSelectionStrip(
                                pages: _project.pages,
                                selectedIndexes: selectedExportPageIndexes,
                                onToggle: (pageIndex) {
                                  setDialogState(() {
                                    final next = Set<int>.from(
                                      selectedExportPageIndexes,
                                    );
                                    if (next.contains(pageIndex)) {
                                      next.remove(pageIndex);
                                    } else {
                                      next.add(pageIndex);
                                    }
                                    selectedExportPageIndexes = next;
                                  });
                                },
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                '畫質',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF6A6A6A),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: _ExportQualityButton(
                                      label: 'IG標準',
                                      detail: '1080',
                                      selected:
                                          qualityMode ==
                                          ExportQualityMode.igStandard1080,
                                      onTap: () {
                                        setDialogState(() {
                                          qualityMode =
                                              ExportQualityMode.igStandard1080;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _ExportQualityButton(
                                      label: '高畫質',
                                      detail: '2.4K',
                                      selected:
                                          qualityMode ==
                                          ExportQualityMode.high2400,
                                      onTap: () {
                                        setDialogState(() {
                                          qualityMode =
                                              ExportQualityMode.high2400;
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  _ExportReverseSwitch(
                                    value: reverseOrder,
                                    onChanged: (value) {
                                      setDialogState(() {
                                        reverseOrder = value;
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      '從最後一頁反向輸出',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1F1F1F),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOut,
                        child: exportStarted
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 14),
                                  Text(
                                    dialogProgressLabel,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF4A4A4A),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  _ExportProgressPanel(
                                    progress: dialogProgress,
                                    completedPages: dialogCompletedPages,
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 18),
                      if (!exportStarted)
                        Row(
                          children: [
                            Expanded(
                              child: _DialogActionButton(
                                label: '取消',
                                onTap: () => Navigator.of(context).pop(),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _DialogIconActionButton(
                                icon: Icons.ios_share_rounded,
                                isPrimary: true,
                                enabled: selectedExportPageIndexes.isNotEmpty,
                                onTap: () {
                                  unawaited(
                                    startExport(setDialogState, context),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      if (exportStarted && exportDone && !exportRunning)
                        SizedBox(
                          width: double.infinity,
                          child: _DialogActionButton(
                            label: '完成',
                            isPrimary: true,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    AppSettingsController.instance.removeListener(_handleSettingsChanged);
    _pageController.dispose();
    _bottomTabPageController.dispose();
    _previewScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = _project.pages;
    final currentPage = pages[_currentPageIndex];
    final strings = AppStrings.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final shouldCompactCanvas =
        currentPage.aspectHeight > currentPage.aspectWidth &&
        _hasTwoOptionRows(_selectedBottomTab);
    final shouldUseSinglePagePeek = _shouldUseSinglePagePeek();
    final singlePageGap = shouldUseSinglePagePeek ? _singlePagePeekGap : 0.0;
    final singleCanvasWidth =
        (screenWidth *
            (shouldUseSinglePagePeek ? _singlePagePeekViewportFraction : 1.0)) -
        (singlePageGap * 2);
    final previewCanvasWidth = screenWidth * 0.78;
    const fixedCanvasHeightRatio = 4 / 3;
    final singleCanvasHeight = singleCanvasWidth * fixedCanvasHeightRatio;
    final previewCanvasHeight = previewCanvasWidth * fixedCanvasHeightRatio;
    final canvasHeight = _displayMode == PageDisplayMode.single
        ? singleCanvasHeight
        : previewCanvasHeight;
    final canvasScale = shouldUseSinglePagePeek
        ? 1.0
        : shouldCompactCanvas
        ? 0.7
        : 1.0;
    const bottomTabRowHeight = 30.0;
    const bottomTabPanelGap = 10.0;
    final bottomSafePadding = MediaQuery.of(context).padding.bottom;
    final bottomPadding = (32.0 + bottomSafePadding) * 0.5;
    final bottomTabs = _bottomTabs;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBottomTab());

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFFEAEAEA),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              Text(
                _savingRequestCount > 0
                    ? strings.t('saving')
                    : strings.t('saved'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _lastSnapshot == null ? null : _restoreLastStep,
              icon: Icon(
                Icons.undo_rounded,
                color: _lastSnapshot == null ? Colors.black26 : Colors.black54,
              ),
            ),
            IconButton(
              onPressed: _isExporting ? null : _showExportDialog,
              icon: _isExporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black54,
                      ),
                    )
                  : const Icon(Icons.ios_share_rounded),
            ),
            const SizedBox(width: 4),
          ],
        ),
        backgroundColor: const Color(0xFFEAEAEA),
        body: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Row(
                        children: [
                          _SlideSwitch(
                            value: _displayMode == PageDisplayMode.preview,
                            enabled: !_showPageSorter,
                            onChanged: (value) {
                              _changeDisplayMode(
                                value
                                    ? PageDisplayMode.preview
                                    : PageDisplayMode.single,
                              );
                            },
                          ),
                          const Spacer(),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeInOut,
                            switchOutCurve: Curves.easeInOut,
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: SizeTransition(
                                  sizeFactor: animation,
                                  axis: Axis.horizontal,
                                  child: child,
                                ),
                              );
                            },
                            child: _displayMode == PageDisplayMode.preview
                                ? Row(
                                    key: const ValueKey('border-button'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _ToolbarIconButton(
                                        icon: _showPageBorder
                                            ? Icons.border_outer_rounded
                                            : Icons.crop_square_rounded,
                                        onPressed: () {
                                          setState(() {
                                            _showPageBorder = !_showPageBorder;
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                  )
                                : const SizedBox(key: ValueKey('border-empty')),
                          ),
                          if (_displayMode == PageDisplayMode.single) ...[
                            _ToolbarIconButton(
                              icon: Icons.delete_outline_rounded,
                              onPressed: _deleteCurrentPage,
                            ),
                            const SizedBox(width: 8),
                          ],
                          _ToolbarIconButton(
                            icon: Icons.add,
                            onPressed: _addPage,
                            backgroundColor: _showPageSorter ? null : kPrimaryAccentColor,
                            iconColor: _showPageSorter ? null : Colors.white,
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (AppSettingsController.instance.aiSortEnabled) ...[
                            _ToolbarIconButton(
                              icon: Icons.auto_awesome_rounded,
                              enabled: pages.length > 1,
                              onPressed: _requestAiPageSort,
                            ),
                            const SizedBox(width: 8),
                          ],
                          _PageChangeButton(
                            icon: Icons.chevron_left_rounded,
                            enabled: _currentPageIndex > 0,
                            onTap: () => _goToPage(_currentPageIndex - 1),
                          ),
                          const SizedBox(width: 8),
                          _PageIndicatorButton(
                            label: strings.t(
                              'pageIndicator',
                              args: <String, String>{
                                'current': '${_currentPageIndex + 1}',
                                'total': '${pages.length}',
                              },
                            ),
                            selected: _showPageSorter,
                            showBackIcon: _showPageSorter,
                            onTap: _togglePageSorter,
                          ),
                          const SizedBox(width: 8),
                          _PageChangeButton(
                            icon: Icons.chevron_right_rounded,
                            enabled: _currentPageIndex < pages.length - 1,
                            onTap: () => _goToPage(_currentPageIndex + 1),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const canvasVerticalGap = 16.0;
                      final availableCanvasHeight =
                          (constraints.maxHeight - (canvasVerticalGap * 2))
                              .clamp(0.0, double.infinity)
                              .toDouble();
                      final maxFittingScale = canvasHeight <= 0
                          ? canvasScale
                          : (availableCanvasHeight / canvasHeight)
                                .clamp(0.05, 1.0)
                                .toDouble();
                      final fittedCanvasScale = canvasScale > maxFittingScale
                          ? maxFittingScale
                          : canvasScale;

                      final canvasView = Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: canvasVerticalGap,
                        ),
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeInOut,
                            height: canvasHeight * fittedCanvasScale,
                            alignment: Alignment.center,
                            child: OverflowBox(
                              minHeight: 0,
                              maxHeight: canvasHeight,
                              alignment: Alignment.center,
                              child: AnimatedScale(
                                duration: const Duration(milliseconds: 240),
                                curve: Curves.easeInOut,
                                scale: fittedCanvasScale,
                                alignment: Alignment.center,
                                child: SizedBox(
                                  height: canvasHeight,
                                  child: _displayMode == PageDisplayMode.single
                                      ? NotificationListener<
                                          ScrollNotification
                                        >(
                                          onNotification: (notification) {
                                            if (notification
                                                    is ScrollStartNotification ||
                                                notification
                                                    is ScrollUpdateNotification) {
                                              _setSinglePageDividerVisible(
                                                true,
                                              );
                                            } else if (notification
                                                    is ScrollEndNotification ||
                                                (notification
                                                        is UserScrollNotification &&
                                                    notification.direction ==
                                                        ScrollDirection.idle)) {
                                              _setSinglePageDividerVisible(
                                                false,
                                              );
                                            }
                                            return false;
                                          },
                                          child: PageView.builder(
                                            controller: _pageController,
                                            padEnds: shouldUseSinglePagePeek,
                                            physics: _selectedElementId == null
                                                ? const PageScrollPhysics()
                                                : const NeverScrollableScrollPhysics(),
                                            itemCount: pages.length,
                                            onPageChanged: (index) {
                                              setState(() {
                                                _currentPageIndex = index;
                                                _selectedElementId = null;
                                                _croppingElementId = null;
                                                _deleteArmedElementId = null;
                                                _refreshPageControllerViewportIfNeeded();
                                              });
                                              WidgetsBinding.instance
                                                  .addPostFrameCallback(
                                                    (_) => _syncBottomTab(),
                                                  );
                                            },
                                            itemBuilder: (context, index) {
                                              final page = pages[index];
                                              return Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: singlePageGap,
                                                ),
                                                child: _CanvasViewport(
                                                  pages: pages,
                                                  pageIndex: index,
                                                  page: page,
                                                  viewportWidth:
                                                      singleCanvasWidth,
                                                  viewportHeight:
                                                      singleCanvasHeight,
                                                  repaintKey:
                                                      index == _currentPageIndex
                                                      ? _exportRepaintKey
                                                      : null,
                                                  showBorder: _showPageBorder,
                                                  showPageDivider:
                                                      _showSinglePageDivider,
                                                  selectedElementId:
                                                      _selectedElementId,
                                                  croppingElementId:
                                                      _croppingElementId,
                                                  deleteArmedElementId:
                                                      _deleteArmedElementId,
                                                  snapGuides: _activeSnapGuides,
                                                  onTapCanvas:
                                                      _clearSelectedElement,
                                                  onTapElement: _selectElement,
                                                  onDoubleTapElement:
                                                      (elementId) {
                                                        _handleElementDoubleTap(
                                                          pageId: page.id,
                                                          elementId: elementId,
                                                        );
                                                      },
                                                  onMoveElement:
                                                      (
                                                        elementId,
                                                        x,
                                                        y,
                                                        persist,
                                                      ) {
                                                        _updateElementPosition(
                                                          pageId: page.id,
                                                          elementId: elementId,
                                                          x: x,
                                                          y: y,
                                                          persist: persist,
                                                        );
                                                      },
                                                  onResizeElement:
                                                      (
                                                        elementId,
                                                        width,
                                                        persist,
                                                      ) {
                                                        _updateElementSize(
                                                          pageId: page.id,
                                                          elementId: elementId,
                                                          width: width,
                                                          persist: persist,
                                                        );
                                                      },
                                                  onCropMove:
                                                      (
                                                        elementId,
                                                        x,
                                                        y,
                                                        persist,
                                                      ) {
                                                        _updateImageCropOffset(
                                                          elementId: elementId,
                                                          x: x,
                                                          y: y,
                                                          persist: persist,
                                                        );
                                                      },
                                                  onCropScale:
                                                      (
                                                        elementId,
                                                        scale,
                                                        persist,
                                                      ) {
                                                        _updateImageCropScale(
                                                          elementId: elementId,
                                                          scale: scale,
                                                          persist: persist,
                                                        );
                                                      },
                                                  onCropBoundsChanged:
                                                      (
                                                        elementId,
                                                        x,
                                                        y,
                                                        w,
                                                        h,
                                                        cx,
                                                        cy,
                                                        cs,
                                                        persist,
                                                      ) {
                                                        _updateImageCropBounds(
                                                          elementId: elementId,
                                                          x: x,
                                                          y: y,
                                                          width: w,
                                                          height: h,
                                                          cropOffsetX: cx,
                                                          cropOffsetY: cy,
                                                          cropScale: cs,
                                                          persist: persist,
                                                        );
                                                      },
                                                  onDeleteElement: (elementId) {
                                                    _requestDeleteElement(
                                                      elementId: elementId,
                                                    );
                                                  },
                                                  onConfirmDeleteElement:
                                                      (elementId) {
                                                        unawaited(
                                                          _confirmDeleteElement(
                                                            pageId: page.id,
                                                            elementId:
                                                                elementId,
                                                          ),
                                                        );
                                                      },
                                                  onCancelDeleteElement:
                                                      _cancelDeleteElement,
                                                ),
                                              );
                                            },
                                          ),
                                        )
                                      : NotificationListener<
                                          ScrollNotification
                                        >(
                                          onNotification: (notification) {
                                            _syncPreviewPageIndex();
                                            return false;
                                          },
                                          child: SingleChildScrollView(
                                            controller:
                                                _previewScrollController,
                                            scrollDirection: Axis.horizontal,
                                            physics: _selectedElementId == null
                                                ? const BouncingScrollPhysics()
                                                : const NeverScrollableScrollPhysics(),
                                            child: _PreviewCanvasStrip(
                                              pages: pages,
                                              currentPageIndex:
                                                  _currentPageIndex,
                                              viewportWidth: previewCanvasWidth,
                                              viewportHeight:
                                                  previewCanvasHeight,
                                              exportPageId: currentPage.id,
                                              exportRepaintKey:
                                                  _exportRepaintKey,
                                              showBorder: _showPageBorder,
                                              selectedElementId:
                                                  _selectedElementId,
                                              croppingElementId:
                                                  _croppingElementId,
                                              deleteArmedElementId:
                                                  _deleteArmedElementId,
                                              snapGuides: _activeSnapGuides,
                                              onTapCanvas:
                                                  _clearSelectedElement,
                                              onTapElement: _selectElement,
                                              onDoubleTapElement: (elementId) {
                                                final pageId = pages
                                                    .firstWhere(
                                                      (item) =>
                                                          item.elements.any(
                                                            (element) =>
                                                                element.id ==
                                                                elementId,
                                                          ),
                                                    )
                                                    .id;
                                                _handleElementDoubleTap(
                                                  pageId: pageId,
                                                  elementId: elementId,
                                                );
                                              },
                                              onMoveElement:
                                                  (
                                                    pageId,
                                                    elementId,
                                                    x,
                                                    y,
                                                    persist,
                                                  ) {
                                                    _updateElementPosition(
                                                      pageId: pageId,
                                                      elementId: elementId,
                                                      x: x,
                                                      y: y,
                                                      persist: persist,
                                                    );
                                                  },
                                              onResizeElement:
                                                  (
                                                    pageId,
                                                    elementId,
                                                    width,
                                                    persist,
                                                  ) {
                                                    _updateElementSize(
                                                      pageId: pageId,
                                                      elementId: elementId,
                                                      width: width,
                                                      persist: persist,
                                                    );
                                                  },
                                              onCropMove:
                                                  (elementId, x, y, persist) {
                                                    _updateImageCropOffset(
                                                      elementId: elementId,
                                                      x: x,
                                                      y: y,
                                                      persist: persist,
                                                    );
                                                  },
                                              onCropScale:
                                                  (elementId, scale, persist) {
                                                    _updateImageCropScale(
                                                      elementId: elementId,
                                                      scale: scale,
                                                      persist: persist,
                                                    );
                                                  },
                                              onDeleteElement: (_, elementId) {
                                                _requestDeleteElement(
                                                  elementId: elementId,
                                                );
                                              },
                                              onConfirmDeleteElement:
                                                  (pageId, elementId) {
                                                    unawaited(
                                                      _confirmDeleteElement(
                                                        pageId: pageId,
                                                        elementId: elementId,
                                                      ),
                                                    );
                                                  },
                                              onCancelDeleteElement:
                                                  _cancelDeleteElement,
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );

                      return Stack(
                        children: [
                          IgnorePointer(
                            ignoring: _showPageSorter,
                            child: canvasView,
                          ),
                          if (_showPageSorter)
                            Positioned.fill(
                              child: _PageSorterView(
                                pages: pages,
                                selectedPageId: _selectedSorterPageId,
                                onTapPage: _toggleSorterPageSelection,
                                onReorder: _reorderPages,
                                onMoveSelectedPage: _moveSelectedSorterPage,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                Container(
                  color: const Color(0xFFEAEAEA),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: bottomTabRowHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                for (var i = 0; i < bottomTabs.length; i++) ...[
                                  _BottomTab(
                                    label: _tabLabel(context, bottomTabs[i]),
                                    selected:
                                        _selectedBottomTab == bottomTabs[i],
                                    onTap: () =>
                                        _changeBottomTab(bottomTabs[i]),
                                  ),
                                  if (i != bottomTabs.length - 1)
                                    const SizedBox(width: 18),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: bottomTabPanelGap),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOut,
                        alignment: Alignment.topCenter,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Builder(
                            key: ValueKey(_selectedBottomTab),
                            builder: (context) {
                              final pages = _selectedImageElement != null
                                  ? <Widget>[
                                      _PageTabPage(
                                        page: currentPage,
                                        onAspectSelected: (width, height) {
                                          _updateCurrentPageAspect(
                                            aspectWidth: width,
                                            aspectHeight: height,
                                          );
                                        },
                                        onColorSelected: (color, preset) {
                                          _updateCurrentPageColor(
                                            color,
                                            preset: preset,
                                          );
                                        },
                                        onCustomColorTap:
                                            _showCustomPageColorDialog,
                                      ),
                                      _TemplateTabPage(
                                        page: currentPage,
                                        onApplyTemplate: _applyTemplate,
                                      ),
                                      _ElementTabPage(
                                        showTextOption: false,
                                        onAddText: _addTextElement,
                                        onImportImages: _importImages,
                                        importedImagePaths: _importedImagePaths,
                                        onTapImportedImage:
                                            _addImageElementFromPath,
                                        onLongPressImportedImage:
                                            _showImportedImagePreview,
                                      ),
                                      _ElementPositionTabPage(
                                        range: _elementPositionSliderRange(
                                          _selectedImageElement!,
                                          pagePixelSize:
                                              _elementPositionPagePixelSize(
                                                _selectedImageElement!,
                                                singleCanvasWidth:
                                                    singleCanvasWidth,
                                                previewCanvasWidth:
                                                    previewCanvasWidth,
                                              ),
                                        ),
                                        onNudge: _nudgeSelectedImage,
                                        onPositionChanged: (x, y) {
                                          _updateSelectedImagePositionFromSlider(
                                            x: x,
                                            y: y,
                                            persist: false,
                                          );
                                        },
                                        onPositionChangeEnd: (x, y) {
                                          _updateSelectedImagePositionFromSlider(
                                            x: x,
                                            y: y,
                                            persist: true,
                                          );
                                        },
                                      ),
                                      _ImageSettingsTabPage(
                                        selectedElement: _selectedImageElement!,
                                        sizeRange:
                                            _croppingElementId ==
                                                _selectedImageElement!.id
                                            ? (
                                                value: _cropScaleToSliderValue(
                                                  _cropScaleFromData(
                                                    _selectedImageElement!.data,
                                                  ),
                                                ),
                                                min: 0.0,
                                                max: 1.0,
                                              )
                                            : _imageSizeSliderRange(
                                                _selectedImageElement!,
                                              ),
                                        isCropping:
                                            _croppingElementId ==
                                            _selectedImageElement!.id,
                                        onStartCrop:
                                            _startCroppingSelectedImage,
                                        onFinishCrop:
                                            _finishCroppingSelectedImage,
                                        onAspectSelected:
                                            _updateSelectedImageAspect,
                                        onSizeChanged: (value) {
                                          if (_croppingElementId ==
                                              _selectedImageElement!.id) {
                                            _updateImageCropScale(
                                              elementId:
                                                  _selectedImageElement!.id,
                                              scale: _cropScaleFromSliderValue(
                                                value,
                                              ),
                                              persist: false,
                                            );
                                          } else {
                                            _updateSelectedImageSizeFromSlider(
                                              value,
                                              persist: false,
                                            );
                                          }
                                        },
                                        onSizeChangeEnd: (value) {
                                          if (_croppingElementId ==
                                              _selectedImageElement!.id) {
                                            _updateImageCropScale(
                                              elementId:
                                                  _selectedImageElement!.id,
                                              scale: _cropScaleFromSliderValue(
                                                value,
                                              ),
                                              persist: true,
                                            );
                                          } else {
                                            _updateSelectedImageSizeFromSlider(
                                              value,
                                              persist: true,
                                            );
                                          }
                                        },
                                        onBorderRadiusChanged: (value) {
                                          _updateSelectedImageBorderRadius(
                                            value,
                                            persist: false,
                                          );
                                        },
                                        onBorderRadiusChangeEnd: (value) {
                                          _updateSelectedImageBorderRadius(
                                            value,
                                            persist: true,
                                          );
                                        },
                                      ),
                                      _LayersTabPage(
                                        page: currentPage,
                                        selectedElementId: _selectedElementId,
                                        onSelectElement: (elementId) {
                                          if (_selectedElementId != elementId) {
                                            setState(() {
                                              _selectedElementId = elementId;
                                              _croppingElementId = null;
                                              _deleteArmedElementId = null;
                                            });
                                          }
                                        },
                                        onReorderElement: _reorderElements,
                                      ),
                                    ]
                                  : _selectedTextElement != null
                                  ? <Widget>[
                                      _PageTabPage(
                                        page: currentPage,
                                        onAspectSelected: (width, height) {
                                          _updateCurrentPageAspect(
                                            aspectWidth: width,
                                            aspectHeight: height,
                                          );
                                        },
                                        onColorSelected: (color, preset) {
                                          _updateCurrentPageColor(
                                            color,
                                            preset: preset,
                                          );
                                        },
                                        onCustomColorTap:
                                            _showCustomPageColorDialog,
                                      ),
                                      _TemplateTabPage(
                                        page: currentPage,
                                        onApplyTemplate: _applyTemplate,
                                      ),
                                      _ElementTabPage(
                                        showTextOption: true,
                                        onAddText: _addTextElement,
                                        onImportImages: _importImages,
                                        importedImagePaths: _importedImagePaths,
                                        onTapImportedImage:
                                            _addImageElementFromPath,
                                        onLongPressImportedImage:
                                            _showImportedImagePreview,
                                      ),
                                      _ElementPositionTabPage(
                                        range: _elementPositionSliderRange(
                                          _selectedTextElement!,
                                          pagePixelSize:
                                              _elementPositionPagePixelSize(
                                                _selectedTextElement!,
                                                singleCanvasWidth:
                                                    singleCanvasWidth,
                                                previewCanvasWidth:
                                                    previewCanvasWidth,
                                              ),
                                        ),
                                        onNudge: _nudgeSelectedText,
                                        onPositionChanged: (x, y) {
                                          _updateSelectedTextPositionFromSlider(
                                            x: x,
                                            y: y,
                                            persist: false,
                                          );
                                        },
                                        onPositionChangeEnd: (x, y) {
                                          _updateSelectedTextPositionFromSlider(
                                            x: x,
                                            y: y,
                                            persist: true,
                                          );
                                        },
                                      ),
                                      _TextSettingsTabPage(
                                        selectedElement: _selectedTextElement!,
                                        onEditText: () {
                                          _showTextEditor(
                                            _selectedTextElement!.id,
                                          );
                                        },
                                        onColorSelected:
                                            _updateSelectedTextColor,
                                        onSizeChanged: (value) {
                                          _updateSelectedTextSize(
                                            value,
                                            persist: false,
                                          );
                                        },
                                        onSizeChangeEnd: (value) {
                                          _updateSelectedTextSize(
                                            value,
                                            persist: true,
                                          );
                                        },
                                      ),
                                      _LayersTabPage(
                                        page: currentPage,
                                        selectedElementId: _selectedElementId,
                                        onSelectElement: (elementId) {
                                          if (_selectedElementId != elementId) {
                                            setState(() {
                                              _selectedElementId = elementId;
                                              _croppingElementId = null;
                                              _deleteArmedElementId = null;
                                            });
                                          }
                                        },
                                        onReorderElement: _reorderElements,
                                      ),
                                    ]
                                  : <Widget>[
                                      _PageTabPage(
                                        page: currentPage,
                                        onAspectSelected: (width, height) {
                                          _updateCurrentPageAspect(
                                            aspectWidth: width,
                                            aspectHeight: height,
                                          );
                                        },
                                        onColorSelected: (color, preset) {
                                          _updateCurrentPageColor(
                                            color,
                                            preset: preset,
                                          );
                                        },
                                        onCustomColorTap:
                                            _showCustomPageColorDialog,
                                      ),
                                      _TemplateTabPage(
                                        page: currentPage,
                                        onApplyTemplate: _applyTemplate,
                                      ),
                                      _ElementTabPage(
                                        showTextOption: true,
                                        onAddText: _addTextElement,
                                        onImportImages: _importImages,
                                        importedImagePaths: _importedImagePaths,
                                        onTapImportedImage:
                                            _addImageElementFromPath,
                                        onLongPressImportedImage:
                                            _showImportedImagePreview,
                                      ),
                                      _LayersTabPage(
                                        page: currentPage,
                                        selectedElementId: _selectedElementId,
                                        onSelectElement: (elementId) {
                                          if (_selectedElementId != elementId) {
                                            setState(() {
                                              _selectedElementId = elementId;
                                              _croppingElementId = null;
                                              _deleteArmedElementId = null;
                                            });
                                          }
                                        },
                                        onReorderElement: _reorderElements,
                                      ),
                                    ];
                              final index = bottomTabs.indexOf(
                                _selectedBottomTab,
                              );
                              if (index == -1 || index >= pages.length) {
                                return const SizedBox.shrink();
                              }
                              return SizedBox(
                                width: double.infinity,
                                child: pages[index],
                              );
                            },
                          ),
                        ),
                      ),
                      SizedBox(
                        height: bottomPadding,
                        child: const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_isPreparingImage)
              Positioned.fill(
                child: AbsorbPointer(
                  absorbing: true,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.10),
                    alignment: Alignment.center,
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Color(0xFF8F8F8F),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CanvasViewport extends StatelessWidget {
  const _CanvasViewport({
    required this.pages,
    required this.pageIndex,
    required this.page,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.repaintKey,
    required this.showBorder,
    required this.showPageDivider,
    required this.selectedElementId,
    required this.croppingElementId,
    required this.deleteArmedElementId,
    required this.snapGuides,
    required this.onTapCanvas,
    required this.onTapElement,
    required this.onDoubleTapElement,
    required this.onMoveElement,
    required this.onResizeElement,
    required this.onCropMove,
    required this.onCropScale,
    required this.onCropBoundsChanged,
    required this.onDeleteElement,
    required this.onConfirmDeleteElement,
    required this.onCancelDeleteElement,
  });

  final List<ProjectPage> pages;
  final int pageIndex;
  final ProjectPage page;
  final double viewportWidth;
  final double viewportHeight;
  final GlobalKey? repaintKey;
  final bool showBorder;
  final bool showPageDivider;
  final String? selectedElementId;
  final String? croppingElementId;
  final String? deleteArmedElementId;
  final List<_SnapGuide> snapGuides;
  final VoidCallback onTapCanvas;
  final ValueChanged<String> onTapElement;
  final ValueChanged<String> onDoubleTapElement;
  final void Function(String elementId, double x, double y, bool persist)
  onMoveElement;
  final void Function(String elementId, double width, bool persist)
  onResizeElement;
  final void Function(String elementId, double x, double y, bool persist)
  onCropMove;
  final void Function(String elementId, double scale, bool persist) onCropScale;
  final void Function(
    String elementId,
    double x,
    double y,
    double width,
    double height,
    double cropOffsetX,
    double cropOffsetY,
    double cropScale,
    bool persist,
  )
  onCropBoundsChanged;
  final ValueChanged<String> onDeleteElement;
  final ValueChanged<String> onConfirmDeleteElement;
  final ValueChanged<String> onCancelDeleteElement;

  @override
  Widget build(BuildContext context) {
    final pageWidth = (viewportWidth - (_canvasControlChromePadding * 2))
        .clamp(1.0, viewportWidth)
        .toDouble();
    final pageHeight = pageWidth * (page.aspectHeight / page.aspectWidth);
    final canvasTop = (viewportHeight - pageHeight) / 2;

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: viewportWidth,
        height: viewportHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onTapCanvas,
                child: RepaintBoundary(
                  key: repaintKey,
                  child: Container(
                    width: pageWidth,
                    height: pageHeight,
                    decoration: BoxDecoration(
                      color: _pageBackgroundColorFromExtras(page.extras),
                      border: showBorder
                          ? Border.all(color: const Color(0xFF8F8F8F), width: 1)
                          : null,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IgnorePointer(
                              child: ClipRect(
                                child: Stack(
                                  clipBehavior: Clip.hardEdge,
                                  children: [
                                    for (
                                      var sourceIndex = 0;
                                      sourceIndex < pages.length;
                                      sourceIndex++
                                    )
                                      for (final element
                                          in pages[sourceIndex].elements)
                                        if (element.type == 'image' &&
                                            _shouldPaintCrossPageElement(
                                              element: element,
                                              sourcePageIndex: sourceIndex,
                                              targetPageIndex: pageIndex,
                                            ))
                                          _PreviewImageElementWidget(
                                            element: element,
                                            isSelected: false,
                                            isDeleteArmed: false,
                                            isCropMode: false,
                                            pageWidth: constraints.maxWidth,
                                            pageHeight: constraints.maxHeight,
                                            pageOffsetX:
                                                (sourceIndex - pageIndex) *
                                                constraints.maxWidth,
                                            pageOffsetY: 0,
                                            onTap: () {},
                                            onDoubleTap: () {},
                                            onMove: (_, _, _) {},
                                            onResize: (_, _) {},
                                            onCropMove: (_, _, _) {},
                                            onCropScale: (_, _) {},
                                            onDelete: () {},
                                            onConfirmDelete: () {},
                                            onCancelDelete: () {},
                                          ),
                                  ],
                                ),
                              ),
                            ),
                            for (final element in page.elements) ...[
                              if (element.type == 'image')
                                _ImageElementWidget(
                                  key: ValueKey('canvas_${element.id}'),
                                  element: element,
                                  isSelected: selectedElementId == element.id,
                                  isDeleteArmed:
                                      deleteArmedElementId == element.id,
                                  isCropMode: croppingElementId == element.id,
                                  canvasWidth: constraints.maxWidth,
                                  canvasHeight: constraints.maxHeight,
                                  onTap: () => onTapElement(element.id),
                                  onDoubleTap: () =>
                                      onDoubleTapElement(element.id),
                                  onMove: (x, y, persist) {
                                    onMoveElement(element.id, x, y, persist);
                                  },
                                  onResize: (width, persist) {
                                    onResizeElement(element.id, width, persist);
                                  },
                                  onCropMove: (x, y, persist) {
                                    onCropMove(element.id, x, y, persist);
                                  },
                                  onCropScale: (scale, persist) {
                                    onCropScale(element.id, scale, persist);
                                  },
                                  onCropBoundsChanged:
                                      (x, y, w, h, cx, cy, cs, persist) {
                                        onCropBoundsChanged(
                                          element.id,
                                          x,
                                          y,
                                          w,
                                          h,
                                          cx,
                                          cy,
                                          cs,
                                          persist,
                                        );
                                      },
                                  onDelete: () => onDeleteElement(element.id),
                                  onConfirmDelete: () =>
                                      onConfirmDeleteElement(element.id),
                                  onCancelDelete: () =>
                                      onCancelDeleteElement(element.id),
                                ),
                              if (element.type == 'text')
                                _TextElementWidget(
                                  key: ValueKey('canvas_text_${element.id}'),
                                  element: element,
                                  isSelected: selectedElementId == element.id,
                                  isDeleteArmed:
                                      deleteArmedElementId == element.id,
                                  pageWidth: constraints.maxWidth,
                                  pageHeight: constraints.maxHeight,
                                  pageOffsetX: 0,
                                  pageOffsetY: 0,
                                  onTap: () => onTapElement(element.id),
                                  onDoubleTap: () =>
                                      onDoubleTapElement(element.id),
                                  onMove: (x, y, persist) {
                                    onMoveElement(element.id, x, y, persist);
                                  },
                                  onDelete: () => onDeleteElement(element.id),
                                  onConfirmDelete: () =>
                                      onConfirmDeleteElement(element.id),
                                  onCancelDelete: () =>
                                      onCancelDeleteElement(element.id),
                                ),
                            ],
                            _SnapGuideOverlay(
                              guides: snapGuides,
                              pageIndex: pageIndex,
                              pageWidth: constraints.maxWidth,
                              pageHeight: constraints.maxHeight,
                              pageOffsetX: 0,
                              pageOffsetY: 0,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (page.extras['aiCaption'] != null &&
                (page.extras['aiCaption'] as String).isNotEmpty)
              Positioned(
                left: (viewportWidth - pageWidth) / 2 + 8,
                bottom: viewportHeight - canvasTop + 8,
                width: pageWidth - 16,
                child: Text(
                  page.extras['aiCaption'] as String,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B6F75),
                    height: 1.35,
                  ),
                ),
              ),
            if (showPageDivider && pageIndex < pages.length - 1)
              Positioned(
                right: -1,
                top: canvasTop,
                child: IgnorePointer(
                  child: Container(
                    width: 2,
                    height: pageHeight,
                    color: const Color(0xFFBDBDBD),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCanvasStrip extends StatelessWidget {
  const _PreviewCanvasStrip({
    required this.pages,
    required this.currentPageIndex,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.exportPageId,
    required this.exportRepaintKey,
    required this.showBorder,
    required this.selectedElementId,
    required this.croppingElementId,
    required this.deleteArmedElementId,
    required this.snapGuides,
    required this.onTapCanvas,
    required this.onTapElement,
    required this.onDoubleTapElement,
    required this.onMoveElement,
    required this.onResizeElement,
    required this.onCropMove,
    required this.onCropScale,
    required this.onDeleteElement,
    required this.onConfirmDeleteElement,
    required this.onCancelDeleteElement,
  });

  final List<ProjectPage> pages;
  final int currentPageIndex;
  final double viewportWidth;
  final double viewportHeight;
  final String exportPageId;
  final GlobalKey exportRepaintKey;
  final bool showBorder;
  final String? selectedElementId;
  final String? croppingElementId;
  final String? deleteArmedElementId;
  final List<_SnapGuide> snapGuides;
  final VoidCallback onTapCanvas;
  final ValueChanged<String> onTapElement;
  final ValueChanged<String> onDoubleTapElement;
  final void Function(
    String pageId,
    String elementId,
    double x,
    double y,
    bool persist,
  )
  onMoveElement;
  final void Function(
    String pageId,
    String elementId,
    double width,
    bool persist,
  )
  onResizeElement;
  final void Function(String elementId, double x, double y, bool persist)
  onCropMove;
  final void Function(String elementId, double scale, bool persist) onCropScale;
  final void Function(String pageId, String elementId) onDeleteElement;
  final void Function(String pageId, String elementId) onConfirmDeleteElement;
  final ValueChanged<String> onCancelDeleteElement;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: viewportWidth * pages.length,
      height: viewportHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < pages.length; i++) ...[
            if (_shouldBuildPreviewPage(
              pageIndex: i,
              currentPageIndex: currentPageIndex,
            ))
              Positioned(
                left: viewportWidth * i,
                top:
                    ((viewportHeight -
                        (viewportWidth *
                            (pages[i].aspectHeight / pages[i].aspectWidth))) /
                    2),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: onTapCanvas,
                  child: RepaintBoundary(
                    key: pages[i].id == exportPageId ? exportRepaintKey : null,
                    child: Container(
                      width: viewportWidth,
                      height:
                          viewportWidth *
                          (pages[i].aspectHeight / pages[i].aspectWidth),
                      decoration: BoxDecoration(
                        color: _pageBackgroundColorFromExtras(pages[i].extras),
                        border: showBorder
                            ? Border.all(
                                color: const Color(0xFF8F8F8F),
                                width: 1,
                              )
                            : null,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return IgnorePointer(
                            child: ClipRect(
                              child: Stack(
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  for (
                                    var sourceIndex = 0;
                                    sourceIndex < pages.length;
                                    sourceIndex++
                                  )
                                    for (final element
                                        in pages[sourceIndex].elements)
                                      if (element.type == 'image' &&
                                          _shouldPaintCrossPageElement(
                                            element: element,
                                            sourcePageIndex: sourceIndex,
                                            targetPageIndex: i,
                                          ))
                                        _PreviewImageElementWidget(
                                          element: element,
                                          isSelected: false,
                                          isDeleteArmed: false,
                                          isCropMode: false,
                                          pageWidth: constraints.maxWidth,
                                          pageHeight: constraints.maxHeight,
                                          pageOffsetX:
                                              (sourceIndex - i) *
                                              constraints.maxWidth,
                                          pageOffsetY: 0,
                                          onTap: () {},
                                          onDoubleTap: () {},
                                          onMove: (_, _, _) {},
                                          onResize: (_, _) {},
                                          onCropMove: (_, _, _) {},
                                          onCropScale: (_, _) {},
                                          onDelete: () {},
                                          onConfirmDelete: () {},
                                          onCancelDelete: () {},
                                        ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
          ],
          for (var i = 0; i < pages.length; i++)
            if (_shouldBuildPreviewPage(
              pageIndex: i,
              currentPageIndex: currentPageIndex,
            ))
              for (final element in pages[i].elements) ...[
                if (element.type == 'image')
                  _PreviewImageElementWidget(
                    key: ValueKey('preview_${element.id}'),
                    element: element,
                    isSelected: selectedElementId == element.id,
                    isDeleteArmed: deleteArmedElementId == element.id,
                    isCropMode: croppingElementId == element.id,
                    pageWidth: viewportWidth,
                    pageHeight:
                        viewportWidth *
                        (pages[i].aspectHeight / pages[i].aspectWidth),
                    pageOffsetX: viewportWidth * i,
                    pageOffsetY:
                        ((viewportHeight -
                            (viewportWidth *
                                (pages[i].aspectHeight /
                                    pages[i].aspectWidth))) /
                        2),
                    onTap: () => onTapElement(element.id),
                    onDoubleTap: () => onDoubleTapElement(element.id),
                    onMove: (x, y, persist) {
                      onMoveElement(pages[i].id, element.id, x, y, persist);
                    },
                    onResize: (width, persist) {
                      onResizeElement(pages[i].id, element.id, width, persist);
                    },
                    onCropMove: (x, y, persist) {
                      onCropMove(element.id, x, y, persist);
                    },
                    onCropScale: (scale, persist) {
                      onCropScale(element.id, scale, persist);
                    },
                    onDelete: () => onDeleteElement(pages[i].id, element.id),
                    onConfirmDelete: () =>
                        onConfirmDeleteElement(pages[i].id, element.id),
                    onCancelDelete: () => onCancelDeleteElement(element.id),
                  ),
                if (element.type == 'text')
                  _TextElementWidget(
                    key: ValueKey('preview_text_${element.id}'),
                    element: element,
                    isSelected: selectedElementId == element.id,
                    isDeleteArmed: deleteArmedElementId == element.id,
                    pageWidth: viewportWidth,
                    pageHeight:
                        viewportWidth *
                        (pages[i].aspectHeight / pages[i].aspectWidth),
                    pageOffsetX: viewportWidth * i,
                    pageOffsetY:
                        ((viewportHeight -
                            (viewportWidth *
                                (pages[i].aspectHeight /
                                    pages[i].aspectWidth))) /
                        2),
                    onTap: () => onTapElement(element.id),
                    onDoubleTap: () => onDoubleTapElement(element.id),
                    onMove: (x, y, persist) {
                      onMoveElement(pages[i].id, element.id, x, y, persist);
                    },
                    onDelete: () => onDeleteElement(pages[i].id, element.id),
                    onConfirmDelete: () =>
                        onConfirmDeleteElement(pages[i].id, element.id),
                    onCancelDelete: () => onCancelDeleteElement(element.id),
                  ),
              ],
          for (var i = 0; i < pages.length; i++)
            if (_shouldBuildPreviewPage(
              pageIndex: i,
              currentPageIndex: currentPageIndex,
            ))
              _SnapGuideOverlay(
                guides: snapGuides,
                pageIndex: i,
                pageWidth: viewportWidth,
                pageHeight:
                    viewportWidth *
                    (pages[i].aspectHeight / pages[i].aspectWidth),
                pageOffsetX: viewportWidth * i,
                pageOffsetY:
                    ((viewportHeight -
                        (viewportWidth *
                            (pages[i].aspectHeight / pages[i].aspectWidth))) /
                    2),
              ),
        ],
      ),
    );
  }
}

class _SnapGuideOverlay extends StatefulWidget {
  const _SnapGuideOverlay({
    required this.guides,
    required this.pageIndex,
    required this.pageWidth,
    required this.pageHeight,
    required this.pageOffsetX,
    required this.pageOffsetY,
  });

  final List<_SnapGuide> guides;
  final int pageIndex;
  final double pageWidth;
  final double pageHeight;
  final double pageOffsetX;
  final double pageOffsetY;

  @override
  State<_SnapGuideOverlay> createState() => _SnapGuideOverlayState();
}

class _SnapGuideOverlayState extends State<_SnapGuideOverlay> {
  List<_SnapGuide> _visibleGuides = const <_SnapGuide>[];

  @override
  void initState() {
    super.initState();
    _visibleGuides = widget.guides;
  }

  @override
  void didUpdateWidget(covariant _SnapGuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.guides.isNotEmpty && widget.guides != _visibleGuides) {
      _visibleGuides = widget.guides;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_visibleGuides.isEmpty) {
      return const SizedBox.shrink();
    }

    const guideThickness = 3.0;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.guides.isEmpty ? 0 : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeInOut,
        onEnd: () {
          if (widget.guides.isEmpty && _visibleGuides.isNotEmpty) {
            setState(() {
              _visibleGuides = const <_SnapGuide>[];
            });
          }
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final guide in _visibleGuides)
              if (guide.axis == _SnapGuideAxis.vertical)
                ...() {
                  final localX =
                      (guide.value - widget.pageIndex) * widget.pageWidth;
                  if (localX < -0.5 || localX > widget.pageWidth + 0.5) {
                    return const <Widget>[];
                  }
                  final lineStart = (guide.start ?? 0).clamp(0.0, 1.0);
                  final lineEnd = (guide.end ?? 1).clamp(0.0, 1.0);
                  final lineTop =
                      widget.pageOffsetY + (lineStart * widget.pageHeight);
                  final lineHeight =
                      ((lineEnd - lineStart).abs() * widget.pageHeight).clamp(
                        guideThickness,
                        widget.pageHeight,
                      );
                  return <Widget>[
                    Positioned(
                      left: widget.pageOffsetX + localX - (guideThickness / 2),
                      top: lineTop,
                      child: SizedBox(
                        width: guideThickness,
                        height: lineHeight,
                        child: CustomPaint(
                          painter: const _DashedGuidePainter(
                            axis: _SnapGuideAxis.vertical,
                          ),
                        ),
                      ),
                    ),
                  ];
                }()
              else
                ...() {
                  final localY = guide.value * widget.pageHeight;
                  if (localY < -0.5 || localY > widget.pageHeight + 0.5) {
                    return const <Widget>[];
                  }
                  final lineStart =
                      ((guide.start ?? widget.pageIndex) - widget.pageIndex)
                          .clamp(0.0, 1.0);
                  final lineEnd =
                      ((guide.end ?? (widget.pageIndex + 1)) - widget.pageIndex)
                          .clamp(0.0, 1.0);
                  final lineLeft =
                      widget.pageOffsetX + (lineStart * widget.pageWidth);
                  final lineWidth =
                      ((lineEnd - lineStart).abs() * widget.pageWidth).clamp(
                        guideThickness,
                        widget.pageWidth,
                      );
                  return <Widget>[
                    Positioned(
                      left: lineLeft,
                      top: widget.pageOffsetY + localY - (guideThickness / 2),
                      child: SizedBox(
                        width: lineWidth,
                        height: guideThickness,
                        child: CustomPaint(
                          painter: const _DashedGuidePainter(
                            axis: _SnapGuideAxis.horizontal,
                          ),
                        ),
                      ),
                    ),
                  ];
                }(),
          ],
        ),
      ),
    );
  }
}

class _DashedGuidePainter extends CustomPainter {
  const _DashedGuidePainter({required this.axis});

  final _SnapGuideAxis axis;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kPrimaryAccentColor
      ..strokeWidth = axis == _SnapGuideAxis.vertical ? size.width : size.height
      ..strokeCap = StrokeCap.round;
    const dashLength = 8.0;
    const gapLength = 5.0;

    if (axis == _SnapGuideAxis.vertical) {
      final x = size.width / 2;
      var y = 0.0;
      while (y < size.height) {
        canvas.drawLine(
          Offset(x, y),
          Offset(x, (y + dashLength).clamp(0.0, size.height)),
          paint,
        );
        y += dashLength + gapLength;
      }
      return;
    }

    final y = size.height / 2;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + dashLength).clamp(0.0, size.width), y),
        paint,
      );
      x += dashLength + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedGuidePainter oldDelegate) {
    return oldDelegate.axis != axis;
  }
}

class _CroppedImageFile extends StatelessWidget {
  const _CroppedImageFile({
    required this.path,
    required this.frameWidth,
    required this.frameHeight,
    required this.sourceAspectRatio,
    required this.cropOffsetX,
    required this.cropOffsetY,
    required this.cropScale,
    required this.cacheWidth,
  });

  final String path;
  final double frameWidth;
  final double frameHeight;
  final double sourceAspectRatio;
  final double cropOffsetX;
  final double cropOffsetY;
  final double cropScale;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final frameAspectRatio = frameWidth / frameHeight;
    final safeSourceAspectRatio = sourceAspectRatio <= 0
        ? frameAspectRatio
        : sourceAspectRatio;
    final safeCropScale = cropScale < 1 ? 1.0 : cropScale;
    var imageWidth = frameWidth;
    var imageHeight = frameHeight;

    if (safeSourceAspectRatio > frameAspectRatio) {
      imageHeight = frameHeight;
      imageWidth = imageHeight * safeSourceAspectRatio;
    } else {
      imageWidth = frameWidth;
      imageHeight = imageWidth / safeSourceAspectRatio;
    }

    imageWidth *= safeCropScale;
    imageHeight *= safeCropScale;
    final left = _clampCropImageOffset(
      ((frameWidth - imageWidth) / 2) + (cropOffsetX * frameWidth),
      frameWidth - imageWidth,
      0,
    );
    final top = _clampCropImageOffset(
      ((frameHeight - imageHeight) / 2) + (cropOffsetY * frameHeight),
      frameHeight - imageHeight,
      0,
    );

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: left,
          top: top,
          width: imageWidth,
          height: imageHeight,
          child: Image.file(
            File(path),
            fit: BoxFit.fill,
            cacheWidth: cacheWidth,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
          ),
        ),
      ],
    );
  }
}

class _ImagePathPreviewDialog extends StatelessWidget {
  const _ImagePathPreviewDialog({required this.imagePath});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth = constraints.maxWidth * 0.88;
                final maxHeight = constraints.maxHeight * 0.78;

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: maxWidth,
                      maxHeight: maxHeight,
                    ),
                    clipBehavior: Clip.hardEdge,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.26),
                          blurRadius: 34,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: HdrImageView(path: imagePath, fit: BoxFit.contain),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageElementWidget extends StatefulWidget {
  const _ImageElementWidget({
    super.key,
    required this.element,
    required this.isSelected,
    required this.isDeleteArmed,
    required this.isCropMode,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMove,
    required this.onResize,
    required this.onCropMove,
    required this.onCropScale,
    required this.onCropBoundsChanged,
    required this.onDelete,
    required this.onConfirmDelete,
    required this.onCancelDelete,
  });

  final CanvasElement element;
  final bool isSelected;
  final bool isDeleteArmed;
  final bool isCropMode;
  final double canvasWidth;
  final double canvasHeight;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(double x, double y, bool persist) onMove;
  final void Function(double width, bool persist) onResize;
  final void Function(double x, double y, bool persist) onCropMove;
  final void Function(double scale, bool persist) onCropScale;
  final void Function(
    double x,
    double y,
    double width,
    double height,
    double cropOffsetX,
    double cropOffsetY,
    double cropScale,
    bool persist,
  )
  onCropBoundsChanged;
  final VoidCallback onDelete;
  final VoidCallback onConfirmDelete;
  final VoidCallback onCancelDelete;

  @override
  State<_ImageElementWidget> createState() => _ImageElementWidgetState();
}

class _ImageElementWidgetState extends State<_ImageElementWidget> {
  late double _currentX;
  late double _currentY;
  late double _currentWidth;
  late double _currentCropOffsetX;
  late double _currentCropOffsetY;
  late double _currentCropScale;
  late double _resizeStartCropScale;
  bool _isResizing = false;
  late double _resizeStartWidth;
  late Offset _resizeStartGlobalPosition;

  bool _isEdgeDragging = false;
  late CanvasElement _edgeDragStartElement;
  late Offset _edgeDragStartGlobalPosition;

  void _onCropEdgePanStart(DragStartDetails details) {
    _isEdgeDragging = true;
    _edgeDragStartElement = widget.element;
    _edgeDragStartGlobalPosition = details.globalPosition;
  }

  void _onCropEdgePanUpdate(DragUpdateDetails details, String edge) {
    if (!_isEdgeDragging) return;

    final totalDx = details.globalPosition.dx - _edgeDragStartGlobalPosition.dx;
    final totalDy = details.globalPosition.dy - _edgeDragStartGlobalPosition.dy;

    final startWidth = _edgeDragStartElement.width;
    final startAspectRatio =
        (_edgeDragStartElement.data['aspectRatio'] as num?)?.toDouble() ?? 1.0;
    final startHeight = startAspectRatio > 0
        ? startWidth / startAspectRatio
        : startWidth;
    final startX = _edgeDragStartElement.x;
    final startY = _edgeDragStartElement.y;

    final dx = totalDx / widget.canvasWidth;
    final dy = totalDy / widget.canvasHeight;

    double newX = startX;
    double newY = startY;
    double newWidth = startWidth;
    double newHeight = startHeight;

    if (edge == 'left') {
      newX = startX + dx;
      newWidth = startWidth - dx;
    } else if (edge == 'right') {
      newWidth = startWidth + dx;
    } else if (edge == 'top') {
      newY = startY + dy;
      newHeight = startHeight - dy;
    } else if (edge == 'bottom') {
      newHeight = startHeight + dy;
    }

    if (newWidth < 0.05) {
      newX = edge == 'left' ? startX + startWidth - 0.05 : startX;
      newWidth = 0.05;
    }
    if (newHeight < 0.05) {
      newY = edge == 'top' ? startY + startHeight - 0.05 : startY;
      newHeight = 0.05;
    }

    final newAspectRatio = newWidth / newHeight;
    final frameWidth = newWidth * widget.canvasWidth;
    final frameHeight = newHeight * widget.canvasHeight;
    final frameAspectRatio = frameWidth / frameHeight;

    final sourceAspectRatio =
        (_edgeDragStartElement.data['originalAspectRatio'] as num?)
            ?.toDouble() ??
        (_edgeDragStartElement.data['aspectRatio'] as num?)?.toDouble() ??
        newAspectRatio;
    final safeSourceAspectRatio = sourceAspectRatio <= 0
        ? frameAspectRatio
        : sourceAspectRatio;

    final oldFrameWidth = startWidth * widget.canvasWidth;
    final oldFrameHeight = startHeight * widget.canvasHeight;
    final oldFrameAspectRatio = oldFrameWidth / oldFrameHeight;

    double oldBaseImageWidth;
    if (safeSourceAspectRatio > oldFrameAspectRatio) {
      oldBaseImageWidth = oldFrameHeight * safeSourceAspectRatio;
    } else {
      oldBaseImageWidth = oldFrameWidth;
    }
    final oldCropScale = _cropScaleFromData(_edgeDragStartElement.data);
    final currentImageWidth = oldBaseImageWidth * oldCropScale;

    double newBaseImageWidth;
    if (safeSourceAspectRatio > frameAspectRatio) {
      newBaseImageWidth = frameHeight * safeSourceAspectRatio;
    } else {
      newBaseImageWidth = frameWidth;
    }
    final newCropScale = currentImageWidth / newBaseImageWidth;

    final oldCropOffsetX = _cropOffsetXFromData(_edgeDragStartElement.data);
    final oldCropOffsetY = _cropOffsetYFromData(_edgeDragStartElement.data);

    final currentVisualLeft =
        ((oldFrameWidth - currentImageWidth) / 2) +
        (oldCropOffsetX * oldFrameWidth);
    final currentVisualTop =
        ((oldFrameHeight - (currentImageWidth / safeSourceAspectRatio)) / 2) +
        (oldCropOffsetY * oldFrameHeight);

    final newVisualLeft =
        currentVisualLeft - (newX - startX) * widget.canvasWidth;
    final newVisualTop =
        currentVisualTop - (newY - startY) * widget.canvasHeight;

    final newCropOffsetX =
        (newVisualLeft - (frameWidth - currentImageWidth) / 2) / frameWidth;
    final newCropOffsetY =
        (newVisualTop -
            (frameHeight - (currentImageWidth / safeSourceAspectRatio)) / 2) /
        frameHeight;

    widget.onCropBoundsChanged(
      newX,
      newY,
      newWidth,
      newHeight,
      newCropOffsetX,
      newCropOffsetY,
      newCropScale,
      false,
    );
  }

  void _onCropEdgePanEnd(DragEndDetails details) {
    _isEdgeDragging = false;
    final aspectRatio =
        (widget.element.data['aspectRatio'] as num?)?.toDouble() ?? 1.0;
    widget.onCropBoundsChanged(
      widget.element.x,
      widget.element.y,
      widget.element.width,
      aspectRatio > 0
          ? widget.element.width / aspectRatio
          : widget.element.width,
      _cropOffsetXFromData(widget.element.data),
      _cropOffsetYFromData(widget.element.data),
      _cropScaleFromData(widget.element.data),
      true,
    );
  }

  Widget _buildEdgeHandle({
    required double width,
    required double height,
    required String edge,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onCropEdgePanStart,
      onPanUpdate: (details) => _onCropEdgePanUpdate(details, edge),
      onPanEnd: _onCropEdgePanEnd,
      onPanCancel: () {
        _isEdgeDragging = false;
      },
      child: Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        child: Container(
          width: edge == 'top' || edge == 'bottom' ? 36 : 8,
          height: edge == 'left' || edge == 'right' ? 36 : 8,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 2,
                spreadRadius: 0.5,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = (widget.element.data['aspectRatio'] as num?)
        ?.toDouble();
    final left = widget.element.x * widget.canvasWidth;
    final top = widget.element.y * widget.canvasHeight;
    final width = widget.element.width * widget.canvasWidth;
    final height = aspectRatio != null && aspectRatio > 0
        ? width / aspectRatio
        : widget.element.height * widget.canvasHeight;
    final src = widget.element.data['src'] as String? ?? '';
    const handleHitSize = 52.0;
    const handleVisualSize = 30.0;
    const handleVisualOffset = 10.0;
    final selectionColor = widget.isDeleteArmed
        ? kDeleteConfirmColor
        : _selectionChromeColor;

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onDoubleTap: widget.isDeleteArmed
            ? widget.onCancelDelete
            : widget.isCropMode
            ? null
            : widget.onDoubleTap,
        onLongPress: () {
          if (_isResizing || widget.isCropMode) {
            return;
          }
          widget.onTap();
          widget.onDelete();
        },
        onPanStart: (_) {
          if (_isResizing) {
            return;
          }
          if (widget.isDeleteArmed) {
            widget.onCancelDelete();
            return;
          }
          if (widget.isCropMode) {
            _currentCropOffsetX = _cropOffsetXFromData(widget.element.data);
            _currentCropOffsetY = _cropOffsetYFromData(widget.element.data);
            return;
          }
          _currentX = widget.element.x;
          _currentY = widget.element.y;
          if (!widget.isSelected) {
            widget.onTap();
          }
        },
        onPanUpdate: (details) {
          if (_isResizing) {
            return;
          }
          if (widget.isCropMode) {
            _currentCropOffsetX += details.delta.dx / width;
            _currentCropOffsetY += details.delta.dy / height;
            widget.onCropMove(_currentCropOffsetX, _currentCropOffsetY, false);
            return;
          }
          _currentX += details.delta.dx / widget.canvasWidth;
          _currentY += details.delta.dy / widget.canvasHeight;
          widget.onMove(_currentX, _currentY, false);
        },
        onPanEnd: (_) {
          if (_isResizing) {
            return;
          }
          if (widget.isCropMode) {
            widget.onCropMove(_currentCropOffsetX, _currentCropOffsetY, true);
            return;
          }
          widget.onMove(_currentX, _currentY, true);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: src.isEmpty
                    ? const Color(0xFFF6F6F6)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(
                  ((widget.element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0) *
                  (width < height ? width : height)
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: src.isEmpty
                  ? const Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: Color(0xFF8A8A8A),
                        size: 24,
                      ),
                    )
                  : _CroppedImageFile(
                      path: src,
                      frameWidth: width,
                      frameHeight: height,
                      sourceAspectRatio:
                          (widget.element.data['originalAspectRatio'] as num?)
                              ?.toDouble() ??
                          (widget.element.data['aspectRatio'] as num?)
                              ?.toDouble() ??
                          (width / height),
                      cropOffsetX: _cropOffsetXFromData(widget.element.data),
                      cropOffsetY: _cropOffsetYFromData(widget.element.data),
                      cropScale: _cropScaleFromData(widget.element.data),
                      cacheWidth: _previewImageCacheExtent(
                        context,
                        width,
                        height,
                      ),
                    ),
            ),
            _DeleteConfirmOverlay(
              visible: widget.isDeleteArmed,
              onConfirm: widget.onConfirmDelete,
            ),
            Positioned(
              left: -2,
              top: -2,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: widget.isSelected ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeInOut,
                  child: Container(
                    width: width + 4,
                    height: height + 4,
                    decoration: BoxDecoration(
                      border: Border.all(color: selectionColor, width: 4),
                      borderRadius: BorderRadius.circular(
                        (() {
                          final rRatio = (widget.element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0;
                          final rVal = rRatio * (width < height ? width : height);
                          return rVal > 0 ? rVal + 2 : 0.0;
                        })()
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !widget.isSelected || widget.isDeleteArmed,
                child: AnimatedOpacity(
                  opacity: widget.isSelected && !widget.isDeleteArmed ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeInOut,
                  child: AnimatedScale(
                    scale: widget.isSelected ? 1 : 0.82,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeInOut,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        _isResizing = true;
                        if (widget.isCropMode) {
                          _resizeStartCropScale = _cropScaleFromData(
                            widget.element.data,
                          );
                          _currentCropScale = _resizeStartCropScale;
                        } else {
                          _resizeStartWidth = widget.element.width;
                          _currentWidth = widget.element.width;
                        }
                        _resizeStartGlobalPosition = details.globalPosition;
                      },
                      onPanUpdate: (details) {
                        final totalDx =
                            details.globalPosition.dx -
                            _resizeStartGlobalPosition.dx;
                        final totalDy =
                            details.globalPosition.dy -
                            _resizeStartGlobalPosition.dy;
                        final aspectRatio =
                            (widget.element.data['aspectRatio'] as num?)
                                ?.toDouble() ??
                            (widget.element.width / widget.element.height);
                        if (widget.isCropMode) {
                          final scaleDelta =
                              (totalDx / width) + (totalDy / height);
                          _currentCropScale =
                              _resizeStartCropScale + (scaleDelta * 0.8);
                          widget.onCropScale(_currentCropScale, false);
                          return;
                        }
                        final scaleDelta =
                            (totalDx / widget.canvasWidth) +
                            ((totalDy / widget.canvasHeight) * aspectRatio);
                        _currentWidth = _resizeStartWidth + (scaleDelta * 0.5);
                        widget.onResize(_currentWidth, false);
                      },
                      onPanEnd: (_) {
                        _isResizing = false;
                        if (widget.isCropMode) {
                          widget.onCropScale(_currentCropScale, true);
                          return;
                        }
                        widget.onResize(_currentWidth, true);
                      },
                      onPanCancel: () {
                        _isResizing = false;
                      },
                      child: SizedBox(
                        width: handleHitSize,
                        height: handleHitSize,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Transform.translate(
                            offset: const Offset(
                              handleVisualOffset,
                              handleVisualOffset,
                            ),
                            child: Container(
                              width: handleVisualSize,
                              height: handleVisualSize,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _selectionChromeColor,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.open_in_full_rounded,
                                size: 15,
                                color: _selectionChromeColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.isCropMode) ...[
              Positioned(
                top: -12,
                left: width / 2 - 24,
                child: _buildEdgeHandle(width: 48, height: 24, edge: 'top'),
              ),
              Positioned(
                bottom: -12,
                left: width / 2 - 24,
                child: _buildEdgeHandle(width: 48, height: 24, edge: 'bottom'),
              ),
              Positioned(
                left: -12,
                top: height / 2 - 24,
                child: _buildEdgeHandle(width: 24, height: 48, edge: 'left'),
              ),
              Positioned(
                right: -12,
                top: height / 2 - 24,
                child: _buildEdgeHandle(width: 24, height: 48, edge: 'right'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PreviewImageElementWidget extends StatefulWidget {
  const _PreviewImageElementWidget({
    super.key,
    required this.element,
    required this.isSelected,
    required this.isDeleteArmed,
    required this.isCropMode,
    required this.pageWidth,
    required this.pageHeight,
    required this.pageOffsetX,
    required this.pageOffsetY,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMove,
    required this.onResize,
    required this.onCropMove,
    required this.onCropScale,
    required this.onDelete,
    required this.onConfirmDelete,
    required this.onCancelDelete,
  });

  final CanvasElement element;
  final bool isSelected;
  final bool isDeleteArmed;
  final bool isCropMode;
  final double pageWidth;
  final double pageHeight;
  final double pageOffsetX;
  final double pageOffsetY;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(double x, double y, bool persist) onMove;
  final void Function(double width, bool persist) onResize;
  final void Function(double x, double y, bool persist) onCropMove;
  final void Function(double scale, bool persist) onCropScale;
  final VoidCallback onDelete;
  final VoidCallback onConfirmDelete;
  final VoidCallback onCancelDelete;

  @override
  State<_PreviewImageElementWidget> createState() =>
      _PreviewImageElementWidgetState();
}

class _PreviewImageElementWidgetState
    extends State<_PreviewImageElementWidget> {
  late double _currentX;
  late double _currentY;
  late double _currentWidth;
  late double _currentCropOffsetX;
  late double _currentCropOffsetY;
  late double _currentCropScale;
  late double _resizeStartCropScale;
  bool _isResizing = false;
  late double _resizeStartWidth;
  late Offset _resizeStartGlobalPosition;

  @override
  Widget build(BuildContext context) {
    final aspectRatio = (widget.element.data['aspectRatio'] as num?)
        ?.toDouble();
    final left = widget.pageOffsetX + (widget.element.x * widget.pageWidth);
    final top = widget.pageOffsetY + (widget.element.y * widget.pageHeight);
    final width = widget.element.width * widget.pageWidth;
    final height = aspectRatio != null && aspectRatio > 0
        ? width / aspectRatio
        : widget.element.height * widget.pageHeight;
    final src = widget.element.data['src'] as String? ?? '';
    const handleHitSize = 52.0;
    const handleVisualSize = 30.0;
    const handleVisualOffset = 10.0;
    final selectionColor = widget.isDeleteArmed
        ? kDeleteConfirmColor
        : _selectionChromeColor;

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onDoubleTap: widget.isDeleteArmed
            ? widget.onCancelDelete
            : widget.isCropMode
            ? null
            : widget.onDoubleTap,
        onLongPress: () {
          if (_isResizing || widget.isCropMode) {
            return;
          }
          widget.onTap();
          widget.onDelete();
        },
        onPanStart: (_) {
          if (_isResizing) {
            return;
          }
          if (widget.isDeleteArmed) {
            widget.onCancelDelete();
            return;
          }
          if (widget.isCropMode) {
            _currentCropOffsetX = _cropOffsetXFromData(widget.element.data);
            _currentCropOffsetY = _cropOffsetYFromData(widget.element.data);
            return;
          }
          _currentX = widget.element.x;
          _currentY = widget.element.y;
          if (!widget.isSelected) {
            widget.onTap();
          }
        },
        onPanUpdate: (details) {
          if (_isResizing) {
            return;
          }
          if (widget.isCropMode) {
            _currentCropOffsetX += details.delta.dx / width;
            _currentCropOffsetY += details.delta.dy / height;
            widget.onCropMove(_currentCropOffsetX, _currentCropOffsetY, false);
            return;
          }
          _currentX += details.delta.dx / widget.pageWidth;
          _currentY += details.delta.dy / widget.pageHeight;
          widget.onMove(_currentX, _currentY, false);
        },
        onPanEnd: (_) {
          if (_isResizing) {
            return;
          }
          if (widget.isCropMode) {
            widget.onCropMove(_currentCropOffsetX, _currentCropOffsetY, true);
            return;
          }
          widget.onMove(_currentX, _currentY, true);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: src.isEmpty
                    ? const Color(0xFFF6F6F6)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(
                  ((widget.element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0) *
                  (width < height ? width : height)
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: src.isEmpty
                  ? const Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: Color(0xFF8A8A8A),
                        size: 24,
                      ),
                    )
                  : _CroppedImageFile(
                      path: src,
                      frameWidth: width,
                      frameHeight: height,
                      sourceAspectRatio:
                          (widget.element.data['originalAspectRatio'] as num?)
                              ?.toDouble() ??
                          (widget.element.data['aspectRatio'] as num?)
                              ?.toDouble() ??
                          (width / height),
                      cropOffsetX: _cropOffsetXFromData(widget.element.data),
                      cropOffsetY: _cropOffsetYFromData(widget.element.data),
                      cropScale: _cropScaleFromData(widget.element.data),
                      cacheWidth: _previewImageCacheExtent(
                        context,
                        width,
                        height,
                      ),
                    ),
            ),
            _DeleteConfirmOverlay(
              visible: widget.isDeleteArmed,
              onConfirm: widget.onConfirmDelete,
            ),
            Positioned(
              left: -2,
              top: -2,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: widget.isSelected ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeInOut,
                  child: Container(
                    width: width + 4,
                    height: height + 4,
                    decoration: BoxDecoration(
                      border: Border.all(color: selectionColor, width: 4),
                      borderRadius: BorderRadius.circular(
                        (() {
                          final rRatio = (widget.element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0;
                          final rVal = rRatio * (width < height ? width : height);
                          return rVal > 0 ? rVal + 2 : 0.0;
                        })()
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !widget.isSelected || widget.isDeleteArmed,
                child: AnimatedOpacity(
                  opacity: widget.isSelected && !widget.isDeleteArmed ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeInOut,
                  child: AnimatedScale(
                    scale: widget.isSelected ? 1 : 0.82,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeInOut,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        _isResizing = true;
                        if (widget.isCropMode) {
                          _resizeStartCropScale = _cropScaleFromData(
                            widget.element.data,
                          );
                          _currentCropScale = _resizeStartCropScale;
                        } else {
                          _resizeStartWidth = widget.element.width;
                          _currentWidth = widget.element.width;
                        }
                        _resizeStartGlobalPosition = details.globalPosition;
                      },
                      onPanUpdate: (details) {
                        final totalDx =
                            details.globalPosition.dx -
                            _resizeStartGlobalPosition.dx;
                        final totalDy =
                            details.globalPosition.dy -
                            _resizeStartGlobalPosition.dy;
                        final aspectRatio =
                            (widget.element.data['aspectRatio'] as num?)
                                ?.toDouble() ??
                            (widget.element.width / widget.element.height);
                        if (widget.isCropMode) {
                          final scaleDelta =
                              (totalDx / width) + (totalDy / height);
                          _currentCropScale =
                              _resizeStartCropScale + (scaleDelta * 0.8);
                          widget.onCropScale(_currentCropScale, false);
                          return;
                        }
                        final scaleDelta =
                            (totalDx / widget.pageWidth) +
                            ((totalDy / widget.pageHeight) * aspectRatio);
                        _currentWidth = _resizeStartWidth + (scaleDelta * 0.5);
                        widget.onResize(_currentWidth, false);
                      },
                      onPanEnd: (_) {
                        _isResizing = false;
                        if (widget.isCropMode) {
                          widget.onCropScale(_currentCropScale, true);
                          return;
                        }
                        widget.onResize(_currentWidth, true);
                      },
                      onPanCancel: () {
                        _isResizing = false;
                      },
                      child: SizedBox(
                        width: handleHitSize,
                        height: handleHitSize,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Transform.translate(
                            offset: const Offset(
                              handleVisualOffset,
                              handleVisualOffset,
                            ),
                            child: Container(
                              width: handleVisualSize,
                              height: handleVisualSize,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _selectionChromeColor,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.open_in_full_rounded,
                                size: 15,
                                color: _selectionChromeColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextElementWidget extends StatefulWidget {
  const _TextElementWidget({
    super.key,
    required this.element,
    required this.isSelected,
    required this.isDeleteArmed,
    required this.pageWidth,
    required this.pageHeight,
    required this.pageOffsetX,
    required this.pageOffsetY,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMove,
    required this.onDelete,
    required this.onConfirmDelete,
    required this.onCancelDelete,
  });

  final CanvasElement element;
  final bool isSelected;
  final bool isDeleteArmed;
  final double pageWidth;
  final double pageHeight;
  final double pageOffsetX;
  final double pageOffsetY;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(double x, double y, bool persist) onMove;
  final VoidCallback onDelete;
  final VoidCallback onConfirmDelete;
  final VoidCallback onCancelDelete;

  @override
  State<_TextElementWidget> createState() => _TextElementWidgetState();
}

class _TextElementWidgetState extends State<_TextElementWidget> {
  late double _currentX;
  late double _currentY;

  @override
  Widget build(BuildContext context) {
    final text = _textContentFromData(widget.element.data);
    final fontSize =
        _textFontSizeRatioFromData(widget.element.data) * widget.pageWidth;
    final lineCount = _textLineCount(text);
    final width = widget.element.width * widget.pageWidth;
    final height = (fontSize * 1.24 * lineCount)
        .clamp(1.0, widget.pageHeight)
        .toDouble();
    final left = widget.pageOffsetX + (widget.element.x * widget.pageWidth);
    final top = widget.pageOffsetY + (widget.element.y * widget.pageHeight);
    final color = _textColorFromData(widget.element.data);
    final selectionColor = widget.isDeleteArmed
        ? kDeleteConfirmColor
        : _selectionChromeColor;

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onDoubleTap: widget.isDeleteArmed
            ? widget.onCancelDelete
            : widget.onDoubleTap,
        onLongPress: () {
          widget.onTap();
          widget.onDelete();
        },
        onPanStart: (_) {
          if (widget.isDeleteArmed) {
            widget.onCancelDelete();
            return;
          }
          _currentX = widget.element.x;
          _currentY = widget.element.y;
          if (!widget.isSelected) {
            widget.onTap();
          }
        },
        onPanUpdate: (details) {
          _currentX += details.delta.dx / widget.pageWidth;
          _currentY += details.delta.dy / widget.pageHeight;
          widget.onMove(_currentX, _currentY, false);
        },
        onPanEnd: (_) {
          widget.onMove(_currentX, _currentY, true);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: width,
              height: height,
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(color: Colors.transparent),
              child: Text(
                text,
                maxLines: lineCount,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: color,
                  fontSize: fontSize,
                  height: 1.12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _DeleteConfirmOverlay(
              visible: widget.isDeleteArmed,
              onConfirm: widget.onConfirmDelete,
            ),
            Positioned(
              left: -2,
              top: -2,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: widget.isSelected ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeInOut,
                  child: Container(
                    width: width + 4,
                    height: height + 4,
                    decoration: BoxDecoration(
                      border: Border.all(color: selectionColor, width: 3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextEditorField extends StatefulWidget {
  const _TextEditorField({required this.initialText});

  final String initialText;

  @override
  State<_TextEditorField> createState() => _TextEditorFieldState();
}

class _TextEditorFieldState extends State<_TextEditorField> {
  late String _draftText;

  @override
  void initState() {
    super.initState();
    _draftText = widget.initialText;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextFormField(
          initialValue: widget.initialText,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (value) {
            _draftText = value;
          },
          onFieldSubmitted: (value) {
            Navigator.of(context).pop(value);
          },
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(strings.t('cancel')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(_draftText),
                child: Text(strings.t('done')),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DeleteConfirmOverlay extends StatelessWidget {
  const _DeleteConfirmOverlay({required this.visible, required this.onConfirm});

  final bool visible;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeInOut,
          child: Container(
            color: Colors.white.withValues(alpha: 0.76),
            child: Center(
              child: _DeleteConfirmButton(
                icon: Icons.delete_outline_rounded,
                onTap: onConfirm,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteConfirmButton extends StatelessWidget {
  const _DeleteConfirmButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: kDeleteConfirmColor,
          shape: BoxShape.circle,
          border: Border.all(color: kDeleteConfirmColor, width: 2),
        ),
        child: Icon(icon, size: 22, color: Colors.white),
      ),
    );
  }
}

class _AiSortOrderPreview extends StatelessWidget {
  const _AiSortOrderPreview({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF7A7A7A),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF252525),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportSelectionSummary extends StatelessWidget {
  const _ExportSelectionSummary({
    required this.totalCount,
    required this.selectedIndexes,
    required this.reverseOrder,
  });

  final int totalCount;
  final Set<int> selectedIndexes;
  final bool reverseOrder;

  @override
  Widget build(BuildContext context) {
    final selected = selectedIndexes.toList()..sort();
    final ordered = reverseOrder ? selected.reversed.toList() : selected;
    final orderLabel = ordered.isEmpty
        ? '尚未選取頁面'
        : ordered.map((index) => '${index + 1}').join(', ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE4E4E4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已選 ${selected.length}/$totalCount 頁',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF252525),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '輸出順序：$orderLabel',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A6A6A),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportPageSelectionStrip extends StatelessWidget {
  const _ExportPageSelectionStrip({
    required this.pages,
    required this.selectedIndexes,
    required this.onToggle,
  });

  final List<ProjectPage> pages;
  final Set<int> selectedIndexes;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pages.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          return _ExportPageSelectionTile(
            page: pages[index],
            pageNumber: index + 1,
            selected: selectedIndexes.contains(index),
            onTap: () => onToggle(index),
          );
        },
      ),
    );
  }
}

class _ExportPageSelectionTile extends StatelessWidget {
  const _ExportPageSelectionTile({
    required this.page,
    required this.pageNumber,
    required this.selected,
    required this.onTap,
  });

  final ProjectPage page;
  final int pageNumber;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const previewHeight = 82.0;
    final previewWidth =
        (previewHeight * (page.aspectWidth / page.aspectHeight))
            .clamp(52.0, 96.0)
            .toDouble();
    return _PressableScale(
      onTap: onTap,
      pressedScale: 0.96,
      child: SizedBox(
        width: previewWidth + 14,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: selected
                    ? kPrimaryAccentColor.withValues(alpha: 0.22)
                    : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? kPrimaryAccentColor
                      : const Color(0xFFE0E0E0),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Stack(
                children: [
                  _MiniPagePreview(
                    page: page,
                    width: previewWidth,
                    height: previewHeight,
                  ),
                  if (selected)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: kPrimaryAccentColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '$pageNumber',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF4A4A4A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportProgressPanel extends StatelessWidget {
  const _ExportProgressPanel({
    required this.progress,
    required this.completedPages,
  });

  final double progress;
  final List<_CompletedExportPage> completedPages;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(10, 10, 10, completedPages.isEmpty ? 10 : 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F6F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E5E5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: progress <= 0 ? null : progress,
              backgroundColor: const Color(0xFFE1E1E1),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF8F8F8F),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            child: completedPages.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 10),
                      _CompletedExportPagesStrip(pages: completedPages),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _CompletedExportPagesStrip extends StatelessWidget {
  const _CompletedExportPagesStrip({required this.pages});

  final List<_CompletedExportPage> pages;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pages.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final page = pages[index];
          return _CompletedExportPageTile(page: page);
        },
      ),
    );
  }
}

class _CompletedExportPageTile extends StatelessWidget {
  const _CompletedExportPageTile({required this.page});

  final _CompletedExportPage page;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      scale: 1,
      child: Container(
        width: 54,
        height: 76,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  page.bytes,
                  fit: BoxFit.contain,
                  cacheHeight: 144,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                ),
              ),
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                height: 18,
                constraints: const BoxConstraints(minWidth: 18),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.68),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${page.pageNumber}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PressableScale extends StatefulWidget {
  const _PressableScale({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.pressedScale = 0.96,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final double pressedScale;

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _pressed = false;

  bool get _isEnabled =>
      widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  @override
  void didUpdateWidget(covariant _PressableScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEnabled && _pressed) {
      _pressed = false;
    }
  }

  void _setPressed(bool value) {
    if (!_isEnabled || _pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeInOut,
        child: widget.child,
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.backgroundColor,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;
  final Color? backgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: enabled ? onPressed : null,
      enabled: enabled,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        width: 44,
        height: 32,
        decoration: BoxDecoration(
          color: enabled
              ? (backgroundColor ?? const Color(0xFFF8F8F8))
              : const Color(0xFFECECEC),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled
              ? (iconColor ?? const Color(0xFF4A4A4A))
              : Colors.black38,
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isPrimary ? kPrimaryAccentColor : Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF1F1F1F),
          ),
        ),
      ),
    );
  }
}

class _DialogIconActionButton extends StatelessWidget {
  const _DialogIconActionButton({
    required this.icon,
    required this.onTap,
    this.isPrimary = false,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool isPrimary;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: enabled ? onTap : null,
      enabled: enabled,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? (isPrimary ? kPrimaryAccentColor : Colors.white)
              : const Color(0xFFE2E2E2),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled
              ? (isPrimary ? Colors.white : const Color(0xFF1F1F1F))
              : Colors.black38,
        ),
      ),
    );
  }
}

class _PageChangeButton extends StatelessWidget {
  const _PageChangeButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: enabled ? onTap : null,
      enabled: enabled,
      pressedScale: 0.9,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFD8D8D8) : const Color(0xFFE2E2E2),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled ? Colors.black87 : Colors.black38,
        ),
      ),
    );
  }
}

class _PageIndicatorButton extends StatelessWidget {
  const _PageIndicatorButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.showBackIcon = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showBackIcon;

  @override
  Widget build(BuildContext context) {
    final primary = kPrimaryAccentColor;
    final isDefaultPurple = primary.toARGB32() == const Color(0xFFC3AEFF).toARGB32();
    final darkAccent = isDefaultPurple ? const Color(0xFF6B4EE6) : primary;

    final bgColor = selected
        ? primary.withValues(alpha: 0.28)
        : const Color(0xFFD8D8D8);

    final contentColor = selected
        ? (isDefaultPurple ? darkAccent : const Color(0xFF222222))
        : Colors.black54;

    return _PressableScale(
      onTap: onTap,
      pressedScale: 0.95,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
        ),
        child: showBackIcon
            ? Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: 0,
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_back_rounded,
                    size: 17,
                    color: contentColor,
                  ),
                ],
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: contentColor,
                ),
              ),
      ),
    );
  }
}

class _PageSorterView extends StatelessWidget {
  const _PageSorterView({
    required this.pages,
    required this.selectedPageId,
    required this.onTapPage,
    required this.onReorder,
    required this.onMoveSelectedPage,
  });

  final List<ProjectPage> pages;
  final String? selectedPageId;
  final ValueChanged<int> onTapPage;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<int> onMoveSelectedPage;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final selectedIndex = selectedPageId == null
            ? -1
            : pages.indexWhere((page) => page.id == selectedPageId);
        final hasSelectedPage = selectedIndex != -1;
        final controlsHeight = hasSelectedPage ? 38.0 : 0.0;
        final listHeight = (constraints.maxHeight - controlsHeight)
            .clamp(150.0, 196.0)
            .toDouble();
        final horizontalPadding = (constraints.maxWidth * 0.04)
            .clamp(12.0, 22.0)
            .toDouble();
        final frameGap = (constraints.maxWidth * 0.035)
            .clamp(10.0, 18.0)
            .toDouble();

        return Container(
          color: const Color(0xFFEAEAEA),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: constraints.maxWidth,
                  height: listHeight,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (var index = 0; index < pages.length; index++) ...[
                          _PageDropTarget(
                            key: ValueKey('page_drop_${pages[index].id}'),
                            index: index,
                            onDrop: onReorder,
                            child: _PageThumbnailCard(
                              key: ValueKey('page_sorter_${pages[index].id}'),
                              page: pages[index],
                              pageNumber: index + 1,
                              selected: pages[index].id == selectedPageId,
                              onTap: () => onTapPage(index),
                            ),
                          ),
                          if (index != pages.length - 1)
                            SizedBox(width: frameGap),
                        ],
                      ],
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: hasSelectedPage
                      ? Padding(
                          key: const ValueKey('page-move-controls'),
                          padding: const EdgeInsets.only(top: 4),
                          child: _PageSorterMoveControls(
                            canMoveLeft: selectedIndex > 0,
                            canMoveRight: selectedIndex < pages.length - 1,
                            onMoveLeft: () => onMoveSelectedPage(-1),
                            onMoveRight: () => onMoveSelectedPage(1),
                          ),
                        )
                      : const SizedBox(
                          key: ValueKey('page-move-controls-empty'),
                          height: 0,
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PageSorterMoveControls extends StatelessWidget {
  const _PageSorterMoveControls({
    required this.canMoveLeft,
    required this.canMoveRight,
    required this.onMoveLeft,
    required this.onMoveRight,
  });

  final bool canMoveLeft;
  final bool canMoveRight;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PageChangeButton(
            icon: Icons.chevron_left_rounded,
            enabled: canMoveLeft,
            onTap: onMoveLeft,
          ),
          const SizedBox(width: 18),
          _PageChangeButton(
            icon: Icons.chevron_right_rounded,
            enabled: canMoveRight,
            onTap: onMoveRight,
          ),
        ],
      ),
    );
  }
}

class _PageDropTarget extends StatelessWidget {
  const _PageDropTarget({
    super.key,
    required this.index,
    required this.onDrop,
    required this.child,
  });

  final int index;
  final void Function(int oldIndex, int newIndex) onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      hitTestBehavior: HitTestBehavior.translucent,
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onDrop(details.data, index),
      builder: (context, candidateData, rejectedData) {
        final isTarget = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
          padding: EdgeInsets.symmetric(horizontal: isTarget ? 3 : 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: isTarget ? 3 : 0,
                height: 178,
                decoration: BoxDecoration(
                  color: kPrimaryAccentColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              if (isTarget) const SizedBox(width: 8),
              child,
            ],
          ),
        );
      },
    );
  }
}

class _PageThumbnailCard extends StatelessWidget {
  const _PageThumbnailCard({
    super.key,
    required this.page,
    required this.pageNumber,
    required this.selected,
    required this.onTap,
  });

  final ProjectPage page;
  final int pageNumber;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final aspectRatio = page.aspectWidth / page.aspectHeight;
    const previewHeight = 152.0;
    const framePadding = 8.0;
    final previewWidth = (previewHeight * aspectRatio)
        .clamp(88.0, 172.0)
        .toDouble();
    final card = _PageThumbnailContent(
      page: page,
      pageNumber: pageNumber,
      selected: selected,
      previewWidth: previewWidth,
      previewHeight: previewHeight,
      framePadding: framePadding,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: LongPressDraggable<int>(
        data: pageNumber - 1,
        feedback: Material(
          color: Colors.transparent,
          child: Transform.scale(scale: 1.04, child: card),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: card),
        child: _PressableScale(onTap: onTap, pressedScale: 0.97, child: card),
      ),
    );
  }
}

class _PageThumbnailContent extends StatelessWidget {
  const _PageThumbnailContent({
    required this.page,
    required this.pageNumber,
    required this.selected,
    required this.previewWidth,
    required this.previewHeight,
    required this.framePadding,
  });

  final ProjectPage page;
  final int pageNumber;
  final bool selected;
  final double previewWidth;
  final double previewHeight;
  final double framePadding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: previewWidth + (framePadding * 2) + 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
            padding: EdgeInsets.all(framePadding),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFE7F0FF) : Colors.white,
              border: Border.all(
                color: selected ? kPrimaryAccentColor : const Color(0xFFE0E0E0),
                width: selected ? 2 : 1,
              ),
            ),
            child: _MiniPagePreview(
              page: page,
              width: previewWidth,
              height: previewHeight,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '$pageNumber',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4A4A4A),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPagePreview extends StatelessWidget {
  const _MiniPagePreview({
    required this.page,
    required this.width,
    required this.height,
  });

  final ProjectPage page;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _pageBackgroundColorFromExtras(page.extras),
        border: Border.all(color: const Color(0xFFD6D6D6), width: 1),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (final element in page.elements)
            if (element.type == 'image')
              _MiniImageElement(
                element: element,
                pageWidth: width,
                pageHeight: height,
              )
            else if (element.type == 'text')
              _MiniTextElement(
                element: element,
                pageWidth: width,
                pageHeight: height,
              ),
        ],
      ),
    );
  }
}

class _MiniImageElement extends StatelessWidget {
  const _MiniImageElement({
    required this.element,
    required this.pageWidth,
    required this.pageHeight,
  });

  final CanvasElement element;
  final double pageWidth;
  final double pageHeight;

  @override
  Widget build(BuildContext context) {
    final src = element.data['src'] as String? ?? '';
    final aspectRatio = (element.data['aspectRatio'] as num?)?.toDouble();
    final left = element.x * pageWidth;
    final top = element.y * pageHeight;
    final width = element.width * pageWidth;
    final height = aspectRatio != null && aspectRatio > 0
        ? width / aspectRatio
        : element.height * pageHeight;

    final borderRadiusRatio = (element.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0;
    final borderRadiusValue = borderRadiusRatio * (width < height ? width : height);

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadiusValue),
        child: src.isEmpty
            ? Container(color: const Color(0xFFF0F0F0))
            : _CroppedImageFile(
                path: src,
                frameWidth: width,
                frameHeight: height,
                sourceAspectRatio:
                    (element.data['originalAspectRatio'] as num?)?.toDouble() ??
                    (element.data['aspectRatio'] as num?)?.toDouble() ??
                    (width / height),
                cropOffsetX: _cropOffsetXFromData(element.data),
                cropOffsetY: _cropOffsetYFromData(element.data),
                cropScale: _cropScaleFromData(element.data),
                cacheWidth: 180,
              ),
      ),
    );
  }
}

class _MiniTextElement extends StatelessWidget {
  const _MiniTextElement({
    required this.element,
    required this.pageWidth,
    required this.pageHeight,
  });

  final CanvasElement element;
  final double pageWidth;
  final double pageHeight;

  @override
  Widget build(BuildContext context) {
    final text = _textContentFromData(element.data);
    final left = element.x * pageWidth;
    final top = element.y * pageHeight;
    final width = element.width * pageWidth;
    final fontSize = (_textFontSizeRatioFromData(element.data) * pageWidth)
        .clamp(4.0, 13.0)
        .toDouble();

    return Positioned(
      left: left,
      top: top,
      width: width,
      child: Text(
        text,
        maxLines: _textLineCount(text),
        overflow: TextOverflow.clip,
        style: TextStyle(
          color: _textColorFromData(element.data),
          fontSize: fontSize,
          height: 1.05,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SlideSwitch extends StatelessWidget {
  const _SlideSwitch({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? Colors.black54 : Colors.black26;
    return _PressableScale(
      onTap: enabled ? () => onChanged(!value) : null,
      enabled: enabled,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 94,
        height: 32,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFD8D8D8) : const Color(0xFFE2E2E2),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Stack(
          children: [
            Row(
              children: [
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.crop_portrait_rounded,
                      size: 14,
                      color: iconColor,
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.view_carousel_rounded,
                      size: 14,
                      color: iconColor,
                    ),
                  ),
                ),
              ],
            ),
            AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 40,
                height: 24,
                decoration: BoxDecoration(
                  color: enabled ? Colors.white : const Color(0xFFF4F4F4),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(
                  value
                      ? Icons.view_carousel_rounded
                      : Icons.crop_portrait_rounded,
                  size: 14,
                  color: enabled ? Colors.black87 : Colors.black38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportReverseSwitch extends StatelessWidget {
  const _ExportReverseSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 54,
        height: 28,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: value ? kPrimaryAccentColor : const Color(0xFFD8D8D8),
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportQualityButton extends StatelessWidget {
  const _ExportQualityButton({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      pressedScale: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? kPrimaryAccentColor : const Color(0xFFE2E2E2),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: const Color(0xFF1F1F1F),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(width: 6),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? kPrimaryAccentColor
                      : const Color(0xFF7A7A7A),
                ),
                child: Text(detail),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BottomTab extends StatelessWidget {
  const _BottomTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      pressedScale: 0.95,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            style: TextStyle(
              fontSize: 16,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? kPrimaryAccentColor : const Color(0xFF7A7A7A),
            ),
            child: Text(label),
          ),
          const SizedBox(height: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            width: selected ? 18 : 0,
            height: 3,
            decoration: BoxDecoration(
              color: kPrimaryAccentColor,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageTabPage extends StatelessWidget {
  const _PageTabPage({
    required this.page,
    required this.onAspectSelected,
    required this.onColorSelected,
    required this.onCustomColorTap,
  });

  final ProjectPage page;
  final void Function(double aspectWidth, double aspectHeight) onAspectSelected;
  final void Function(Color color, String preset) onColorSelected;
  final Future<void> Function() onCustomColorTap;

  static const List<_PageAspectOption> _options = <_PageAspectOption>[
    _PageAspectOption(label: '4:5', width: 4, height: 5),
    _PageAspectOption(label: '3:4', width: 3, height: 4),
    _PageAspectOption(label: '4:3', width: 4, height: 3),
    _PageAspectOption(label: '5:4', width: 5, height: 4),
    _PageAspectOption(label: '3:2', width: 3, height: 2),
    _PageAspectOption(label: '16:9', width: 16, height: 9),
  ];

  @override
  Widget build(BuildContext context) {
    const double cardHeight = 75;
    final selectedColorValue =
        (page.extras['backgroundColorValue'] as num?)?.toInt() ??
        _pageWhiteBackgroundColorValue;
    final selectedPreset =
        page.extras[_pageBackgroundColorPresetKey] as String?;
    final isKnownPreset =
        selectedPreset == _pageBackgroundColorPresetWhite ||
        selectedPreset == _pageBackgroundColorPresetBlack ||
        selectedPreset == _pageBackgroundColorPresetIgBlack ||
        selectedPreset == _pageBackgroundColorPresetCustom;
    final isWhiteSelected =
        selectedPreset == _pageBackgroundColorPresetWhite ||
        (!isKnownPreset &&
            selectedColorValue == _pageWhiteBackgroundColorValue);
    final isBlackSelected =
        selectedPreset == _pageBackgroundColorPresetBlack ||
        (!isKnownPreset &&
            selectedColorValue == _pageBlackBackgroundColorValue);
    final isIgBlackSelected =
        selectedPreset == _pageBackgroundColorPresetIgBlack ||
        (!isKnownPreset && selectedColorValue == _igDarkBackgroundColorValue);
    final isCustomSelected =
        selectedPreset == _pageBackgroundColorPresetCustom ||
        (!isKnownPreset &&
            selectedColorValue != _pageWhiteBackgroundColorValue &&
            selectedColorValue != _pageBlackBackgroundColorValue &&
            selectedColorValue != _igDarkBackgroundColorValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '頁面比例',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A6A6A),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _options.length; i++) ...[
                  _PageAspectCard(
                    option: _options[i],
                    height: cardHeight,
                    selected:
                        page.aspectWidth == _options[i].width &&
                        page.aspectHeight == _options[i].height,
                    onTap: () {
                      onAspectSelected(_options[i].width, _options[i].height);
                    },
                  ),
                  if (i != _options.length - 1) const SizedBox(width: 12),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '頁面色彩',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A6A6A),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _PageColorCard(
                  label: '白',
                  color: Colors.white,
                  selected: isWhiteSelected,
                  onTap: () => onColorSelected(
                    Colors.white,
                    _pageBackgroundColorPresetWhite,
                  ),
                ),
                const SizedBox(width: 12),
                _PageColorCard(
                  label: '黑',
                  color: Colors.black,
                  selected: isBlackSelected,
                  onTap: () => onColorSelected(
                    Colors.black,
                    _pageBackgroundColorPresetBlack,
                  ),
                ),
                const SizedBox(width: 12),
                _PageColorCard(
                  label: 'IG黑',
                  color: const Color(_igDarkBackgroundColorValue),
                  selected: isIgBlackSelected,
                  onTap: () => onColorSelected(
                    const Color(_igDarkBackgroundColorValue),
                    _pageBackgroundColorPresetIgBlack,
                  ),
                ),
                const SizedBox(width: 12),
                _PageColorCard(
                  label: '自訂',
                  color: Color(selectedColorValue),
                  selected: isCustomSelected,
                  onTap: onCustomColorTap,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TemplateTabPage extends StatelessWidget {
  const _TemplateTabPage({required this.page, required this.onApplyTemplate});

  final ProjectPage page;
  final ValueChanged<_TemplateOption> onApplyTemplate;

  static final List<_TemplateOption> _allTemplates = <_TemplateOption>[
    _TemplateOption(
      id: 'page_fill',
      label: 'fill',
      buildElements: (pageId, page) {
        return <CanvasElement>[
          CanvasElement.image(pageId: pageId).copyWith(
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            allowCrossPage: true,
            data: <String, dynamic>{
              'src': '',
              'aspectRatio': page.aspectWidth / page.aspectHeight,
              'originalAspectRatio': page.aspectWidth / page.aspectHeight,
              'aspectPreset': '${page.aspectWidth}:${page.aspectHeight}',
              'templateSlot': 'fill',
            },
          ),
        ];
      },
    ),
    _TemplateOption(
      id: 'page_3_4_two_images_3_2_vertical',
      label: 'stackedImages',
      pageAspectWidth: 3,
      pageAspectHeight: 4,
      buildElements: (pageId, page) {
        CanvasElement buildSlot({
          required String slot,
          required double x,
          required double y,
        }) {
          return CanvasElement.image(pageId: pageId).copyWith(
            x: x,
            y: y,
            width: 1,
            height: 0.5,
            allowCrossPage: true,
            data: <String, dynamic>{
              'src': '',
              'aspectRatio': 3 / 2,
              'originalAspectRatio': 3 / 2,
              'aspectPreset': '3:2',
              'templateSlot': slot,
            },
          );
        }

        return <CanvasElement>[
          buildSlot(slot: 'top', x: 0, y: 0),
          buildSlot(slot: 'bottom', x: 0, y: 0.5),
        ];
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final templates = _allTemplates
        .where(
          (template) =>
              (template.pageAspectWidth == null &&
                  template.pageAspectHeight == null) ||
              (template.pageAspectWidth == page.aspectWidth &&
                  template.pageAspectHeight == page.aspectHeight),
        )
        .toList();

    if (templates.isEmpty) {
      return const SizedBox.expand();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < templates.length; i++) ...[
              _TemplateCard(
                option: templates[i],
                page: page,
                onTap: () => onApplyTemplate(templates[i]),
              ),
              if (i != templates.length - 1) const SizedBox(width: 12),
            ],
          ],
        ),
      ),
    );
  }
}

const List<_ImageAspectOption> _imageAspectOptions = <_ImageAspectOption>[
  _ImageAspectOption(key: 'original', label: 'originalSize'),
  _ImageAspectOption(key: '1:1', label: '1:1', width: 1, height: 1),
  _ImageAspectOption(key: '5:4', label: '5:4', width: 5, height: 4),
  _ImageAspectOption(key: '4:5', label: '4:5', width: 4, height: 5),
  _ImageAspectOption(key: '4:3', label: '4:3', width: 4, height: 3),
  _ImageAspectOption(key: '3:4', label: '3:4', width: 3, height: 4),
  _ImageAspectOption(key: '3:2', label: '3:2', width: 3, height: 2),
  _ImageAspectOption(key: '16:9', label: '16:9', width: 16, height: 9),
];

class _ElementTabPage extends StatelessWidget {
  const _ElementTabPage({
    required this.showTextOption,
    required this.onAddText,
    required this.onImportImages,
    required this.importedImagePaths,
    required this.onTapImportedImage,
    required this.onLongPressImportedImage,
  });

  final bool showTextOption;
  final VoidCallback onAddText;
  final VoidCallback onImportImages;
  final List<String> importedImagePaths;
  final ValueChanged<String> onTapImportedImage;
  final ValueChanged<String> onLongPressImportedImage;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTextOption) ...[
            SizedBox(
              width: 96,
              child: _ElementOptionCard(
                icon: Icons.text_fields_rounded,
                label: 'text',
                onTap: onAddText,
              ),
            ),
            const SizedBox(width: 12),
          ],
          SizedBox(
            width: 120,
            child: _ElementOptionCard(
              icon: Icons.photo_library_outlined,
              label: 'importImages',
              onTap: onImportImages,
            ),
          ),
          for (final imagePath in importedImagePaths) ...[
            const SizedBox(width: 12),
            _ImportedImageCard(
              imagePath: imagePath,
              onTap: () => onTapImportedImage(imagePath),
              onLongPress: () => onLongPressImportedImage(imagePath),
            ),
          ],
        ],
      ),
    );
  }
}

class _ElementPositionTabPage extends StatelessWidget {
  const _ElementPositionTabPage({
    required this.range,
    required this.onNudge,
    required this.onPositionChanged,
    required this.onPositionChangeEnd,
  });

  final ({
    double x,
    double y,
    double minX,
    double maxX,
    double minY,
    double maxY,
    double pixelStepX,
    double pixelStepY,
  })
  range;
  final void Function(double dx, double dy) onNudge;
  final void Function(double x, double y) onPositionChanged;
  final void Function(double x, double y) onPositionChangeEnd;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            strings.t('nudgePosition'),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A6A6A),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _AxisPositionSlider(
                label: 'X',
                value: range.x,
                min: range.minX,
                max: range.maxX,
                leadingIcon: Icons.chevron_left_rounded,
                trailingIcon: Icons.chevron_right_rounded,
                onStepDown: () => onNudge(-range.pixelStepX, 0),
                onStepUp: () => onNudge(range.pixelStepX, 0),
                onChanged: (value) => onPositionChanged(value, range.y),
                onChangeEnd: (value) => onPositionChangeEnd(value, range.y),
              ),
              const SizedBox(height: 8),
              _AxisPositionSlider(
                label: 'Y',
                value: range.y,
                min: range.minY,
                max: range.maxY,
                leadingIcon: Icons.keyboard_arrow_up_rounded,
                trailingIcon: Icons.keyboard_arrow_down_rounded,
                onStepDown: () => onNudge(0, -range.pixelStepY),
                onStepUp: () => onNudge(0, range.pixelStepY),
                onChanged: (value) => onPositionChanged(range.x, value),
                onChangeEnd: (value) => onPositionChangeEnd(range.x, value),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PositionStepButton extends StatelessWidget {
  const _PositionStepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      pressedScale: 0.92,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 21, color: const Color(0xFF4A4A4A)),
      ),
    );
  }
}

class _AxisPositionSlider extends StatelessWidget {
  const _AxisPositionSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.leadingIcon,
    required this.trailingIcon,
    required this.onStepDown,
    required this.onStepUp,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final IconData leadingIcon;
  final IconData trailingIcon;
  final VoidCallback onStepDown;
  final VoidCallback onStepUp;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF6A6A6A),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _PositionStepButton(icon: leadingIcon, onTap: onStepDown),
        const SizedBox(width: 6),
        Expanded(
          child: SliderTheme(
            data: _positionControlSliderTheme(context),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        const SizedBox(width: 6),
        _PositionStepButton(icon: trailingIcon, onTap: onStepUp),
      ],
    );
  }
}

class _ImageSettingsTabPage extends StatelessWidget {
  const _ImageSettingsTabPage({
    required this.selectedElement,
    required this.sizeRange,
    required this.isCropping,
    required this.onStartCrop,
    required this.onFinishCrop,
    required this.onAspectSelected,
    required this.onSizeChanged,
    required this.onSizeChangeEnd,
    required this.onBorderRadiusChanged,
    required this.onBorderRadiusChangeEnd,
  });

  final CanvasElement selectedElement;
  final ({double value, double min, double max}) sizeRange;
  final bool isCropping;
  final VoidCallback onStartCrop;
  final VoidCallback onFinishCrop;
  final ValueChanged<_ImageAspectOption> onAspectSelected;
  final ValueChanged<double> onSizeChanged;
  final ValueChanged<double> onSizeChangeEnd;
  final ValueChanged<double> onBorderRadiusChanged;
  final ValueChanged<double> onBorderRadiusChangeEnd;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final selectedKey =
        selectedElement.data['aspectPreset'] as String? ?? 'original';
    final borderRadiusRatio = (selectedElement.data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CropActionCard(
                label: isCropping ? strings.t('done') : strings.t('crop'),
                icon: isCropping ? Icons.check_rounded : Icons.crop_rounded,
                selected: isCropping,
                onTap: isCropping ? onFinishCrop : onStartCrop,
              ),
              const SizedBox(width: 12),
              Container(width: 1, height: 75, color: const Color(0xFFD6D6D6)),
              const SizedBox(width: 12),
              for (var i = 0; i < _imageAspectOptions.length; i++) ...[
                _ImageAspectCard(
                  option: _imageAspectOptions[i],
                  height: 75,
                  selected: selectedKey == _imageAspectOptions[i].key,
                  onTap: () => onAspectSelected(_imageAspectOptions[i]),
                ),
                if (i != _imageAspectOptions.length - 1)
                  const SizedBox(width: 12),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                strings.t('size'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6A6A6A),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SliderTheme(
                  data: _lightControlSliderTheme(context),
                  child: Slider(
                    value: sizeRange.value,
                    min: sizeRange.min,
                    max: sizeRange.max,
                    onChanged: onSizeChanged,
                    onChangeEnd: onSizeChangeEnd,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                strings.t('imageCornerRadius'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6A6A6A),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SliderTheme(
                  data: _lightControlSliderTheme(context),
                  child: Slider(
                    value: borderRadiusRatio,
                    min: 0.0,
                    max: 0.5,
                    onChanged: onBorderRadiusChanged,
                    onChangeEnd: onBorderRadiusChangeEnd,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TextSettingsTabPage extends StatelessWidget {
  const _TextSettingsTabPage({
    required this.selectedElement,
    required this.onEditText,
    required this.onColorSelected,
    required this.onSizeChanged,
    required this.onSizeChangeEnd,
  });

  final CanvasElement selectedElement;
  final VoidCallback onEditText;
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<double> onSizeChanged;
  final ValueChanged<double> onSizeChangeEnd;

  @override
  Widget build(BuildContext context) {
    final selectedColor = _textColorFromData(selectedElement.data);
    final selectedColorValue = selectedColor.toARGB32();
    final fontSizeRatio = _textFontSizeRatioFromData(selectedElement.data);
    const colors = <Color>[
      Color(0xFF111111),
      Colors.white,
      Color(0xFFE63946),
      Color(0xFFFFB703),
      Color(0xFF2A9D8F),
      Color(0xFF4361EE),
    ];

    final strings = AppStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            strings.t('textColor'),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6A6A6A),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CropActionCard(
                label: strings.t('edit'),
                icon: Icons.edit_rounded,
                selected: false,
                onTap: onEditText,
              ),
              const SizedBox(width: 12),
              Container(width: 1, height: 75, color: const Color(0xFFD6D6D6)),
              const SizedBox(width: 12),
              for (var i = 0; i < colors.length; i++) ...[
                _TextColorCard(
                  color: colors[i],
                  selected: selectedColorValue == colors[i].toARGB32(),
                  onTap: () => onColorSelected(colors[i]),
                ),
                if (i != colors.length - 1) const SizedBox(width: 10),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                strings.t('size'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6A6A6A),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SliderTheme(
                  data: _lightControlSliderTheme(context),
                  child: Slider(
                    value: fontSizeRatio,
                    min: 0.025,
                    max: 0.16,
                    onChanged: onSizeChanged,
                    onChangeEnd: onSizeChangeEnd,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TextColorCard extends StatelessWidget {
  const _TextColorCard({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 54,
        height: 46,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: selected
              ? Border.all(color: kPrimaryAccentColor, width: 2)
              : null,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
            border: color.toARGB32() == Colors.white.toARGB32()
                ? Border.all(color: const Color(0xFFD0D0D0))
                : null,
          ),
        ),
      ),
    );
  }
}

class _ImageSourceTabPage extends StatelessWidget {
  const _ImageSourceTabPage({
    required this.onUploadImage,
    required this.imagePath,
  });

  final VoidCallback onUploadImage;
  final String imagePath;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: _ElementOptionCard(
              icon: Icons.upload_rounded,
              label: imagePath.isEmpty ? 'uploadPhoto' : 'replaceImage',
              onTap: onUploadImage,
            ),
          ),
          if (imagePath.isNotEmpty) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: Container(
                height: 75,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImageAspectOption {
  const _ImageAspectOption({
    required this.key,
    required this.label,
    this.width,
    this.height,
  });

  final String key;
  final String label;
  final double? width;
  final double? height;

  double? get aspectRatio {
    final width = this.width;
    final height = this.height;
    if (width == null || height == null || height == 0) {
      return null;
    }
    return width / height;
  }
}

class _TemplateOption {
  const _TemplateOption({
    required this.id,
    required this.label,
    this.pageAspectWidth,
    this.pageAspectHeight,
    required this.buildElements,
  });

  final String id;
  final String label;
  final double? pageAspectWidth;
  final double? pageAspectHeight;
  final List<CanvasElement> Function(String pageId, ProjectPage page)
  buildElements;
}

class _PageAspectOption {
  const _PageAspectOption({
    required this.label,
    required this.width,
    required this.height,
  });

  final String label;
  final double width;
  final double height;
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.option,
    required this.page,
    required this.onTap,
  });

  final _TemplateOption option;
  final ProjectPage page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        width: 120,
        height: 75,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: _TemplatePreview(option: option, page: page),
            ),
            const Spacer(),
            Text(
              strings.t(option.label),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F1F1F),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplatePreview extends StatelessWidget {
  const _TemplatePreview({required this.option, required this.page});

  final _TemplateOption option;
  final ProjectPage page;

  @override
  Widget build(BuildContext context) {
    final previewAspectWidth = option.pageAspectWidth ?? page.aspectWidth;
    final previewAspectHeight = option.pageAspectHeight ?? page.aspectHeight;
    const outerWidth = 42.0;
    const outerHeight = 32.0;
    final previewAspectRatio = previewAspectWidth / previewAspectHeight;

    double innerWidth = outerWidth - 10;
    double innerHeight = innerWidth / previewAspectRatio;

    if (innerHeight > outerHeight - 8) {
      innerHeight = outerHeight - 8;
      innerWidth = innerHeight * previewAspectRatio;
    }

    return Container(
      width: outerWidth,
      height: outerHeight,
      decoration: BoxDecoration(
        color: const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: SizedBox(
          width: innerWidth,
          height: innerHeight,
          child: switch (option.id) {
            'page_fill' => Container(
              decoration: BoxDecoration(
                color: const Color(0xFFD8D8D8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            'page_3_4_two_images_3_2_vertical' => Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFD8D8D8),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFD8D8D8),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
            _ => Container(
              decoration: BoxDecoration(
                color: const Color(0xFFD8D8D8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          },
        ),
      ),
    );
  }
}

class _PageAspectCard extends StatelessWidget {
  const _PageAspectCard({
    required this.option,
    required this.height,
    required this.selected,
    required this.onTap,
  });

  final _PageAspectOption option;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cardWidth = height * (option.width / option.height);

    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: cardWidth,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(color: kPrimaryAccentColor, width: 2)
              : null,
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOut,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: const Color(0xFF1F1F1F),
          ),
          child: Text(option.label),
        ),
      ),
    );
  }
}

class _PageColorCard extends StatelessWidget {
  const _PageColorCard({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 75,
        height: 75,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(color: kPrimaryAccentColor, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(999),
                border: color == Colors.white
                    ? Border.all(color: const Color(0xFFD0D0D0))
                    : null,
              ),
            ),
            const Spacer(),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: const Color(0xFF1F1F1F),
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropActionCard extends StatelessWidget {
  const _CropActionCard({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 96,
        height: 75,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? kPrimaryAccentColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 22,
              color: selected ? Colors.white : const Color(0xFF1F1F1F),
            ),
            const Spacer(),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : const Color(0xFF1F1F1F),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageAspectCard extends StatelessWidget {
  const _ImageAspectCard({
    required this.option,
    required this.height,
    required this.selected,
    required this.onTap,
  });

  final _ImageAspectOption option;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final ratio = option.aspectRatio;
    final cardWidth = ratio == null
        ? 92.0
        : (height * ratio).clamp(42.0, 160.0).toDouble();
    final previewHeight = ratio == null ? 18.0 : 20.0;
    final previewWidth = ratio == null
        ? 20.0
        : (previewHeight * ratio).clamp(12.0, 42.0).toDouble();

    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: cardWidth,
        height: height,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(color: const Color(0xFF8F8F8F), width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                width: previewWidth,
                height: previewHeight,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFFB8B8B8), width: 2),
                ),
              ),
            ),
            const Spacer(),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: const Color(0xFF1F1F1F),
              ),
              child: Text(
                option.label.contains(':')
                    ? option.label
                    : strings.t(option.label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ElementOptionCard extends StatelessWidget {
  const _ElementOptionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return _PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        height: 75,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Icon(icon, size: 20, color: const Color(0xFF1F1F1F)),
            ),
            const Spacer(),
            Text(
              strings.t(label),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F1F1F),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportedImageCard extends StatelessWidget {
  const _ImportedImageCard({
    required this.imagePath,
    required this.onTap,
    required this.onLongPress,
  });

  final String imagePath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    const imageSize = 56.0;

    return _PressableScale(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        width: 68,
        height: 75,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(imagePath),
              width: imageSize,
              height: imageSize,
              fit: BoxFit.cover,
              cacheWidth: 112,
              cacheHeight: 112,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => const SizedBox(
                width: imageSize,
                height: imageSize,
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 20,
                  color: Color(0xFF8A8A8A),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HdrImageView extends StatelessWidget {
  final String path;
  final BoxFit fit;
  const HdrImageView({required this.path, this.fit = BoxFit.fill, super.key});

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
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

class _LayersTabPage extends StatelessWidget {
  const _LayersTabPage({
    required this.page,
    required this.selectedElementId,
    required this.onSelectElement,
    required this.onReorderElement,
  });

  final ProjectPage page;
  final String? selectedElementId;
  final ValueChanged<String> onSelectElement;
  final void Function(int oldIndex, int newIndex) onReorderElement;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final elements = page.elements;

    if (elements.isEmpty) {
      return Container(
        height: 75,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.layers_clear_outlined,
              size: 24,
              color: Color(0xFF8A8A8A),
            ),
            const SizedBox(height: 4),
            Text(
              strings.t('noLayers'),
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF8A8A8A),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var index = elements.length - 1; index >= 0; index--) ...[
            _LayerDropTarget(
              key: ValueKey('layer_drop_${elements[index].id}'),
              index: index + 1,
              onDrop: onReorderElement,
              child: _LayerCard(
                key: ValueKey('layer_card_${elements[index].id}'),
                element: elements[index],
                index: index,
                layerNumber: elements.length - index,
                selected: elements[index].id == selectedElementId,
                onTap: () => onSelectElement(elements[index].id),
              ),
            ),
            if (index != 0)
              const SizedBox(width: 12),
          ],
          _LayerDropTarget(
            key: const ValueKey('layer_drop_end'),
            index: 0,
            onDrop: onReorderElement,
            child: const SizedBox(width: 12, height: 75),
          ),
        ],
      ),
    );
  }
}

class _LayerDropTarget extends StatelessWidget {
  const _LayerDropTarget({
    super.key,
    required this.index,
    required this.onDrop,
    required this.child,
  });

  final int index;
  final void Function(int oldIndex, int newIndex) onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      hitTestBehavior: HitTestBehavior.translucent,
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onDrop(details.data, index),
      builder: (context, candidateData, rejectedData) {
        final isTarget = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
          padding: EdgeInsets.symmetric(horizontal: isTarget ? 3 : 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: isTarget ? 3 : 0,
                height: 75,
                decoration: BoxDecoration(
                  color: kPrimaryAccentColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              if (isTarget) const SizedBox(width: 8),
              child,
            ],
          ),
        );
      },
    );
  }
}

class _LayerCard extends StatelessWidget {
  const _LayerCard({
    super.key,
    required this.element,
    required this.index,
    required this.layerNumber,
    required this.selected,
    required this.onTap,
  });

  final CanvasElement element;
  final int index;
  final int layerNumber;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final card = _LayerCardContent(
      element: element,
      layerNumber: layerNumber,
      selected: selected,
    );

    return LongPressDraggable<int>(
      data: index,
      feedback: Material(
        color: Colors.transparent,
        child: Transform.scale(
          scale: 1.05,
          child: card,
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: card,
      ),
      child: _PressableScale(
        onTap: onTap,
        pressedScale: 0.96,
        child: card,
      ),
    );
  }
}

class _LayerCardContent extends StatelessWidget {
  const _LayerCardContent({
    required this.element,
    required this.layerNumber,
    required this.selected,
  });

  final CanvasElement element;
  final int layerNumber;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    const cardWidth = 68.0;
    const cardHeight = 75.0;
    const contentSize = 56.0;

    Widget thumbnail;
    if (element.type == 'image') {
      final src = element.data['src'] as String? ?? '';
      if (src.isEmpty) {
        thumbnail = Container(
          color: const Color(0xFFF2F2F2),
          child: const Center(
            child: Icon(
              Icons.image_outlined,
              size: 20,
              color: Color(0xFF8A8A8A),
            ),
          ),
        );
      } else {
        thumbnail = _CroppedImageFile(
          path: src,
          frameWidth: contentSize,
          frameHeight: contentSize,
          sourceAspectRatio:
              (element.data['originalAspectRatio'] as num?)?.toDouble() ??
              (element.data['aspectRatio'] as num?)?.toDouble() ??
              1.0,
          cropOffsetX: _cropOffsetXFromData(element.data),
          cropOffsetY: _cropOffsetYFromData(element.data),
          cropScale: _cropScaleFromData(element.data),
          cacheWidth: 120,
        );
      }
    } else {
      final text = element.data['text'] as String? ?? '';
      thumbnail = Container(
        color: const Color(0xFFF6F6F6),
        padding: const EdgeInsets.all(4),
        child: Stack(
          children: [
            const Positioned(
              top: 0,
              left: 0,
              child: Icon(
                Icons.title_rounded,
                size: 10,
                color: Color(0xFF8A8A8A),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: Color(0xFF1F1F1F),
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: cardWidth,
      height: cardHeight,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: selected
            ? Border.all(color: kPrimaryAccentColor, width: 2)
            : Border.all(color: const Color(0xFFE2E2E2), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: thumbnail,
            ),
          ),
          Positioned(
            bottom: 2,
            right: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$layerNumber',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
