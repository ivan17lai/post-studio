import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_strings.dart';
import 'app_settings.dart';
import 'blank_page.dart';
import 'project_record.dart';
import 'settings_page.dart';
import 'theme_constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettingsController.instance.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettingsController.instance,
      builder: (context, _) {
        final primary = AppSettingsController.instance.primaryColor;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: primary,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFEAEAEA),
          ),
          home: const MainPage(),
        );
      },
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
  static const MethodChannel _galleryChannel = MethodChannel('igapp/gallery');

  final List<ProjectRecord> _projects = <ProjectRecord>[];
  bool _isLoading = true;
  bool _isAiCreating = false;
  bool _hasUpdate = false;
  String? _latestVersionUrl;
  String? _newVersionString;
  final String _appVersion = kAppDisplayVersion;

  @override
  void initState() {
    super.initState();
    _shareChannel.setMethodCallHandler(_handleShareMethodCall);
    AppSettingsController.instance.addListener(_handleSettingsChanged);
    _loadProjects();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePendingSharedImages());
      unawaited(_checkForUpdates(isSilent: true));
    });
  }

  @override
  void dispose() {
    _shareChannel.setMethodCallHandler(null);
    AppSettingsController.instance.removeListener(_handleSettingsChanged);
    super.dispose();
  }

  void _handleSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
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
    final pending =
        await _shareChannel.invokeListMethod<dynamic>(
          'getPendingSharedImages',
        ) ??
        const <dynamic>[];
    final paths = pending
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList();
    if (paths.isEmpty) {
      return;
    }
    await _showCreateProjectDialogWithImportedImages(paths);
  }

  Future<void> _showCreateProjectDialogWithImportedImages([
    List<String> initialImportedSourcePaths = const <String>[],
  ]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          _StyledCreateProjectDialog(initialPaths: initialImportedSourcePaths),
    );

    if (!mounted || result == null) {
      return;
    }

    final name = result['name'] as String? ?? '';
    final paths = List<String>.from(result['paths'] as Iterable? ?? []);
    final isAi = result['isAi'] as bool? ?? false;

    if (isAi && paths.isNotEmpty) {
      await _createProjectWithAiLayout(name, paths);
      return;
    }

    final project = ProjectRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.isEmpty ? AppStrings.of(context).t('unnamedProject') : name,
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

    await _openProject(project, initialImportedSourcePaths: paths);
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

  Future<void> _createProjectWithAiLayout(
    String projectName,
    List<String> imagePaths,
  ) async {
    final settings = AppSettingsController.instance;
    final strings = AppStrings.of(context);
    if (!settings.aiSortEnabled || !settings.hasGeminiApiKey) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('enableAiFirst'))));
      return;
    }

    setState(() {
      _isAiCreating = true;
    });

    try {
      final projectId = DateTime.now().microsecondsSinceEpoch.toString();
      final preparedPaths = <({String displayPath, String originalPath})>[];

      for (final path in imagePaths) {
        final prepared = await _prepareImageAsset(projectId, path);
        preparedPaths.add(prepared);
      }

      // Send to Gemini
      final parts = <Map<String, dynamic>>[
        <String, String>{
          'text':
              'You are an AI layout designer. Arrange these N images into carousel pages. '
              'For each page, you can choose to layout either 1 or 2 images. '
              'The layout style for each page MUST be either: '
              '1. "fill": A single image layout. '
              '2. "split": A two-image layout (split top and bottom). '
              'For each page, write a short, creative description sentence describing the content or narrative of this page in Traditional Chinese. '
              'The description will be displayed above the images. '
              'Return ONLY JSON in this exact format: '
              '{"pages":[{"layout":"fill" or "split","imageIndexes":[0] or [1,2],"description":"one sentence description"}]}. '
              'The imageIndexes arrays across all pages must use every original image index (0-based) exactly once.',
        },
      ];

      for (var i = 0; i < preparedPaths.length; i++) {
        final bytes = await File(preparedPaths[i].displayPath).readAsBytes();
        parts
          ..add(<String, String>{'text': 'Image index $i'})
          ..add(<String, dynamic>{
            'inlineData': <String, String>{
              'mimeType': 'image/jpeg',
              'data': base64Encode(bytes),
            },
          });
      }

      final uri = Uri.https(
        'generativelanguage.googleapis.com',
        '/v1beta/models/$kGeminiSortModel:generateContent',
        <String, String>{'key': settings.geminiApiKey},
      );
      final response = await http
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'contents': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'parts': parts},
              ],
              'generationConfig': <String, dynamic>{
                'temperature': 0.2,
                'responseMimeType': 'application/json',
              },
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Gemini request failed: ${response.statusCode}');
      }

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = responseData['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) {
        throw Exception('Missing Gemini candidates');
      }
      final content =
          (candidates.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?;
      final responseParts = content?['parts'] as List<dynamic>?;
      var text =
          responseParts
              ?.whereType<Map<String, dynamic>>()
              .map((part) => part['text'])
              .whereType<String>()
              .join('\n')
              .trim() ??
          '';

      // Parse JSON
      var cleaned = text.trim();
      final fenced = RegExp(
        r'```(?:json)?\s*([\s\S]*?)\s*```',
        caseSensitive: false,
      ).firstMatch(cleaned);
      if (fenced != null) {
        cleaned = fenced.group(1)!.trim();
      }
      final objectStart = cleaned.indexOf('{');
      final objectEnd = cleaned.lastIndexOf('}');
      if (objectStart != -1 && objectEnd > objectStart) {
        cleaned = cleaned.substring(objectStart, objectEnd + 1);
      }
      final decodedResult = jsonDecode(cleaned) as Map<String, dynamic>;
      final pagesList = decodedResult['pages'] as List<dynamic>?;
      if (pagesList == null || pagesList.isEmpty) {
        throw Exception('Invalid Gemini response: missing pages');
      }

      final List<ProjectPage> projectPages = [];
      for (var pageIdx = 0; pageIdx < pagesList.length; pageIdx++) {
        final pageData = pagesList[pageIdx] as Map<String, dynamic>;
        final layout = pageData['layout'] as String? ?? 'fill';
        final imageIndexes = List<int>.from(
          pageData['imageIndexes'] as Iterable? ?? [],
        );
        final description = pageData['description'] as String? ?? '';

        final pageId = '${DateTime.now().microsecondsSinceEpoch}_page_$pageIdx';
        final List<CanvasElement> elements = [];

        // Add images elements
        if (layout == 'split' && imageIndexes.length >= 2) {
          final topImgIdx = imageIndexes[0];
          final botImgIdx = imageIndexes[1];

          if (topImgIdx >= 0 && topImgIdx < preparedPaths.length) {
            final prep = preparedPaths[topImgIdx];
            final aspect = await _getImageAspectRatio(prep.displayPath);
            elements.add(
              CanvasElement(
                id: '${DateTime.now().microsecondsSinceEpoch}_img_${pageIdx}_top',
                type: 'image',
                pageId: pageId,
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 0.49,
                allowCrossPage: true,
                data: <String, dynamic>{
                  'src': prep.displayPath,
                  'originalSrc': prep.originalPath,
                  'aspectRatio': aspect,
                  'originalAspectRatio': aspect,
                },
              ),
            );
          }

          if (botImgIdx >= 0 && botImgIdx < preparedPaths.length) {
            final prep = preparedPaths[botImgIdx];
            final aspect = await _getImageAspectRatio(prep.displayPath);
            elements.add(
              CanvasElement(
                id: '${DateTime.now().microsecondsSinceEpoch}_img_${pageIdx}_bot',
                type: 'image',
                pageId: pageId,
                x: 0.0,
                y: 0.51,
                width: 1.0,
                height: 0.49,
                allowCrossPage: true,
                data: <String, dynamic>{
                  'src': prep.displayPath,
                  'originalSrc': prep.originalPath,
                  'aspectRatio': aspect,
                  'originalAspectRatio': aspect,
                },
              ),
            );
          }
        } else {
          // Fill layout (or default fallback)
          final imgIdx = imageIndexes.isNotEmpty ? imageIndexes[0] : 0;
          if (imgIdx >= 0 && imgIdx < preparedPaths.length) {
            final prep = preparedPaths[imgIdx];
            final aspect = await _getImageAspectRatio(prep.displayPath);

            const pageAspect = 3.0 / 4.0;
            final targetRatio = aspect / pageAspect;

            double wNorm, hNorm;
            if (targetRatio > 1.0) {
              // Width limited
              wNorm = 1.0;
              hNorm = pageAspect / aspect;
            } else {
              // Height limited
              hNorm = 1.0;
              wNorm = hNorm * targetRatio;
            }

            final xCoord = (1.0 - wNorm) / 2;
            final yCoord = (1.0 - hNorm) / 2;

            elements.add(
              CanvasElement(
                id: '${DateTime.now().microsecondsSinceEpoch}_img_${pageIdx}_fill',
                type: 'image',
                pageId: pageId,
                x: xCoord,
                y: yCoord,
                width: wNorm,
                height: hNorm,
                allowCrossPage: true,
                data: <String, dynamic>{
                  'src': prep.displayPath,
                  'originalSrc': prep.originalPath,
                  'aspectRatio': aspect,
                  'originalAspectRatio': aspect,
                },
              ),
            );
          }
        }

        projectPages.add(
          ProjectPage(
            id: pageId,
            title: '頁面 ${pageIdx + 1}',
            type: 'page',
            aspectWidth: 3,
            aspectHeight: 4,
            elements: elements,
            extras: <String, dynamic>{'aiCaption': description},
          ),
        );
      }

      final List<Map<String, String>> importedImagesList = [];
      for (final prep in preparedPaths) {
        importedImagesList.add({
          'src': prep.displayPath,
          'originalSrc': prep.originalPath,
        });
      }

      final project = ProjectRecord(
        id: projectId,
        name: projectName.isEmpty ? strings.t('aiCreatedProject') : projectName,
        createdAt: DateTime.now(),
        pageCount: projectPages.length,
        pages: projectPages,
        extras: {'importedImages': importedImagesList},
      );

      setState(() {
        _projects.insert(0, project);
        _isAiCreating = false;
      });

      await _persistProjects();
      if (!mounted) return;
      await _openProject(project);
    } catch (e) {
      debugPrint('[AI Create] Error: $e');
      if (mounted) {
        setState(() {
          _isAiCreating = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              strings.t(
                'aiProjectCreationFailed',
                args: {'error': e.toString()},
              ),
            ),
          ),
        );
      }
    }
  }

  Future<({String displayPath, String originalPath})> _prepareImageAsset(
    String projectId,
    String sourcePath,
  ) async {
    try {
      final result =
          await _galleryChannel.invokeMapMethod<String, dynamic>(
            'prepareImageAsset',
            <String, dynamic>{
              'sourcePath': sourcePath,
              'projectId': projectId,
              'maxPreviewSide': 720,
            },
          ) ??
          <String, dynamic>{};

      final displayPath =
          result['displayPath'] as String? ??
          result['originalPath'] as String? ??
          sourcePath;
      final originalPath =
          result['originalPath'] as String? ??
          result['displayPath'] as String? ??
          sourcePath;
      return (displayPath: displayPath, originalPath: originalPath);
    } catch (_) {
      return (displayPath: sourcePath, originalPath: sourcePath);
    }
  }

  Future<double> _getImageAspectRatio(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final completer = Completer<double>();
      ui.decodeImageFromList(bytes, (image) {
        completer.complete(image.width / image.height);
      });
      return await completer.future;
    } catch (_) {
      return 1.0;
    }
  }

  Future<void> _openSettingsPage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          appVersion: _appVersion,
          hasUpdate: _hasUpdate,
          latestVersion: _newVersionString,
          latestVersionUrl: _latestVersionUrl,
          onCheckForUpdates: () => _checkForUpdates(),
        ),
      ),
    );
  }

  Future<void> _checkForUpdates({bool isSilent = false}) async {
    final strings = AppStrings.of(context);
    if (!isSilent) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );
    }

    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;

      final response = await http.get(
        Uri.parse(
          'https://api.github.com/repos/ivan17lai/post-studio/releases/latest',
        ),
      );
      if (!mounted) return;
      if (!isSilent) Navigator.of(context).pop();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tag = data['tag_name'] as String;
        final htmlUrl = data['html_url'] as String;

        final latestVersion = tag.startsWith('v') ? tag.substring(1) : tag;

        final isNewer = _isVersionNewer(currentVersion, latestVersion);

        if (isNewer) {
          setState(() {
            _hasUpdate = true;
            _latestVersionUrl = htmlUrl;
            _newVersionString = latestVersion;
          });
          if (!isSilent) {
            _showUpdateDialog(latestVersion, htmlUrl);
          }
        } else {
          if (!isSilent) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(strings.t('alreadyLatestVersion'))),
            );
          }
        }
      } else {
        if (!isSilent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(strings.t('updateCheckFailed'))),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (!isSilent) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.t('networkError'))));
      }
    }
  }

  bool _isVersionNewer(String current, String latest) {
    final currentParts = current
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final latestParts = latest
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    for (var i = 0; i < 3; i++) {
      final c = i < currentParts.length ? currentParts[i] : 0;
      final l = i < latestParts.length ? latestParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  void _showUpdateDialog(String newVersion, String url) {
    final strings = AppStrings.of(context);
    showDialog<void>(
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
                    Icons.system_update_rounded,
                    size: 20,
                    color: Color(0xFF6F6F6F),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  strings.t('newVersionFound'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  strings.t('updatePrompt', args: {'version': newVersion}),
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
                        label: strings.t('askMeLater'),
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogActionButton(
                        label: strings.t('downloadNow'),
                        isPrimary: true,
                        onTap: () {
                          Navigator.of(context).pop();
                          launchUrl(
                            Uri.parse(url),
                            mode: LaunchMode.externalApplication,
                          );
                        },
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
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final strings = AppStrings.of(context);
    final primary = AppSettingsController.instance.primaryColor;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFFEAEAEA),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      onPressed: _openSettingsPage,
                      icon: const Icon(
                        Icons.settings_rounded,
                        color: Color(0xFF5F5F5F),
                      ),
                    ),
                    if (_hasUpdate)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: kPrimaryAccentColor,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFFEAEAEA),
          floatingActionButton: FloatingActionButton(
            onPressed: _showCreateProjectDialog,
            backgroundColor: primary,
            foregroundColor: Colors.white,
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
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
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
                if (_appVersion.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      _appVersion,
                      style: const TextStyle(
                        color: Color(0xFF9A9A9A),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_isAiCreating)
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: true,
              child: Container(
                color: Colors.black.withValues(alpha: 0.10),
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Color(0xFF8F8F8F),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.t('aiCreatingProject'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF5F5F5F),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
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
    final primary = AppSettingsController.instance.primaryColor;

    return Center(
      child: SizedBox(
        width: width * 0.9,
        height: 80,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
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
                      color: primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.folder_outlined,
                      color: Colors.white,
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
  const _StyledCreateProjectDialog({this.initialPaths = const <String>[]});

  final List<String> initialPaths;

  @override
  State<_StyledCreateProjectDialog> createState() =>
      _StyledCreateProjectDialogState();
}

class _StyledCreateProjectDialogState
    extends State<_StyledCreateProjectDialog> {
  late final TextEditingController _controller;
  final ImagePicker _imagePicker = ImagePicker();
  List<String> _selectedPhotoPaths = [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _selectedPhotoPaths = List<String>.from(widget.initialPaths);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickPhotos() async {
    try {
      final pickedFiles = await _imagePicker.pickMultiImage();
      if (pickedFiles.isNotEmpty) {
        setState(() {
          _selectedPhotoPaths.addAll(pickedFiles.map((f) => f.path));
        });
      }
    } catch (e) {
      debugPrint('[Dialog Pick] Error picking photos: $e');
    }
  }

  void _submitNormal() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop({
      'name': _controller.text.trim(),
      'paths': _selectedPhotoPaths,
      'isAi': false,
    });
  }

  void _submitAi() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop({
      'name': _controller.text.trim(),
      'paths': _selectedPhotoPaths,
      'isAi': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final hasSelectedPhotos = _selectedPhotoPaths.isNotEmpty;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
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
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitNormal(),
                decoration: InputDecoration(
                  hintText: strings.t('enterProjectName'),
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Text(
                strings.t('preselectedPhotos'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF7A7A7A),
                ),
              ),
            ),
            if (!hasSelectedPhotos)
              GestureDetector(
                onTap: _pickPhotos,
                child: Container(
                  width: double.infinity,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E2E2)),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.add_photo_alternate_outlined,
                          color: Color(0xFF8F8F8F),
                          size: 24,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          strings.t('selectPhotosOptional'),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8F8F8F),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SizedBox(
                height: 80,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _selectedPhotoPaths.length + 1,
                  itemBuilder: (context, index) {
                    if (index == _selectedPhotoPaths.length) {
                      return GestureDetector(
                        onTap: _pickPhotos,
                        child: Container(
                          width: 60,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E2E2)),
                          ),
                          child: const Icon(
                            Icons.add_a_photo_outlined,
                            color: Color(0xFF8F8F8F),
                            size: 20,
                          ),
                        ),
                      );
                    }
                    final path = _selectedPhotoPaths[index];
                    return Stack(
                      children: [
                        Container(
                          width: 60,
                          height: 80,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            image: DecorationImage(
                              image: FileImage(File(path)),
                              fit: BoxFit.cover,
                            ),
                            border: Border.all(color: const Color(0xFFE2E2E2)),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 10,
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedPhotoPaths.removeAt(index);
                              });
                            },
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(3),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 10,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
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
                if (hasSelectedPhotos) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _DialogActionButton(
                      label: strings.t('createByAi'),
                      isPrimary: true,
                      onTap: _submitAi,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: _DialogActionButton(
                    label: strings.t('create'),
                    isPrimary: !hasSelectedPhotos,
                    onTap: _submitNormal,
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
