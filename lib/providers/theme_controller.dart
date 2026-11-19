import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/font_service.dart';

/// Device appearance is independent of account credentials and logout cleanup.
class ThemeController extends ChangeNotifier {
  static const preferenceKey = 'readamber_theme_mode';
  static const fontPreferenceKey = 'readamber_font_id';
  final Future<SharedPreferences> Function() _preferences;
  final FontService _fontService;
  ThemeController({
    Future<SharedPreferences> Function()? preferences,
    FontService? fontService,
  })  : _preferences = preferences ?? SharedPreferences.getInstance,
        _fontService = fontService ?? FontService();

  ThemeMode _mode = ThemeMode.light;
  String? _fontId;
  Set<String> _downloadedFonts = {};
  String? _downloadingFontId;
  double _downloadProgress = 0;
  bool _busy = false;
  bool _disposed = false;
  String? _error;
  String? _fontError;

  ThemeMode get mode => _mode;
  String? get fontId => _fontId;
  String? get fontFamily => OpenSourceFont.byId(_fontId)?.family;
  Set<String> get downloadedFonts => _downloadedFonts;
  String? get downloadingFontId => _downloadingFontId;
  double get downloadProgress => _downloadProgress;
  bool get isBusy => _busy;
  String? get error => _error;
  String? get fontError => _fontError;

  Future<void> load() async {
    if (_disposed || _busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    String? savedFontId;
    try {
      final preferences = await _preferences();
      await preferences.reload();
      if (_disposed) return;
      _mode = switch (preferences.getString(preferenceKey)) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      };
      savedFontId = preferences.getString(fontPreferenceKey);
    } catch (_) {
      _error = '主题读取失败，可重试或重新选择';
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
    if (!_disposed && _error == null) {
      await _loadFontPreference(savedFontId);
    }
  }

  Future<void> _loadFontPreference(String? savedId) async {
    try {
      final downloaded = await _fontService.listDownloadedIds();
      if (!_disposed) {
        _downloadedFonts = downloaded;
        final saved = OpenSourceFont.byId(savedId);
        if (saved != null && downloaded.contains(saved.id)) {
          await _fontService.loadFont(saved);
          if (!_disposed) _fontId = saved.id;
        } else {
          _fontId = null;
        }
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      // 字体目录不可用时静默回退系统默认字体，不影响主题加载。
      _fontId = null;
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    // Serialize interaction by disabling the selector until persistence settles.
    if (_disposed || _busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final preferences = await _preferences();
      if (_disposed) return;
      if (!await preferences.setString(preferenceKey, mode.name)) {
        throw StateError('Theme preference write failed');
      }
      if (_disposed) return;
      _mode = mode;
    } catch (_) {
      _error = '主题保存失败，请重新选择';
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> setFont(String? fontId) async {
    if (_disposed || _downloadingFontId != null) return;
    _fontError = null;
    try {
      final font = OpenSourceFont.byId(fontId);
      if (font != null) {
        await _fontService.loadFont(font);
      }
      final preferences = await _preferences();
      final saved = font == null
          ? await preferences.remove(fontPreferenceKey)
          : await preferences.setString(fontPreferenceKey, font.id);
      if (!saved) throw StateError('Font preference write failed');
      if (!_disposed) _fontId = font?.id;
    } catch (_) {
      _fontError = '字体切换失败，请重试';
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> downloadAndApplyFont(OpenSourceFont font) async {
    if (_disposed || _downloadingFontId != null) return;
    _downloadingFontId = font.id;
    _downloadProgress = 0;
    _fontError = null;
    notifyListeners();
    try {
      await _fontService.downloadFont(
        font,
        onProgress: (p) {
          if (!_disposed) {
            _downloadProgress = p;
            notifyListeners();
          }
        },
      );
      if (!_disposed) {
        _downloadedFonts = {..._downloadedFonts, font.id};
        final preferences = await _preferences();
        await preferences.setString(fontPreferenceKey, font.id);
        if (!_disposed) _fontId = font.id;
      }
    } catch (_) {
      _fontError = '${font.name} 下载失败，请检查网络后重试';
    } finally {
      _downloadingFontId = null;
      _downloadProgress = 0;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> deleteFont(OpenSourceFont font) async {
    if (_disposed || _downloadingFontId != null) return;
    _fontError = null;
    try {
      await _fontService.deleteFont(font);
      _downloadedFonts = {..._downloadedFonts}..remove(font.id);
      if (_fontId == font.id) {
        final preferences = await _preferences();
        await preferences.remove(fontPreferenceKey);
        _fontId = null;
      }
    } catch (_) {
      _fontError = '${font.name} 删除失败，请重试';
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
