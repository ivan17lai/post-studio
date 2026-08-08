import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/hdr/lossless_passthrough.dart';
import 'package:igapp/project_record.dart';

CanvasElement _fullBleedImage({
  double x = 0,
  double y = 0,
  double width = 1,
  double aspectRatio = 0.8,
  double? originalAspectRatio = 0.8,
  double cropScale = 1,
  double cropOffsetX = 0,
  double cropOffsetY = 0,
  double borderRadiusRatio = 0,
  bool allowCrossPage = true,
  double hdrBrightness = 1.0,
  Map<String, dynamic>? adjustments,
}) {
  return CanvasElement(
    id: 'e1',
    type: 'image',
    x: x,
    y: y,
    width: width,
    height: 1,
    allowCrossPage: allowCrossPage,
    data: <String, dynamic>{
      'src': '/previews/photo.jpg',
      'originalSrc': '/originals/photo.jpg',
      'aspectRatio': aspectRatio,
      'originalAspectRatio': ?originalAspectRatio,
      'cropScale': cropScale,
      'cropOffsetX': cropOffsetX,
      'cropOffsetY': cropOffsetY,
      'borderRadiusRatio': borderRadiusRatio,
      'hdrBrightness': hdrBrightness,
      'adjustments': ?adjustments,
    },
  );
}

/// A page together with the elements filed under it. Cases read most naturally
/// that way, and [_project] flattens them into the single document-space list
/// the record actually stores, offsetting each page's x by its index.
typedef _PageSpec = ({ProjectPage page, List<CanvasElement> elements});

_PageSpec _page(String id, List<CanvasElement> elements) {
  // 4:5 page -> page aspect 0.8, matching the default test element.
  return (
    page: ProjectPage(
      id: id,
      title: id,
      type: 'page',
      aspectWidth: 4,
      aspectHeight: 5,
      extras: const <String, dynamic>{},
    ),
    elements: elements,
  );
}

ProjectRecord _project(List<_PageSpec> specs) {
  return ProjectRecord(
    id: 'test',
    name: 'test',
    createdAt: DateTime(2026, 1, 1),
    pageCount: specs.length,
    pages: <ProjectPage>[for (final spec in specs) spec.page],
    elements: <CanvasElement>[
      for (var index = 0; index < specs.length; index++)
        for (final element in specs[index].elements)
          element.copyWith(x: element.x + index),
    ],
    extras: const <String, dynamic>{},
  );
}

void main() {
  test('single full-bleed uncropped photo qualifies', () {
    final project = _project([
      _page('p1', [_fullBleedImage()]),
    ]);
    final decision = evaluateLosslessExport(project: project, pageIndex: 0);
    expect(decision.eligible, isTrue);
    expect(decision.originalPath, '/originals/photo.jpg');
    expect(decision.displayPath, '/previews/photo.jpg');
  });

  test('cropped photo does not qualify', () {
    final project = _project([
      _page('p1', [_fullBleedImage(cropScale: 1.4)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('panned photo does not qualify', () {
    final project = _project([
      _page('p1', [_fullBleedImage(cropOffsetX: 0.1)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('photo that does not cover the page does not qualify', () {
    final project = _project([
      _page('p1', [_fullBleedImage(width: 0.8, x: 0.1)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('frame aspect differing from page aspect does not qualify', () {
    final project = _project([
      _page('p1', [
        _fullBleedImage(aspectRatio: 1.0, originalAspectRatio: 1.0),
      ]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('source cropped by the frame (aspect mismatch) does not qualify', () {
    final project = _project([
      _page('p1', [_fullBleedImage(originalAspectRatio: 1.5)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('missing originalAspectRatio is conservatively rejected', () {
    final project = _project([
      _page('p1', [_fullBleedImage(originalAspectRatio: null)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('rounded corners do not qualify', () {
    final project = _project([
      _page('p1', [_fullBleedImage(borderRadiusRatio: 0.1)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('page with extra text element does not qualify', () {
    final project = _project([
      _page('p1', [
        _fullBleedImage(),
        CanvasElement.text(),
      ]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('element bleeding in from the previous page disqualifies', () {
    final crossPageElement = CanvasElement(
      id: 'bleed',
      type: 'image',
      // Starts on page 1 and extends well into page 2.
      x: 0.7,
      y: 0.2,
      width: 0.6,
      height: 0.4,
      allowCrossPage: true,
      data: const <String, dynamic>{
        'src': '/previews/other.jpg',
        'aspectRatio': 1.5,
      },
    );
    final project = _project([
      _page('p1', [crossPageElement]),
      _page('p2', [_fullBleedImage()]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 1).eligible,
      isFalse,
    );
  });

  test('neighbor element without cross-page does not disqualify', () {
    final localElement = CanvasElement(
      id: 'local',
      type: 'image',
      x: 0.7,
      y: 0.2,
      width: 0.6,
      height: 0.4,
      allowCrossPage: false,
      data: const <String, dynamic>{
        'src': '/previews/other.jpg',
        'aspectRatio': 1.5,
      },
    );
    final project = _project([
      _page('p1', [localElement]),
      _page('p2', [_fullBleedImage()]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 1).eligible,
      isTrue,
    );
  });

  test('adjusted HDR brightness disqualifies', () {
    final project = _project([
      _page('p1', [_fullBleedImage(hdrBrightness: 1.5)]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('non-neutral colour adjustments disqualify', () {
    final project = _project([
      _page('p1', [
        _fullBleedImage(adjustments: <String, dynamic>{'saturation': 0.4}),
      ]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isFalse,
    );
  });

  test('neutral adjustments and default brightness still qualify', () {
    final project = _project([
      _page('p1', [
        _fullBleedImage(
          hdrBrightness: 1.0,
          adjustments: <String, dynamic>{
            'brightness': 0.0,
            'saturation': 0.0,
          },
        ),
      ]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 0).eligible,
      isTrue,
    );
  });
}
