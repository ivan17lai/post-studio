import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'blank_page.dart';
import 'project_record.dart';

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

  final List<ProjectRecord> _projects = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_projectsStorageKey) ?? <String>[];

    final projects =
        rawList
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

  Future<void> _showCreateProjectDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateProjectDialog(),
    );

    if (!mounted || name == null || name.isEmpty) {
      return;
    }

    final project = ProjectRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
      pageCount: 1,
      pages: <ProjectPage>[ProjectPage.initial()],
      extras: const <String, dynamic>{},
    );

    setState(() {
      _projects.insert(0, project);
    });

    await _persistProjects();
  }

  Future<void> _openProject(ProjectRecord project) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            BlankPage(project: project, onProjectChanged: _upsertProject),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;

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
            const Padding(
              padding: EdgeInsets.only(
                top: 20,
                left: 26,
                bottom: 20,
                right: 20,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '所有專案',
                  textAlign: TextAlign.left,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
  });

  final double width;
  final ProjectRecord project;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
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
                          '建立時間 ${formatProjectDate(project.createdAt)} ・ 總頁數 ${project.pageCount}',
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
    return AlertDialog(
      title: const Text('新增專案'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          hintText: '輸入專案名稱',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('建立')),
      ],
    );
  }
}
