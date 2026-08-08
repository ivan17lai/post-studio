import 'app_strings.dart';

/// A project: an ordered run of pages, plus one flat list of the elements laid
/// out across them.
///
/// Elements live here rather than on a page. They used to be stored per page,
/// under whichever page happened to be current when they were added, which
/// made ownership arbitrary as soon as an element spanned a seam: the layers
/// panel only listed a page's own elements, so a photo covering two pages was
/// invisible on one of them, and painting order was fixed at
/// (page index, element index), which meant a cross-page photo could never sit
/// above the next page's content.
///
/// The per-page split never bought anything at render time either: every
/// renderer walked pages then elements and composited in exactly that order,
/// which is this flat list with a partition drawn through it.
class ProjectRecord {
  const ProjectRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.pageCount,
    required this.pages,
    required this.elements,
    required this.extras,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final int pageCount;
  final List<ProjectPage> pages;

  /// Every element in the project, back to front. List order *is* z-order, and
  /// it spans pages, so an element anchored to one page can sit above one
  /// anchored to another.
  final List<CanvasElement> elements;

  final Map<String, dynamic> extras;

  ProjectRecord copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    int? pageCount,
    List<ProjectPage>? pages,
    List<CanvasElement>? elements,
    Map<String, dynamic>? extras,
  }) {
    return ProjectRecord(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      pageCount: pageCount ?? this.pageCount,
      pages: pages ?? this.pages,
      elements: elements ?? this.elements,
      extras: extras ?? this.extras,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'pageCount': pageCount,
      'pages': pages.map((page) => page.toJson()).toList(),
      'elements': elements.map((element) => element.toJson()).toList(),
      'extras': extras,
    };
  }

  factory ProjectRecord.fromJson(Map<String, dynamic> json) {
    final rawPages = (json['pages'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    final pages = rawPages.map(ProjectPage.fromJson).toList();
    final rawElements = json['elements'] as List<dynamic>?;

    final elements = rawElements == null
        ? _elementsFromPerPageFormat(rawPages)
        : rawElements
              .map(
                (item) =>
                    CanvasElement.fromJson(Map<String, dynamic>.from(item as Map)),
              )
              .toList();

    return ProjectRecord(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      pageCount: json['pageCount'] as int? ?? pages.length,
      pages: pages.isEmpty ? <ProjectPage>[ProjectPage.initial()] : pages,
      elements: elements,
      extras: Map<String, dynamic>.from(
        json['extras'] as Map? ?? <String, dynamic>{},
      ),
    );
  }

  /// Reads a project saved before elements moved off the pages.
  ///
  /// Concatenating the pages' lists in page order reproduces the old painting
  /// order exactly, so z-order survives the move unchanged. `x` was relative to
  /// the owning page, so it shifts by that page's index to become absolute.
  static List<CanvasElement> _elementsFromPerPageFormat(
    List<Map<String, dynamic>> rawPages,
  ) {
    final elements = <CanvasElement>[];
    for (var pageIndex = 0; pageIndex < rawPages.length; pageIndex++) {
      final rawElements =
          (rawPages[pageIndex]['elements'] as List<dynamic>? ?? <dynamic>[])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList();
      for (final rawElement in rawElements) {
        final element = CanvasElement.fromJson(rawElement);
        elements.add(element.copyWith(x: element.x + pageIndex));
      }
    }
    return elements;
  }
}

/// A page: a frame the elements are viewed and exported through. Position,
/// shape and background only — the elements themselves live on the project.
class ProjectPage {
  const ProjectPage({
    required this.id,
    required this.title,
    required this.type,
    required this.aspectWidth,
    required this.aspectHeight,
    required this.extras,
  });

  final String id;
  final String title;
  final String type;
  final double aspectWidth;
  final double aspectHeight;
  final Map<String, dynamic> extras;

  factory ProjectPage.initial([int index = 1]) {
    return ProjectPage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: AppStrings.system.t(
        'pageTitle',
        args: <String, String>{'index': '$index'},
      ),
      type: 'page',
      aspectWidth: 4,
      aspectHeight: 5,
      extras: const <String, dynamic>{},
    );
  }

  ProjectPage copyWith({
    String? id,
    String? title,
    String? type,
    double? aspectWidth,
    double? aspectHeight,
    Map<String, dynamic>? extras,
  }) {
    return ProjectPage(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      aspectWidth: aspectWidth ?? this.aspectWidth,
      aspectHeight: aspectHeight ?? this.aspectHeight,
      extras: extras ?? this.extras,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'type': type,
      'aspectWidth': aspectWidth,
      'aspectHeight': aspectHeight,
      'extras': extras,
    };
  }

  factory ProjectPage.fromJson(Map<String, dynamic> json) {
    return ProjectPage(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: json['type'] as String? ?? 'page',
      aspectWidth: (json['aspectWidth'] as num?)?.toDouble() ?? 4,
      aspectHeight: (json['aspectHeight'] as num?)?.toDouble() ?? 5,
      extras: Map<String, dynamic>.from(
        json['extras'] as Map? ?? <String, dynamic>{},
      ),
    );
  }
}

