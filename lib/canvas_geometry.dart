/// Single source of truth for canvas and cross-page geometry.
///
/// Every consumer must go through this file: the on-screen single-page canvas,
/// the on-screen preview strip, the `ui.Canvas` exporter, the isolate JPG
/// exporter, the export payload builder and the lossless-passthrough check.
/// Each of those used to carry its own copy of the maths and they disagreed —
/// most visibly, the payload builder dropped a cross-page image the renderer
/// still tried to draw, so the image silently vanished from the export.
///
/// Two rules keep the copies from coming back:
///   * height is always derived here, never read back from a stored field;
///   * how far an element may travel depends on `allowCrossPage` alone, never
///     on which display mode the editor happens to be in.
library;

import 'dart:math' as math;

import 'project_record.dart';

/// Narrowest an element may get, as a fraction of its own page's width.
const double kMinElementWidth = 0.08;

/// Element box in the coordinate space of one target page, where `0` is that
/// page's left/top edge and `1` its right/bottom edge. Values outside `0..1`
/// mean the element spills onto a neighbouring page.
class CanvasRect {
  const CanvasRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// Whether any part of the box lands inside the target page.
  bool get overlapsPage => right > 0 && left < 1 && bottom > 0 && top < 1;

  @override
  String toString() =>
      'CanvasRect(left: $left, top: $top, width: $width, height: $height)';
}

/// Inclusive range an element's `x` may take, as a fraction of page width.
class CanvasXRange {
  const CanvasXRange(this.min, this.max);

  final double min;
  final double max;

  double clamp(double value) => value.clamp(min, max).toDouble();

  @override
  String toString() => 'CanvasXRange($min, $max)';
}

/// Height of an element as a fraction of page height.
///
/// [aspectRatio] is the element's own width/height ratio in pixels, so it has
/// to be converted through the page's own aspect before it means anything in
/// page-fraction space. Omitting that conversion is what made the old screen
/// and payload paths disagree with the exporters by 25% on a 4:5 page.
///
/// [fallbackHeight] is only consulted when no usable aspect ratio is recorded.
double imageHeightRatio({
  required double width,
  required double? aspectRatio,
  required double fallbackHeight,
  required double pageAspectWidth,
  required double pageAspectHeight,
}) {
  if (aspectRatio != null && aspectRatio > 0 && pageAspectHeight > 0) {
    return width * (pageAspectWidth / pageAspectHeight) / aspectRatio;
  }
  return fallbackHeight;
}

/// Inverse of [imageHeightRatio]: the width that yields a given height.
double imageWidthForHeightRatio({
  required double height,
  required double aspectRatio,
  required double pageAspectWidth,
  required double pageAspectHeight,
}) {
  if (aspectRatio <= 0 || pageAspectWidth <= 0) {
    return 0;
  }
  return height * aspectRatio * (pageAspectHeight / pageAspectWidth);
}

/// Height of a text element as a fraction of page height.
double textHeightRatio({
  required double fontSizeRatio,
  required int lineCount,
  required double pageAspectWidth,
  required double pageAspectHeight,
}) {
  if (pageAspectHeight <= 0) {
    return 0;
  }
  final height =
      fontSizeRatio * (pageAspectWidth / pageAspectHeight) * 1.24 * lineCount;
  return height.clamp(0.04, 0.9).toDouble();
}

/// Page [element] is filed under: the one its left edge starts on.
///
/// Derived, never stored. A stored owner went stale the moment the element was
/// dragged or the pages reordered, and forced an element spanning a seam to
/// pick one page to belong to.
int anchorPageIndex(CanvasElement element, int pageCount) {
  if (pageCount <= 0) {
    return 0;
  }
  return element.x.floor().clamp(0, pageCount - 1);
}

/// The page [element] should take its shape from.
///
/// Height is a fraction of page height, so it needs a page to be a fraction
/// *of*; the anchor page is that reference.
ProjectPage anchorPage(CanvasElement element, ProjectRecord project) {
  return project.pages[anchorPageIndex(element, project.pages.length)];
}

/// Where [element] lands when painted onto the page at [targetPageIndex].
CanvasRect elementRectOnPage({
  required CanvasElement element,
  required ProjectPage anchorPage,
  required int targetPageIndex,
  double? width,
}) {
  final resolvedWidth = width ?? element.width;
  return CanvasRect(
    left: element.x - targetPageIndex,
    top: element.y,
    width: resolvedWidth,
    height: elementHeightRatio(element, anchorPage, width: resolvedWidth),
  );
}

