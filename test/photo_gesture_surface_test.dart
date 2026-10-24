import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/photo_gesture_surface.dart';

void main() {
  for (final canvasScale in [1.0, 0.5, 0.25]) {
    for (final direction in [-1.0, 1.0]) {
      testWidgets('photo owns horizontal drag $direction at $canvasScale', (
        tester,
      ) async {
        final pages = PageController(initialPage: 1);
        addTearDown(pages.dispose);
        var movement = Offset.zero;
        final completions = <bool>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Transform.scale(
                scale: canvasScale,
                alignment: Alignment.topLeft,
                child: PageView(
                  controller: pages,
                  children: [
                    const SizedBox.expand(),
                    Stack(
                      children: [
                        Positioned(
                          left: 100,
                          top: 100,
                          child: PhotoGestureSurface(
                            onStart: () {},
                            onMove: (delta) => movement += delta,
                            onPinch: (_) {},
                            onEnd: completions.add,
                            onTap: () {},
                            onDoubleTap: () {},
                            onLongPress: () {},
                            child: const SizedBox(width: 300, height: 300),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox.expand(),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Small successive moves reproduce the page recognizer winning before
        // the scale recognizer; the last move leaves the original photo bounds.
        final gesture = await tester.startGesture(
          const Offset(240, 240) * canvasScale,
        );
        for (final dx in [4.0, 8.0, 10.0, 20.0, 80.0, 300.0]) {
          await gesture.moveBy(Offset(dx * direction, 0));
          await tester.pump();
          expect(pages.page, 1);
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(movement.dx * direction, greaterThan(300 / canvasScale));
        expect(completions, [false]);
        expect(pages.page, 1);

        // A fresh fast swipe also belongs to the photo, even after cancellation.
        final cancelled = await tester.startGesture(
          const Offset(240, 240) * canvasScale,
        );
        await cancelled.moveBy(Offset(60 * direction, 2));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        await tester.flingFrom(
          const Offset(240, 240) * canvasScale,
          Offset(400 * direction, 0),
          2000,
        );
        await tester.pumpAndSettle();
        expect(pages.page, 1);
        expect(completions.length, 3);

        // Only a gesture starting outside the photo may turn a page.
        await tester.dragFrom(
          const Offset(600, 60) * canvasScale,
          Offset(700 * direction, 0) * canvasScale,
        );
        await tester.pumpAndSettle();
        expect(pages.page, direction < 0 ? 2 : 0);
      });
    }
  }

  testWidgets('photo selection, double tap and long press remain available', (
    tester,
  ) async {
    var taps = 0;
    var doubles = 0;
    var holds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PhotoGestureSurface(
            onStart: () {},
            onMove: (_) {},
            onPinch: (_) {},
            onEnd: (_) {},
            onTap: () => taps++,
            onDoubleTap: () => doubles++,
            onLongPress: () => holds++,
            child: const SizedBox(width: 300, height: 300),
          ),
        ),
      ),
    );
    final photo = find.byType(PhotoGestureSurface);
    await tester.tap(photo);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(taps, 1);
    await tester.tap(photo);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(photo);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(doubles, 1);
    await tester.longPress(photo);
    await tester.pumpAndSettle();
    expect(holds, 1);
  });

  for (final canvasScale in [1.0, 0.5]) {
    testWidgets('pinch and single finger gestures at $canvasScale', (
      tester,
    ) async {
      final pages = PageController();
      addTearDown(pages.dispose);
      var scale = 1.0;
      var movement = Offset.zero;
      final completions = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Transform.scale(
              scale: canvasScale,
              alignment: Alignment.topLeft,
              child: PageView(
                controller: pages,
                children: [
                  Stack(
                    children: [
                      Positioned(
                        left: 100,
                        top: 100,
                        child: PhotoGestureSurface(
                          onStart: () {},
                          onMove: (delta) => movement += delta,
                          onPinch: (value) => scale = value,
                          onEnd: completions.add,
                          child: const SizedBox(
                            width: 300,
                            height: 300,
                            child: ColoredBox(color: Colors.blue),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const ColoredBox(color: Colors.green),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = await tester.startGesture(
        Offset(170, 240) * canvasScale,
        pointer: 1,
      );
      final second = await tester.startGesture(
        Offset(310, 240) * canvasScale,
        pointer: 2,
      );
      await first.moveTo(Offset(130, 240) * canvasScale);
      await second.moveTo(Offset(350, 240) * canvasScale);
      await tester.pump();
      await first.moveTo(Offset(110, 240) * canvasScale);
      await second.moveTo(Offset(370, 240) * canvasScale);
      await tester.pump();
      expect(scale, greaterThan(1));
      expect(pages.page, 0);
      final expanded = scale;
      await first.moveTo(Offset(190, 240) * canvasScale);
      await second.moveTo(Offset(290, 240) * canvasScale);
      await tester.pump();
      expect(scale, lessThan(expanded));
      await second.up();
      final before = movement;
      await first.moveBy(Offset(0, 40) * canvasScale);
      await first.up();
      await tester.pumpAndSettle();
      expect(movement, before);
      expect(completions.last, isTrue);
      expect(pages.page, 0);
      final completedBefore = completions.length;
      final quickA = await tester.startGesture(
        Offset(170, 240) * canvasScale,
        pointer: 3,
      );
      final quickB = await tester.startGesture(
        Offset(310, 240) * canvasScale,
        pointer: 4,
      );
      await quickA.moveBy(const Offset(-40, 0));
      await quickB.moveBy(const Offset(40, 0));
      await quickB.up();
      await quickA.up();
      await tester.pumpAndSettle();
      expect(completions.length, completedBefore + 1);
      expect(completions.last, isTrue);
      final move = await tester.startGesture(Offset(200, 200) * canvasScale);
      await move.moveBy(const Offset(0, 40));
      await tester.pump();
      await move.moveBy(const Offset(0, 20));
      await move.up();
      await tester.pumpAndSettle();
      expect(movement.dy, greaterThan(before.dy));
      expect(completions.last, isFalse);
      await tester.dragFrom(
        Offset(600, 80) * canvasScale,
        Offset(-700, 0) * canvasScale,
      );
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
    });
  }
}
