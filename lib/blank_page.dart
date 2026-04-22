import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'project_record.dart';

enum PageDisplayMode { single, preview }

class BlankPage extends StatefulWidget {
  const BlankPage({
    super.key,
    required this.project,
    required this.onProjectChanged,
  });

  final ProjectRecord project;
  final Future<void> Function(ProjectRecord project) onProjectChanged;

  @override
  State<BlankPage> createState() => _BlankPageState();
}

class _BlankPageState extends State<BlankPage> {
  static const MethodChannel _galleryChannel = MethodChannel('igapp/gallery');
  static const String _tabPage = '頁面';
  static const String _tabTemplate = '模板';
  static const String _tabElements = '元素';
  static const String _tabImageSource = '圖片來源';
  static const String _tabImageSettings = '圖片設置';
  int _currentPageIndex = 0;
  late ProjectRecord _project;
  bool _showPageBorder = false;
  bool _isExporting = false;
  PageDisplayMode _displayMode = PageDisplayMode.single;
  String _selectedBottomTab = _tabTemplate;
  String? _selectedElementId;
  late PageController _pageController;
  late final PageController _bottomTabPageController;
  final ScrollController _previewScrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey _exportRepaintKey = GlobalKey();

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
  }

  PageController _buildPageController() {
    return PageController(
      initialPage: _currentPageIndex,
      viewportFraction: _displayMode == PageDisplayMode.single ? 1 : 0.78,
    );
  }

  Future<void> _persistProject(ProjectRecord updatedProject) async {
    _project = updatedProject.copyWith(pageCount: updatedProject.pages.length);
    if (mounted) {
      setState(() {});
    }
    await widget.onProjectChanged(_project);
  }

  Future<void> _saveProject(ProjectRecord updatedProject) async {
    await _persistProject(updatedProject);
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
        _tabImageSource,
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
      _selectedBottomTab = tabs.last;
    }
    final targetIndex = tabs.indexOf(_selectedBottomTab);
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(targetIndex);
    }
  }

  void _changeBottomTab(String tab) {
    final tabs = _bottomTabs;
    final targetIndex = tabs.indexOf(tab);
    if (targetIndex == -1) {
      return;
    }

    final isImageTab = tab == _tabImageSource || tab == _tabImageSettings;
    final shouldClearSelection =
        _selectedImageElement != null && !isImageTab;

    setState(() {
      if (shouldClearSelection) {
        _selectedElementId = null;
      }
      _selectedBottomTab = tab;
    });

    _bottomTabPageController.animateToPage(
      targetIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _clearSelectedElement() {
    final shouldFallbackToElements =
        _selectedBottomTab == _tabImageSource ||
        _selectedBottomTab == _tabImageSettings;
    setState(() {
      _selectedElementId = null;
      if (shouldFallbackToElements) {
        _selectedBottomTab = _tabElements;
      }
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(
        shouldFallbackToElements ? 2 : _bottomTabs.indexOf(_selectedBottomTab),
      );
    }
  }

  Future<void> _addPage() async {
    final nextIndex = _project.pages.length + 1;
    final newPages = List<ProjectPage>.from(_project.pages)
      ..add(ProjectPage.initial(nextIndex));

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
      _selectedBottomTab = _tabTemplate;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_displayMode == PageDisplayMode.single &&
          _pageController.hasClients) {
        _pageController.animateToPage(
          _currentPageIndex,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
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

    if (_project.pages.length <= 1) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('至少保留一頁')));
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
                const Text(
                  '刪除頁面',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '確定要刪除目前頁面嗎？',
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
                        label: '取消',
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: '刪除',
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
      _selectedBottomTab = _tabTemplate;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentPageIndex);
      }
      _syncBottomTab();
    });
  }

  Future<void> _updateCurrentPageAspect({
    required double aspectWidth,
    required double aspectHeight,
  }) async {
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
      _selectedBottomTab = _tabImageSource;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabImageSource));
    }
  }

  Future<void> _pickImageForSelected() async {
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('圖片選擇器尚未載入，請完整重啟 App 後再試一次。')),
      );
      return;
    }

    if (picked == null) {
      return;
    }

    final size = await _decodeImageSize(picked.path);
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
        'src': picked.path,
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
      _selectedBottomTab = _tabImageSource;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabImageSource));
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

  void _selectElement(String? elementId) {
    if (elementId == null) {
      _clearSelectedElement();
      return;
    }

    setState(() {
      _selectedElementId = elementId;
      _selectedBottomTab = _tabImageSource;
    });
    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(_bottomTabs.indexOf(_tabImageSource));
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
    final pageIndex = _project.pages.indexWhere((page) => page.id == pageId);
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final element = page.elements.firstWhere((item) => item.id == elementId);
    final maxX = (1 - element.width).clamp(0.0, 1.0);
    final maxY = (1 - element.height).clamp(0.0, 1.0);
    final updatedElement = element.copyWith(
      x: (_displayMode == PageDisplayMode.single
          ? x.clamp(0.0, maxX)
          : x.clamp(-0.95, 1.95)),
      y: y.clamp(0.0, maxY),
    );

    unawaited(_replaceElement(updatedElement, persist: persist));
  }

  void _updateElementSize({
    required String pageId,
    required String elementId,
    required double width,
    required bool persist,
  }) {
    final pageIndex = _project.pages.indexWhere((page) => page.id == pageId);
    if (pageIndex == -1) {
      return;
    }

    final page = _project.pages[pageIndex];
    final element = page.elements.firstWhere((item) => item.id == elementId);
    final aspectRatio =
        (element.data['aspectRatio'] as num?)?.toDouble() ??
        (element.width / element.height);
    final nextWidth = width.clamp(0.08, 2.2);
    final nextHeight = nextWidth / aspectRatio;
    final maxX = (1 - nextWidth).clamp(0.0, 1.0);
    final maxY = (1 - nextHeight).clamp(0.0, 1.0);
    final updatedElement = element.copyWith(
      width: nextWidth,
      height: nextHeight,
      x: (_displayMode == PageDisplayMode.single
          ? element.x.clamp(0.0, maxX)
          : element.x),
      y: element.y.clamp(0.0, maxY),
      data: <String, dynamic>{...element.data, 'aspectRatio': aspectRatio},
    );

    unawaited(_replaceElement(updatedElement, persist: persist));
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
    final currentPage = _project.pages[_currentPageIndex];
    final templateElements = option.buildElements(currentPage.id, currentPage);
    final updatedPage = currentPage.copyWith(
      elements: templateElements,
      extras: <String, dynamic>{
        ...currentPage.extras,
        'templateId': option.id,
      },
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
    });

    if (_bottomTabPageController.hasClients) {
      _bottomTabPageController.jumpToPage(1);
    }
  }

  void _jumpPreviewToPage(int pageIndex) {
    if (!_previewScrollController.hasClients) {
      return;
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final pageWidth = screenWidth * 0.78;
    _previewScrollController.jumpTo(pageWidth * pageIndex);
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
        throw Exception('找不到可匯出的畫布');
      }

      final uiImage = await boundary.toImage(pixelRatio: 6);
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('畫布轉換失敗');
      }

      final pngBytes = byteData.buffer.asUint8List();
      final decodedImage = img.decodeImage(pngBytes);
      if (decodedImage == null) {
        throw Exception('圖片編碼失敗');
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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已匯出 JPG：${file.path}')));
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('匯出失敗，請再試一次。')));
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
    final exportHeight =
        (exportWidth * (page.aspectHeight / page.aspectWidth)).round();
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

      img.compositeImage(
        canvas,
        resizedImage,
        dstX: targetX,
        dstY: targetY,
      );
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

  Future<void> _exportAllPagesToGallery() async {
    if (_isExporting) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isExporting = true;
    });

    try {
      var successCount = 0;

      for (var i = 0; i < _project.pages.length; i++) {
        final pageImage = await _renderProjectPageForGallery(_project.pages[i]);
        final jpgBytes = Uint8List.fromList(
          img.encodeJpg(pageImage, quality: 100),
        );

        final isSuccess = await _saveImageToGallery(
          bytes: jpgBytes,
          name: _buildGalleryExportName(i),
        );
        if (isSuccess) {
          successCount += 1;
        }
      }

      if (!mounted) {
        return;
      }

      if (successCount == _project.pages.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已儲存 ${successCount} 張到手機相簿')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已儲存 ${successCount} 張，部分頁面匯出失敗')),
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('匯出失敗，請再試一次。')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
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
    final screenWidth = MediaQuery.of(context).size.width;
    final singleCanvasWidth = screenWidth - 24;
    final previewCanvasWidth = screenWidth * 0.78;
    const fixedCanvasHeightRatio = 4 / 3;
    final singleCanvasHeight = singleCanvasWidth * fixedCanvasHeightRatio;
    final previewCanvasHeight = previewCanvasWidth * fixedCanvasHeightRatio;
    final canvasHeight = _displayMode == PageDisplayMode.single
        ? singleCanvasHeight
        : previewCanvasHeight;
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
                '建立時間  ・ 總頁數 ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _isExporting ? null : _exportAllPagesToGallery,
              icon: _isExporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black54,
                      ),
                    )
                  : const Icon(Icons.file_download_outlined),
            ),
            const SizedBox(width: 4),
          ],
        ),
        backgroundColor: const Color(0xFFEAEAEA),
        body: Column(
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
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
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
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
                      _ToolbarIconButton(
                        icon: Icons.delete_outline_rounded,
                        onPressed: _deleteCurrentPage,
                        enabled: _displayMode == PageDisplayMode.single,
                      ),
                      const SizedBox(width: 8),
                      _ToolbarIconButton(icon: Icons.add, onPressed: _addPage),
                    ],
                  ),
                  Text(
                    '第 ${_currentPageIndex + 1} / ${pages.length} 頁',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              height: canvasHeight,
              alignment: Alignment.center,
              child: _displayMode == PageDisplayMode.single
                  ? PageView.builder(
                      controller: _pageController,
                      padEnds: false,
                      physics: _selectedElementId == null
                          ? const PageScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      itemCount: pages.length,
                      onPageChanged: (index) {
                        setState(() {
                          _currentPageIndex = index;
                          _selectedElementId = null;
                          _selectedBottomTab = _tabElements;
                        });
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _syncBottomTab(),
                        );
                      },
                      itemBuilder: (context, index) {
                        final page = pages[index];
                        return _CanvasViewport(
                          page: page,
                          viewportWidth: singleCanvasWidth,
                          viewportHeight: singleCanvasHeight,
                          repaintKey: index == _currentPageIndex
                              ? _exportRepaintKey
                              : null,
                          showBorder: _showPageBorder,
                          selectedElementId: _selectedElementId,
                          onTapCanvas: _clearSelectedElement,
                          onTapElement: _selectElement,
                          onMoveElement: (elementId, x, y, persist) {
                            _updateElementPosition(
                              pageId: page.id,
                              elementId: elementId,
                              x: x,
                              y: y,
                              persist: persist,
                            );
                          },
                          onResizeElement: (elementId, width, persist) {
                            _updateElementSize(
                              pageId: page.id,
                              elementId: elementId,
                              width: width,
                              persist: persist,
                            );
                          },
                          onDeleteElement: (elementId) {
                            _deleteElement(
                              pageId: page.id,
                              elementId: elementId,
                            );
                          },
                        );
                      },
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        _syncPreviewPageIndex();
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: _previewScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: _selectedElementId == null
                            ? const BouncingScrollPhysics()
                            : const NeverScrollableScrollPhysics(),
                        child: _PreviewCanvasStrip(
                          pages: pages,
                          viewportWidth: previewCanvasWidth,
                          viewportHeight: previewCanvasHeight,
                          exportPageId: currentPage.id,
                          exportRepaintKey: _exportRepaintKey,
                          showBorder: _showPageBorder,
                          selectedElementId: _selectedElementId,
                          onTapCanvas: _clearSelectedElement,
                          onTapElement: _selectElement,
                          onMoveElement: (pageId, elementId, x, y, persist) {
                            _updateElementPosition(
                              pageId: pageId,
                              elementId: elementId,
                              x: x,
                              y: y,
                              persist: persist,
                            );
                          },
                          onResizeElement: (pageId, elementId, width, persist) {
                            _updateElementSize(
                              pageId: pageId,
                              elementId: elementId,
                              width: width,
                              persist: persist,
                            );
                          },
                          onDeleteElement: (pageId, elementId) {
                            _deleteElement(
                              pageId: pageId,
                              elementId: elementId,
                            );
                          },
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (var i = 0; i < bottomTabs.length; i++) ...[
                    _BottomTab(
                      label: bottomTabs[i],
                      selected: _selectedBottomTab == bottomTabs[i],
                      onTap: () => _changeBottomTab(bottomTabs[i]),
                    ),
                    if (i != bottomTabs.length - 1) const SizedBox(width: 18),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 180,
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
                        ),
                        _TemplateTabPage(
                          page: currentPage,
                          onApplyTemplate: _applyTemplate,
                        ),
                        _ElementTabPage(onAddImage: _addImageElement),
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
                        ),
                        _TemplateTabPage(
                          page: currentPage,
                          onApplyTemplate: _applyTemplate,
                        ),
                        _ElementTabPage(onAddImage: _addImageElement),
                        _ImageSourceTabPage(
                          onUploadImage: _pickImageForSelected,
                          imagePath:
                              _selectedImageElement?.data['src'] as String? ??
                              '',
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
      ),
    );
  }
}

