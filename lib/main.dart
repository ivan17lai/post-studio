import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_strings.dart';
import 'blank_page.dart';
import 'project_record.dart';
import 'theme_constants.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  static const String _projectsStorageKey = 'projects_v1';
  static const MethodChannel _shareChannel = MethodChannel('igapp/share');

  final List<ProjectRecord> _projects = <ProjectRecord>[];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _shareChannel.setMethodCallHandler(_handleShareMethodCall);
    _loadProjects();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePendingSharedImages());
    });
  }

  @override
  void dispose() {
    _shareChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _loadProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_projectsStorageKey) ?? <String>[];

    final projects = rawList
        .map(
          (item) => ProjectRecord.fromJson(
            jsonDecode(item) as Map<String, dynamic>,
          ),
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (!mounted) {
      return;
    }

    setState(() {
      _projects
        ..clear()
        ..addAll(projects);
      _isLoading = false;
    });
  }

  Future<void> _persistProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = _projects
        .map((project) => jsonEncode(project.toJson()))
        .toList();
    await prefs.setStringList(_projectsStorageKey, rawList);
  }

  Future<void> _upsertProject(ProjectRecord updatedProject) async {
    final index = _projects.indexWhere((item) => item.id == updatedProject.id);
    if (index == -1) {
      return;
    }

    if (mounted) {
      setState(() {
        _projects[index] = updatedProject;
      });
    } else {
      _projects[index] = updatedProject;
    }

    await _persistProjects();
  }

  Future<void> _deleteProject(ProjectRecord project) async {
    final strings = AppStrings.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F4),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: Color(0xFF6F6F6F),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  strings.t('deleteProject'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  strings.t('confirmDeleteCurrentProject'),
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Color(0xFF6A6A6A),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('cancel'),
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('deleteProject'),
                        isPrimary: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    setState(() {
      _projects.removeWhere((item) => item.id == project.id);
    });
    await _persistProjects();
  }

  Future<void> _showCreateProjectDialog() async {
    await _showCreateProjectDialogWithImportedImages();
  }

  Future<dynamic> _handleShareMethodCall(MethodCall call) async {
    if (call.method != 'sharedImagesReceived') {
      return null;
    }
    final paths = (call.arguments as List<dynamic>? ?? const <dynamic>[])
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList();
    await _showCreateProjectDialogWithImportedImages(paths);
    return null;
  }

  Future<void> _consumePendingSharedImages() async {
    final pending = await _shareChannel.invokeListMethod<dynamic>(
          'getPendingSharedImages',
        ) ??
        const <dynamic>[];
    final paths = pending.whereType<String>().where((item) => item.isNotEmpty).toList();
    if (paths.isEmpty) {
      return;
    }
    await _showCreateProjectDialogWithImportedImages(paths);
  }

  Future<void> _showCreateProjectDialogWithImportedImages([
    List<String> initialImportedSourcePaths = const <String>[],
  ]) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _StyledCreateProjectDialog(
        attachedPhotoCount: initialImportedSourcePaths.length,
      ),
    );

    if (!mounted || name == null || name.isEmpty) {
      return;
    }

    final project = ProjectRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
      pageCount: 1,
      pages: <ProjectPage>[
        ProjectPage.initial().copyWith(aspectWidth: 3, aspectHeight: 4),
      ],
      extras: const <String, dynamic>{},
    );

    setState(() {
      _projects.insert(0, project);
    });

    await _persistProjects();

    if (!mounted) {
      return;
    }

    await _openProject(
      project,
      initialImportedSourcePaths: initialImportedSourcePaths,
    );
  }

  Future<void> _openProject(
    ProjectRecord project, {
    List<String> initialImportedSourcePaths = const <String>[],
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BlankPage(
          project: project,
          onProjectChanged: _upsertProject,
          initialImportedSourcePaths: initialImportedSourcePaths,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final strings = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(backgroundColor: const Color(0xFFEAEAEA)),
      backgroundColor: const Color(0xFFEAEAEA),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateProjectDialog,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        shape: const CircleBorder(),
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: 20,
                left: 26,
                bottom: 20,
                right: 20,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.t('allProjects'),
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 100),
                      itemCount: _projects.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final project = _projects[index];
                        return _ProjectCard(
                          key: ValueKey(project.id),
                          width: width,
                          project: project,
                          onPressed: () => _openProject(project),
                          onLongPress: () => _deleteProject(project),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required super.key,
    required this.width,
    required this.project,
    required this.onPressed,
    required this.onLongPress,
  });

  final double width;
  final ProjectRecord project;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);

    return Center(
      child: SizedBox(
        width: width * 0.9,
        height: 80,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPressed,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F1F1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.folder_outlined,
                      color: Colors.black87,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          strings.t(
                            'projectMeta',
                            args: <String, String>{
                              'date': formatProjectDate(project.createdAt),
                              'count': '${project.pageCount}',
                            },
                          ),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog();

  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);

    return AlertDialog(
      title: Text(strings.t('createProject')),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: strings.t('enterProjectName'),
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.t('cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(strings.t('create'))),
      ],
    );
  }
}

class _StyledCreateProjectDialog extends StatefulWidget {
  const _StyledCreateProjectDialog({this.attachedPhotoCount = 0});

  final int attachedPhotoCount;

  @override
  State<_StyledCreateProjectDialog> createState() =>
      _StyledCreateProjectDialogState();
}

class _StyledCreateProjectDialogState
    extends State<_StyledCreateProjectDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F4F4),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Icon(
                Icons.create_new_folder_outlined,
                size: 20,
                color: Color(0xFF6F6F6F),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              strings.t('createProject'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F1F1F),
              ),
            ),
            if (widget.attachedPhotoCount > 0) ...[
              const SizedBox(height: 6),
              Text(
                strings.t(
                  'attachedPhotos',
                  args: <String, String>{
                    'count': '${widget.attachedPhotoCount}',
                  },
                ),
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6A6A6A),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: strings.t('enterProjectName'),
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _DialogActionButton(
                    label: strings.t('cancel'),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DialogActionButton(
                    label: strings.t('create'),
                    isPrimary: true,
                    onTap: _submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isPrimary ? kPrimaryAccentColor : Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1F1F1F),
          ),
        ),
      ),
    );
  }
}
