import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/canvas_geometry.dart';
import 'package:igapp/project_record.dart';

CanvasElement _image({
  double x = 0,
  double y = 0,
  double width = 0.5,
  double height = 0.5,
  double? aspectRatio = 1.0,
  bool allowCrossPage = true,
}) {
  return CanvasElement(
    id: 'e1',
    type: 'image',
    pageId: 'p1',
    x: x,
    y: y,
    width: width,
    height: height,
    allowCrossPage: allowCrossPage,
    data: <String, dynamic>{'src': '/photo.jpg', 'aspectRatio': ?aspectRatio},
  );
}

CanvasElement _text({
  double x = 0,
  double y = 0,
  String text = 'Hello',
  double fontSizeRatio = 0.075,
  bool allowCrossPage = false,
}) {
  return CanvasElement(
    id: 't1',
    type: 'text',
    pageId: 'p1',
    x: x,
    y: y,
    width: 0.6,
    height: 0.08,
    allowCrossPage: allowCrossPage,
    data: <String, dynamic>{'text': text, 'fontSizeRatio': fontSizeRatio},
  );
}

/// 4:5 portrait, the app's default. Page aspect = 0.8, which is exactly the
/// factor the old screen-side and payload-side height formulas dropped.
ProjectPage _page({double aspectWidth = 4, double aspectHeight = 5}) {
  return ProjectPage(
    id: 'p1',
    title: 'p1',
    type: 'page',
    aspectWidth: aspectWidth,
    aspectHeight: aspectHeight,
    elements: const <CanvasElement>[],
    extras: const <String, dynamic>{},
  );
}