class _CanvasViewport extends StatelessWidget {
  const _CanvasViewport({
    required this.page,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.repaintKey,
    required this.showBorder,
    required this.selectedElementId,
    required this.onTapCanvas,
    required this.onTapElement,
    required this.onMoveElement,
    required this.onResizeElement,
    required this.onDeleteElement,
  });

  final ProjectPage page;
  final double viewportWidth;
  final double viewportHeight;
  final GlobalKey? repaintKey;
  final bool showBorder;
  final String? selectedElementId;
  final VoidCallback onTapCanvas;
  final ValueChanged<String> onTapElement;
  final void Function(String elementId, double x, double y, bool persist)
  onMoveElement;
  final void Function(String elementId, double width, bool persist)
  onResizeElement;
  final ValueChanged<String> onDeleteElement;

  @override
  Widget build(BuildContext context) {
    final pageHeight = viewportWidth * (page.aspectHeight / page.aspectWidth);

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: viewportWidth,
        height: viewportHeight,
        child: Center(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onTapCanvas,
            child: RepaintBoundary(
              key: repaintKey,
              child: Container(
                width: viewportWidth,
                height: pageHeight,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: showBorder
                      ? Border.all(color: const Color(0xFF8F8F8F), width: 1)
                      : null,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final element in page.elements)
                          if (element.type == 'image')
                            _ImageElementWidget(
                              element: element,
                              isSelected: selectedElementId == element.id,
                              canvasWidth: constraints.maxWidth,
                              canvasHeight: constraints.maxHeight,
                              onTap: () => onTapElement(element.id),
                              onMove: (x, y, persist) {
                                onMoveElement(element.id, x, y, persist);
                              },
                              onResize: (width, persist) {
                                onResizeElement(element.id, width, persist);
                              },
                              onDelete: () => onDeleteElement(element.id),
                            ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
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
    required this.onTapCanvas,
    required this.onTapElement,
    required this.onMoveElement,
    required this.onResizeElement,
    required this.onDeleteElement,
  });

  final List<ProjectPage> pages;
  final double viewportWidth;
  final double viewportHeight;
  final String exportPageId;
  final GlobalKey exportRepaintKey;
  final bool showBorder;
  final String? selectedElementId;
  final VoidCallback onTapCanvas;
  final ValueChanged<String> onTapElement;
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
                      color: Colors.white,
                      border: showBorder
                          ? Border.all(color: const Color(0xFF8F8F8F), width: 1)
                          : null,
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
                  onMove: (x, y, persist) {
                    onMoveElement(pages[i].id, element.id, x, y, persist);
                  },
                  onResize: (width, persist) {
                    onResizeElement(pages[i].id, element.id, width, persist);
                  },
                  onDelete: () => onDeleteElement(pages[i].id, element.id),
                ),
        ],
      ),
    );
  }
}

