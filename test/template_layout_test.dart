import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/project_record.dart';
import 'package:igapp/template_layout.dart';

ProjectPage _page(double aspectWidth, double aspectHeight) {
  return ProjectPage(
    id: 'page-1',
    title: 'Page 1',
    type: 'page',
    aspectWidth: aspectWidth,
    aspectHeight: aspectHeight,
    extras: const <String, dynamic>{},
  );
}

const TemplateOption _twoRows = TemplateOption(
  id: 'grid_rows_2',
  label: 'stackedImages',
  rowWeights: <double>[1, 1],
  slots: <TemplateSlot>[
    TemplateSlot(column: 0, row: 0),
    TemplateSlot(column: 0, row: 1),
  ],
);

const TemplateOption _twoColumns = TemplateOption(
  id: 'grid_columns_2',
  label: 'sideBySideImages',
  columnWeights: <double>[1, 1],
  slots: <TemplateSlot>[
    TemplateSlot(column: 0, row: 0),
    TemplateSlot(column: 1, row: 0),
  ],
);

const TemplateOption _heroTopTwoBottom = TemplateOption(
  id: 'hero_top_two_bottom',
  label: 'heroTopTwoBottom',
  columnWeights: <double>[1, 1],
  rowWeights: <double>[2, 1],
  slots: <TemplateSlot>[
    TemplateSlot(column: 0, row: 0, columnSpan: 2),
    TemplateSlot(column: 0, row: 1),
    TemplateSlot(column: 1, row: 1),
  ],
);

