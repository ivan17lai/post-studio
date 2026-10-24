import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/app_settings.dart';
import 'package:igapp/blank_page.dart';
import 'package:igapp/photo_gesture_surface.dart';
import 'package:igapp/project_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _colors = [Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF0000FF)];

Finder _page(Color color) => find.byWidgetPredicate(
  (widget) =>
      widget is Container &&
      widget.decoration is BoxDecoration &&
      (widget.decoration! as BoxDecoration).color == color,
);

Rect _screenRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(box.size.bottomRight(Offset.zero)),
  );
}

Future<List<Color>> _pixels(
  WidgetTester tester,
  GlobalKey key,
  List<Offset> points,
) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final colors = points.map((point) {
      final offset = (point.dy.round() * image.width + point.dx.round()) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    }).toList();
    image.dispose();
    return colors;
  }))!;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettingsController.instance.setLanguage('zh');
  });

  for (final screen in [const Size(800, 600), const Size(390, 700)]) {
    testWidgets(
      'neighbours paint in side margins only during swipe at $screen',
      (tester) async {
        tester.view.physicalSize = screen;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        final project = ProjectRecord(
          id: 'swipe',
          name: 'Swipe test',
          createdAt: DateTime(2026),
          pageCount: 3,
          pages: [
            for (var i = 0; i < 3; i++)
              ProjectPage(
                id: 'page-$i',
                title: 'Page $i',
                type: 'page',
                aspectWidth: 9,
                aspectHeight: 16,
                extras: {'backgroundColorValue': _colors[i].toARGB32()},
              ),
          ],
          elements: const [
            CanvasElement(
              id: 'photo',
              type: 'image',
              x: 1.3,
              y: 0.35,
              width: 0.3,
              height: 0.2,
              allowCrossPage: false,
              data: {'src': '', 'aspectRatio': 1.0},
            ),
          ],
          extras: const {},
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              home: BlankPage(project: project, onProjectChanged: (_) async {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final pager = tester.widget<PageView>(
          find.byKey(const ValueKey('single-page-pager')),
        );
        final controller = pager.controller!;
        controller.jumpToPage(1);
        await tester.pumpAndSettle();
        final center = _screenRect(tester, _page(_colors[1]));
        expect(center.center.dx, closeTo(screen.width / 2, 0.1));
        expect(center.left, greaterThan(45));
        final samples = [
          Offset(center.left - 40, center.center.dy),
          Offset(center.right + 40, center.center.dy),
        ];
        expect(await _pixels(tester, capture, samples), [
          const Color(0xFFEAEAEA),
          const Color(0xFFEAEAEA),
        ]);

        final blankStart = center.topCenter + const Offset(0, 20);

        // A slow drag must reveal both neighbours beyond the central page slot.
        final drag = await tester.startGesture(blankStart);
        await drag.moveBy(const Offset(-20, 0));
        await drag.moveBy(const Offset(-8, 0));
        await tester.pump();
        await tester.pump();
        expect(await _pixels(tester, capture, samples), [
          _colors[0],
          _colors[2],
        ]);
        await drag.up();
        await tester.pump();
        await tester.pump();
        // Start hiding on release, before the snapping animation settles.
        for (final color in [_colors[0], _colors[2]]) {
          final opacity = tester.widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: _page(color),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          );
          expect(opacity.opacity, 0);
        }
        await tester.pumpAndSettle();
        expect(controller.page, 1);
        expect(await _pixels(tester, capture, samples), [
          const Color(0xFFEAEAEA),
          const Color(0xFFEAEAEA),
        ]);

        // A swipe starting in the grey margin also turns the page; the invisible
        // neighbouring canvas must not swallow it.
        final cancel = await tester.startGesture(samples.first);
        await cancel.moveBy(const Offset(20, 0));
        await cancel.moveBy(const Offset(8, 0));
        await tester.pump();
        await tester.pump();
        expect(await _pixels(tester, capture, samples), [
          _colors[0],
          _colors[2],
        ]);
        await cancel.cancel();
        await tester.pumpAndSettle();
        expect(await _pixels(tester, capture, samples), [
          const Color(0xFFEAEAEA),
          const Color(0xFFEAEAEA),
        ]);

        await tester.dragFrom(blankStart, Offset(-center.width * 0.75, 0));
        await tester.pumpAndSettle();
        expect(controller.page, 2);
        expect(
          _screenRect(tester, _page(_colors[2])).width,
          closeTo(center.width, 0.1),
        );
        expect(await _pixels(tester, capture, samples), [
          const Color(0xFFEAEAEA),
          const Color(0xFFEAEAEA),
        ]);
        // Photo gestures must not reveal neighbours or turn the page, even
        // though the expanded viewport includes those pages for painting.
        controller.jumpToPage(1);
        await tester.pumpAndSettle();
        final photo = find.byType(PhotoGestureSurface);
        final photoDrag = await tester.startGesture(
          _screenRect(tester, photo).center,
        );
        await photoDrag.moveBy(const Offset(-50, 0));
        await tester.pumpAndSettle();
        expect(controller.page, 1);
        // Selection may resize the bottom panel, so sample the new margins.
        final selectedPage = _screenRect(tester, _page(_colors[1]));
        expect(
          await _pixels(tester, capture, [
            Offset(selectedPage.left - 20, selectedPage.center.dy),
            Offset(selectedPage.right + 20, selectedPage.center.dy),
          ]),
          [const Color(0xFFEAEAEA), const Color(0xFFEAEAEA)],
        );
        await photoDrag.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
