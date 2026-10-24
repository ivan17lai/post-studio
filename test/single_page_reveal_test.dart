import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/single_page_reveal.dart';

double offset(double p, int i) => singlePageRevealOffset(
  position: p,
  pageIndex: i,
  gap: 8,
  hiddenDistance: 600,
);

void main() {
  test(
    'reveal uses actual side space, including flush and nearly flush pages',
    () {
      for (final scale in [1.0, 0.99, 0.8, 0.4]) {
        final geometry = singlePageRevealGeometry(
          screenWidth: 400,
          pageWidth: 400,
          scale: scale,
        );
        final sideSpace = (400 - 400 * scale) / 2;
        expect(geometry.hiddenDistance * scale, closeTo(sideSpace, 1e-9));
        expect(geometry.gap * scale, closeTo(sideSpace.clamp(0, 8), 1e-9));
        // The resting neighbour's nearest edge lands exactly at the screen edge.
        expect(
          200 + 200 * scale + geometry.hiddenDistance * scale,
          closeTo(400, 1e-9),
        );
        if (scale == 1) {
          for (final p in [0.0, 0.25, 0.5, 0.75, 1.0]) {
            expect(
              singlePageRevealOffset(
                position: p,
                pageIndex: 1,
                gap: geometry.gap,
                hiddenDistance: geometry.hiddenDistance,
              ),
              0,
            );
          }
        }
      }
    },
  );
  test('rest hides neighbours and midpoint uses only the gap', () {
    expect(offset(1, 1), 0);
    expect(offset(1, 0), -600);
    expect(offset(1, 2), 600);
    expect(offset(1.5, 1), -4);
    expect(offset(1.5, 2), 4);
    expect(offset(2, 2), 0);
  });
  test(
    'retreat is gentler than linear and the anchor switch is continuous',
    () {
      for (var i = 0; i < 4; i++) {
        expect(offset(1.5 - 1e-8, i), closeTo(offset(1.5 + 1e-8, i), 0.0001));
      }
      final outgoingHalf = (offset(1.75, 1) + 6).abs();
      expect(outgoingHalf, lessThan((600 - 8) / 2));
      expect(outgoingHalf, greaterThan((600 - 8) / 3));
      // Same easing for the opposite swipe direction.
      expect(offset(1.25, 2), closeTo(-offset(1.75, 1), 1e-9));
    },
  );
  test('both participating pages move monotonically without bouncing', () {
    for (final index in [1, 2]) {
      double x(double p) => (index - p) * 390 + offset(p, index);
      for (var step = 1; step <= 100; step++) {
        expect(x(1 + step / 100), lessThan(x(1 + (step - 1) / 100)));
      }
    }
  });
}
