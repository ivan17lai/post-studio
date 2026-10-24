import 'app_settings.dart';
import 'project_record.dart';

extension PageTemplateMargin on ProjectPage {
  bool get templateMarginEnabled =>
      extras['templateMarginEnabled'] as bool? ?? false;
  String get templateMarginSize {
    final size = extras['templateMarginSize'] as String?;
    return kTemplateMarginRatios.containsKey(size)
        ? size!
        : kTemplateMarginSizeMedium;
  }

  double get templateMarginRatio =>
      templateMarginEnabled ? kTemplateMarginRatios[templateMarginSize]! : 0;

  ProjectPage withTemplateMargin({bool? enabled, String? size}) => copyWith(
    extras: {
      ...extras,
      'templateMarginEnabled': enabled ?? templateMarginEnabled,
      'templateMarginSize': kTemplateMarginRatios.containsKey(size)
          ? size
          : templateMarginSize,
    },
  );
}

/// Freeze the legacy global preference on each page without changing geometry.
ProjectRecord migratePageTemplateMargins(
  ProjectRecord project, {
  required bool enabled,
  required String size,
}) => project.copyWith(
  pages: [
    for (final page in project.pages)
      page.withTemplateMargin(
        enabled: page.extras.containsKey('templateMarginEnabled')
            ? page.templateMarginEnabled
            : enabled,
        size: page.extras.containsKey('templateMarginSize')
            ? page.templateMarginSize
            : size,
      ),
  ],
);

ProjectRecord updatePageTemplateMargin(
  ProjectRecord project,
  int pageIndex, {
  bool? enabled,
  String? size,
}) => project.copyWith(
  pages: [
    for (var i = 0; i < project.pages.length; i++)
      i == pageIndex
          ? project.pages[i].withTemplateMargin(enabled: enabled, size: size)
          : project.pages[i],
  ],
);
