import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/canvas_corner_handle.dart';

void main() {
  for (final scale in [1.0, 0.5]) {
    testWidgets('all four icon-free corners resize without paging at $scale', (
      tester,
    ) async {
      final pages = PageController();
      addTearDown(pages.dispose);
      final values = <Offset, double>{};
      var ends = 0;
      const directions = [
        Offset(-1, -1),
        Offset(1, -1),
        Offset(-1, 1),
        Offset(1, 1),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Overlay.wrap(
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topLeft,
                child: PageView(
                  controller: pages,
                  children: [
                    Stack(
                      children: [
                        for (final d in directions)
                          Positioned(
                            left: d.dx < 0 ? 100 : 400,
                            top: d.dy < 0 ? 100 : 400,
                            child: CanvasCornerHandle(
                              visible: true,
                              direction: d,
                              photoSize: const Size(300, 300),
                              color: Colors.black,
                              onStart: () {},
                              onScale: (s) => values[d] = s,
                              onEnd: () => ends++,
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
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Icon), findsNothing);
      for (final d in directions) {
        final center =
            Offset(d.dx < 0 ? 100 : 400, d.dy < 0 ? 100 : 400) * scale;
        final gesture = await tester.startGesture(center + d * 20);
        await gesture.moveBy(d * 30);
        await tester.pump();
        await gesture.moveBy(d * 30);
        await tester.pump();
        // The moving corner travels the full diagonal, not half the diagonal
        // as it would for a center-based resize. Include the initial slop move.
        expect(values[d], closeTo(1 + 60 / (300 * scale), 1e-9));
        await gesture.moveBy(d * -100);
        await tester.pump();
        expect(values[d], lessThan(1));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(pages.page, 0);
      }
      expect(ends, 4);
    });
  }
}
