import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:igapp/blank_page.dart';
import 'package:igapp/project_record.dart';
import 'package:igapp/app_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const gallery = MethodChannel('igapp/gallery');

  testWidgets('native forward/reverse/subset pixels and real editor export', (
    tester,
  ) async {
    await AppSettingsController.instance.setLanguage('zh');
    final dir = await getApplicationDocumentsDirectory();
    final source = img.Image(width: 300, height: 100);
    img.fillRect(
      source,
      x1: 0,
      y1: 0,
      x2: 99,
      y2: 99,
      color: img.ColorRgb8(255, 0, 0),
    );
    img.fillRect(
      source,
      x1: 100,
      y1: 0,
      x2: 199,
      y2: 99,
      color: img.ColorRgb8(0, 255, 0),
    );
    img.fillRect(
      source,
      x1: 200,
      y1: 0,
      x2: 299,
      y2: 99,
      color: img.ColorRgb8(0, 0, 255),
    );
    final sourceFile = File('${dir.path}/cross_page_fixture.png');
    await sourceFile.writeAsBytes(img.encodePng(source));

    for (final ratio in [
      const Size(4, 5),
      const Size(9, 16),
      const Size(9.5, 16),
    ]) {
      for (final mode in ['off', 'on', 'enhanced']) {
        final pages = List.generate(
          3,
          (_) => <String, dynamic>{
            'aspectWidth': ratio.width,
            'aspectHeight': ratio.height,
            'backgroundColor': 0xFFFFFFFF,
          },
        );
        final elements = [
          <String, dynamic>{
            'type': 'image',
            'src': sourceFile.path,
            'x': 0.0,
            'y': 0.0,
            'width': 3.0,
            'height': 1.0,
            'aspectRatio': 3 * ratio.width / ratio.height,
            'anchorPageIndex': 0,
            'allowCrossPage': true,
          },
        ];
        final forward = <int, Uint8List>{};
        for (final order in [
          [0, 1, 2],
          [2, 1, 0],
          [2, 1],
        ]) {
          for (final index in order) {
            final bytes = await gallery
                .invokeMethod<Uint8List>('renderPageToJpgNative', {
                  'exportWidth': 120,
                  'targetPageIndex': index,
                  'hdrMode': mode,
                  'pages': pages,
                  'elements': elements,
                });
            expect(bytes, isNotNull);
            final decoded = img.decodeJpg(bytes!)!;
            final pixel = decoded.getPixel(
              decoded.width ~/ 2,
              decoded.height ~/ 2,
            );
            final channels = [pixel.r, pixel.g, pixel.b];
            expect(channels[index], greaterThan(240));
            expect(channels[(index + 1) % 3], lessThan(15));
            if (forward.containsKey(index)) {
              expect(
                bytes,
                orderedEquals(forward[index]!),
                reason: 'mode=$mode ratio=$ratio page=$index',
              );
            } else {
              forward[index] = bytes;
            }
            await File(
              '${dir.path}/check_${ratio.width}_${mode}_$index.jpg',
            ).writeAsBytes(bytes);
          }
        }
      }
    }

    // Run the real editor's export button and gallery writes, not just the renderer.
    final pages = List.generate(
      3,
      (i) => ProjectPage.initial().copyWith(
        id: 'page-$i',
        aspectWidth: 9,
        aspectHeight: 16,
      ),
    );
    final project = ProjectRecord(
      id: 'export-regression',
      name: 'export-regression',
      createdAt: DateTime(2026, 10, 16),
      pageCount: 3,
      pages: pages,
      elements: [
        CanvasElement(
          id: 'stripe',
          type: 'image',
          x: 0,
          y: 0,
          width: 3,
          height: 1,
          allowCrossPage: true,
          data: {
            'src': sourceFile.path,
            'originalSrc': sourceFile.path,
            'aspectRatio': 27 / 16,
            'allowCrossPage': true,
          },
        ),
      ],
      extras: {},
    );
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          home: BlankPage(project: project, onProjectChanged: (_) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final reverse in [true, false]) {
      await tester.tap(find.byIcon(Icons.ios_share_rounded).first);
      await tester.pumpAndSettle();
      if (!reverse) {
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_ExportReverseSwitch',
          ),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byIcon(Icons.ios_share_rounded).last);
      for (var i = 0; i < 180 && find.text('完成').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('完成'), findsOneWidget);
      expect(find.textContaining('匯出失敗'), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    }
    if (const bool.fromEnvironment('BASELINE_EXPORT_CHECK')) return;
    Future<void> capture(String name) async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${dir.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      await gallery.invokeMethod<bool>('saveJpgToGallery', {
        'bytes': Uint8List.fromList(
          img.encodeJpg(
            img.decodePng(bytes.buffer.asUint8List())!,
            quality: 100,
          ),
        ),
        'name': 'verification-$name',
      });
      image.dispose();
    }

    await tester.tap(find.text('頁面').last);
    await tester.pumpAndSettle();
    await capture('page-ratios');
    await tester.tap(find.text('自訂').first);
    await tester.pumpAndSettle();
    await capture('custom-ratio');
    await tester.enterText(find.byType(TextField).first, '9.5');
    await tester.enterText(find.byType(TextField).last, '16');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('繼續'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