/// Whether [element] should be painted onto the page at [targetPageIndex].
///
/// An element always paints on the page it is anchored to, even when it
/// overflows: the overflow is the whole point of cross-page layout, and
/// clipping it here would make the screen disagree with the export.
bool isVisibleOnPage({
  required CanvasElement element,
  required ProjectPage anchorPage,
  required int anchorPageIndex,
  required int targetPageIndex,
}) {
  if (anchorPageIndex == targetPageIndex) {
    return true;
  }
  if (!element.allowCrossPage) {
    return false;
  }
  return elementRectOnPage(
    element: element,
    anchorPage: anchorPage,
    targetPageIndex: targetPageIndex,
  ).overlapsPage;
}

/// Every element that shows on the page at [pageIndex], back to front.
///
/// One flat pass in z-order. Each renderer used to walk pages then elements,
/// which fixed cross-page stacking at (page index, element index) and made a
/// photo from an earlier page permanently sit under the next page's content.
List<CanvasElement> elementsVisibleOnPage(
  ProjectRecord project,
  int pageIndex,
) => visibleElementsOnPage(
  pages: project.pages,
  elements: project.elements,
  pageIndex: pageIndex,
);

/// [elementsVisibleOnPage] for callers holding the two lists rather than a
/// whole [ProjectRecord] — the thumbnail widgets, which are handed a page and
/// its elements and never see the project.
List<CanvasElement> visibleElementsOnPage({
  required List<ProjectPage> pages,
  required List<CanvasElement> elements,
  required int pageIndex,
}) {
  final pageCount = pages.length;
  return <CanvasElement>[
    for (final element in elements)
      if (isVisibleOnPage(
        element: element,
        anchorPage: pages[anchorPageIndex(element, pageCount)],
        anchorPageIndex: anchorPageIndex(element, pageCount),
        targetPageIndex: pageIndex,
      ))
        element,
  ];
}

/// Elements filed under the page at [pageIndex], back to front.
List<CanvasElement> elementsAnchoredToPage(
  ProjectRecord project,
  int pageIndex,
) {
  final pageCount = project.pages.length;
  return <CanvasElement>[
    for (final element in project.elements)
      if (anchorPageIndex(element, pageCount) == pageIndex) element,
  ];
}

/// [isVisibleOnPage] for callers holding plain maps instead of model objects.
///
/// The isolate renderer is handed its payload as JSON-shaped maps, so it cannot
/// use the object form. Keeping the two in step matters: when the map-based
/// payload builder and the object-based renderer disagreed about which
/// elements were visible, images were filtered out of the payload and then
/// silently missing from the exported page.
bool isPayloadVisibleOnPage({
  required Map<String, dynamic> element,
  required double anchorAspectWidth,
  required double anchorAspectHeight,
  required int anchorPageIndex,
  required int targetPageIndex,
}) {
  if (anchorPageIndex == targetPageIndex) {
    return true;
  }
  if (!(element['allowCrossPage'] as bool? ??
      defaultAllowCrossPage(element['type'] as String? ?? 'image'))) {
    return false;
  }

  final width = (element['width'] as num?)?.toDouble() ?? 0;
  return CanvasRect(
    left: ((element['x'] as num?)?.toDouble() ?? 0) - targetPageIndex,
    top: (element['y'] as num?)?.toDouble() ?? 0,
    width: width,
    height: imageHeightRatio(
      width: width,
      aspectRatio: (element['aspectRatio'] as num?)?.toDouble(),
      fallbackHeight: (element['height'] as num?)?.toDouble() ?? 0,
      pageAspectWidth: anchorAspectWidth,
      pageAspectHeight: anchorAspectHeight,
    ),
  ).overlapsPage;
}

