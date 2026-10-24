import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:igapp/app_settings.dart';
import 'package:igapp/blank_page.dart';
import 'package:igapp/canvas_geometry.dart';
import 'package:igapp/photo_gesture_surface.dart';
import 'package:igapp/project_record.dart';
import 'package:igapp/template_layout.dart';

Finder typeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

void main() {
  for (final preview in [false, true]) {
    for (final scenario in [
      'ordinary addition',
      'addition while changing page',
      'ordinary replacement',
      'fill replacement',
      'apply fill',
      'selection clears after paging',
    ]) {
      testWidgets('$scenario in ${preview ? 'preview' : 'single'} mode', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        await AppSettingsController.instance.setLanguage('zh');
        final fixture = File('work/photo-placement-fixture.png').absolute;
        await tester.runAsync(() async {
          await fixture.parent.create(recursive: true);
          await fixture.writeAsBytes(
            img.encodePng(img.Image(width: 80, height: 100)),
          );
        });
        final startsOnFirst = scenario == 'selection clears after paging';
        final adding =
            scenario == 'ordinary addition' ||
            scenario == 'addition while changing page';
        final initial = CanvasElement(
          id: 'photo',
          type: 'image',
          x: (startsOnFirst ? 0 : 2) + 0.12,
          y: 0.2,
          width: 0.36,
          height: 0.36,
          allowCrossPage: false,
          data: {
            'src': scenario == 'apply fill' ? fixture.path : '',
            'aspectRatio': 0.8,
            'originalAspectRatio': 0.8,
            'isUltraHdr': false,
            if (scenario == 'fill replacement') 'templateSlot': 'fill',
          },
        );
        var saved = ProjectRecord(
          id: 'audit',
          name: 'Placement audit',
          createdAt: DateTime(2026),
          pageCount: 3,
          pages: [
            for (var i = 0; i < 3; i++)
              ProjectPage(
                id: 'p$i',
                title: 'Page $i',
                type: 'page',
                aspectWidth: 4,
                aspectHeight: 5,
                extras: const {},
              ),
          ],
          elements: adding ? [] : [initial],
          extras: {
            'importedImages': [fixture.path],
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: BlankPage(
              project: saved,
              onProjectChanged: (project) async {
                saved = project;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (preview) {
          final dynamic toggle = tester.widget(typeName('_SlideSwitch'));
          toggle.onChanged(true);
          await tester.pumpAndSettle();
        }
        PageController? controller;
        ScrollController? previewController;
        if (preview) {
          previewController = tester
              .widget<SingleChildScrollView>(
                find
                    .ancestor(
                      of: typeName('_PreviewCanvasStrip'),
                      matching: find.byType(SingleChildScrollView),
                    )
                    .first,
              )
              .controller!;
        } else {
          controller = tester
              .widget<PageView>(find.byKey(const ValueKey('single-page-pager')))
              .controller!;
        }
        void goToThirdPage() {
          if (preview) {
            previewController!.jumpTo(800 * 0.78 * 2);
          } else {
            controller!.jumpToPage(2);
          }
        }

        if (!startsOnFirst) {
          goToThirdPage();
          await tester.pumpAndSettle();
        }
        if (scenario == 'apply fill') {
          final dynamic tab = tester.widget(typeName('_TemplateTabPage').first);
          tab.onApplyTemplate(
            const TemplateOption(
              id: 'page_fill',
              label: 'fill',
              isContainFill: true,
            ),
          );
          await tester.pumpAndSettle();
        } else {
          if (adding) {
            await tester.tap(find.text('元素'));
          } else {
            tester
                .widget<PhotoGestureSurface>(find.byType(PhotoGestureSurface))
                .onTap!();
          }
          await tester.pumpAndSettle();
          if (startsOnFirst) {
            goToThirdPage();
            await tester.pumpAndSettle();
            expect(find.text('更換圖片'), findsNothing);
          }
          final dynamic tab = tester.widget(typeName('_ElementTabPage').first);
          await tester.runAsync(() async {
            final pending = tab.onTapImportedImage(fixture.path);
            if (scenario == 'addition while changing page') {
              if (preview) {
                previewController!.jumpTo(0);
              } else {
                controller!.jumpToPage(0);
              }
            }
            await pending;
          });
          await tester.pumpAndSettle();
        }
        final image = startsOnFirst
            ? saved.elements.singleWhere((element) => element.id != initial.id)
            : saved.elements.single;
        if (startsOnFirst) {
          expect(saved.elements.length, 2);
          final previous = saved.elements.singleWhere(
            (element) => element.id == initial.id,
          );
          expect(previous.toJson(), initial.toJson());
        }
        expect(image.data['src'], fixture.path);
        if (!preview) {
          expect(
            controller!.page,
            scenario == 'addition while changing page' ? 0 : 2,
          );
        }
        if (scenario == 'addition while changing page') {
          expect(find.text('更換圖片'), findsNothing);
        }
        final actualPage = anchorPageIndex(image, saved.pages.length);
        expect(actualPage, 2);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