class _ImageElementWidget extends StatefulWidget {
  const _ImageElementWidget({
    required this.element,
    required this.isSelected,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.onTap,
    required this.onMove,
    required this.onResize,
    required this.onDelete,
  });

  final CanvasElement element;
  final bool isSelected;
  final double canvasWidth;
  final double canvasHeight;
  final VoidCallback onTap;
  final void Function(double x, double y, bool persist) onMove;
  final void Function(double width, bool persist) onResize;
  final VoidCallback onDelete;

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

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onPanStart: (_) {
          if (_isResizing) {
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
                border: widget.isSelected
                    ? Border.all(color: const Color(0xFF8F8F8F), width: 2)
                    : null,
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
                  : Image.file(File(src), fit: BoxFit.cover),
            ),
            if (widget.isSelected)
              Positioned(
                top: -10,
                right: -10,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDelete,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF8F8F8F)),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Color(0xFF8F8F8F),
                    ),
                  ),
                ),
              ),
            if (widget.isSelected)
              Positioned(
                right: -10,
                bottom: -10,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
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
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF8F8F8F)),
                    ),
                    child: const Icon(
                      Icons.open_in_full_rounded,
                      size: 12,
                      color: Color(0xFF8F8F8F),
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
    required this.pageWidth,
    required this.pageHeight,
    required this.pageOffsetX,
    required this.pageOffsetY,
    required this.onTap,
    required this.onMove,
    required this.onResize,
    required this.onDelete,
  });

  final CanvasElement element;
  final bool isSelected;
  final double pageWidth;
  final double pageHeight;
  final double pageOffsetX;
  final double pageOffsetY;
  final VoidCallback onTap;
  final void Function(double x, double y, bool persist) onMove;
  final void Function(double width, bool persist) onResize;
  final VoidCallback onDelete;

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

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onPanStart: (_) {
          if (_isResizing) {
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
                border: widget.isSelected
                    ? Border.all(color: const Color(0xFF8F8F8F), width: 2)
                    : null,
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
                  : Image.file(File(src), fit: BoxFit.cover),
            ),
            if (widget.isSelected)
              Positioned(
                top: -10,
                right: -10,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDelete,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF8F8F8F)),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Color(0xFF8F8F8F),
                    ),
                  ),
                ),
              ),
            if (widget.isSelected)
              Positioned(
                right: -10,
                bottom: -10,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
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
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF8F8F8F)),
                    ),
                    child: const Icon(
                      Icons.open_in_full_rounded,
                      size: 12,
                      color: Color(0xFF8F8F8F),
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
    return Container(
      width: 44,
      height: 32,
      decoration: BoxDecoration(
        color: enabled ? const Color(0xFFD8D8D8) : const Color(0xFFE2E2E2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: IconButton(
        onPressed: enabled ? onPressed : null,
        padding: EdgeInsets.zero,
        splashRadius: 18,
        icon: Icon(
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isPrimary ? const Color(0xFFD8D8D8) : Colors.white,
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

class _SlideSwitch extends StatelessWidget {
  const _SlideSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
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
              curve: Curves.easeOut,
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
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? const Color(0xFF1F1F1F) : const Color(0xFF7A7A7A),
        ),
      ),
    );
  }
}

class _PageTabPage extends StatelessWidget {
  const _PageTabPage({required this.page, required this.onAspectSelected});

  final ProjectPage page;
  final void Function(double aspectWidth, double aspectHeight) onAspectSelected;

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
    const double cardHeight = 72;

    return Padding(
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
    );
  }
}

class _TemplateTabPage extends StatelessWidget {
  const _TemplateTabPage({
    required this.page,
    required this.onApplyTemplate,
  });

  final ProjectPage page;
  final ValueChanged<_TemplateOption> onApplyTemplate;

  static final List<_TemplateOption> _allTemplates = <_TemplateOption>[
    _TemplateOption(
      id: 'page_fill',
      label: '填滿',
      buildElements: (pageId, page) {
        return <CanvasElement>[
          CanvasElement.image(pageId: pageId).copyWith(
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            allowCrossPage: false,
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
      label: '上下雙圖',
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
            allowCrossPage: false,
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

class _ElementTabPage extends StatelessWidget {
  const _ElementTabPage({required this.onAddImage});

  final VoidCallback onAddImage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: GestureDetector(
              onTap: onAddImage,
              child: const _ElementOptionCard(
                icon: Icons.image_outlined,
                label: '圖片',
              ),
            ),
          ),
          const SizedBox(width: 12),
          const SizedBox(
            width: 100,
            child: _ElementOptionCard(
              icon: Icons.text_fields_rounded,
              label: '文字',
            ),
          ),
        ],
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
            child: GestureDetector(
              onTap: onUploadImage,
              child: _ElementOptionCard(
                icon: Icons.upload_rounded,
                label: imagePath.isEmpty ? '上傳照片' : '更換圖片',
              ),
            ),
          ),
          if (imagePath.isNotEmpty) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: Container(
                height: 72,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            ),
          ],
        ],
      ),
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

  static const List<_ImageAspectOption> _options = <_ImageAspectOption>[
    _ImageAspectOption(key: 'original', label: '原始尺寸'),
    _ImageAspectOption(key: '1:1', label: '1:1', width: 1, height: 1),
    _ImageAspectOption(key: '5:4', label: '5:4', width: 5, height: 4),
    _ImageAspectOption(key: '4:5', label: '4:5', width: 4, height: 5),
    _ImageAspectOption(key: '4:3', label: '4:3', width: 4, height: 3),
    _ImageAspectOption(key: '3:4', label: '3:4', width: 3, height: 4),
    _ImageAspectOption(key: '3:2', label: '3:2', width: 3, height: 2),
    _ImageAspectOption(key: '16:9', label: '16:9', width: 16, height: 9),
  ];

  @override
  Widget build(BuildContext context) {
    final selectedKey =
        selectedElement.data['aspectPreset'] as String? ?? 'original';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _options.length; i++) ...[
              _ImageAspectCard(
                option: _options[i],
                height: 72,
                selected: selectedKey == _options[i].key,
                onTap: () => onAspectSelected(_options[i]),
              ),
              if (i != _options.length - 1) const SizedBox(width: 12),
            ],
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
  const _TemplateCard({required this.option, required this.onTap});

  final _TemplateOption option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        height: 96,
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
              child: Container(
                width: 42,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 4,
                  ),
                  child: Column(
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
                ),
              ),
            ),
            const Spacer(),
            Text(
              option.label,
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

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: cardWidth,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(color: const Color(0xFF8F8F8F), width: 2)
              : null,
        ),
        child: Text(
          option.label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: const Color(0xFF1F1F1F),
          ),
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
    final ratio = option.aspectRatio;
    final cardWidth = ratio == null
        ? 92.0
        : (height * ratio).clamp(42.0, 160.0).toDouble();
    final previewHeight = ratio == null ? 18.0 : 20.0;
    final previewWidth = ratio == null
        ? 20.0
        : (previewHeight * ratio).clamp(12.0, 42.0).toDouble();

    return GestureDetector(
      onTap: onTap,
      child: Container(
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
              child: Container(
                width: previewWidth,
                height: previewHeight,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: const Color(0xFFB8B8B8),
                    width: 2,
                  ),
                ),
              ),
            ),
            const Spacer(),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: const Color(0xFF1F1F1F),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ElementOptionCard extends StatelessWidget {
  const _ElementOptionCard({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
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
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1F1F1F),
            ),
          ),
        ],
      ),
    );
  }
}
