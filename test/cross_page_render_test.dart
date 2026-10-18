import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:igapp/blank_page.dart';

void main() {
  test(
    'SDR fallback retains cross-page slices in reverse and partial exports',
    () {
      final source = img.Image(width: 120, height: 10);
      for (var x = 0; x < 120; x++) {
        for (var y = 0; y < 10; y++) {
          source.setPixelRgb(
            x,
            y,
            x < 40 ? 255 : 0,
            x >= 40 && x < 80 ? 255 : 0,
            x >= 80 ? 255 : 0,
          );
        }
      }
      final payload = <String, dynamic>{
        'exportWidth': 2400,
        'pages': List.generate(
          3,
          (_) => <String, dynamic>{'aspectWidth': 4.0, 'aspectHeight': 1.0},
        ),
        'images': <String, Uint8List>{
          'fixture': Uint8List.fromList(img.encodePng(source)),
        },
        'elements': [
          <String, dynamic>{
            'type': 'image',
            'src': 'fixture',
            'x': 0.0,
            'y': 0.0,
            'width': 3.0,
            'height': 1.0,
            'aspectRatio': 12.0,
            'anchorPageIndex': 0,
            'allowCrossPage': true,
          },
        ],
      };
      final forward = <int, Uint8List>{};
      for (final order in [
        [0, 1, 2],
        [2, 1, 0],
        [2, 1],
      ]) {
        for (final index in order) {
          final bytes = renderSelectedPageJpgBytes({
            ...payload,
            'targetPageIndex': index,
          });
          final image = img.decodeJpg(bytes)!;
          final pixel = image.getPixel(image.width ~/ 2, image.height ~/ 2);
          expect([pixel.r, pixel.g, pixel.b][index], greaterThan(240));
          expect([pixel.r, pixel.g, pixel.b][(index + 1) % 3], lessThan(15));
          if (forward.containsKey(index)) {
            expect(bytes, orderedEquals(forward[index]!));
          } else {
            forward[index] = bytes;
          }
        }
      }
    },
  );
}
