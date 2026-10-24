import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/app_settings.dart';
import 'package:igapp/blank_page.dart';
import 'package:igapp/photo_gesture_surface.dart';
import 'package:igapp/project_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

Rect screenRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(box.size.bottomRight(Offset.zero)),
  );
}

void main() {
  for (final screen in [
    const Size(800, 600),
    const Size(390, 700),
    const Size(800, 450),
  ]) {
    testWidgets('preview paints and scrolls at both screen edges at $screen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await AppSettingsController.instance.setLanguage('zh');
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final colors = List.generate(
        15,
        (i) => Color.fromARGB(255, 32 + i * 13, 40 + i * 7, 200 - i * 11),
      );
      final project = ProjectRecord(
        id: 'preview',
        name: 'Preview test',
        createdAt: DateTime(2026),
        pageCount: colors.length,
        pages: [
          for (var i = 0; i < colors.length; i++)
            ProjectPage(
              id: 'p$i',
              title: 'Page $i',
              type: 'page',
              aspectWidth: 9,
              aspectHeight: 16,
              extras: {'backgroundColorValue': colors[i].toARGB32()},
            ),
        ],
        elements: const [
          CanvasElement(
            id: 'photo',
            type: 'image',
            x: 7.35,
            y: 0.3,
            width: 0.2,
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
      Finder modeSwitch() => find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_SlideSwitch',
      );
      (tester.widget(modeSwitch()) as dynamic).onChanged(true);
      await tester.pumpAndSettle();
      final scroll = find.byKey(const ValueKey('preview-page-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!;
      final pageWidth = screen.width * 0.78;
      controller.jumpTo(pageWidth * 7);
      await tester.pumpAndSettle();

      Rect referencePage() => screenRect(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color == colors[7],
        ),
      );

      Future<void> expectFullWidthPages() async {
        final viewport = screenRect(tester, scroll);
        expect(viewport.left, closeTo(0, 0.1));
        expect(viewport.right, closeTo(screen.width, 0.1));
        final reference = referencePage();
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          for (final x in [8.0, 32.0, screen.width - 32, screen.width - 8]) {
            final index = 7 + ((x - reference.left) / reference.width).floor();
            expect(index, inInclusiveRange(0, colors.length - 1));
            final offset =
                (reference.center.dy.round() * image.width + x.round()) * 4;
            final actual = Color.fromARGB(
              bytes.getUint8(offset + 3),
              bytes.getUint8(offset),
              bytes.getUint8(offset + 1),
              bytes.getUint8(offset + 2),
            );
            expect(
              actual,
              colors[index],
              reason: 'page ${index + 1} must paint at screen x=$x',
            );
          }
          image.dispose();
        });
      }

      expect(referencePage().center.dx, closeTo(screen.width / 2, 0.1));
      await expectFullWidthPages();
      // This used to land outside the shrunken scrollable's hit-test area.
      final before = controller.offset;
      final drag = await tester.startGesture(
        Offset(8, referencePage().center.dy),
      );
      await drag.moveBy(const Offset(20, 0));
      await drag.moveBy(const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(controller.offset, lessThan(before));
      await expectFullWidthPages();
      await drag.up();
      await tester.pumpAndSettle();
      await expectFullWidthPages();

      // Selecting an image changes the available height and fitted scale.
      tester
          .widget<PhotoGestureSurface>(find.byType(PhotoGestureSurface))
          .onTap!();
      await tester.pumpAndSettle();
      await expectFullWidthPages();
      final currentPage = (controller.offset / pageWidth).round();
      (tester.widget(modeSwitch()) as dynamic).onChanged(false);
      await tester.pumpAndSettle();
      final single = tester.widget<PageView>(
        find.byKey(const ValueKey('single-page-pager')),
      );
      expect(single.controller!.page, currentPage);
      expect(tester.takeException(), isNull);
    });
  }
}