void main() {
  group('imageHeightRatio', () {
    test('converts through page aspect, not just the element aspect', () {
      // A square image half the page wide, on a 4:5 page, is 0.4 of the page
      // tall — not 0.5. Dropping the 0.8 factor overstated height by 25% and
      // was the root of the screen/export disagreement.
      expect(
        imageHeightRatio(
          width: 0.5,
          aspectRatio: 1.0,
          fallbackHeight: 999,
          pageAspectWidth: 4,
          pageAspectHeight: 5,
        ),
        closeTo(0.4, 1e-9),
      );
    });

    test('a square element on a square page is as tall as it is wide', () {
      expect(
        imageHeightRatio(
          width: 0.5,
          aspectRatio: 1.0,
          fallbackHeight: 999,
          pageAspectWidth: 1,
          pageAspectHeight: 1,
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('falls back to the stored height when no aspect is recorded', () {
      expect(
        imageHeightRatio(
          width: 0.5,
          aspectRatio: null,
          fallbackHeight: 0.33,
          pageAspectWidth: 4,
          pageAspectHeight: 5,
        ),
        0.33,
      );
      expect(
        imageHeightRatio(
          width: 0.5,
          aspectRatio: 0,
          fallbackHeight: 0.33,
          pageAspectWidth: 4,
          pageAspectHeight: 5,
        ),
        0.33,
      );
    });

    test('imageWidthForHeightRatio round-trips', () {
      const width = 0.42;
      final height = imageHeightRatio(
        width: width,
        aspectRatio: 1.5,
        fallbackHeight: 0,
        pageAspectWidth: 4,
        pageAspectHeight: 5,
      );
      expect(
        imageWidthForHeightRatio(
          height: height,
          aspectRatio: 1.5,
          pageAspectWidth: 4,
          pageAspectHeight: 5,
        ),
        closeTo(width, 1e-9),
      );
    });
  });

  group('elementHeightRatio', () {
    test('routes images through the page-aspect conversion', () {
      expect(
        elementHeightRatio(_image(width: 0.5, aspectRatio: 1.0), _page()),
        closeTo(0.4, 1e-9),
      );
    });

    test('answers what the height would be at a different width', () {
      expect(
        elementHeightRatio(
          _image(width: 0.5, aspectRatio: 1.0),
          _page(),
          width: 1.0,
        ),
        closeTo(0.8, 1e-9),
      );
    });

    test('routes text through the line-count formula', () {
      final single = elementHeightRatio(_text(text: 'one'), _page());
      final triple = elementHeightRatio(_text(text: 'a\nb\nc'), _page());
      expect(triple, closeTo(single * 3, 1e-9));
    });
  });

  group('textHeightRatio', () {
    test('scales with line count and page aspect', () {
      expect(
        textHeightRatio(
          fontSizeRatio: 0.1,
          lineCount: 2,
          pageAspectWidth: 4,
          pageAspectHeight: 5,
        ),
        closeTo(0.1 * 0.8 * 1.24 * 2, 1e-9),
      );
    });

    test('stays within the 0.04..0.9 band', () {
      expect(
        textHeightRatio(
          fontSizeRatio: 0.16,
          lineCount: 8,
          pageAspectWidth: 1,
          pageAspectHeight: 1,
        ),
        0.9,
      );
      expect(
        textHeightRatio(
          fontSizeRatio: 0.001,
          lineCount: 1,
          pageAspectWidth: 4,
          pageAspectHeight: 5,
        ),
        0.04,
      );
    });
  });

  group('isVisibleOnPage', () {
    test('an element always paints on its own page, overflow included', () {
      final overflowing = _image(x: -0.5, width: 2.0);
      expect(
        isVisibleOnPage(
          element: overflowing,
          sourcePage: _page(),
          sourcePageIndex: 3,
          targetPageIndex: 3,
        ),
        isTrue,
      );
    });

    test('a page-bound element never reaches a neighbour', () {
      final bound = _image(x: 0.9, width: 0.8, allowCrossPage: false);
      expect(
        isVisibleOnPage(
          element: bound,
          sourcePage: _page(),
          sourcePageIndex: 0,
          targetPageIndex: 1,
        ),
        isFalse,
      );
    });

    test('a cross-page element reaches the neighbour it spills onto', () {
      final spilling = _image(x: 0.6, width: 0.8);
      expect(
        isVisibleOnPage(
          element: spilling,
          sourcePage: _page(),
          sourcePageIndex: 0,
          targetPageIndex: 1,
        ),
        isTrue,
      );
      expect(
        isVisibleOnPage(
          element: spilling,
          sourcePage: _page(),
          sourcePageIndex: 0,
          targetPageIndex: 2,
        ),
        isFalse,
      );
    });

    test('touching an edge exactly does not count as overlap', () {
      // Right edge lands exactly on the next page's left edge.
      final abutting = _image(x: 0.5, width: 0.5);
      expect(
        isVisibleOnPage(
          element: abutting,
          sourcePage: _page(),
          sourcePageIndex: 0,
          targetPageIndex: 1,
        ),
        isFalse,
      );
    });

    test('page aspect decides vertical overlap near the bottom edge', () {
      // width 1.0, square image: 1.0 tall by the old formula (would spill past
      // the bottom), 0.8 tall by the correct one.
      final element = _image(x: 0.5, y: 0.5, width: 1.0, aspectRatio: 1.0);
      final rect = elementRectOnPage(
        element: element,
        sourcePage: _page(),
        sourcePageIndex: 0,
        targetPageIndex: 1,
      );
      expect(rect.height, closeTo(0.8, 1e-9));
      expect(rect.bottom, closeTo(1.3, 1e-9));
      expect(rect.left, closeTo(-0.5, 1e-9));
    });
  });

  group('screen and export paths agree', () {
    /// The payload shape the export builder ships to the isolate renderer.
    Map<String, dynamic> payloadOf(CanvasElement element) {
      return <String, dynamic>{
        'type': element.type,
        'x': element.x,
        'y': element.y,
        'width': element.width,
        'height': element.height,
        'allowCrossPage': element.allowCrossPage,
        'aspectRatio': (element.data['aspectRatio'] as num?)?.toDouble(),
      };
    }

    test('the object and map forms return the same visibility', () {
      // The two forms feed different halves of the export: the map form picks
      // which image bytes to ship, the object form decides what to draw. When
      // they disagreed, cross-page images vanished from the exported page.
      final page = _page();
      final cases = <CanvasElement>[
        for (final x in <double>[-0.95, -0.5, -0.01, 0, 0.5, 0.99, 1.0, 1.5])
          for (final width in <double>[0.2, 0.5, 1.0, 1.8])
            for (final aspectRatio in <double?>[null, 0.5, 1.0, 1.78])
              for (final allowCrossPage in <bool>[true, false])
                _image(
                  x: x,
                  y: 0.1,
                  width: width,
                  aspectRatio: aspectRatio,
                  allowCrossPage: allowCrossPage,
                ),
      ];

      for (final element in cases) {
        for (var sourceIndex = 0; sourceIndex < 3; sourceIndex++) {
          for (var targetIndex = 0; targetIndex < 3; targetIndex++) {
            expect(
              isPayloadVisibleOnPage(
                element: payloadOf(element),
                sourceAspectWidth: page.aspectWidth,
                sourceAspectHeight: page.aspectHeight,
                sourcePageIndex: sourceIndex,
                targetPageIndex: targetIndex,
              ),
              isVisibleOnPage(
                element: element,
                sourcePage: page,
                sourcePageIndex: sourceIndex,
                targetPageIndex: targetIndex,
              ),
              reason:
                  'x=${element.x} w=${element.width} '
                  'ar=${element.data['aspectRatio']} '
                  'cross=${element.allowCrossPage} '
                  '$sourceIndex->$targetIndex',
            );
          }
        }
      }
    });

    test('ratio-space height matches the pixel maths the widgets use', () {
      // The element widgets size themselves in pixels as widthPx / aspectRatio.
      // elementHeightRatio works in fractions of page height. Both have to
      // describe the same box or the on-screen hit box drifts from the
      // visibility test that decides whether to draw it at all.
      const pageWidthPx = 320.0;
      final page = _page();
      final pageHeightPx =
          pageWidthPx * (page.aspectHeight / page.aspectWidth);

      for (final aspectRatio in <double>[0.5, 0.8, 1.0, 1.78]) {
        for (final width in <double>[0.25, 0.5, 1.0]) {
          final element = _image(width: width, aspectRatio: aspectRatio);
          final widthPx = width * pageWidthPx;
          expect(
            elementHeightRatio(element, page) * pageHeightPx,
            closeTo(widthPx / aspectRatio, 1e-9),
            reason: 'ar=$aspectRatio w=$width',
          );
        }
      }
    });
  });

  group('allowedXRange', () {
    test('a cross-page element in the middle may hang off either side', () {
      final range = allowedXRange(
        _image(width: 0.5),
        pageIndex: 1,
        pageCount: 3,
      );
      // Left: far enough to sit flush on the previous page without leaving it.
      // Right: flush on the next page, and page 2 ends the document at x = 1.5.
      expect(range.min, closeTo(-0.5, 1e-9));
      expect(range.max, closeTo(1.0, 1e-9));
    });

    test('a page-bound element is held inside its own page', () {
      final range = allowedXRange(
        _image(width: 0.3, allowCrossPage: false),
        pageIndex: 1,
        pageCount: 3,
      );
      expect(range.min, 0);
      expect(range.max, closeTo(0.7, 1e-9));
      expect(range.clamp(-0.4), 0);
      expect(range.clamp(0.9), closeTo(0.7, 1e-9));
    });

    test('an oversized page-bound element collapses to x = 0', () {
      final range = allowedXRange(
        _image(width: 1.8, allowCrossPage: false),
        pageIndex: 1,
        pageCount: 3,
      );
      expect(range.min, 0);
      expect(range.max, 0);
    });

    test('the range depends on the element, not the display mode', () {
      // Regression guard: the old code picked the range from the editor's
      // display mode, so a cross-page layout built in preview was flattened
      // the moment it was touched in single mode.
      final crossPage = _image(x: -0.4, width: 1.5);
      expect(
        allowedXRange(crossPage, pageIndex: 1, pageCount: 3).clamp(crossPage.x),
        -0.4,
      );
    });

    test('the first page has nothing to spill onto to its left', () {
      final range = allowedXRange(
        _image(width: 0.5),
        pageIndex: 0,
        pageCount: 3,
      );
      expect(range.min, 0);
      expect(range.max, closeTo(1.0, 1e-9));
    });

    test('the last page has nothing to spill onto to its right', () {
      final range = allowedXRange(
        _image(width: 0.5),
        pageIndex: 2,
        pageCount: 3,
      );
      expect(range.min, closeTo(-0.5, 1e-9));
      expect(range.max, closeTo(0.5, 1e-9));
    });

    test('the span may not run off the end of the document', () {
      // Regression guard for the fixed-overhang model this replaced: it let an
      // element on page 0 of a two-page project reach x = 1.95, putting its
      // right edge at 2.45 -- half a page past the end, rendering nowhere.
      // At width 1.8 the document bound is the one that binds.
      const width = 1.8;
      final range = allowedXRange(
        _image(width: width),
        pageIndex: 0,
        pageCount: 2,
      );
      expect(range.max, closeTo(0.2, 1e-9));
      expect(range.max + width, closeTo(2.0, 1e-9));
    });

    test('a full-document spread is pinned to the only place it fits', () {
      // Two pages wide, filed under page 1: it has to start at page 0.
      final range = allowedXRange(
        _image(width: 2.0),
        pageIndex: 1,
        pageCount: 2,
      );
      expect(range.min, closeTo(-1.0, 1e-9));
      expect(range.max, closeTo(-1.0, 1e-9));
    });

    test('an element may not be stranded off its own page', () {
      final range = allowedXRange(
        _image(width: 0.4),
        pageIndex: 3,
        pageCount: 9,
      );
      // Bounded by its own page, not by how much document lies either side.
      expect(range.min, closeTo(-0.4, 1e-9));
      expect(range.max, closeTo(1.0, 1e-9));
    });

    test('a lone page confines even a cross-page element', () {
      final range = allowedXRange(
        _image(width: 0.5),
        pageIndex: 0,
        pageCount: 1,
      );
      expect(range.min, 0);
      expect(range.max, closeTo(0.5, 1e-9));
    });
  });

  group('allowedYRange', () {
    test('holds every element inside the page vertically', () {
      final range = allowedYRange(_image(width: 0.5, aspectRatio: 1.0), _page());
      expect(range.min, 0);
      expect(range.max, closeTo(0.6, 1e-9));
    });
  });

  group('maxElementWidth', () {
    test('a cross-page element may grow to cover the whole document', () {
      expect(
        maxElementWidth(
          element: _image(x: 0.2, y: 0.2),
          page: _page(),
          aspectRatio: 1.0,
          pageCount: 3,
        ),
        3.0,
      );
    });

    test('a page-bound element stops at the right edge', () {
      expect(
        maxElementWidth(
          element: _image(x: 0.3, y: 0, allowCrossPage: false),
          page: _page(),
          aspectRatio: 1.0,
          pageCount: 3,
        ),
        closeTo(0.7, 1e-9),
      );
    });

    test('a page-bound element stops at the bottom edge when that binds', () {
      // y = 0.6 leaves 0.4 of page height; a square image on a 4:5 page needs
      // width = 0.4 * 1.0 * (5/4) = 0.5 to be that tall.
      expect(
        maxElementWidth(
          element: _image(x: 0, y: 0.6, allowCrossPage: false),
          page: _page(),
          aspectRatio: 1.0,
          pageCount: 3,
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('never returns less than the minimum width', () {
      expect(
        maxElementWidth(
          element: _image(x: 0.99, y: 0.99, allowCrossPage: false),
          page: _page(),
          aspectRatio: 1.0,
          pageCount: 3,
        ),
        kMinElementWidth,
      );
    });
  });

  group('touchedPageRange', () {
    ({int first, int last}) rangeOf(
      CanvasElement element, {
      int pageIndex = 0,
      int pageCount = 3,
    }) {
      return touchedPageRange(
        element: element,
        pageIndex: pageIndex,
        pageCount: pageCount,
      );
    }

    test('an element inside its page touches only that page', () {
      final range = rangeOf(_image(x: 0.1, width: 0.5), pageIndex: 1);
      expect(range.first, 1);
      expect(range.last, 1);
    });

    test('the slightest overlap counts as touching', () {
      // Covers page 1 and clips 5% into page 2.
      final range = rangeOf(_image(x: 0.05, width: 1.0), pageIndex: 1);
      expect(range.first, 1);
      expect(range.last, 2);
    });

    test('a span landing exactly on a boundary does not touch beyond it', () {
      final range = rangeOf(_image(x: 0, width: 1.0), pageIndex: 1);
      expect(range.first, 1);
      expect(range.last, 1);
    });

    test('a spread reaching backwards starts at the earlier page', () {
      final range = rangeOf(_image(x: -0.6, width: 1.2), pageIndex: 2);
      expect(range.first, 1);
      expect(range.last, 2);
    });

    test('three pages wide touches three pages', () {
      final range = rangeOf(_image(x: 0, width: 3.0), pageIndex: 0);
      expect(range.first, 0);
      expect(range.last, 2);
    });

    test('never reports a page outside the document', () {
      final range = rangeOf(_image(x: -5, width: 20), pageIndex: 1);
      expect(range.first, 0);
      expect(range.last, 2);
    });
  });

  group('fullBleedFrameAspectRatio', () {
    test('yields a frame exactly one page tall', () {
      final page = _page();
      for (final spanWidth in <double>[1, 2, 3]) {
        final aspectRatio = fullBleedFrameAspectRatio(
          spanWidth: spanWidth,
          page: page,
        );
        // The whole point: at this aspect, that width is exactly 1.0 tall.
        expect(
          imageHeightRatio(
            width: spanWidth,
            aspectRatio: aspectRatio,
            fallbackHeight: 0,
            pageAspectWidth: page.aspectWidth,
            pageAspectHeight: page.aspectHeight,
          ),
          closeTo(1.0, 1e-9),
          reason: 'span=$spanWidth',
        );
      }
    });

    test('a two-page spread on a 4:5 page is 1.6:1', () {
      expect(
        fullBleedFrameAspectRatio(spanWidth: 2, page: _page()),
        closeTo(1.6, 1e-9),
      );
    });

    test('the resulting spread is a position allowedXRange permits', () {
      // The snap sets x so the span starts on the leftmost touched page; that
      // has to be inside the range, or the next edit would yank it back.
      final spread = _image(x: -1, width: 2.0);
      final range = allowedXRange(spread, pageIndex: 1, pageCount: 2);
      expect(range.clamp(spread.x), closeTo(-1.0, 1e-9));
    });
  });

  group('defaultAllowCrossPage', () {
    test('agrees with the CanvasElement factories', () {
      expect(
        defaultAllowCrossPage('image'),
        CanvasElement.image(pageId: 'p1').allowCrossPage,
      );
      expect(
        defaultAllowCrossPage('text'),
        CanvasElement.text(pageId: 'p1').allowCrossPage,
      );
    });

    test('a legacy element with no stored flag takes the type default', () {
      final legacyText = CanvasElement.fromJson(<String, dynamic>{
        'id': 't1',
        'type': 'text',
        'pageId': 'p1',
      });
      expect(legacyText.allowCrossPage, isFalse);

      final legacyImage = CanvasElement.fromJson(<String, dynamic>{
        'id': 'e1',
        'type': 'image',
        'pageId': 'p1',
      });
      expect(legacyImage.allowCrossPage, isTrue);
    });

    test('an explicitly stored flag is respected either way', () {
      final crossPageText = CanvasElement.fromJson(<String, dynamic>{
        'id': 't1',
        'type': 'text',
        'pageId': 'p1',
        'allowCrossPage': true,
      });
      expect(crossPageText.allowCrossPage, isTrue);
    });
  });

  group('normalizeProject', () {
    ProjectRecord projectOf(List<CanvasElement> elements, {ProjectPage? page}) {
      final basePage = page ?? _page();
      return ProjectRecord(
        id: 'proj',
        name: 'proj',
        createdAt: DateTime(2026),
        pageCount: 1,
        pages: <ProjectPage>[basePage.copyWith(elements: elements)],
        extras: const <String, dynamic>{},
      );
    }

    /// [elementsPerPage] spread over that many pages, sharing one page shape.
    ProjectRecord multiPageProject(List<List<CanvasElement>> elementsPerPage) {
      return ProjectRecord(
        id: 'proj',
        name: 'proj',
        createdAt: DateTime(2026),
        pageCount: elementsPerPage.length,
        pages: elementsPerPage.indexed
            .map(
              (entry) => _page().copyWith(
                id: 'p${entry.$1}',
                elements: entry.$2,
              ),
            )
            .toList(),
        extras: const <String, dynamic>{},
      );
    }

    test('keeps a spill that still has a page to land on', () {
      final spilling = _image(x: 0.6, width: 0.8, aspectRatio: 1.0);
      final normalized = multiPageProject(<List<CanvasElement>>[
        <CanvasElement>[spilling],
        const <CanvasElement>[],
      ]);
      expect(
        normalizeProject(normalized).pages.first.elements.single.x,
        closeTo(0.6, 1e-9),
      );
    });

    test('reclaims a spill off the end of the document', () {
      // Same element, but now its page is the last one: the overflow has no
      // page behind it, so it would render nowhere and be lost on export.
      final spilling = _image(x: 0.6, width: 0.8, aspectRatio: 1.0);
      final normalized = multiPageProject(<List<CanvasElement>>[
        const <CanvasElement>[],
        <CanvasElement>[spilling],
      ]);
      expect(
        normalizeProject(normalized).pages.last.elements.single.x,
        closeTo(0.2, 1e-9),
      );
    });

    test('reclaims a spill off the front of the document', () {
      final spilling = _image(x: -0.3, width: 0.8, aspectRatio: 1.0);
      final normalized = multiPageProject(<List<CanvasElement>>[
        <CanvasElement>[spilling],
        const <CanvasElement>[],
      ]);
      expect(normalizeProject(normalized).pages.first.elements.single.x, 0);
    });

    test('recomputes a height left stale by a page aspect change', () {
      // Stored height of 0.5 was correct on a square page; on 4:5 it is 0.4.
      final stale = _image(width: 0.5, height: 0.5, aspectRatio: 1.0);
      final normalized = normalizeProject(projectOf(<CanvasElement>[stale]));
      expect(normalized.pages.single.elements.single.height, closeTo(0.4, 1e-9));
    });

    test('pulls a page-bound element back inside its page', () {
      final escaped = _image(x: -0.4, width: 0.5, allowCrossPage: false);
      final normalized = normalizeProject(projectOf(<CanvasElement>[escaped]));
      expect(normalized.pages.single.elements.single.x, 0);
    });

    test('leaves a cross-page element with neighbours on both sides', () {
      final spilling = _image(x: -0.4, width: 1.5, aspectRatio: 1.0);
      final normalized = normalizeProject(
        multiPageProject(<List<CanvasElement>>[
          const <CanvasElement>[],
          <CanvasElement>[spilling],
          const <CanvasElement>[],
        ]),
      );
      expect(normalized.pages[1].elements.single.x, -0.4);
    });

    test('clamps y when the recomputed height no longer fits', () {
      final tooLow = _image(y: 0.9, width: 1.0, height: 0.1, aspectRatio: 1.0);
      final normalized = normalizeProject(projectOf(<CanvasElement>[tooLow]));
      final element = normalized.pages.single.elements.single;
      expect(element.height, closeTo(0.8, 1e-9));
      expect(element.y, closeTo(0.2, 1e-9));
    });

    test('returns the same instance when nothing needs repair', () {
      final clean = _image(x: 0.1, y: 0.1, width: 0.5, aspectRatio: 1.0)
          .copyWith(height: 0.4);
      final project = projectOf(<CanvasElement>[clean]);
      expect(identical(normalizeProject(project), project), isTrue);
    });
  });
}
