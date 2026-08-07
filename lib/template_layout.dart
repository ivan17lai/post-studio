import 'dart:math' as math;

import 'project_record.dart';

/// One cell of a template's grid, addressed by its top-left track and how many
/// tracks it spans.
class TemplateSlot {
  const TemplateSlot({
    required this.column,
    required this.row,
    this.columnSpan = 1,
    this.rowSpan = 1,
  });

  final int column;
  final int row;
  final int columnSpan;
  final int rowSpan;
}

/// A normalised rectangle on the page, plus the aspect ratio its frame ends up
/// with once the page's own aspect is taken into account.
class TemplateRect {
  const TemplateRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.aspectRatio,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final double aspectRatio;
}

/// A template is described declaratively as a weighted grid rather than as
/// hand-placed elements, so a single definition lays itself out correctly on
/// every page aspect.
class TemplateOption {
  const TemplateOption({
    required this.id,
    required this.label,
    this.pageAspects,
    this.columnWeights = const <double>[1],
    this.rowWeights = const <double>[1],
    this.slots = const <TemplateSlot>[TemplateSlot(column: 0, row: 0)],
    this.isContainFill = false,
  });

  final String id;
  final String label;

  /// Page aspects this template is offered for, as `w:h` keys. `null` means
  /// every aspect.
  final List<String>? pageAspects;

  final List<double> columnWeights;
  final List<double> rowWeights;
  final List<TemplateSlot> slots;

  /// The single-slot "fill" template fits the whole photo inside the frame
  /// (letterboxed) instead of cropping it to the slot.
  final bool isContainFill;

  bool matchesPage(ProjectPage page) {
    final aspects = pageAspects;
    return aspects == null ||
        aspects.contains(aspectKey(page.aspectWidth, page.aspectHeight));
  }

  /// Lays the grid out over the unit page.
  ///
  /// The margin is *not* applied by insetting each slot — that would stack two
  /// margins wherever slots meet, so a two-row layout would show a gap twice as
  /// thick in the middle as at the edges. Instead the margin is treated as a
  /// grid gutter: the outer edge and every seam between slots each get exactly
  /// one margin.
  ///
  /// The margin is also converted per axis. `x`/`width` are normalised against
  /// the page width and `y`/`height` against the page height, so the same
  /// number means different physical distances on a non-square page. Deriving
  /// both from one physical thickness keeps all four edges visually equal.
  List<TemplateRect> resolveRects(ProjectPage page, double marginRatio) {
    final pageWidth = page.aspectWidth;
    final pageHeight = page.aspectHeight;
    final thickness = marginRatio * math.min(pageWidth, pageHeight);
    final marginX = pageWidth <= 0 ? 0.0 : thickness / pageWidth;
    final marginY = pageHeight <= 0 ? 0.0 : thickness / pageHeight;

    final columns = _resolveTracks(columnWeights, marginX);
    final rows = _resolveTracks(rowWeights, marginY);

    return <TemplateRect>[
      for (final slot in slots)
        () {
          final startColumn = slot.column.clamp(0, columns.length - 1);
          final endColumn = (slot.column + slot.columnSpan - 1).clamp(
            startColumn,
            columns.length - 1,
          );
          final startRow = slot.row.clamp(0, rows.length - 1);
          final endRow = (slot.row + slot.rowSpan - 1).clamp(
            startRow,
            rows.length - 1,
          );

          final x = columns[startColumn].start;
          final y = rows[startRow].start;
          // A spanning slot swallows the gutters it crosses.
          final width = columns[endColumn].end - x;
          final height = rows[endRow].end - y;
          final frameWidth = width * pageWidth;
          final frameHeight = height * pageHeight;

          return TemplateRect(
            x: x,
            y: y,
            width: width,
            height: height,
            aspectRatio: frameHeight <= 0 ? 1.0 : frameWidth / frameHeight,
          );
        }(),
    ];
  }

  static List<({double start, double end})> _resolveTracks(
    List<double> weights,
    double margin,
  ) {
    final count = weights.length;
    final totalWeight = weights.fold<double>(0, (sum, w) => sum + w);
    // Outer margins on both edges, plus one gutter per seam.
    final available = 1 - margin * 2 - margin * (count - 1);
    final unit = totalWeight <= 0 ? 0.0 : available / totalWeight;

    final tracks = <({double start, double end})>[];
    var cursor = margin;
    for (var i = 0; i < count; i++) {
      final size = unit * weights[i];
      tracks.add((start: cursor, end: cursor + size));
      cursor += size + margin;
    }
    return tracks;
  }

