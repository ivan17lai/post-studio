import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'app_settings.dart';
import 'app_strings.dart';
import 'hdr/ultra_hdr.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.appVersion,
    required this.hasUpdate,
    required this.latestVersion,
    required this.latestVersionUrl,
    required this.onCheckForUpdates,
  });

  final String appVersion;
  final bool hasUpdate;
  final String? latestVersion;
  final String? latestVersionUrl;
  final Future<void> Function() onCheckForUpdates;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppSettingsController _settings = AppSettingsController.instance;
  late final TextEditingController _apiKeyController;
  bool _isCheckingApi = false;
  bool _isCheckingUpdate = false;
  final bool _showExtensions = false;
  HdrCapabilities _hdrCapabilities = HdrCapabilities.unsupported;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: _settings.geminiApiKey);
    _settings.addListener(_handleSettingsChanged);
    unawaited(_loadHdrCapabilities());
  }

  Future<void> _loadHdrCapabilities() async {
    final capabilities = await UltraHdr.capabilities();
    if (!mounted) {
      return;
    }
    setState(() {
      _hdrCapabilities = capabilities;
    });
  }

  @override
  void dispose() {
    _settings.removeListener(_handleSettingsChanged);
    _apiKeyController.dispose();
    super.dispose();
  }

  void _handleSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _verifyGeminiApiKey(String apiKey) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      return false;
    }

    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$kGeminiSortModel:generateContent',
      <String, String>{'key': trimmedKey},
    );

    try {
      final response = await http
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'contents': <Map<String, dynamic>>[
                <String, dynamic>{
                  'role': 'user',
                  'parts': <Map<String, String>>[
                    <String, String>{'text': 'Reply with OK only.'},
                  ],
                },
              ],
              'generationConfig': <String, dynamic>{
                'temperature': 0,
                'maxOutputTokens': 8,
              },
            }),
          )
          .timeout(const Duration(seconds: 18));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List<dynamic>?;
      return candidates != null && candidates.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveApiKey() async {
    final strings = AppStrings.of(context);
    await _settings.setGeminiApiKey(_apiKeyController.text);
    if (!_settings.hasGeminiApiKey) {
      await _settings.setAiSortEnabled(false);
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.t('settingsSaved'))));
    }
  }

  Future<void> _toggleAiSort(bool enabled) async {
    final strings = AppStrings.of(context);
    await _settings.setGeminiApiKey(_apiKeyController.text);
    if (!enabled) {
      await _settings.setAiSortEnabled(false);
      return;
    }

    if (!_settings.hasGeminiApiKey) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.t('enterApiKeyFirst'))));
      }
      return;
    }

    setState(() {
      _isCheckingApi = true;
    });
    final isValid = await _verifyGeminiApiKey(_settings.geminiApiKey);
    if (!mounted) {
      return;
    }
    setState(() {
      _isCheckingApi = false;
    });

    if (isValid) {
      await _settings.setAiSortEnabled(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.t('aiCollaborationEnabled'))),
        );
      }
    } else {
      await _settings.setAiSortEnabled(false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.t('apiUnavailable'))));
      }
    }
  }

  Future<void> _checkUpdates() async {
    if (widget.hasUpdate && widget.latestVersionUrl != null) {
      await launchUrl(
        Uri.parse(widget.latestVersionUrl!),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    setState(() {
      _isCheckingUpdate = true;
    });
    await widget.onCheckForUpdates();
    if (!mounted) {
      return;
    }
    setState(() {
      _isCheckingUpdate = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = _settings.primaryColor;
    final strings = AppStrings.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1F2F4),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF2A2A2A)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          strings.t('settingsTitle'),
          style: const TextStyle(
            color: Color(0xFF222222),
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 28),
          children: [
            _SettingsSectionTitle(title: strings.t('themeColor')),
            const SizedBox(height: 10),
            _ThemeColorGrid(primary: primary, settings: _settings),
            const SizedBox(height: 22),
            _SettingsSectionTitle(title: strings.t('languageSetting')),
            const SizedBox(height: 10),
            _LanguageSelectionCard(
              primary: primary,
              language: _settings.language,
              onLanguageChanged: (value) async {
                await _settings.setLanguage(value);
              },
              strings: strings,
            ),
            const SizedBox(height: 22),
            _SettingsSectionTitle(title: strings.t('hdrSectionTitle')),
            const SizedBox(height: 10),
            _SettingsCard(
              primary: primary,
              icon: Icons.hdr_on_rounded,
              title: strings.t('hdrSettingTitle'),
              subtitle: _hdrCapabilities.supportsGainmap
                  ? strings.t('hdrSettingSubtitle')
                  : strings.t('hdrUnsupported'),
              trailing: Switch(
                value: _hdrCapabilities.supportsGainmap && _settings.hdrEnabled,
                activeThumbColor: primary,
                onChanged: _hdrCapabilities.supportsGainmap
                    ? (value) => unawaited(_settings.setHdrEnabled(value))
                    : null,
              ),
            ),
            const SizedBox(height: 22),
            // Keep the code preserved but hidden for later development
            if (_showExtensions) ...[
              _SettingsSectionTitle(title: strings.t('extensions')),
              const SizedBox(height: 10),
              _SettingsCard(
                primary: primary,
                icon: Icons.auto_awesome_rounded,
                title: strings.t('aiCollaboration'),
                subtitle: _settings.aiSortEnabled
                    ? strings.t('aiCollaborationSubtitleActive')
                    : strings.t('aiCollaborationSubtitleInactive'),
                trailing: _isCheckingApi
                    ? const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Switch(
                        value: _settings.aiSortEnabled,
                        activeThumbColor: primary,
                        onChanged: _toggleAiSort,
                      ),
              ),
              const SizedBox(height: 12),
              AnimatedOpacity(
                opacity: _settings.aiSortEnabled ? 1.0 : 0.5,
                duration: const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !_settings.aiSortEnabled,
                  child: Column(
                    children: [
                      _SettingsInputCard(
                        primary: primary,
                        controller: _apiKeyController,
                        onSave: _saveApiKey,
                      ),
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: Color(0xFFF1F2F4),
                        indent: 18,
                        endIndent: 18,
                      ),
                      _SettingsCostCard(
                        primary: primary,
                        aiSortCount: _settings.aiSortCount,
                        onReset: () async {
                          await _settings.resetAiSortCount();
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
            ],
            _SettingsSectionTitle(title: strings.t('versionUpdate')),
            const SizedBox(height: 10),
            _SettingsCard(
              primary: primary,
              icon: Icons.system_update_rounded,
              title: strings.t('versionUpdate'),
              subtitle: widget.hasUpdate
                  ? strings.t(
                      'updateAvailable',
                      args: {
                        'version': widget.appVersion,
                        'latest': widget.latestVersion ?? 'New Version',
                      },
                    )
                  : strings.t(
                      'currentVersion',
                      args: {'version': widget.appVersion},
                    ),
              trailing: TextButton(
                onPressed: _isCheckingUpdate ? null : _checkUpdates,
                style: TextButton.styleFrom(
                  backgroundColor: primary.withValues(alpha: 0.16),
                  foregroundColor: const Color(0xFF222222),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  widget.hasUpdate && widget.latestVersionUrl != null
                      ? strings.t('goToUpdate')
                      : _isCheckingUpdate
                      ? strings.t('checking')
                      : strings.t('checkUpdates'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: Color(0xFF2E3033),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.primary,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final Color primary;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(icon, color: primary, size: 25),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF25272A),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B6F75),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class _SettingsInputCard extends StatelessWidget {
  const _SettingsInputCard({
    required this.primary,
    required this.controller,
    required this.onSave,
  });

  final Color primary;
  final TextEditingController controller;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gemini API Key',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF25272A),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            obscureText: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFFF4F5F7),
              hintText: 'AIza...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onSave,
              style: FilledButton.styleFrom(
                backgroundColor: primary,
                foregroundColor: const Color(0xFF1F1F1F),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: Text(strings.t('saveApiKey')),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeColorGrid extends StatelessWidget {
  const _ThemeColorGrid({required this.primary, required this.settings});

  final Color primary;
  final AppSettingsController settings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final color in kPrimaryAccentPalette)
            GestureDetector(
              onTap: () => unawaited(settings.setPrimaryColor(color)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: color.toARGB32() == settings.primaryColor.toARGB32()
                        ? const Color(0xFF202124)
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: color.toARGB32() == settings.primaryColor.toARGB32()
                    ? const Icon(Icons.check_rounded, size: 20)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsCostCard extends StatelessWidget {
  const _SettingsCostCard({
    required this.primary,
    required this.aiSortCount,
    required this.onReset,
  });

  final Color primary;
  final int aiSortCount;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final double estimatedCost = aiSortCount * 0.0000002;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(Icons.calculate_rounded, color: primary, size: 25),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.t('aiUsageEstimate'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF25272A),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  strings.t(
                    'estimatedCost',
                    args: {'cost': estimatedCost.toStringAsFixed(6)},
                  ),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B6F75),
                  ),
                ),
              ],
            ),
          ),
          if (aiSortCount > 0) ...[
            const SizedBox(width: 10),
            TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                backgroundColor: Colors.red.withValues(alpha: 0.08),
                foregroundColor: Colors.red[700],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
              ),
              child: Text(
                strings.t('reset'),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LanguageSelectionCard extends StatelessWidget {
  const _LanguageSelectionCard({
    required this.primary,
    required this.language,
    required this.onLanguageChanged,
    required this.strings,
  });

  final Color primary;
  final String language;
  final ValueChanged<String> onLanguageChanged;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final opt in ['system', 'zh', 'en']) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () => onLanguageChanged(opt),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: language == opt
                            ? primary.withValues(alpha: 0.16)
                            : const Color(0xFFF4F5F7),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: language == opt ? primary : Colors.transparent,
                          width: 1.6,
                        ),
                      ),
                      child: Text(
                        opt == 'system'
                            ? strings.t('languageFollowSystem')
                            : opt == 'zh'
                            ? strings.t('languageTraditionalChinese')
                            : strings.t('languageEnglish'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: language == opt
                              ? const Color(0xFF222222)
                              : const Color(0xFF6B6F75),
                        ),
                      ),
                    ),
                  ),
                ),
                if (opt != 'en') const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              strings.t('languageChangeNotice'),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9A9A9A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
