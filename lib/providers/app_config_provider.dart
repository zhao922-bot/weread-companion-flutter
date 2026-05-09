import 'package:flutter/material.dart';
import '../services/config.dart';

/// 应用配置 Provider
/// 管理登录状态、Cookie、AI 配置等
class AppConfigProvider extends ChangeNotifier {
  final AppConfig config;
  bool _isLoggedIn = false;
  String _userName = '';
  bool _isLoaded = false;

  AppConfigProvider({required this.config});

  bool get isLoggedIn => _isLoggedIn;
  String get userName => _userName;
  String get cookie => config.cookie;
  bool get isLoaded => _isLoaded;

  /// 初始化：从存储加载配置
  Future<void> init() async {
    await config.load();
    _isLoggedIn = config.cookie.isNotEmpty;
    if (_isLoggedIn) {
      _userName = '微信用户';
      _extractUserName();
    }
    _isLoaded = true;
    notifyListeners();
  }

  /// 从 cookie 中提取用户信息
  void _extractUserName() {
    // wr_name 字段包含用户名
    final parts = config.cookie.split(';');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.startsWith('wr_name=')) {
        _userName = Uri.decodeComponent(trimmed.substring(8));
        break;
      }
    }
  }

  /// 微信扫码登录成功后保存 Cookie
  Future<void> loginWithCookie(String cookieStr) async {
    config.cookie = cookieStr;
    await config.save();
    _isLoggedIn = true;
    _extractUserName();
    notifyListeners();
  }

  /// 退出登录
  Future<void> logout() async {
    await config.clear();
    _isLoggedIn = false;
    _userName = '';
    notifyListeners();
  }

  /// 更新 AI 配置
  Future<void> updateAiConfig({
    String? apiKey,
    String? baseUrl,
    String? modelName,
  }) async {
    if (apiKey != null) config.apiKey = apiKey;
    if (baseUrl != null) config.baseUrl = baseUrl;
    if (modelName != null) config.modelName = modelName;
    await config.save();
    notifyListeners();
  }
}