  /// Whether [page] is currently laid out exactly as this template would lay
  /// it out.
  ///
  /// The template picker highlights the matching card, and derives that from
  /// the page instead of remembering which template was applied. Moving,
  /// resizing or deleting any slot stops the page from matching, so the
  /// highlight clears on its own — no bookkeeping to keep in step with every
  /// path that can edit an element, and undo, page changes and reopening a
  /// project all stay correct for free.
  bool matchesLayout(ProjectPage page, double marginRatio) {
    final images = page.elements
        .where((element) => element.type == 'image')
        .toList();

    if (isContainFill) {
      if (images.length != 1) {
        return false;
      }
      // "Fill" letterboxes the photo, so once one is in place the frame takes
      // the photo's own ratio rather than the slot's.
      final image = images.single;
      final source = (image.data['src'] as String?) ?? '';
      final expected = source.isEmpty
          ? resolveRects(page, marginRatio).single
          : containFillRect(
              page: page,
              imageAspectRatio:
                  (image.data['originalAspectRatio'] as num?)?.toDouble() ??
                  (image.data['aspectRatio'] as num?)?.toDouble() ??
                  1.0,
              marginRatio: marginRatio,
            );
      return _matches(image, expected);
    }

    final rects = resolveRects(page, marginRatio);
    if (images.length != rects.length) {
      return false;
    }

    // Matched without regard to order, so reordering layers does not read as a
    // change to the layout.
    final unmatched = List<CanvasElement>.from(images);
    for (final rect in rects) {
      final index = unmatched.indexWhere((image) => _matches(image, rect));
      if (index == -1) {
        return false;
      }
      unmatched.removeAt(index);
    }
    return true;
  }

  static bool _matches(CanvasElement element, TemplateRect rect) {
    // Rendered height follows from the frame ratio rather than from `height`,
    // so the ratio is what has to agree.
    final aspectRatio = (element.data['aspectRatio'] as num?)?.toDouble();
    return aspectRatio != null &&
        _closeEnough(element.x, rect.x) &&
        _closeEnough(element.y, rect.y) &&
        _closeEnough(element.width, rect.width) &&
        _closeEnough(aspectRatio, rect.aspectRatio);
  }

  /// Loose enough to absorb the rounding a save/load round trip through JSON
  /// can introduce, tight enough that a deliberate nudge never passes.
  static bool _closeEnough(double a, double b) => (a - b).abs() < 0.001;

  List<CanvasElement> buildElements(
    String pageId,
    ProjectPage page,
    double marginRatio,
  ) {
    final rects = resolveRects(page, marginRatio);
    return <CanvasElement>[
      for (var i = 0; i < rects.length; i++)
        CanvasElement.image(pageId: pageId).copyWith(
          x: rects[i].x,
          y: rects[i].y,
          width: rects[i].width,
          height: rects[i].height,
          allowCrossPage: true,
          data: <String, dynamic>{
            'src': '',
            'aspectRatio': rects[i].aspectRatio,
            'originalAspectRatio': rects[i].aspectRatio,
            if (!isContainFill)
              'aspectPreset': aspectPresetForRatio(rects[i].aspectRatio),
            'templateSlot': isContainFill ? 'fill' : 'slot$i',
            // Remembered so a photo dropped into a "fill" slot later can be
            // re-fitted inside the same margins.
            if (isContainFill) 'templateMarginRatio': marginRatio,
          },
        ),
    ];
  }
}

String aspectKey(double width, double height) {
  String format(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
  return '${format(width)}:${format(height)}';
}

/// Slots carry a free-form preset string purely so the editor knows the frame
/// is template-owned and must not be resized to the photo's own ratio.
String aspectPresetForRatio(double ratio) =>
    'template:${ratio.toStringAsFixed(4)}';

/// Centres a photo inside the page (or inside the box the template margin
/// leaves) without cropping it, letterboxing on whichever axis has slack.
///
/// The margin is converted per axis so the border reads as equally thick on
/// all four sides: `x`/`width` are page-width-normalised while `y`/`height`
/// are page-height-normalised.
TemplateRect containFillRect({
  required ProjectPage page,
  required double imageAspectRatio,
  required double marginRatio,
}) {
  final pageWidth = page.aspectWidth;
  final pageHeight = page.aspectHeight;
  final safeImageAspect = imageAspectRatio > 0 ? imageAspectRatio : 1.0;
  final thickness = marginRatio * math.min(pageWidth, pageHeight);
  final marginX = pageWidth <= 0 ? 0.0 : thickness / pageWidth;
  final marginY = pageHeight <= 0 ? 0.0 : thickness / pageHeight;

  final boxWidth = 1 - marginX * 2;
  final boxHeight = 1 - marginY * 2;
  // Aspect of the available box in real page units.
  final boxAspect = (boxWidth * pageWidth) / (boxHeight * pageHeight);

  double width;
  double height;
  if (safeImageAspect > boxAspect) {
    width = boxWidth;
    height = boxHeight * (boxAspect / safeImageAspect);
  } else {
    height = boxHeight;
    width = boxWidth * (safeImageAspect / boxAspect);
  }

  return TemplateRect(
    x: (1 - width) / 2,
    y: (1 - height) / 2,
    width: width,
    height: height,
    aspectRatio: safeImageAspect,
  );
}
