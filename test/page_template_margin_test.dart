import 'package:flutter_test/flutter_test.dart';
import 'package:igapp/page_template_margin.dart';
import 'package:igapp/project_record.dart';

ProjectRecord project() => ProjectRecord(
  id: 'p',
  name: 'Margins',
  createdAt: DateTime(2026),
  pageCount: 2,
  pages: [
    ProjectPage.initial().copyWith(id: 'a', extras: {'background': 123}),
    ProjectPage.initial(2).copyWith(id: 'b'),
  ],
  elements: [],
  extras: {},
);

void main() {
  test(
    'toggle and thickness affect only one page and survive serialization',
    () {
      final initial = migratePageTemplateMargins(
        project(),
        enabled: false,
        size: 'medium',
      );
      final changed = updatePageTemplateMargin(
        initial,
        0,
        enabled: true,
        size: 'large',
      );
      expect(identical(changed.pages[1], initial.pages[1]), isTrue);
      expect(initial.pages[0].templateMarginEnabled, isFalse);
      final saved = ProjectRecord.fromJson(changed.toJson());
      expect(saved.pages[0].templateMarginRatio, 0.08);
      expect(saved.pages[1].templateMarginRatio, 0);
      expect(saved.pages[0].extras['background'], 123);
      final off = updatePageTemplateMargin(saved, 0, enabled: false);
      expect(off.pages[0].templateMarginSize, 'large');
      expect(off.pages[0].templateMarginRatio, 0);
      expect(
        updatePageTemplateMargin(
          off,
          0,
          enabled: true,
        ).pages[0].templateMarginRatio,
        0.08,
      );
    },
  );
  test(
    'migration freezes legacy defaults without overriding individual settings',
    () {
      final migrated = migratePageTemplateMargins(
        project(),
        enabled: true,
        size: 'small',
      );
      final changed = updatePageTemplateMargin(
        migrated,
        1,
        enabled: false,
        size: 'large',
      );
      final reopened = migratePageTemplateMargins(
        ProjectRecord.fromJson(changed.toJson()),
        enabled: false,
        size: 'medium',
      );
      expect(reopened.pages[0].templateMarginRatio, 0.03);
      expect(reopened.pages[1].templateMarginRatio, 0);
      expect(reopened.pages[1].templateMarginSize, 'large');
    },
  );
  test('settings travel with their page on reorder and copy', () {
    final changed = updatePageTemplateMargin(
      project(),
      0,
      enabled: true,
      size: 'small',
    );
    final reordered = changed.copyWith(pages: changed.pages.reversed.toList());
    expect(reordered.pages[0].templateMarginEnabled, isFalse);
    expect(reordered.pages[1].templateMarginRatio, 0.03);
    expect(reordered.pages[1].copyWith(id: 'copy').templateMarginRatio, 0.03);
  });
  test('blank new pages use independent defaults', () {
    final existing = updatePageTemplateMargin(
      project(),
      0,
      enabled: true,
      size: 'large',
    );
    final added = existing.copyWith(
      pages: [...existing.pages, ProjectPage.initial(3)],
    );
    final saved = migratePageTemplateMargins(
      added,
      enabled: false,
      size: 'medium',
    );
    expect(saved.pages[0].templateMarginRatio, 0.08);
    expect(saved.pages[2].templateMarginEnabled, isFalse);
  });
}