/// Range [element] may be dragged along x, in fractions of page width.
///
/// Deliberately independent of the editor's display mode. The old code clamped
/// to the page in single mode and to `-0.95..1.95` in preview mode, so a
/// cross-page layout built in preview was silently flattened the moment it was
/// touched in single mode.
///
/// A cross-page element may go anywhere in the document: `[0, pageCount]` is
/// the whole canvas, and its span must simply stay inside it. Past either end
/// there is no page to receive the overflow, so it renders nowhere and is
/// dropped from the export.
///
/// There is no longer a "must stay near the page that owns it" bound. Ownership
/// is derived from where the element starts, so it follows the element instead
/// of tethering it -- one of the things storing elements per page forced.
///
/// A page-bound element is confined to the page it is currently filed under.
CanvasXRange allowedXRange(
  CanvasElement element, {
  required int anchorPageIndex,
  required int pageCount,
  double? width,
}) {
  final resolvedWidth = width ?? element.width;

  if (!element.allowCrossPage) {
    final min = anchorPageIndex.toDouble();
    return CanvasXRange(min, math.max(min, min + 1 - resolvedWidth));
  }

  return CanvasXRange(0, math.max(0.0, pageCount - resolvedWidth));
}

/// Range [element] may be dragged along y, in fractions of page height.
///
/// Vertical spill has no neighbouring page to land on, so it stays clamped for
/// every element.
CanvasXRange allowedYRange(
  CanvasElement element,
  ProjectPage page, {
  double? width,
}) {
  final height = elementHeightRatio(element, page, width: width);
  return CanvasXRange(0, (1 - height).clamp(0.0, 1.0).toDouble());
}

/// Widest [element] may be resized to, in fractions of page width.
///
/// A cross-page element is free to grow past its page; a page-bound one stops
/// at whichever edge it would cross first.
double maxElementWidth({
  required CanvasElement element,
  required ProjectPage page,
  required double aspectRatio,
  required int anchorPageIndex,
  required int pageCount,
}) {
  if (element.allowCrossPage) {
    // A spread may cover the whole document but no more; allowedXRange then
    // pins where it has to start.
    return pageCount.toDouble();
  }

  final pageLocalX = element.x - anchorPageIndex;
  final maxWidthByRight = (1 - pageLocalX)
      .clamp(kMinElementWidth, 1.0)
      .toDouble();
  final maxHeightByBottom = (1 - element.y).clamp(0.0, 1.0).toDouble();
  final maxWidthByBottom =
      imageWidthForHeightRatio(
        height: maxHeightByBottom,
        aspectRatio: aspectRatio,
        pageAspectWidth: page.aspectWidth,
        pageAspectHeight: page.aspectHeight,
      ).clamp(kMinElementWidth, 1.0).toDouble();

  final maxWidth = maxWidthByRight < maxWidthByBottom
      ? maxWidthByRight
      : maxWidthByBottom;
  return maxWidth.clamp(kMinElementWidth, 1.0).toDouble();
}

/// Height of [element] on [page] as a fraction of page height.
///
/// Pass [width] to ask what the height *would* be at a different width, which
/// is what the resize path needs before it commits.
double elementHeightRatio(
  CanvasElement element,
  ProjectPage page, {
  double? width,
}) {
  if (element.type == 'text') {
    return textHeightRatio(
      fontSizeRatio: textFontSizeRatioFromData(element.data),
      lineCount: textLineCount(textContentFromData(element.data)),
      pageAspectWidth: page.aspectWidth,
      pageAspectHeight: page.aspectHeight,
    );
  }
  return imageHeightRatio(
    width: width ?? element.width,
    aspectRatio: (element.data['aspectRatio'] as num?)?.toDouble(),
    fallbackHeight: element.height,
    pageAspectWidth: page.aspectWidth,
    pageAspectHeight: page.aspectHeight,
  );
}

String textContentFromData(Map<String, dynamic> data) {
  final text = data['text'] as String?;
  if (text == null || text.trim().isEmpty) {
    return 'Text';
  }
  return text;
}

double textFontSizeRatioFromData(Map<String, dynamic> data) {
  final value = (data['fontSizeRatio'] as num?)?.toDouble() ?? 0.075;
  return value.clamp(0.025, 0.16).toDouble();
}

int textLineCount(String text) {
  return text.split('\n').length.clamp(1, 8);
}

/// The run of pages [element] currently overlaps, as document page indices.
///
/// Any overlap counts, however slight: an element covering its own page and
/// clipping 5% into the next touches both. That is what makes "drag it roughly
/// across the seam, then snap it flush" work.
({int first, int last}) touchedPageRange({
  required CanvasElement element,
  required int pageCount,
}) {
  // Nudge both edges inward so a span that lands exactly on a page boundary is
  // not counted as touching the page beyond it.
  const epsilon = 1e-9;
  final left = element.x;
  final right = left + element.width;

  final first = (left + epsilon).floor().clamp(0, pageCount - 1);
  final last = ((right - epsilon).ceil() - 1).clamp(first, pageCount - 1);
  return (first: first, last: last);
}

