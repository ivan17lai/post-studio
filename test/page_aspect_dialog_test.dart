import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/blank_page.dart';
import 'package:igapp/project_record.dart';
import 'package:igapp/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettingsController.instance.setLanguage('zh');
  });
  testWidgets('custom ratio validates input, returns decimals and cancels', (
    tester,
  ) async {
    Size? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showCustomPageAspectDialog(
                  context,
                  ProjectPage.initial(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    for (final invalid in ['', '0', '-1', 'NaN', 'Infinity']) {
      await tester.enterText(fields.first, invalid);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('請輸入大於 0 的寬與高'), findsOneWidget);
      expect(result, isNull);
    }
    await tester.enterText(fields.first, '9.5');
    await tester.enterText(fields.last, '16');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(result, const Size(9.5, 16));
    final saved = ProjectPage.fromJson(
      ProjectPage.initial()
          .copyWith(aspectWidth: result!.width, aspectHeight: result!.height)
          .toJson(),
    );
    expect(saved.aspectWidth, 9.5);
    expect(saved.aspectHeight, 16);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