void main() {
  group('no margin', () {
    test('stacked slots tile the page edge to edge', () {
      final rects = _twoRows.resolveRects(_page(3, 4), 0);

      expect(rects[0].x, closeTo(0, 1e-9));
      expect(rects[0].y, closeTo(0, 1e-9));
      expect(rects[0].width, closeTo(1, 1e-9));
      expect(rects[0].height, closeTo(0.5, 1e-9));
      expect(rects[1].y, closeTo(0.5, 1e-9));
      expect(rects[1].y + rects[1].height, closeTo(1, 1e-9));
    });

    test('slot aspect ratio accounts for the page aspect', () {
      // Half of a 3:4 page is 3:2.
      final rects = _twoRows.resolveRects(_page(3, 4), 0);
      expect(rects[0].aspectRatio, closeTo(3 / 2, 1e-9));

      // Half of a 4:5 page is 8:5.
      final wide = _twoRows.resolveRects(_page(4, 5), 0);
      expect(wide[0].aspectRatio, closeTo(8 / 5, 1e-9));
    });
  });

  group('margin distribution', () {
    test('the seam between stacked slots is one margin, not two', () {
      const marginRatio = 0.05;
      final page = _page(3, 4);
      final rects = _twoRows.resolveRects(page, marginRatio);

      // Physical thickness, using the shorter side as the reference.
      const thickness = marginRatio * 3;
      final marginY = thickness / 4;

      final topGap = rects[0].y;
      final seamGap = rects[1].y - (rects[0].y + rects[0].height);
      final bottomGap = 1 - (rects[1].y + rects[1].height);

      expect(topGap, closeTo(marginY, 1e-9));
      expect(bottomGap, closeTo(marginY, 1e-9));
      // The regression this guards: insetting each slot separately would make
      // the middle seam twice as thick as the outer edges.
      expect(seamGap, closeTo(marginY, 1e-9));
      expect(seamGap, closeTo(topGap, 1e-9));
    });

    test('the seam between side-by-side slots is one margin, not two', () {
      const marginRatio = 0.05;
      final rects = _twoColumns.resolveRects(_page(16, 9), marginRatio);

      const thickness = marginRatio * 9;
      final marginX = thickness / 16;

      final leftGap = rects[0].x;
      final seamGap = rects[1].x - (rects[0].x + rects[0].width);
      final rightGap = 1 - (rects[1].x + rects[1].width);

      expect(leftGap, closeTo(marginX, 1e-9));
      expect(seamGap, closeTo(marginX, 1e-9));
      expect(rightGap, closeTo(marginX, 1e-9));
    });

    test('margins are physically equal on all four edges', () {
      const marginRatio = 0.06;
      for (final page in <ProjectPage>[
        _page(4, 5),
        _page(3, 4),
        _page(4, 3),
        _page(5, 4),
        _page(3, 2),
        _page(16, 9),
      ]) {
        final rect = const TemplateOption(
          id: 'single',
          label: 'single',
        ).resolveRects(page, marginRatio).single;

        // Convert the normalised gaps back into page units before comparing.
        final leftPhysical = rect.x * page.aspectWidth;
        final topPhysical = rect.y * page.aspectHeight;
        final rightPhysical =
            (1 - (rect.x + rect.width)) * page.aspectWidth;
        final bottomPhysical =
            (1 - (rect.y + rect.height)) * page.aspectHeight;

        expect(leftPhysical, closeTo(topPhysical, 1e-9));
        expect(rightPhysical, closeTo(leftPhysical, 1e-9));
        expect(bottomPhysical, closeTo(topPhysical, 1e-9));
      }
    });

    test('a spanning slot swallows the gutters it crosses', () {
      const marginRatio = 0.05;
      final page = _page(4, 5);
      final rects = _heroTopTwoBottom.resolveRects(page, marginRatio);

      const thickness = marginRatio * 4;
      final marginX = thickness / 4;

      final hero = rects[0];
      final bottomLeft = rects[1];
      final bottomRight = rects[2];

      // The hero spans both columns, so it runs the full content width rather
      // than stopping at the first column's edge.
      expect(hero.x, closeTo(marginX, 1e-9));
      expect(hero.x + hero.width, closeTo(1 - marginX, 1e-9));
      expect(hero.width, closeTo(bottomLeft.width * 2 + marginX, 1e-9));

      // And the row it spans is still twice the height of the bottom row.
      expect(hero.height, closeTo(bottomLeft.height * 2, 1e-9));
      expect(bottomRight.x + bottomRight.width, closeTo(1 - marginX, 1e-9));
    });

    test('weighted tracks keep their ratio once margins are applied', () {
      final rects = _heroTopTwoBottom.resolveRects(_page(3, 4), 0.08);
      expect(rects[0].height / rects[1].height, closeTo(2, 1e-9));
    });
  });

  group('containFillRect', () {
    test('letterboxes a landscape photo on a portrait page', () {
      final rect = containFillRect(
        page: _page(4, 5),
        imageAspectRatio: 16 / 9,
        marginRatio: 0,
      );

      expect(rect.width, closeTo(1, 1e-9));
      // 4 wide at 16:9 is 2.25 tall, on a page 5 tall.
      expect(rect.height, closeTo((4 / (16 / 9)) / 5, 1e-9));
      expect(rect.x, closeTo(0, 1e-9));
      expect(rect.y, closeTo((1 - rect.height) / 2, 1e-9));
      expect(rect.aspectRatio, closeTo(16 / 9, 1e-9));
    });

    test('letterboxes a portrait photo on a wide page', () {
      final rect = containFillRect(
        page: _page(16, 9),
        imageAspectRatio: 3 / 4,
        marginRatio: 0,
      );

      expect(rect.height, closeTo(1, 1e-9));
      expect(rect.width, closeTo((9 * (3 / 4)) / 16, 1e-9));
      expect(rect.x, closeTo((1 - rect.width) / 2, 1e-9));
    });

    test('a photo matching the page aspect fills it exactly', () {
      final rect = containFillRect(
        page: _page(3, 4),
        imageAspectRatio: 3 / 4,
        marginRatio: 0,
      );

      expect(rect.x, closeTo(0, 1e-9));
      expect(rect.y, closeTo(0, 1e-9));
      expect(rect.width, closeTo(1, 1e-9));
      expect(rect.height, closeTo(1, 1e-9));
    });

    test('the margin leaves a physically even border', () {
      const marginRatio = 0.05;
      final page = _page(16, 9);
      // Matching the box aspect means the photo touches all four margins.
      final boxAspect =
          ((1 - 2 * (marginRatio * 9 / 16)) * 16) /
          ((1 - 2 * marginRatio) * 9);
      final rect = containFillRect(
        page: page,
        imageAspectRatio: boxAspect,
        marginRatio: marginRatio,
      );

      final leftPhysical = rect.x * page.aspectWidth;
      final topPhysical = rect.y * page.aspectHeight;
      expect(leftPhysical, closeTo(topPhysical, 1e-9));
      expect(leftPhysical, closeTo(marginRatio * 9, 1e-9));
    });

    test('stays centred and inside the margin box for any photo', () {
      const marginRatio = 0.05;
      final page = _page(4, 5);
      for (final imageAspect in <double>[0.5, 3 / 4, 1, 4 / 3, 16 / 9, 3]) {
        final rect = containFillRect(
          page: page,
          imageAspectRatio: imageAspect,
          marginRatio: marginRatio,
        );

        final marginX = marginRatio * 4 / 4;
        final marginY = marginRatio * 4 / 5;

        expect(rect.x, greaterThanOrEqualTo(marginX - 1e-9));
        expect(rect.y, greaterThanOrEqualTo(marginY - 1e-9));
        expect(rect.x + rect.width, lessThanOrEqualTo(1 - marginX + 1e-9));
        expect(rect.y + rect.height, lessThanOrEqualTo(1 - marginY + 1e-9));
        expect(rect.x, closeTo((1 - rect.width) / 2, 1e-9));
        expect(rect.y, closeTo((1 - rect.height) / 2, 1e-9));
      }
    });
  });

  group('page matching', () {
    test('an unrestricted template is offered on every aspect', () {
      const option = TemplateOption(id: 'x', label: 'x');
      expect(option.matchesPage(_page(4, 5)), isTrue);
      expect(option.matchesPage(_page(16, 9)), isTrue);
    });

    test('a restricted template only matches its listed aspects', () {
      const option = TemplateOption(
        id: 'x',
        label: 'x',
        pageAspects: <String>['3:2', '16:9'],
      );
      expect(option.matchesPage(_page(16, 9)), isTrue);
      expect(option.matchesPage(_page(3, 2)), isTrue);
      expect(option.matchesPage(_page(4, 5)), isFalse);
    });
  });

  group('matchesLayout', () {
    // Templates lay out one page; these cases put it first in the
    // document, so page-local and document-space x coincide.
    final page = _page(3, 4);
    bool matches(
      TemplateOption option,
      List<CanvasElement> elements,
      double marginRatio,
    ) => option.matchesLayout(page, elements, 0, marginRatio);

    test('a freshly applied template matches its own layout', () {
      for (final marginRatio in <double>[0, 0.05]) {
        final laidOut = _twoRows.buildElements(0, page, marginRatio);
        expect(matches(_twoRows, laidOut, marginRatio), isTrue);
      }
    });

    test('a different template does not match', () {
      final laidOut = _twoRows.buildElements(0, page, 0);
      expect(matches(_twoColumns, laidOut, 0), isFalse);
      expect(matches(_heroTopTwoBottom, laidOut, 0), isFalse);
    });

    test('moving a slot stops it matching', () {
      final elements = _twoRows.buildElements(0, page, 0);
      final moved = <CanvasElement>[
        elements.first.copyWith(x: elements.first.x + 0.05),
        elements.last,
      ];
      expect(matches(_twoRows, moved, 0), isFalse);
    });

    test('resizing a slot stops it matching', () {
      final elements = _twoRows.buildElements(0, page, 0);
      final resized = <CanvasElement>[
        elements.first.copyWith(
          width: 0.6,
          data: <String, dynamic>{...elements.first.data, 'aspectRatio': 1.0},
        ),
        elements.last,
      ];
      expect(matches(_twoRows, resized, 0), isFalse);
    });

    test('removing a slot stops it matching', () {
      final elements = _twoRows.buildElements(0, page, 0);
      expect(
        matches(_twoRows, <CanvasElement>[elements.first], 0),
        isFalse,
      );
    });

    test('reordering layers still matches', () {
      final elements = _twoRows.buildElements(0, page, 0);
      final reordered = elements.reversed.toList();
      expect(matches(_twoRows, reordered, 0), isTrue);
    });

    test('text elements are ignored', () {
      final elements = _twoRows.buildElements(0, page, 0);
      final withText = <CanvasElement>[
        ...elements,
        CanvasElement.text(),
      ];
      expect(matches(_twoRows, withText, 0), isTrue);
    });

    test('changing the margin stops the old layout matching', () {
      final laidOut = _twoRows.buildElements(0, page, 0);
      expect(matches(_twoRows, laidOut, 0), isTrue);
      expect(matches(_twoRows, laidOut, 0.05), isFalse);
    });

    group('contain fill', () {
      const fill = TemplateOption(
        id: 'page_fill',
        label: 'fill',
        isContainFill: true,
      );

      test('matches while the slot is still empty', () {
        final laidOut = fill.buildElements(0, page, 0);
        expect(matches(fill, laidOut, 0), isTrue);
      });

      test('matches a photo letterboxed to its own ratio', () {
        const photoAspect = 16 / 9;
        final fitted = containFillRect(
          page: _page(3, 4),
          imageAspectRatio: photoAspect,
          marginRatio: 0,
        );
        final placed = fill
            .buildElements(0, page, 0)
            .single
            .copyWith(
              x: fitted.x,
              y: fitted.y,
              width: fitted.width,
              height: fitted.height,
              data: <String, dynamic>{
                'src': '/photos/a.jpg',
                'aspectRatio': photoAspect,
                'originalAspectRatio': photoAspect,
                'templateSlot': 'fill',
              },
            );
        expect(matches(fill, <CanvasElement>[placed], 0), isTrue);
      });

      test('does not match a two-slot layout', () {
        final laidOut = _twoRows.buildElements(0, page, 0);
        expect(matches(fill, laidOut, 0), isFalse);
      });
    });
  });

  group('buildElements', () {
    test('slots carry the frame ratio the layout computed', () {
      final page = _page(3, 4);
      final elements = _twoRows.buildElements(0, page, 0);

      expect(elements, hasLength(2));
      for (final element in elements) {
        expect(element.type, 'image');
        expect(element.data['aspectRatio'], closeTo(3 / 2, 1e-9));
        expect(element.data['aspectPreset'], isNotNull);
        expect(element.allowCrossPage, isTrue);
      }
      expect(elements[0].data['templateSlot'], 'slot0');
      expect(elements[1].data['templateSlot'], 'slot1');
    });

    test('a contain-fill template records its margin for later re-fitting', () {
      const fill = TemplateOption(
        id: 'page_fill',
        label: 'fill',
        isContainFill: true,
      );
      final elements = fill.buildElements(0, _page(4, 5), 0.05);

      expect(elements, hasLength(1));
      expect(elements.single.data['templateSlot'], 'fill');
      expect(elements.single.data['templateMarginRatio'], closeTo(0.05, 1e-9));
      // The fill slot must not be pinned to a preset, since it takes the
      // photo's own ratio.
      expect(elements.single.data.containsKey('aspectPreset'), isFalse);
    });
  });
}
