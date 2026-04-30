import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'app_strings.dart';
import 'project_record.dart';
import 'theme_constants.dart';

enum PageDisplayMode { single, preview }

enum ExportQualityMode { igStandard1080, high2400 }

Color _pageBackgroundColorFromExtras(Map<String, dynamic> extras) {
  final colorValue =
      (extras['backgroundColorValue'] as num?)?.toInt() ?? Colors.white.value;
  return Color(colorValue);
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
    );
  }

  return Uint8List.fromList(img.encodeJpg(canvas, quality: 100));
}

img.Image _cropSourceToFrame({
  required img.Image sourceImage,
  required double frameAspectRatio,
}) {
  final sourceAspectRatio = sourceImage.width / sourceImage.height;
  if (sourceAspectRatio > frameAspectRatio) {
    final cropWidth = (sourceImage.height * frameAspectRatio).round().clamp(
      1,
      sourceImage.width,
    );
    final offsetX = ((sourceImage.width - cropWidth) / 2).round();
    return img.copyCrop(
      sourceImage,
      x: offsetX,
      y: 0,
      width: cropWidth,
      height: sourceImage.height,
    );
  }

  final cropHeight = (sourceImage.width / frameAspectRatio).round().clamp(
    1,
    sourceImage.height,
  );
  final offsetY = ((sourceImage.height - cropHeight) / 2).round();
  return img.copyCrop(
    sourceImage,
    x: 0,
    y: offsetY,
    width: sourceImage.width,
    height: cropHeight,
  );
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
  );
  final resizedImage = img.copyResize(
    croppedSource,
    width: targetWidth,
    height: targetHeight,
    interpolation: interpolation,
  );

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
  final pixelRatio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
  return (logicalWidth > logicalHeight ? logicalWidth : logicalHeight).isFinite
      ? ((logicalWidth > logicalHeight ? logicalWidth : logicalHeight) *
                pixelRatio)
            .round()
            .clamp(96, 2048)
      : 1024;
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

bool _snapEnabledForElement(CanvasElement element) {
  return element.data['snapEnabled'] as bool? ?? true;
}

bool _snapFlagForElement(CanvasElement element, String key) {
  return element.data[key] as bool? ?? true;
}

enum _SnapGuideAxis { vertical, horizontal }