/// Default for `allowCrossPage` when a stored element predates the field.
///
/// Must agree with [CanvasElement.image] and [CanvasElement.text]. It did not:
/// `fromJson` defaulted everything to `true`, so every legacy text element came
/// back cross-page enabled even though the factory creates them page-bound.
bool defaultAllowCrossPage(String type) => type != 'text';

class CanvasElement {
  const CanvasElement({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.allowCrossPage,
    required this.data,
  });

  final String id;
  final String type;

  /// Left edge in document space, in page widths: 0 is the first page's left
  /// edge, 1 the second page's, and so on. A value of 1.5 sits halfway across
  /// the second page; 0.6 with width 0.8 straddles the first seam.
  ///
  /// This replaced a page-relative x plus a stored `pageId`. Which page an
  /// element belongs to is now derived from where it starts, so it cannot go
  /// stale, and an element spanning pages no longer has to pick one to be
  /// filed under.
  final double x;

  /// Top edge as a fraction of page height. Pages do not stack, so this stays
  /// page-relative.
  final double y;

  /// Width in page widths: 1.0 is exactly one page across.
  final double width;

  final double height;
  final bool allowCrossPage;
  final Map<String, dynamic> data;

  factory CanvasElement.image({double x = 0.12, double y = 0.12}) {
    return CanvasElement(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: 'image',
      x: x,
      y: y,
      width: 0.36,
      height: 0.36,
      allowCrossPage: true,
      data: const <String, dynamic>{'src': '', 'aspectRatio': 1.0},
    );
  }

  factory CanvasElement.text({double x = 0.14, double y = 0.18}) {
    return CanvasElement(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: 'text',
      x: x,
      y: y,
      width: 0.62,
      height: 0.08,
      allowCrossPage: false,
      data: const <String, dynamic>{
        'text': 'Text',
        'fontSizeRatio': 0.075,
        'colorValue': 0xFF111111,
      },
    );
  }

  ProjectElementBounds get bounds =>
      ProjectElementBounds(x: x, y: y, width: width, height: height);

  CanvasElement copyWith({
    String? id,
    String? type,
    double? x,
    double? y,
    double? width,
    double? height,
    bool? allowCrossPage,
    Map<String, dynamic>? data,
  }) {
    return CanvasElement(
      id: id ?? this.id,
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      allowCrossPage: allowCrossPage ?? this.allowCrossPage,
      data: data ?? this.data,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'allowCrossPage': allowCrossPage,
      'data': data,
    };
  }

  factory CanvasElement.fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(
      json['data'] as Map? ?? <String, dynamic>{},
    );
    final type = json['type'] as String? ?? 'image';

    return CanvasElement(
      id: json['id'] as String? ?? '',
      type: type,
      x: (json['x'] as num?)?.toDouble() ?? 0.12,
      y: (json['y'] as num?)?.toDouble() ?? 0.12,
      width: (json['width'] as num?)?.toDouble() ?? 0.36,
      height: (json['height'] as num?)?.toDouble() ?? 0.36,
      allowCrossPage:
          json['allowCrossPage'] as bool? ?? defaultAllowCrossPage(type),
      data: {
        'src': data['src'] ?? '',
        'aspectRatio': (data['aspectRatio'] as num?)?.toDouble() ?? 1.0,
        ...data,
      },
    );
  }
}

class ProjectElementBounds {
  const ProjectElementBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

String formatProjectDate(DateTime dateTime) {
  final year = dateTime.year.toString().padLeft(4, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final day = dateTime.day.toString().padLeft(2, '0');
  return '$year/$month/$day';
}