/// Frame aspect ratio that makes [element] exactly [spanWidth] pages wide and
/// one page tall on [page].
///
/// Solves [imageHeightRatio] for the aspect that yields a height of 1. The
/// photo inside is cropped to the frame rather than stretched, so its own
/// proportions survive.
double fullBleedFrameAspectRatio({
  required double spanWidth,
  required ProjectPage page,
}) {
  if (page.aspectHeight <= 0) {
    return spanWidth;
  }
  return spanWidth * (page.aspectWidth / page.aspectHeight);
}

/// The element list after the page at [removedPageIndex] is deleted.
///
/// Elements filed under that page go with it. Everything anchored after it
/// slides one page left, keeping its offset within its own page.
///
/// Both halves are needed because page membership is derived from `x` rather
/// than stored: without the shift, every element past the deletion would
/// silently re-anchor to whichever page moved into its slot.
List<CanvasElement> elementsAfterPageRemoved({
  required List<CanvasElement> elements,
  required int pageCount,
  required int removedPageIndex,
}) {
  return <CanvasElement>[
    for (final element in elements)
      if (anchorPageIndex(element, pageCount) != removedPageIndex)
        anchorPageIndex(element, pageCount) > removedPageIndex
            ? element.copyWith(x: element.x - 1)
            : element,
  ];
}

/// The element list after the pages are permuted by [order], where
/// `order[newIndex]` is the index that page had before.
///
/// Each element keeps its offset relative to the page it is anchored to, so it
/// travels with that page. Under per-page storage this was free — the element
/// was inside the page being moved. With one flat list it has to be done by
/// hand, and a page that lands first or last may leave a cross-page element
/// hanging off an edge with nothing behind it, so [normalizeProject] still has
/// the last word.
List<CanvasElement> elementsAfterPagesReordered({
  required List<CanvasElement> elements,
  required int pageCount,
  required List<int> order,
}) {
  final newIndexOfOld = List<int>.generate(pageCount, (i) => i);
  for (var newIndex = 0; newIndex < order.length; newIndex++) {
    final oldIndex = order[newIndex];
    if (oldIndex >= 0 && oldIndex < pageCount) {
      newIndexOfOld[oldIndex] = newIndex;
    }
  }

  return <CanvasElement>[
    for (final element in elements)
      () {
        final anchor = anchorPageIndex(element, pageCount);
        final shift = newIndexOfOld[anchor] - anchor;
        return shift == 0 ? element : element.copyWith(x: element.x + shift);
      }(),
  ];
}

/// [elementsAfterPagesReordered] for the common case of lifting one page out
/// and dropping it somewhere else.
List<CanvasElement> elementsAfterPageMoved({
  required List<CanvasElement> elements,
  required int pageCount,
  required int oldIndex,
  required int newIndex,
}) {
  final order = List<int>.generate(pageCount, (i) => i)..removeAt(oldIndex);
  order.insert(newIndex, oldIndex);
  return elementsAfterPagesReordered(
    elements: elements,
    pageCount: pageCount,
    order: order,
  );
}

/// Brings a freshly loaded project in line with the invariants above.
///
/// `height` is a derived value that was nonetheless stored, so it went stale
/// whenever the page aspect changed underneath it, and `x` could sit outside
/// the range its own `allowCrossPage` allows because the old editor picked that
/// range from the display mode. Both are repaired here, once, at load, so an
/// existing project heals itself instead of rendering differently in each of
/// the paths that read it.
///
/// Returns the same instance when nothing needed repair.
ProjectRecord normalizeProject(ProjectRecord project) {
  if (project.pages.isEmpty) {
    return project;
  }

  var changed = false;
  final pageCount = project.pages.length;

  final elements = project.elements.map((element) {
    final anchorIndex = anchorPageIndex(element, pageCount);
    final page = project.pages[anchorIndex];

    final height = elementHeightRatio(element, page);
    final x = allowedXRange(
      element,
      anchorPageIndex: anchorIndex,
      pageCount: pageCount,
    ).clamp(element.x);
    final y = allowedYRange(element, page).clamp(element.y);

    if ((height - element.height).abs() < 1e-9 &&
        x == element.x &&
        y == element.y) {
      return element;
    }

    changed = true;
    return element.copyWith(height: height, x: x, y: y);
  }).toList();

  return changed ? project.copyWith(elements: elements) : project;
}
