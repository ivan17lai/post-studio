import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hdr/ultra_hdr.dart';

const String kAppDisplayVersion = '1.7.3';
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

  /// Also read natively in MainActivity.onCreate (as
  /// `flutter.settings_hdr_enabled`) to set the window color mode before the
  /// first frame — keep the key in sync with the Kotlin side.
  static const String _hdrEnabledKey = 'settings_hdr_enabled';

  bool _loaded = false;
  String _geminiApiKey = '';
  bool _aiSortEnabled = false;
  int _primaryColorValue = kDefaultPrimaryAccentColor.toARGB32();
  int _aiSortCount = 0;
  String _language = 'system';
  bool _hdrEnabled = true;

  bool get loaded => _loaded;
  String get geminiApiKey => _geminiApiKey;
  bool get aiSortEnabled => _aiSortEnabled;
  Color get primaryColor => Color(_primaryColorValue);
  bool get hasGeminiApiKey => _geminiApiKey.trim().isNotEmpty;
  int get aiSortCount => _aiSortCount;
  String get language => _language;
  bool get hdrEnabled => _hdrEnabled;

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
    _hdrEnabled = prefs.getBool(_hdrEnabledKey) ?? true;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setHdrEnabled(bool value) async {
    _hdrEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hdrEnabledKey, value);
    await UltraHdr.setWindowHdrColorMode(value);
    notifyListeners();
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
