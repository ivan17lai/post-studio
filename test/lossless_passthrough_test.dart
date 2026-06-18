import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/hdr/lossless_passthrough.dart';
import 'package:igapp/project_record.dart';

CanvasElement _fullBleedImage({
  String pageId = 'p1',
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
}) {
  return CanvasElement(
    id: 'e1',
    type: 'image',
    pageId: pageId,
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
    },
  );
}

ProjectPage _page(String id, List<CanvasElement> elements) {
  // 4:5 page → page aspect 0.8, matching the default test element.
  return ProjectPage(
    id: id,
    title: id,
    type: 'page',
    aspectWidth: 4,
    aspectHeight: 5,
    elements: elements,
    extras: const <String, dynamic>{},
  );
}

ProjectRecord _project(List<ProjectPage> pages) {
  return ProjectRecord(
    id: 'test',
    name: 'test',
    createdAt: DateTime(2026, 1, 1),
    pageCount: pages.length,
    pages: pages,
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
        CanvasElement.text(pageId: 'p1'),
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
      pageId: 'p1',
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
      _page('p2', [_fullBleedImage(pageId: 'p2')]),
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
      pageId: 'p1',
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
      _page('p2', [_fullBleedImage(pageId: 'p2')]),
    ]);
    expect(
      evaluateLosslessExport(project: project, pageIndex: 1).eligible,
      isTrue,
    );
  });
}
