import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hdr/ultra_hdr.dart';

const String kAppDisplayVersion = '1.7.10';
const String kGeminiSortModel = 'gemini-3.5-flash';
const Color kDefaultPrimaryAccentColor = Color(0xFFC3AEFF);

const List<Color> kPrimaryAccentPalette = <Color>[
  Color(0xFFC3AEFF),
  Color(0xFF8EC5FF),
  Color(0xFF78DFA4),
  Color(0xFFFFB4D8),
  Color(0xFFFFC078),
  Color(0xFFFF8F8F),
];

class AppSettingsController extends ChangeNotifier {
  AppSettingsController._();

  static final AppSettingsController instance = AppSettingsController._();

  static const String _geminiApiKeyKey = 'settings_gemini_api_key';
  static const String _aiSortEnabledKey = 'settings_ai_sort_enabled';
  static const String _primaryColorKey = 'settings_primary_color';
  static const String _aiSortCountKey = 'settings_ai_sort_count';
  static const String _languageKey = 'settings_language';
  static const String _fullScreenEnabledKey = 'settings_full_screen_enabled';

  /// Also read natively in MainActivity.onCreate (as
  /// `flutter.settings_hdr_enabled`) to set the window color mode before the
  /// first frame — keep the key in sync with the Kotlin side.
  static const String _hdrEnabledKey = 'settings_hdr_enabled';

  /// Global palette of user-saved page colours, shared across all projects.
  static const String _savedColorsKey = 'settings_saved_colors';

  bool _loaded = false;
  String _geminiApiKey = '';
  bool _aiSortEnabled = false;
  int _primaryColorValue = kDefaultPrimaryAccentColor.toARGB32();
  int _aiSortCount = 0;
  String _language = 'system';
  bool _fullScreenEnabled = false;
  bool _hdrEnabled = true;
  List<int> _savedColors = <int>[];

  bool get loaded => _loaded;
  String get geminiApiKey => _geminiApiKey;
  bool get aiSortEnabled => _aiSortEnabled;
  Color get primaryColor => Color(_primaryColorValue);
  bool get hasGeminiApiKey => _geminiApiKey.trim().isNotEmpty;
  int get aiSortCount => _aiSortCount;
  String get language => _language;
  bool get fullScreenEnabled => _fullScreenEnabled;
  bool get hdrEnabled => _hdrEnabled;

  /// User-saved page colours, in insertion order.
  List<Color> get savedColors =>
      _savedColors.map((value) => Color(value)).toList(growable: false);

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _geminiApiKey = prefs.getString(_geminiApiKeyKey) ?? '';
    _aiSortEnabled = prefs.getBool(_aiSortEnabledKey) ?? false;
    _primaryColorValue =
        prefs.getInt(_primaryColorKey) ?? kDefaultPrimaryAccentColor.toARGB32();
    _aiSortCount = prefs.getInt(_aiSortCountKey) ?? 0;
    _language = prefs.getString(_languageKey) ?? 'system';
    _fullScreenEnabled = prefs.getBool(_fullScreenEnabledKey) ?? false;
    _hdrEnabled = prefs.getBool(_hdrEnabledKey) ?? true;
    _savedColors = (prefs.getStringList(_savedColorsKey) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    _loaded = true;
    await _applySystemUiMode(_fullScreenEnabled);
    notifyListeners();
  }

  Future<void> _persistSavedColors() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _savedColorsKey,
      _savedColors.map((value) => value.toString()).toList(),
    );
  }

  Future<void> addSavedColor(Color color) async {
    final value = color.toARGB32();
    if (_savedColors.contains(value)) {
      return;
    }
    _savedColors = <int>[..._savedColors, value];
    await _persistSavedColors();
    notifyListeners();
  }

  Future<void> removeSavedColor(Color color) async {
    final value = color.toARGB32();
    if (!_savedColors.contains(value)) {
      return;
    }
    _savedColors = _savedColors.where((v) => v != value).toList();
    await _persistSavedColors();
    notifyListeners();
  }

  Future<void> setHdrEnabled(bool value) async {
    _hdrEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hdrEnabledKey, value);
    await UltraHdr.setWindowHdrColorMode(value);
    notifyListeners();
  }

  Future<void> setFullScreenEnabled(bool value) async {
    _fullScreenEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_fullScreenEnabledKey, value);
    await _applySystemUiMode(value);
    notifyListeners();
  }

  Future<void> _applySystemUiMode(bool fullScreenEnabled) {
    if (fullScreenEnabled) {
      return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    return SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> setLanguage(String value) async {
    _language = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, value);
    notifyListeners();
  }

  Future<void> setGeminiApiKey(String value) async {
    _geminiApiKey = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_geminiApiKeyKey, _geminiApiKey);
    notifyListeners();
  }

  Future<void> setAiSortEnabled(bool value) async {
    _aiSortEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_aiSortEnabledKey, value);
    notifyListeners();
  }

  Future<void> setPrimaryColor(Color color) async {
    _primaryColorValue = color.toARGB32();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_primaryColorKey, _primaryColorValue);
    notifyListeners();
  }

  Future<void> incrementAiSortCount() async {
    _aiSortCount++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_aiSortCountKey, _aiSortCount);
    notifyListeners();
  }

  Future<void> resetAiSortCount() async {
    _aiSortCount = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_aiSortCountKey, 0);
    notifyListeners();
  }
}