const Color _selectionChromeColor = Color(0xFFBDBDBD);

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
  static const String _tabImageSnap = 'image_snap';
  static const double _singlePagePeekViewportFraction = 0.78;
  static const double _singlePagePeekGap = 8.0;
  int _currentPageIndex = 0;
  late ProjectRecord _project;
  bool _showPageBorder = false;
  bool _isExporting = false;
  bool _isPreparingImage = false;
  int _savingRequestCount = 0;
  PageDisplayMode _displayMode = PageDisplayMode.single;
  String _selectedBottomTab = _tabTemplate;
  String? _selectedElementId;
  String? _deleteArmedElementId;
  late PageController _pageController;
  late final PageController _bottomTabPageController;
  final ScrollController _previewScrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey _exportRepaintKey = GlobalKey();
  final Map<String, Uint8List> _exportImageBytesCache = <String, Uint8List>{};
  final Map<String, Color> _customPageColorDrafts = <String, Color>{};
  List<_SnapGuide> _activeSnapGuides = const <_SnapGuide>[];
  bool _showSinglePageDivider = false;
  _EditorSnapshot? _lastSnapshot;
  bool _hasPendingElementUndoSnapshot = false;

  @override
  void initState() {
    super.initState();
    _project = widget.project.pages.isEmpty
        ? widget.project.copyWith(
            pages: <ProjectPage>[ProjectPage.initial()],
            pageCount: 1,
          )
        : widget.project.copyWith(pageCount: widget.project.pages.length);
    _pageController = _buildPageController();
    _bottomTabPageController = PageController();
    unawaited(_persistProject(_project));
    if (widget.initialImportedSourcePaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_importSourcePaths(widget.initialImportedSourcePaths));
      });
    }
  }

  PageController _buildPageController() {
    return PageController(
      initialPage: _currentPageIndex,
      viewportFraction: _pageControllerViewportFractionForState(),
    );
  }

  bool _hasTwoOptionRows(String tab) =>
      tab == _tabPage || tab == _tabImagePosition;

  bool _isImageTab(String tab) =>
      tab == _tabElements ||
      tab == _tabImagePosition ||
      tab == _tabImageSettings ||
      tab == _tabImageSnap;

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
      _tabElements => strings.t('image'),
      _tabImageSource => strings.t('imageSource'),
      _tabImagePosition => '\u5716\u7247\u4f4d\u7f6e',
      _tabImageSettings => strings.t('imageSettings'),
      _tabImageSnap => strings.t('imageSnap'),
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
    final aspectRatio = (element.data['aspectRatio'] as num?)?.toDouble();
    final nextWidth = width ?? element.width;
    if (aspectRatio != null && aspectRatio > 0) {
      return nextWidth * (page.aspectWidth / page.aspectHeight) / aspectRatio;
    }
    return element.height;
  }

  String _importedImageOriginalPath(String displayPath) {
    final rawList = _project.extras['importedImages'] as List<dynamic>?;
    if (rawList == null) {
      return displayPath;
    }

    for (final item in rawList) {
      if (item is Map && item['src'] == displayPath) {
        final originalSrc = item['originalSrc'] as String?;
        if (originalSrc != null && originalSrc.isNotEmpty) {
          return originalSrc;
        }
      }
    }

    return displayPath;
  }

  Future<({String displayPath, String originalPath})> _prepareImageAsset(
    String sourcePath,
  ) async {
    if (mounted) {
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
              'maxPreviewSide': 1080,
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
      if (mounted) {
        setState(() {
          _isPreparingImage = false;
        });
      }
    }
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
      ];
    }
    return const <String>[_tabPage, _tabTemplate, _tabElements];
  }

  CanvasElement? get _selectedImageElement {
    final selectedId = _selectedElementId;
    if (selectedId == null) {
      return null;
    }

    for (final page in _project.pages) {
      for (final element in page.elements) {
        if (element.id == selectedId && element.type == 'image') {
          return element;
        }
      }
    }
    return null;
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
    if (_showSinglePageDivider == isVisible) {
      return;
    }
    setState(() {
      _showSinglePageDivider = isVisible;
    });
  }

  void _changeBottomTab(String tab) {
    final tabs = _bottomTabs;
    final targetIndex = tabs.indexOf(tab);
    if (targetIndex == -1) {
      return;
    }

    final isImageTab = _isImageTab(tab);
    final shouldClearSelection = _selectedImageElement != null && !isImageTab;

    setState(() {
      if (shouldClearSelection) {
        _selectedElementId = null;
      }
      _deleteArmedElementId = null;
      _selectedBottomTab = tab;
      _refreshPageControllerViewportIfNeeded();
    });

    _bottomTabPageController.animateToPage(
      targetIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
    );
  }

  void _clearSelectedElement() {
    final shouldFallbackToElements =
        _selectedBottomTab == _tabImagePosition ||
        _selectedBottomTab == _tabImageSettings ||
        _selectedBottomTab == _tabImageSnap;
    setState(() {
      _selectedElementId = null;
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
    final strings = AppStrings.of(context);
    if (_displayMode == PageDisplayMode.preview) {
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
    final updatedPages = List<ProjectPage>.from(_project.pages)
      ..removeAt(_currentPageIndex);
    final nextIndex = _currentPageIndex >= updatedPages.length
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
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabTemplate;
      _refreshPageControllerViewportIfNeeded();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentPageIndex);
      }
      _syncBottomTab();
    });
  }

  Future<bool> _confirmPageAspectChangeIfNeeded() async {
    final hasElements = _project.pages.any((page) => page.elements.isNotEmpty);
    if (!hasElements) {
      return true;
    }

    const title = '\u8b8a\u66f4\u9801\u9762\u6bd4\u4f8b';
    const message =
        '\u76ee\u524d\u5c08\u6848\u5df2\u6709\u5167\u5bb9\uff0c'
        '\u8b8a\u66f4\u9801\u9762\u6bd4\u4f8b\u53ef\u80fd\u6703'
        '\u8b93\u5716\u7247\u4f4d\u7f6e\u6216\u5927\u5c0f'
        '\u770b\u8d77\u4f86\u4f4d\u79fb\u3002\u8981\u7e7c\u7e8c\u55ce\uff1f';
    const continueLabel = '\u7e7c\u7e8c';
    final strings = AppStrings.of(context);
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
                const Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  message,
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

  Future<void> _updateCurrentPageColor(Color color) async {
    _storeUndoSnapshot();
    final currentPage = _project.pages[_currentPageIndex];
    final updatedPage = currentPage.copyWith(
      extras: <String, dynamic>{
        ...currentPage.extras,
        'backgroundColorValue': color.toARGB32(),
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
      _deleteArmedElementId = null;
      _selectedBottomTab = _tabElements;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabElements));
    }
  }

  Future<void> _addImageElementFromPath(String path) async {
    if (_selectedImageElement != null) {
      await _applyPathToSelectedImage(path);
      return;
    }

    final preparedImage = await _prepareImageAsset(
      _importedImageOriginalPath(path),
    );

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

    final importedImages = <Map<String, String>>[];
    for (final path in sourcePaths) {
      final preparedImage = await _prepareImageAsset(path);
      importedImages.add(<String, String>{
        'src': preparedImage.displayPath,
        'originalSrc': preparedImage.originalPath,
      });
    }
    final merged = <dynamic>[
      ...(_project.extras['importedImages'] as List<dynamic>? ?? const []),
      ...importedImages,
    ];
    final deduped = <dynamic>[];
    final seenOriginalPaths = <String>{};
    for (final item in merged) {
      if (item is String) {
        if (seenOriginalPaths.add(item)) {
          deduped.add(item);
        }
      } else if (item is Map) {
        final originalSrc =
            (item['originalSrc'] as String?) ?? (item['src'] as String?) ?? '';
        if (originalSrc.isNotEmpty && seenOriginalPaths.add(originalSrc)) {
          deduped.add(item);
        }
      }
    }

    await _saveProjectExtras(<String, dynamic>{
      ..._project.extras,
      'importedImages': deduped,
    });
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

    final preparedImage = await _prepareImageAsset(
      _importedImageOriginalPath(path),
    );

    final size = await _decodeImageSize(preparedImage.displayPath);
    if (size == null || size.height == 0) {
      return;
    }

    final aspectRatio = size.width / size.height;
    final hasTemplateSlot = selectedImage.data['templateSlot'] != null;
    final hasAspectPreset = selectedImage.data['aspectPreset'] != null;
    final shouldKeepFrame = hasTemplateSlot || hasAspectPreset;

    var width = shouldKeepFrame
        ? selectedImage.width
        : selectedImage.width.clamp(0.12, 0.7);
    var height = selectedImage.height;

    if (!shouldKeepFrame) {
      height = width / aspectRatio;

      if (height > 0.84) {
        height = 0.84;
        width = height * aspectRatio;
      }
    }

    final updatedElement = selectedImage.copyWith(
      width: width,
      height: height,
      data: <String, dynamic>{
        ...selectedImage.data,
        'src': preparedImage.displayPath,
        'originalSrc': preparedImage.originalPath,
        'aspectRatio': shouldKeepFrame
            ? ((selectedImage.data['aspectRatio'] as num?)?.toDouble() ??
                  aspectRatio)
            : aspectRatio,
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

  bool _elementCrossesPageBoundary(CanvasElement element) {
    return element.allowCrossPage &&
        (element.x < 0 || (element.x + element.width) > 1);
  }

  void _selectElement(String? elementId) {
    if (elementId == null) {
      _clearSelectedElement();
      return;
    }

    CanvasElement? selectedElement;
    for (final page in _project.pages) {
      for (final element in page.elements) {
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
      if (_selectedBottomTab != _tabPage && !_isImageTab(_selectedBottomTab)) {
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

    var snappedX = x;
    var bestXDistance = snapThreshold;
    _SnapGuide? xGuide;
    for (final target in xTargets) {
      for (final candidate in xCandidates) {
        final distance = (target.value - candidate).abs();
        if (distance < bestXDistance) {
          bestXDistance = distance;
          snappedX = x + (target.value - candidate);
          xGuide = _SnapGuide(
            axis: target.axis,
            value: target.guideValue,
            start: target.guideStart,
            end: target.guideEnd,
          );
        }
      }
    }
    for (final target in xOffsets) {
      final distance = (target.value - x).abs();
      if (distance < bestXDistance) {
        bestXDistance = distance;
        snappedX = target.value;
        xGuide = _SnapGuide(
          axis: target.axis,
          value: target.guideValue,
          start: target.guideStart,
          end: target.guideEnd,
        );
      }
    }

    var snappedY = y;
    var bestYDistance = snapThreshold;
    _SnapGuide? yGuide;
    for (final target in yTargets) {
      for (final candidate in yCandidates) {
        final distance = (target.value - candidate).abs();
        if (distance < bestYDistance) {
          bestYDistance = distance;
          snappedY = y + (target.value - candidate);
          yGuide = _SnapGuide(
            axis: target.axis,
            value: target.guideValue,
            start: target.guideStart,
            end: target.guideEnd,
          );
        }
      }
    }
    for (final target in yOffsets) {
      final distance = (target.value - y).abs();
      if (distance < bestYDistance) {
        bestYDistance = distance;
        snappedY = target.value;
        yGuide = _SnapGuide(
          axis: target.axis,
          value: target.guideValue,
          start: target.guideStart,
          end: target.guideEnd,
        );
      }
    }

    return _SnapResult(
      x: _displayMode == PageDisplayMode.single
          ? snappedX.clamp(0.0, maxX)
          : snappedX.clamp(-0.95, 1.95),
      y: snappedY.clamp(0.0, maxY),
      guides: <_SnapGuide>[
        if (xGuide != null) xGuide,
        if (yGuide != null) yGuide,
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

  Future<void> _updateSelectedImageSnapFlag(String key, bool enabled) async {
    final selectedImage = _selectedImageElement;
    if (selectedImage == null) {
      return;
    }

    _storeUndoSnapshot();
    await _replaceElement(
      selectedImage.copyWith(
        data: <String, dynamic>{...selectedImage.data, key: enabled},
      ),
      persist: true,
    );
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
    const step = 0.01;
    final maxX = (1 - selectedImage.width).clamp(0.0, 1.0);
    final maxY = (1 - _elementRenderedHeight(selectedImage, page)).clamp(
      0.0,
      1.0,
    );
    final rawX = _displayMode == PageDisplayMode.single
        ? (selectedImage.x + (dx * step)).clamp(0.0, maxX)
        : (selectedImage.x + (dx * step)).clamp(-0.95, 1.95);
    final rawY = (selectedImage.y + (dy * step)).clamp(0.0, maxY);

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

    final updatedElement = selectedImage.copyWith(
      y: nextY,
      data: <String, dynamic>{
        ...selectedImage.data,
        'aspectRatio': nextAspectRatio,
        'originalAspectRatio': originalAspectRatio,
        'aspectPreset': option.key,
      },
    );

    await _replaceElement(updatedElement, persist: true);
  }

  Future<void> _applyTemplate(_TemplateOption option) async {
    _storeUndoSnapshot();
    final currentPage = _project.pages[_currentPageIndex];
    final templateElements = option.buildElements(currentPage.id, currentPage);
    final updatedPage = currentPage.copyWith(
      elements: templateElements,
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
        _selectedBottomTab = _tabElements;
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
      _deleteArmedElementId = null;
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
      final sourceAspectRatio = sourceImage.width / sourceImage.height;

      img.Image croppedSource;
      if (sourceAspectRatio > aspectRatio) {
        final cropWidth = (sourceImage.height * aspectRatio).round().clamp(
          1,
          sourceImage.width,
        );
        final offsetX = ((sourceImage.width - cropWidth) / 2).round();
        croppedSource = img.copyCrop(
          sourceImage,
          x: offsetX,
          y: 0,
          width: cropWidth,
          height: sourceImage.height,
        );
      } else {
        final cropHeight = (sourceImage.width / aspectRatio).round().clamp(
          1,
          sourceImage.height,
        );
        final offsetY = ((sourceImage.height - cropHeight) / 2).round();
        croppedSource = img.copyCrop(
          sourceImage,
          x: 0,
          y: offsetY,
          width: sourceImage.width,
          height: cropHeight,
        );
      }

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

      final file = File(path);
      if (!await file.exists()) {
        continue;
      }

      try {
        _exportImageBytesCache[path] = await file.readAsBytes();
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
            },
          )
          .toList(),
    };

    return compute(_renderPageJpgBytes, payload);
  }

  Future<Uint8List> _renderProjectPageInSetBytesForGallery({
    required int exportWidth,
    required List<int> pageIndexes,
    required int targetListIndex,
  }) {
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

    final payload = <String, dynamic>{
      'exportWidth': exportWidth,
      'targetPageIndex': targetListIndex,
      'images': <String, Uint8List>{
        for (final path in usedImagePaths) path: _exportImageBytesCache[path]!,
      },
      'pages': pageIndexes
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
                    },
                  )
                  .toList(),
            },
          )
          .toList(),
    };

    return compute(_renderSelectedPageJpgBytes, payload);
  }

  Future<void> _exportAllPagesToGallery({
    required bool reverseOrder,
    required ExportQualityMode qualityMode,
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
      final totalPages = _project.pages.length;
      final exportWidth = switch (qualityMode) {
        ExportQualityMode.igStandard1080 => 1080,
        ExportQualityMode.high2400 => 2400,
      };
      final pageIndexes = reverseOrder
          ? <int>[for (var i = totalPages - 1; i >= 0; i--) i]
          : <int>[for (var i = 0; i < totalPages; i++) i];

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

      if (successCount == _project.pages.length) {
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
    final bottomPanelHeight = _hasTwoOptionRows(_selectedBottomTab)
        ? 248.0
        : 180.0;
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
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PageChangeButton(
                            icon: Icons.chevron_left_rounded,
                            enabled: _currentPageIndex > 0,
                            onTap: () => _goToPage(_currentPageIndex - 1),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            strings.t(
                              'pageIndicator',
                              args: <String, String>{
                                'current': '${_currentPageIndex + 1}',
                                'total': '${pages.length}',
                              },
                            ),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.black54,
                            ),
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

                      return Padding(
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
                                                  deleteArmedElementId:
                                                      _deleteArmedElementId,
                                                  snapGuides: _activeSnapGuides,
                                                  onTapCanvas:
                                                      _clearSelectedElement,
                                                  onTapElement: _selectElement,
                                                  onDoubleTapElement:
                                                      (elementId) {
                                                        _selectElement(
                                                          elementId,
                                                        );
                                                        unawaited(
                                                          _fitElementToCanvas(
                                                            pageId: page.id,
                                                            elementId:
                                                                elementId,
                                                          ),
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
                                              viewportWidth: previewCanvasWidth,
                                              viewportHeight:
                                                  previewCanvasHeight,
                                              exportPageId: currentPage.id,
                                              exportRepaintKey:
                                                  _exportRepaintKey,
                                              showBorder: _showPageBorder,
                                              selectedElementId:
                                                  _selectedElementId,
                                              deleteArmedElementId:
                                                  _deleteArmedElementId,
                                              snapGuides: _activeSnapGuides,
                                              onTapCanvas:
                                                  _clearSelectedElement,
                                              onTapElement: _selectElement,
                                              onDoubleTapElement: (elementId) {
                                                _selectElement(elementId);
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
                                                unawaited(
                                                  _fitElementToCanvas(
                                                    pageId: pageId,
                                                    elementId: elementId,
                                                  ),
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
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      for (var i = 0; i < bottomTabs.length; i++) ...[
                        _BottomTab(
                          label: _tabLabel(context, bottomTabs[i]),
                          selected: _selectedBottomTab == bottomTabs[i],
                          onTap: () => _changeBottomTab(bottomTabs[i]),
                        ),
                        if (i != bottomTabs.length - 1)
                          const SizedBox(width: 18),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  height: bottomPanelHeight,
                  child: PageView(
                    key: ValueKey(bottomTabs.join('|')),
                    controller: _bottomTabPageController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: _selectedImageElement == null
                        ? <Widget>[
                            _PageTabPage(
                              page: currentPage,
                              onAspectSelected: (width, height) {
                                _updateCurrentPageAspect(
                                  aspectWidth: width,
                                  aspectHeight: height,
                                );
                              },
                              onColorSelected: _updateCurrentPageColor,
                              onCustomColorTap: _showCustomPageColorDialog,
                            ),
                            _TemplateTabPage(
                              page: currentPage,
                              onApplyTemplate: _applyTemplate,
                            ),
                            _ElementTabPage(
                              onImportImages: _importImages,
                              importedImagePaths: _importedImagePaths,
                              onTapImportedImage: _addImageElementFromPath,
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
                              onColorSelected: _updateCurrentPageColor,
                              onCustomColorTap: _showCustomPageColorDialog,
                            ),
                            _TemplateTabPage(
                              page: currentPage,
                              onApplyTemplate: _applyTemplate,
                            ),
                            _ElementTabPage(
                              onImportImages: _importImages,
                              importedImagePaths: _importedImagePaths,
                              onTapImportedImage: _addImageElementFromPath,
                            ),
                            _ImagePositionTabPage(
                              selectedElement: _selectedImageElement!,
                              onNudge: _nudgeSelectedImage,
                              onSnapFlagChanged: _updateSelectedImageSnapFlag,
                            ),
                            _ImageSettingsTabPage(
                              selectedElement: _selectedImageElement!,
                              onAspectSelected: _updateSelectedImageAspect,
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
    required this.deleteArmedElementId,
    required this.snapGuides,
    required this.onTapCanvas,
    required this.onTapElement,
    required this.onDoubleTapElement,
    required this.onMoveElement,
    required this.onResizeElement,
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
  final String? deleteArmedElementId;
  final List<_SnapGuide> snapGuides;
  final VoidCallback onTapCanvas;
  final ValueChanged<String> onTapElement;
  final ValueChanged<String> onDoubleTapElement;
  final void Function(String elementId, double x, double y, bool persist)
  onMoveElement;
  final void Function(String elementId, double width, bool persist)
  onResizeElement;
  final ValueChanged<String> onDeleteElement;
  final ValueChanged<String> onConfirmDeleteElement;
  final ValueChanged<String> onCancelDeleteElement;

  @override
  Widget build(BuildContext context) {
    const controlChromePadding = 9.0;
    final pageWidth = (viewportWidth - (controlChromePadding * 2))
        .clamp(1.0, viewportWidth)
        .toDouble();
    final pageHeight = pageWidth * (page.aspectHeight / page.aspectWidth);

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
                                            onDelete: () {},
                                            onConfirmDelete: () {},
                                            onCancelDelete: () {},
                                          ),
                                  ],
                                ),
                              ),
                            ),
                            for (final element in page.elements)
                              if (element.type == 'image')
                                _ImageElementWidget(
                                  element: element,
                                  isSelected: selectedElementId == element.id,
                                  isDeleteArmed:
                                      deleteArmedElementId == element.id,
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
                                  onDelete: () => onDeleteElement(element.id),
                                  onConfirmDelete: () =>
                                      onConfirmDeleteElement(element.id),
                                  onCancelDelete: () =>
                                      onCancelDeleteElement(element.id),
                                ),
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
            if (showPageDivider && pageIndex < pages.length - 1)
              Positioned(
                right: -1,
                top: (viewportHeight - pageHeight) / 2,
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
    required this.viewportWidth,
    required this.viewportHeight,
    required this.exportPageId,
    required this.exportRepaintKey,
    required this.showBorder,
    required this.selectedElementId,
    required this.deleteArmedElementId,
    required this.snapGuides,
    required this.onTapCanvas,
    required this.onTapElement,
    required this.onDoubleTapElement,
    required this.onMoveElement,
    required this.onResizeElement,
    required this.onDeleteElement,
    required this.onConfirmDeleteElement,
    required this.onCancelDeleteElement,
  });

  final List<ProjectPage> pages;
  final double viewportWidth;
  final double viewportHeight;
  final String exportPageId;
  final GlobalKey exportRepaintKey;
  final bool showBorder;
  final String? selectedElementId;
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
                          ? Border.all(color: const Color(0xFF8F8F8F), width: 1)
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
            for (final element in pages[i].elements)
              if (element.type == 'image')
                _PreviewImageElementWidget(
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
                              (pages[i].aspectHeight / pages[i].aspectWidth))) /
                      2),
                  onTap: () => onTapElement(element.id),
                  onDoubleTap: () => onDoubleTapElement(element.id),
                  onMove: (x, y, persist) {
                    onMoveElement(pages[i].id, element.id, x, y, persist);
                  },
                  onResize: (width, persist) {
                    onResizeElement(pages[i].id, element.id, width, persist);
                  },
                  onDelete: () => onDeleteElement(pages[i].id, element.id),
                  onConfirmDelete: () =>
                      onConfirmDeleteElement(pages[i].id, element.id),
                  onCancelDelete: () => onCancelDeleteElement(element.id),
                ),
          for (var i = 0; i < pages.length; i++)
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

class _ImageElementWidget extends StatefulWidget {
  const _ImageElementWidget({
    required this.element,
    required this.isSelected,
    required this.isDeleteArmed,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMove,
    required this.onResize,
    required this.onDelete,
    required this.onConfirmDelete,
    required this.onCancelDelete,
  });

  final CanvasElement element;
  final bool isSelected;
  final bool isDeleteArmed;
  final double canvasWidth;
  final double canvasHeight;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(double x, double y, bool persist) onMove;
  final void Function(double width, bool persist) onResize;
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
  bool _isResizing = false;
  late double _resizeStartWidth;
  late Offset _resizeStartGlobalPosition;

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
            : widget.onDoubleTap,
        onLongPress: () {
          if (_isResizing) {
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
          _currentX = widget.element.x;
          _currentY = widget.element.y;
          widget.onTap();
        },
        onPanUpdate: (details) {
          if (_isResizing) {
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
              ),
              clipBehavior: Clip.hardEdge,
              child: src.isEmpty
                  ? const Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: Color(0xFF8A8A8A),
                        size: 24,
                      ),
                    )
                  : Image.file(
                      File(src),
                      fit: BoxFit.cover,
                      cacheWidth: _previewImageCacheExtent(
                        context,
                        width,
                        height,
                      ),
                      filterQuality: FilterQuality.low,
                      gaplessPlayback: true,
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
                        _resizeStartWidth = widget.element.width;
                        _currentWidth = widget.element.width;
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
                        final scaleDelta =
                            (totalDx / widget.canvasWidth) +
                            ((totalDy / widget.canvasHeight) * aspectRatio);
                        _currentWidth = _resizeStartWidth + (scaleDelta * 0.5);
                        widget.onResize(_currentWidth, false);
                      },
                      onPanEnd: (_) {
                        _isResizing = false;
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

class _PreviewImageElementWidget extends StatefulWidget {
  const _PreviewImageElementWidget({
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
    required this.onResize,
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
  final void Function(double width, bool persist) onResize;
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
            : widget.onDoubleTap,
        onLongPress: () {
          if (_isResizing) {
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
          _currentX = widget.element.x;
          _currentY = widget.element.y;
          widget.onTap();
        },
        onPanUpdate: (details) {
          if (_isResizing) {
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
              ),
              clipBehavior: Clip.hardEdge,
              child: src.isEmpty
                  ? const Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: Color(0xFF8A8A8A),
                        size: 24,
                      ),
                    )
                  : Image.file(
                      File(src),
                      fit: BoxFit.cover,
                      cacheWidth: _previewImageCacheExtent(
                        context,
                        width,
                        height,
                      ),
                      filterQuality: FilterQuality.low,
                      gaplessPlayback: true,
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
                        _resizeStartWidth = widget.element.width;
                        _currentWidth = widget.element.width;
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
                        final scaleDelta =
                            (totalDx / widget.pageWidth) +
                            ((totalDy / widget.pageHeight) * aspectRatio);
                        _currentWidth = _resizeStartWidth + (scaleDelta * 0.5);
                        widget.onResize(_currentWidth, false);
                      },
                      onPanEnd: (_) {
                        _isResizing = false;
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
    this.enabled = true,
    this.pressedScale = 0.96,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final double pressedScale;

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _pressed = false;

  bool get _isEnabled => widget.enabled && widget.onTap != null;

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
      onTap: _isEnabled ? widget.onTap : null,
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
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

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
  });

  final IconData icon;
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
        child: Icon(
          icon,
          size: 18,
          color: isPrimary ? Colors.white : const Color(0xFF1F1F1F),
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
        width: 24,
        height: 24,
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

class _SlideSwitch extends StatelessWidget {
  const _SlideSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 94,
        height: 32,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFFD8D8D8),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Stack(
          children: [
            const Row(
              children: [
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.crop_portrait_rounded,
                      size: 14,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.view_carousel_rounded,
                      size: 14,
                      color: Colors.black54,
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
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(
                  value
                      ? Icons.view_carousel_rounded
                      : Icons.crop_portrait_rounded,
                  size: 14,
                  color: Colors.black87,
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
            const SizedBox(width: 6),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? kPrimaryAccentColor : const Color(0xFF7A7A7A),
              ),
              child: Text(detail),
            ),
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
  final ValueChanged<Color> onColorSelected;
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
        Colors.white.value;

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
          child: Row(
            children: [
              _PageColorCard(
                label: '白',
                color: Colors.white,
                selected: selectedColorValue == Colors.white.value,
                onTap: () => onColorSelected(Colors.white),
              ),
              const SizedBox(width: 12),
              _PageColorCard(
                label: '黑',
                color: Colors.black,
                selected: selectedColorValue == Colors.black.value,
                onTap: () => onColorSelected(Colors.black),
              ),
              const SizedBox(width: 12),
              _PageColorCard(
                label: '自訂',
                color: Color(selectedColorValue),
                selected:
                    selectedColorValue != Colors.white.value &&
                    selectedColorValue != Colors.black.value,
                onTap: onCustomColorTap,
              ),
            ],
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
    required this.onImportImages,
    required this.importedImagePaths,
    required this.onTapImportedImage,
  });

  final VoidCallback onImportImages;
  final List<String> importedImagePaths;
  final ValueChanged<String> onTapImportedImage;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
            ),
          ],
        ],
      ),
    );
  }
}

class _ImagePositionTabPage extends StatelessWidget {
  const _ImagePositionTabPage({
    required this.selectedElement,
    required this.onNudge,
    required this.onSnapFlagChanged,
  });

  final CanvasElement selectedElement;
  final void Function(double dx, double dy) onNudge;
  final void Function(String key, bool enabled) onSnapFlagChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _ImageNudgeButton(
                icon: Icons.keyboard_arrow_up_rounded,
                onTap: () => onNudge(0, -1),
              ),
              const SizedBox(width: 10),
              _ImageNudgeButton(
                icon: Icons.keyboard_arrow_down_rounded,
                onTap: () => onNudge(0, 1),
              ),
              const SizedBox(width: 10),
              _ImageNudgeButton(
                icon: Icons.keyboard_arrow_left_rounded,
                onTap: () => onNudge(-1, 0),
              ),
              const SizedBox(width: 10),
              _ImageNudgeButton(
                icon: Icons.keyboard_arrow_right_rounded,
                onTap: () => onNudge(1, 0),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _ImageSnapTabPage(
            selectedElement: selectedElement,
            onSnapFlagChanged: onSnapFlagChanged,
          ),
        ),
      ],
    );
  }
}

class _ImageSettingsTabPage extends StatelessWidget {
  const _ImageSettingsTabPage({
    required this.selectedElement,
    required this.onAspectSelected,
  });

  final CanvasElement selectedElement;
  final ValueChanged<_ImageAspectOption> onAspectSelected;

  @override
  Widget build(BuildContext context) {
    final selectedKey =
        selectedElement.data['aspectPreset'] as String? ?? 'original';
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _imageAspectOptions.length; i++) ...[
            _ImageAspectCard(
              option: _imageAspectOptions[i],
              height: 75,
              selected: selectedKey == _imageAspectOptions[i].key,
              onTap: () => onAspectSelected(_imageAspectOptions[i]),
            ),
            if (i != _imageAspectOptions.length - 1) const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }
}

class _ImageNudgeButton extends StatelessWidget {
  const _ImageNudgeButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: onTap,
      pressedScale: 0.92,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        width: 54,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(icon, size: 26, color: const Color(0xFF1F1F1F)),
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

class _ImageSnapTabPage extends StatelessWidget {
  const _ImageSnapTabPage({
    required this.selectedElement,
    required this.onSnapFlagChanged,
  });

  final CanvasElement selectedElement;
  final void Function(String key, bool enabled) onSnapFlagChanged;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final options = <({String key, String label, IconData icon})>[
      (
        key: 'snapEnabled',
        label: strings.t('snapAll'),
        icon: Icons.center_focus_strong_rounded,
      ),
      (
        key: 'snapPageEdges',
        label: strings.t('snapPageEdges'),
        icon: Icons.crop_free_rounded,
      ),
      (
        key: 'snapPageCenter',
        label: strings.t('snapPageCenter'),
        icon: Icons.vertical_align_center_rounded,
      ),
      (
        key: 'snapImageLines',
        label: strings.t('snapImageLines'),
        icon: Icons.align_horizontal_center_rounded,
      ),
      (
        key: 'snapImageEdges',
        label: strings.t('snapImageEdges'),
        icon: Icons.space_bar_rounded,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < options.length; i++) ...[
              _SnapToggleCard(
                label: options[i].label,
                icon: options[i].icon,
                value: options[i].key == 'snapEnabled'
                    ? _snapEnabledForElement(selectedElement)
                    : _snapFlagForElement(selectedElement, options[i].key),
                onChanged: (enabled) =>
                    onSnapFlagChanged(options[i].key, enabled),
              ),
              if (i != options.length - 1) const SizedBox(width: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _SnapToggleCard extends StatelessWidget {
  const _SnapToggleCard({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        width: 120,
        height: 75,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: value
              ? Border.all(color: kPrimaryAccentColor, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 20,
              color: value ? kPrimaryAccentColor : const Color(0xFF7A7A7A),
            ),
            const Spacer(),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              style: TextStyle(
                fontSize: 13,
                fontWeight: value ? FontWeight.w700 : FontWeight.w600,
                color: const Color(0xFF1F1F1F),
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
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
  const _ImportedImageCard({required this.imagePath, required this.onTap});

  final String imagePath;
  final VoidCallback onTap;

  Future<ui.Size?> _decodeSize() async {
    final bytes = await File(imagePath).readAsBytes();
    final completer = Completer<ui.Size?>();
    ui.decodeImageFromList(bytes, (image) {
      completer.complete(
        ui.Size(image.width.toDouble(), image.height.toDouble()),
      );
    });
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Size?>(
      future: _decodeSize(),
      builder: (context, snapshot) {
        const imageHeight = 56.0;
        final ratio = snapshot.data == null || snapshot.data!.height == 0
            ? 1.0
            : snapshot.data!.width / snapshot.data!.height;
        final imageWidth = (imageHeight * ratio).clamp(32.0, 180.0).toDouble();

        return _PressableScale(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
            width: imageWidth + 12,
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
                  width: imageWidth,
                  height: imageHeight,
                  fit: BoxFit.fitHeight,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 56,
                    height: 56,
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
      },
    );
  }
}
