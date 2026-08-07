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

  group('anchorPageIndex', () {
    test('follows position, so it cannot go stale', () {
      // The whole point of document-space x: which page an element belongs to
      // is read off where it starts, never stored alongside it.
      expect(anchorPageIndex(_image(x: 0.0), 3), 0);
      expect(anchorPageIndex(_image(x: 0.99), 3), 0);
      expect(anchorPageIndex(_image(x: 1.0), 3), 1);
      expect(anchorPageIndex(_image(x: 2.5), 3), 2);
    });

    test('clamps to the pages that exist', () {
      // Deleting the last page must not leave an element pointing past the end.
      expect(anchorPageIndex(_image(x: 7.5), 3), 2);
      expect(anchorPageIndex(_image(x: -0.5), 3), 0);
    });
  });

  group('isVisibleOnPage', () {
    test('an element always paints on the page it is anchored to', () {
      // Twice a page wide, starting halfway across page 3: it is filed under
      // page 3 and draws there whatever hangs off the sides.
      final overflowing = _image(x: 3.5, width: 2.0);
      expect(
        isVisibleOnPage(
          element: overflowing,
          anchorPage: _page(),
          anchorPageIndex: 3,
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
          anchorPage: _page(),
          anchorPageIndex: 0,
          targetPageIndex: 1,
        ),
        isFalse,
      );
    });

    test('a cross-page element reaches the neighbour it spills onto', () {
      // Spans 0.6 to 1.4, so it shows on pages 0 and 1 but not 2.
      final spilling = _image(x: 0.6, width: 0.8);
      expect(
        isVisibleOnPage(
          element: spilling,
          anchorPage: _page(),
          anchorPageIndex: 0,
          targetPageIndex: 1,
        ),
        isTrue,
      );
      expect(
        isVisibleOnPage(
          element: spilling,
          anchorPage: _page(),
          anchorPageIndex: 0,
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
          anchorPage: _page(),
          anchorPageIndex: 0,
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
        anchorPage: _page(),
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
      const pageCount = 3;
      final page = _page();
      final cases = <CanvasElement>[
        for (final x in <double>[-0.5, 0, 0.5, 0.99, 1.0, 1.5, 2.2, 2.9])
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
        final anchorIndex = anchorPageIndex(element, pageCount);
        for (var targetIndex = 0; targetIndex < pageCount; targetIndex++) {
          expect(
            isPayloadVisibleOnPage(
              element: payloadOf(element),
              anchorAspectWidth: page.aspectWidth,
              anchorAspectHeight: page.aspectHeight,
              anchorPageIndex: anchorIndex,
              targetPageIndex: targetIndex,
            ),
            isVisibleOnPage(
              element: element,
              anchorPage: page,
              anchorPageIndex: anchorIndex,
              targetPageIndex: targetIndex,
            ),
            reason:
                'x=${element.x} w=${element.width} '
                'ar=${element.data['aspectRatio']} '
                'cross=${element.allowCrossPage} '
                '$anchorIndex->$targetIndex',
          );
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
    test('a cross-page element may be dragged anywhere in the document', () {
      final range = allowedXRange(
        _image(width: 0.5),
        anchorPageIndex: 1,
        pageCount: 3,
      );
      // The whole canvas, not a window around the page it is filed under: the
      // filing follows the drag rather than tethering it.
      expect(range.min, 0);
      expect(range.max, closeTo(2.5, 1e-9));
    });

    test('the anchor page does not narrow a cross-page range', () {
      // Same element, filed under three different pages, same range each time.
      final ranges = <CanvasXRange>[
        for (var anchor = 0; anchor < 3; anchor++)
          allowedXRange(
            _image(width: 0.5),
            anchorPageIndex: anchor,
            pageCount: 3,
          ),
      ];
      for (final range in ranges) {
        expect(range.min, ranges.first.min);
        expect(range.max, ranges.first.max);
      }
    });

    test('a page-bound element is held inside its own page', () {
      final range = allowedXRange(
        _image(width: 0.3, allowCrossPage: false),
        anchorPageIndex: 1,
        pageCount: 3,
      );
      // Page 1 spans x = 1 to x = 2 in document space.
      expect(range.min, 1);
      expect(range.max, closeTo(1.7, 1e-9));
      expect(range.clamp(0.4), 1);
      expect(range.clamp(2.9), closeTo(1.7, 1e-9));
    });

    test('an oversized page-bound element collapses to its page origin', () {
      final range = allowedXRange(
        _image(width: 1.8, allowCrossPage: false),
        anchorPageIndex: 1,
        pageCount: 3,
      );
      expect(range.min, 1);
      expect(range.max, 1);
    });

    test('the range depends on the element, not the display mode', () {
      // Regression guard: the old code picked the range from the editor's
      // display mode, so a cross-page layout built in preview was flattened
      // the moment it was touched in single mode.
      final crossPage = _image(x: 0.6, width: 1.5);
      expect(
        allowedXRange(
          crossPage,
          anchorPageIndex: 0,
          pageCount: 3,
        ).clamp(crossPage.x),
        closeTo(0.6, 1e-9),
      );
    });

    test('the span may not run off the end of the document', () {
      // Regression guard for the fixed-overhang model this replaced: it let an
      // element on page 0 of a two-page project reach x = 1.95, putting its
      // right edge at 2.45 -- half a page past the end, rendering nowhere.
      const width = 1.8;
      final range = allowedXRange(
        _image(width: width),
        anchorPageIndex: 0,
        pageCount: 2,
      );
      expect(range.max, closeTo(0.2, 1e-9));
      expect(range.max + width, closeTo(2.0, 1e-9));
    });

    test('a full-document spread is pinned to the only place it fits', () {
      final range = allowedXRange(
        _image(width: 2.0),
        anchorPageIndex: 1,
        pageCount: 2,
      );
      expect(range.min, 0);
      expect(range.max, 0);
    });

    test('a lone page confines even a cross-page element', () {
      final range = allowedXRange(
        _image(width: 0.5),
        anchorPageIndex: 0,
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
          anchorPageIndex: 0,
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
          anchorPageIndex: 0,
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
          anchorPageIndex: 0,
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
          anchorPageIndex: 0,
          pageCount: 3,
        ),
        kMinElementWidth,
      );
    });
  });

  group('touchedPageRange', () {
    ({int first, int last}) rangeOf(CanvasElement element, {int pageCount = 3}) {
      return touchedPageRange(element: element, pageCount: pageCount);
    }

    test('an element inside one page touches only that page', () {
      final range = rangeOf(_image(x: 1.1, width: 0.5));
      expect(range.first, 1);
      expect(range.last, 1);
    });

    test('the slightest overlap counts as touching', () {
      // Covers page 1 and clips 5% into page 2.
      final range = rangeOf(_image(x: 1.05, width: 1.0));
      expect(range.first, 1);
      expect(range.last, 2);
    });

    test('a span landing exactly on a boundary does not touch beyond it', () {
      final range = rangeOf(_image(x: 1.0, width: 1.0));
      expect(range.first, 1);
      expect(range.last, 1);
    });

    test('a spread straddling a seam reports both pages', () {
      final range = rangeOf(_image(x: 1.4, width: 1.2));
      expect(range.first, 1);
      expect(range.last, 2);
    });

    test('three pages wide touches three pages', () {
      final range = rangeOf(_image(x: 0, width: 3.0));
      expect(range.first, 0);
      expect(range.last, 2);
    });

    test('never reports a page outside the document', () {
      final range = rangeOf(_image(x: -5, width: 20));
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
      final spread = _image(x: 0, width: 2.0);
      final range = allowedXRange(spread, anchorPageIndex: 0, pageCount: 2);
      expect(range.clamp(spread.x), 0);
    });
  });

  group('defaultAllowCrossPage', () {
    test('agrees with the CanvasElement factories', () {
      expect(
        defaultAllowCrossPage('image'),
        CanvasElement.image().allowCrossPage,
      );
      expect(defaultAllowCrossPage('text'), CanvasElement.text().allowCrossPage);
    });

    test('a legacy element with no stored flag takes the type default', () {
      final legacyText = CanvasElement.fromJson(<String, dynamic>{
        'id': 't1',
        'type': 'text',
      });
      expect(legacyText.allowCrossPage, isFalse);

      final legacyImage = CanvasElement.fromJson(<String, dynamic>{
        'id': 'e1',
        'type': 'image',
      });
      expect(legacyImage.allowCrossPage, isTrue);
    });

    test('an explicitly stored flag is respected either way', () {
      final crossPageText = CanvasElement.fromJson(<String, dynamic>{
        'id': 't1',
        'type': 'text',
        'allowCrossPage': true,
      });
      expect(crossPageText.allowCrossPage, isTrue);
    });
  });

  group('per-page projects load into the flat list', () {
    Map<String, dynamic> pageJson(String id, List<Map<String, dynamic>> els) {
      return <String, dynamic>{
        'id': id,
        'aspectWidth': 4,
        'aspectHeight': 5,
        'elements': els,
      };
    }

    test('pages are concatenated in order, so z-order survives', () {
      // The old painting order was (page index, element index); reading the
      // pages in order and appending reproduces it exactly.
      final project = ProjectRecord.fromJson(<String, dynamic>{
        'id': 'proj',
        'pages': <dynamic>[
          pageJson('p0', <Map<String, dynamic>>[
            <String, dynamic>{'id': 'a', 'type': 'image', 'x': 0.1},
            <String, dynamic>{'id': 'b', 'type': 'image', 'x': 0.2},
          ]),
          pageJson('p1', <Map<String, dynamic>>[
            <String, dynamic>{'id': 'c', 'type': 'image', 'x': 0.3},
          ]),
        ],
      });

      expect(project.elements.map((element) => element.id).toList(), <String>[
        'a',
        'b',
        'c',
      ]);
    });

    test('x is rebased from page-relative to document space', () {
      final project = ProjectRecord.fromJson(<String, dynamic>{
        'id': 'proj',
        'pages': <dynamic>[
          pageJson('p0', const <Map<String, dynamic>>[]),
          pageJson('p1', <Map<String, dynamic>>[
            // Straddled the seam back onto page 0 under the old model.
            <String, dynamic>{'id': 'c', 'type': 'image', 'x': -0.25},
          ]),
        ],
      });

      final element = project.elements.single;
      expect(element.x, closeTo(0.75, 1e-9));
      expect(anchorPageIndex(element, project.pages.length), 0);
    });
  });

  group('elementsAfterPageRemoved', () {
    test('the deleted page takes its own elements with it', () {
      final kept = elementsAfterPageRemoved(
        elements: <CanvasElement>[
          _image(x: 0.1).copyWith(id: 'onPage0'),
          _image(x: 1.1).copyWith(id: 'onPage1'),
          _image(x: 2.1).copyWith(id: 'onPage2'),
        ],
        pageCount: 3,
        removedPageIndex: 1,
      );
      expect(kept.map((element) => element.id).toList(), <String>[
        'onPage0',
        'onPage2',
      ]);
    });

    test('everything after the deletion slides one page left', () {
      // Page membership is read off x, so without the shift every element past
      // the deleted page would silently re-anchor to its neighbour.
      final kept = elementsAfterPageRemoved(
        elements: <CanvasElement>[_image(x: 2.4)],
        pageCount: 3,
        removedPageIndex: 0,
      );
      expect(kept.single.x, closeTo(1.4, 1e-9));
      expect(anchorPageIndex(kept.single, 2), 1);
    });

    test('elements before the deletion do not move', () {
      final kept = elementsAfterPageRemoved(
        elements: <CanvasElement>[_image(x: 0.4)],
        pageCount: 3,
        removedPageIndex: 2,
      );
      expect(kept.single.x, closeTo(0.4, 1e-9));
    });
  });

  group('elementsAfterPageMoved', () {
    test('an element travels with the page it is anchored to', () {
      final moved = elementsAfterPageMoved(
        elements: <CanvasElement>[_image(x: 0.25)],
        pageCount: 3,
        oldIndex: 0,
        newIndex: 2,
      );
      // Page 0 became page 2, and the element kept its quarter-page offset.
      expect(moved.single.x, closeTo(2.25, 1e-9));
    });

    test('the pages it displaces shift the other way', () {
      final moved = elementsAfterPageMoved(
        elements: <CanvasElement>[_image(x: 1.5), _image(x: 2.5)],
        pageCount: 3,
        oldIndex: 0,
        newIndex: 2,
      );
      expect(moved[0].x, closeTo(0.5, 1e-9));
      expect(moved[1].x, closeTo(1.5, 1e-9));
    });

    test('a page moved backwards pushes the rest forwards', () {
      final moved = elementsAfterPageMoved(
        elements: <CanvasElement>[_image(x: 2.5), _image(x: 0.5)],
        pageCount: 3,
        oldIndex: 2,
        newIndex: 0,
      );
      expect(moved[0].x, closeTo(0.5, 1e-9));
      expect(moved[1].x, closeTo(1.5, 1e-9));
    });

    test('pages untouched by the move keep their elements in place', () {
      final moved = elementsAfterPageMoved(
        elements: <CanvasElement>[_image(x: 3.5)],
        pageCount: 5,
        oldIndex: 0,
        newIndex: 1,
      );
      expect(moved.single.x, closeTo(3.5, 1e-9));
    });
  });

  group('normalizeProject', () {
    ProjectRecord projectOf(
      List<CanvasElement> elements, {
      ProjectPage? page,
      int pageCount = 1,
    }) {
      final basePage = page ?? _page();
      return ProjectRecord(
        id: 'proj',
        name: 'proj',
        createdAt: DateTime(2026),
        pageCount: pageCount,
        pages: <ProjectPage>[
          for (var i = 0; i < pageCount; i++) basePage.copyWith(id: 'p$i'),
        ],
        elements: elements,
        extras: const <String, dynamic>{},
      );
    }

    test('keeps a spill that still has a page to land on', () {
      final spilling = _image(x: 0.6, width: 0.8, aspectRatio: 1.0);
      final normalized = normalizeProject(
        projectOf(<CanvasElement>[spilling], pageCount: 2),
      );
      expect(normalized.elements.single.x, closeTo(0.6, 1e-9));
    });

    test('reclaims a spill off the end of the document', () {
      // Same shape, but on the last page: the overflow has no page behind it,
      // so it would render nowhere and be lost on export.
      final spilling = _image(x: 1.6, width: 0.8, aspectRatio: 1.0);
      final normalized = normalizeProject(
        projectOf(<CanvasElement>[spilling], pageCount: 2),
      );
      expect(normalized.elements.single.x, closeTo(1.2, 1e-9));
    });

    test('reclaims a spill off the front of the document', () {
      final spilling = _image(x: -0.3, width: 0.8, aspectRatio: 1.0);
      final normalized = normalizeProject(
        projectOf(<CanvasElement>[spilling], pageCount: 2),
      );
      expect(normalized.elements.single.x, 0);
    });

    test('recomputes a height left stale by a page aspect change', () {
      // Stored height of 0.5 was correct on a square page; on 4:5 it is 0.4.
      final stale = _image(width: 0.5, height: 0.5, aspectRatio: 1.0);
      final normalized = normalizeProject(projectOf(<CanvasElement>[stale]));
      expect(normalized.elements.single.height, closeTo(0.4, 1e-9));
    });

    test('pulls a page-bound element back inside its page', () {
      final escaped = _image(x: 1.6, width: 0.5, allowCrossPage: false);
      final normalized = normalizeProject(
        projectOf(<CanvasElement>[escaped], pageCount: 3),
      );
      expect(normalized.elements.single.x, closeTo(1.5, 1e-9));
    });

    test('leaves a cross-page element with neighbours on both sides', () {
      final spilling = _image(x: 0.6, width: 1.5, aspectRatio: 1.0);
      final normalized = normalizeProject(
        projectOf(<CanvasElement>[spilling], pageCount: 3),
      );
      expect(normalized.elements.single.x, closeTo(0.6, 1e-9));
    });

    test('clamps y when the recomputed height no longer fits', () {
      final tooLow = _image(y: 0.9, width: 1.0, height: 0.1, aspectRatio: 1.0);
      final normalized = normalizeProject(projectOf(<CanvasElement>[tooLow]));
      final element = normalized.elements.single;
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
