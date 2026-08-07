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

  group('allowedXRange', () {
    test('a cross-page element may hang off either side', () {
      final range = allowedXRange(_image(width: 0.5));
      expect(range.min, -kCrossPageOverhang);
      expect(range.max, 1 + kCrossPageOverhang);
    });

    test('a page-bound element is held inside its own page', () {
      final range = allowedXRange(_image(width: 0.3, allowCrossPage: false));
      expect(range.min, 0);
      expect(range.max, closeTo(0.7, 1e-9));
      expect(range.clamp(-0.4), 0);
      expect(range.clamp(0.9), closeTo(0.7, 1e-9));
    });

    test('an oversized page-bound element collapses to x = 0', () {
      final range = allowedXRange(_image(width: 1.8, allowCrossPage: false));
      expect(range.min, 0);
      expect(range.max, 0);
    });

    test('the range depends on the element alone', () {
      // Regression guard: the old code picked the range from the editor's
      // display mode, so a cross-page layout built in preview was flattened
      // the moment it was touched in single mode.
      final crossPage = _image(x: -0.4, width: 1.5);
      expect(allowedXRange(crossPage).clamp(crossPage.x), -0.4);
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
    test('a cross-page element may grow past its page', () {
      expect(
        maxElementWidth(
          element: _image(x: 0.2, y: 0.2),
          page: _page(),
          aspectRatio: 1.0,
        ),
        kMaxCrossPageElementWidth,
      );
    });

    test('a page-bound element stops at the right edge', () {
      expect(
        maxElementWidth(
          element: _image(x: 0.3, y: 0, allowCrossPage: false),
          page: _page(),
          aspectRatio: 1.0,
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
        ),
        kMinElementWidth,
      );
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
  });
}
