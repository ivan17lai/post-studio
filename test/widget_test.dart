import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/blank_page.dart';
import 'package:igapp/project_record.dart';

const _canvasRegionKey = ValueKey<String>('editor-canvas-region');
const _bottomDockKey = ValueKey<String>('editor-bottom-dock');
const _bottomPanelKey = ValueKey<String>('editor-bottom-panel');

Future<CanvasElement> _pumpEditor(
  WidgetTester tester, {
  Size logicalSize = const Size(360, 800),
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = logicalSize;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final image = CanvasElement.image();
  final project = ProjectRecord(
    id: 'layout-test',
    name: 'Layout test',
    createdAt: DateTime(2026),
    pageCount: 2,
    pages: <ProjectPage>[
      ProjectPage.initial(1).copyWith(aspectWidth: 4, aspectHeight: 5),
      ProjectPage.initial(2).copyWith(aspectWidth: 3, aspectHeight: 4),
    ],
    elements: <CanvasElement>[image],
    extras: const <String, dynamic>{},
  );

  await tester.pumpWidget(
    MaterialApp(
      home: BlankPage(project: project, onProjectChanged: (_) async {}),
    ),
  );
  await tester.pumpAndSettle();
  return image;
}

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, moreOrLessEquals(expected.left));
  expect(actual.top, moreOrLessEquals(expected.top));
  expect(actual.width, moreOrLessEquals(expected.width));
  expect(actual.height, moreOrLessEquals(expected.height));
}

void main() {
  testWidgets('bottom tabs do not resize or move the canvas', (tester) async {
    await _pumpEditor(tester);

    final canvas = find.byKey(_canvasRegionKey);
    final dock = find.byKey(_bottomDockKey);
    final panel = find.byKey(_bottomPanelKey);
    expect(canvas, findsOneWidget);
    expect(dock, findsOneWidget);
    expect(panel, findsOneWidget);

    final originalCanvasRect = tester.getRect(canvas);
    final originalDockRect = tester.getRect(dock);
    final originalPanelRect = tester.getRect(panel);
    expect(originalPanelRect.bottom, moreOrLessEquals(originalDockRect.bottom));
    final originalPageController = tester
        .widget<PageView>(find.byType(PageView))
        .controller;

    for (final tab in <String>['page', 'template', 'elements', 'layers']) {
      final tabFinder = find.byKey(ValueKey<String>('editor-tab-$tab'));
      await tester.ensureVisible(tabFinder);
      await tester.pumpAndSettle();
      await tester.tap(tabFinder);
      await tester.pumpAndSettle();

      _expectSameRect(tester.getRect(canvas), originalCanvasRect);
      _expectSameRect(tester.getRect(dock), originalDockRect);
      _expectSameRect(tester.getRect(panel), originalPanelRect);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller,
        same(originalPageController),
      );
      final exception = tester.takeException();
      expect(
        exception,
        isNull,
        reason: 'unexpected layout exception after $tab: $exception',
      );
    }
  });

  testWidgets('selecting an image keeps the canvas and controller stable', (
    tester,
  ) async {
    final image = await _pumpEditor(tester);
    final canvas = find.byKey(_canvasRegionKey);
    final originalCanvasRect = tester.getRect(canvas);
    final originalPageController = tester
        .widget<PageView>(find.byType(PageView))
        .controller;

    final imagePlaceholder = find.byIcon(Icons.image_outlined);
    expect(imagePlaceholder, findsOneWidget);
    await tester.tap(imagePlaceholder);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('editor-tab-image')),
      findsOneWidget,
    );
    _expectSameRect(tester.getRect(canvas), originalCanvasRect);
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller,
      same(originalPageController),
    );

    final canvasElement = find.byKey(ValueKey<String>('canvas_${image.id}'));
    expect(canvasElement, findsOneWidget);
    final originalElementRect = tester.getRect(imagePlaceholder);
    final drag = await tester.startGesture(originalElementRect.center);
    await drag.moveBy(const Offset(0, 16));
    await tester.pump();
    await drag.moveBy(const Offset(0, 24));
    await tester.pump();
    await drag.moveBy(const Offset(0, 24));
    await tester.pump();

    final transientElementRect = tester.getRect(imagePlaceholder);
    expect(
      (transientElementRect.topLeft - originalElementRect.topLeft).distance,
      greaterThan(1),
    );
    _expectSameRect(tester.getRect(canvas), originalCanvasRect);

    await drag.up();
    await tester.pumpAndSettle();
    _expectSameRect(tester.getRect(canvas), originalCanvasRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short screens scroll dock content without overflow', (
    tester,
  ) async {
    await _pumpEditor(tester, logicalSize: const Size(360, 640));

    final dock = find.byKey(_bottomDockKey);
    expect(
      find.descendant(of: dock, matching: find.byType(SingleChildScrollView)),
      findsWidgets,
    );

    await tester.tap(find.byKey(const ValueKey<String>('editor-tab-page')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
