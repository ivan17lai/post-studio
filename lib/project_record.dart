class ProjectRecord {
  const ProjectRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.pageCount,
    required this.pages,
    required this.extras,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final int pageCount;
  final List<ProjectPage> pages;
  final Map<String, dynamic> extras;

  ProjectRecord copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    int? pageCount,
    List<ProjectPage>? pages,
    Map<String, dynamic>? extras,
  }) {
    return ProjectRecord(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      pageCount: pageCount ?? this.pageCount,
      pages: pages ?? this.pages,
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
      'extras': extras,
    };
  }

  factory ProjectRecord.fromJson(Map<String, dynamic> json) {
    final rawPages = (json['pages'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    final pages = rawPages.map(ProjectPage.fromJson).toList();

    return ProjectRecord(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      pageCount: json['pageCount'] as int? ?? pages.length,
      pages: pages.isEmpty ? <ProjectPage>[ProjectPage.initial()] : pages,
      extras: Map<String, dynamic>.from(
        json['extras'] as Map? ?? <String, dynamic>{},
      ),
    );
  }
}

class ProjectPage {
  const ProjectPage({
    required this.id,
    required this.title,
    required this.type,
    required this.aspectWidth,
    required this.aspectHeight,
    required this.elements,
    required this.extras,
  });

  final String id;
  final String title;
  final String type;
  final double aspectWidth;
  final double aspectHeight;
  final List<CanvasElement> elements;
  final Map<String, dynamic> extras;

  factory ProjectPage.initial([int index = 1]) {
    return ProjectPage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: '第 $index 頁',
      type: 'page',
      aspectWidth: 4,
      aspectHeight: 5,
      elements: const <CanvasElement>[],
      extras: const <String, dynamic>{},
    );
  }

  ProjectPage copyWith({
    String? id,
    String? title,
    String? type,
    double? aspectWidth,
    double? aspectHeight,
    List<CanvasElement>? elements,
    Map<String, dynamic>? extras,
  }) {
    return ProjectPage(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      aspectWidth: aspectWidth ?? this.aspectWidth,
      aspectHeight: aspectHeight ?? this.aspectHeight,
      elements: elements ?? this.elements,
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
      'elements': elements.map((element) => element.toJson()).toList(),
      'extras': extras,
    };
  }

  factory ProjectPage.fromJson(Map<String, dynamic> json) {
    final rawElements = (json['elements'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return ProjectPage(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: json['type'] as String? ?? 'page',
      aspectWidth: (json['aspectWidth'] as num?)?.toDouble() ?? 4,
      aspectHeight: (json['aspectHeight'] as num?)?.toDouble() ?? 5,
      elements: rawElements.map(CanvasElement.fromJson).toList(),
      extras: Map<String, dynamic>.from(
        json['extras'] as Map? ?? <String, dynamic>{},
      ),
    );
  }
}

class CanvasElement {
  const CanvasElement({
    required this.id,
    required this.type,
    required this.pageId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.allowCrossPage,
    required this.data,
  });

  final String id;
  final String type;
  final String pageId;
  final double x;
  final double y;
  final double width;
  final double height;
  final bool allowCrossPage;
  final Map<String, dynamic> data;

  factory CanvasElement.image({required String pageId}) {
    return CanvasElement(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: 'image',
      pageId: pageId,
      x: 0.12,
      y: 0.12,
      width: 0.36,
      height: 0.36,
      allowCrossPage: true,
      data: const <String, dynamic>{'src': '', 'aspectRatio': 1.0},
    );
  }

  ProjectElementBounds get bounds =>
      ProjectElementBounds(x: x, y: y, width: width, height: height);

  CanvasElement copyWith({
    String? id,
    String? type,
    String? pageId,
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
      pageId: pageId ?? this.pageId,
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
      'pageId': pageId,
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

    return CanvasElement(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'image',
      pageId: json['pageId'] as String? ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 0.12,
      y: (json['y'] as num?)?.toDouble() ?? 0.12,
      width: (json['width'] as num?)?.toDouble() ?? 0.36,
      height: (json['height'] as num?)?.toDouble() ?? 0.36,
      allowCrossPage: json['allowCrossPage'] as bool? ?? true,
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
