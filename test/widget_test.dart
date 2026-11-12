import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/app_settings.dart';
import 'package:igapp/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('igapp/hdr'),
          (_) async => <String, dynamic>{},
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('igapp/share'),
          (_) async => [],
        );
  });
  testWidgets('empty library opens the create dialog', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppSettingsController.instance.setLanguage('zh');
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('還沒有專案'), findsOneWidget);
    await tester.tap(find.text('新增專案'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });
  testWidgets('open a saved project and change its export selection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'projects_v1': [
        jsonEncode({
          'id': 'p',
          'name': '海邊散步',
          'pages': [
            {'id': 'a'},
            {'id': 'b'},
          ],
          'pageCount': 2,
        }),
      ],
    });
    await AppSettingsController.instance.setLanguage('zh');
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('海邊散步'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.ios_share_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部取消'));
    await tester.pumpAndSettle();
    expect(find.text('已選 0/2 頁'), findsOneWidget);
    await tester.tap(find.text('全選'));
    await tester.pumpAndSettle();
    expect(find.text('已選 2/2 頁'), findsOneWidget);
  });
}
