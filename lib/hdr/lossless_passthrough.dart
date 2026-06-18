import '../project_record.dart';

/// Outcome of checking whether a page can be exported as a byte-for-byte copy
/// of its source photo instead of being re-rendered.
class LosslessExportDecision {
  const LosslessExportDecision._({
    required this.eligible,
    this.originalPath,
    this.displayPath,
    this.reason,
  });

  const LosslessExportDecision.ineligible(String reason)
    : this._(eligible: false, reason: reason);

  const LosslessExportDecision.eligibleFor({
    required String originalPath,
    required String displayPath,
  }) : this._(
         eligible: true,
         originalPath: originalPath,
         displayPath: displayPath,
       );

  final bool eligible;

  /// Untouched source file to copy verbatim (gain map/EXIF/ICC preserved).
  final String? originalPath;

  /// Smaller preview variant of the same image, for cheap thumbnails.
  final String? displayPath;

  /// Why the page must be re-rendered instead (diagnostic only).
  final String? reason;
}

/// Decides whether the page at [pageIndex] qualifies for the lossless
/// passthrough export: exactly one image element that covers the whole page,
/// uncropped, unrounded, with no text and no content bleeding in from other
/// pages. Only then is "export = copy the original file" visually identical to
/// "export = re-render the page", so we can skip re-encoding entirely.
///
/// The check is intentionally conservative: any doubt falls back to the
/// regular high-quality render path.
LosslessExportDecision evaluateLosslessExport({
  required ProjectRecord project,
  required int pageIndex,
  double positionTolerance = 0.001,
  double aspectRelativeTolerance = 0.005,
}) {
  if (pageIndex < 0 || pageIndex >= project.pages.length) {
    return const LosslessExportDecision.ineligible('invalidPage');
  }
  final page = project.pages[pageIndex];

  if (page.elements.length != 1) {
    return const LosslessExportDecision.ineligible('notSingleElement');
  }
  final element = page.elements.single;
  if (element.type != 'image') {
    return const LosslessExportDecision.ineligible('notImage');
  }

  final data = element.data;
  final src = data['src'] as String? ?? '';
  final originalSrc = data['originalSrc'] as String? ?? src;
  if (originalSrc.isEmpty) {
    return const LosslessExportDecision.ineligible('missingSource');
  }

  // Full bleed: the frame must start at the page origin and span its width.
  if (element.x.abs() > positionTolerance ||
      element.y.abs() > positionTolerance ||
      (element.width - 1.0).abs() > positionTolerance) {
    return const LosslessExportDecision.ineligible('notFullBleed');
  }

  // The frame must also cover the page vertically. The renderer derives the
  // frame's pixel height as width / frameAspect, so coverage means the frame
  // aspect matches the page aspect.
  final frameAspect = (data['aspectRatio'] as num?)?.toDouble() ?? 0.0;
  if (frameAspect <= 0 || page.aspectHeight <= 0) {
    return const LosslessExportDecision.ineligible('invalidAspect');
  }
  final pageAspect = page.aspectWidth / page.aspectHeight;
  if ((frameAspect - pageAspect).abs() / pageAspect > aspectRelativeTolerance) {
    return const LosslessExportDecision.ineligible('frameNotPageSized');
  }

  // Uncropped: any zoom or pan means exported pixels differ from the source.
  final cropScale = (data['cropScale'] as num?)?.toDouble() ?? 1.0;
  final cropOffsetX = (data['cropOffsetX'] as num?)?.toDouble() ?? 0.0;
  final cropOffsetY = (data['cropOffsetY'] as num?)?.toDouble() ?? 0.0;
  if ((cropScale - 1.0).abs() > positionTolerance ||
      cropOffsetX.abs() > positionTolerance ||
      cropOffsetY.abs() > positionTolerance) {
    return const LosslessExportDecision.ineligible('cropped');
  }

  final borderRadiusRatio = (data['borderRadiusRatio'] as num?)?.toDouble() ?? 0.0;
  if (borderRadiusRatio > positionTolerance) {
    return const LosslessExportDecision.ineligible('rounded');
  }

  // The frame may not crop the source either: source aspect must match the
  // frame aspect. Without a recorded source aspect we cannot be sure.
  final originalAspect = (data['originalAspectRatio'] as num?)?.toDouble();
  if (originalAspect == null || originalAspect <= 0) {
    return const LosslessExportDecision.ineligible('unknownSourceAspect');
  }
  if ((originalAspect - frameAspect).abs() / frameAspect >
      aspectRelativeTolerance) {
    return const LosslessExportDecision.ineligible('sourceCropped');
  }

  // Nothing from other pages may bleed into this one.
  for (var otherIndex = 0; otherIndex < project.pages.length; otherIndex++) {
    if (otherIndex == pageIndex) {
      continue;
    }
    for (final other in project.pages[otherIndex].elements) {
      if (!other.allowCrossPage) {
        continue;
      }
      final left = (otherIndex - pageIndex) + other.x;
      final right = left + other.width;
      if (right > positionTolerance && left < 1.0 - positionTolerance) {
        return const LosslessExportDecision.ineligible('crossPageOverlap');
      }
    }
  }

  return LosslessExportDecision.eligibleFor(
    originalPath: originalSrc,
    displayPath: src.isEmpty ? originalSrc : src,
  );
}
