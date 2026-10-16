import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device appearance is independent of account credentials and logout cleanup.
class ThemeController extends ChangeNotifier {
  static const preferenceKey = 'readamber_theme_mode';
  final Future<SharedPreferences> Function() _preferences;
  ThemeController({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  ThemeMode _mode = ThemeMode.light;
  bool _busy = false;
  bool _disposed = false;
  String? _error;
  ThemeMode get mode => _mode;
  bool get isBusy => _busy;
  String? get error => _error;

  Future<void> load() async {
    if (_disposed || _busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final preferences = await _preferences();
      await preferences.reload();
      if (_disposed) return;
      _mode = switch (preferences.getString(preferenceKey)) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      };
    } catch (_) {
      _error = '主题读取失败，可重试或重新选择';
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
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

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
