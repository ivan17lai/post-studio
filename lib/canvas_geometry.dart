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

import 'project_record.dart';

/// Widest an element may get, as a fraction of its own page's width.
const double kMaxCrossPageElementWidth = 2.2;

/// Narrowest an element may get, as a fraction of its own page's width.
const double kMinElementWidth = 0.08;

/// How far past its own page a cross-page element may be dragged, as a
/// fraction of page width. 0.95 keeps a sliver anchored on the owning page so
/// the element stays reachable after a page reorder.
const double kCrossPageOverhang = 0.95;

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

/// Where [element] lands when painted onto the page at [targetPageIndex].
///
/// Cross-page position is expressed relative to the owning page, so the page
/// index delta is what carries an element onto its neighbours.
CanvasRect elementRectOnPage({
  required CanvasElement element,
  required ProjectPage sourcePage,
  required int sourcePageIndex,
  required int targetPageIndex,
  double? width,
}) {
  final resolvedWidth = width ?? element.width;
  return CanvasRect(
    left: (sourcePageIndex - targetPageIndex) + element.x,
    top: element.y,
    width: resolvedWidth,
    height: elementHeightRatio(element, sourcePage, width: resolvedWidth),
  );
}

/// Whether [element] should be painted onto the page at [targetPageIndex].
///
/// An element always paints on its own page, even when it overflows: the
/// overflow is the whole point of cross-page layout, and clipping it here
/// would make the screen disagree with the export.
bool isVisibleOnPage({
  required CanvasElement element,
  required ProjectPage sourcePage,
  required int sourcePageIndex,
  required int targetPageIndex,
}) {
  if (sourcePageIndex == targetPageIndex) {
    return true;
  }
  if (!element.allowCrossPage) {
    return false;
  }
  return elementRectOnPage(
    element: element,
    sourcePage: sourcePage,
    sourcePageIndex: sourcePageIndex,
    targetPageIndex: targetPageIndex,
  ).overlapsPage;
}

/// Range [element] may be dragged along x, in fractions of page width.
///
/// Deliberately independent of the editor's display mode. The old code clamped
/// to the page in single mode and to `-0.95..1.95` in preview mode, so a
/// cross-page layout built in preview was silently flattened the moment it was
/// touched in single mode.
///
/// [pageIndex] and [pageCount] locate the owning page in the document. An
/// element may only spill onto a page that exists: past the first or last page
/// there is nothing to receive it, so the overflow would render nowhere and be
/// dropped from the export.
CanvasXRange allowedXRange(
  CanvasElement element, {
  required int pageIndex,
  required int pageCount,
  double? width,
}) {
  final resolvedWidth = width ?? element.width;
  final pageBoundMax = (1 - resolvedWidth).clamp(0.0, 1.0).toDouble();
  if (!element.allowCrossPage) {
    return CanvasXRange(0, pageBoundMax);
  }

  final hasPageBefore = pageIndex > 0;
  final hasPageAfter = pageIndex < pageCount - 1;
  return CanvasXRange(
    hasPageBefore ? -kCrossPageOverhang : 0,
    hasPageAfter ? 1 + kCrossPageOverhang : pageBoundMax,
  );
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
}) {
  if (element.allowCrossPage) {
    return kMaxCrossPageElementWidth;
  }

  final maxWidthByRight = (1 - element.x)
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
  var projectChanged = false;

  final pageCount = project.pages.length;

  final pages = project.pages.indexed.map((entry) {
    final (pageIndex, page) = entry;
    var pageChanged = false;

    final elements = page.elements.map((element) {
      final height = elementHeightRatio(element, page);
      final x = allowedXRange(
        element,
        pageIndex: pageIndex,
        pageCount: pageCount,
      ).clamp(element.x);
      final y = allowedYRange(element, page).clamp(element.y);

      if ((height - element.height).abs() < 1e-9 &&
          x == element.x &&
          y == element.y) {
        return element;
      }

      pageChanged = true;
      return element.copyWith(height: height, x: x, y: y);
    }).toList();

    if (!pageChanged) {
      return page;
    }
    projectChanged = true;
    return page.copyWith(elements: elements);
  }).toList();

  return projectChanged ? project.copyWith(pages: pages) : project;
}
