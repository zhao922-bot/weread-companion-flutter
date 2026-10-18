import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../services/config.dart';
import '../services/database.dart';
import '../services/api.dart';
import '../services/ai_service.dart';
import '../services/export_service.dart';
import '../services/credentials.dart';

enum LoginStatus { signedOut, saved, verified, invalid, cleanupPending }

/// 应用配置 Provider
/// 管理登录状态、Cookie、AI 配置等
class AppConfigProvider extends ChangeNotifier {
  final AppConfig config;
  LoginStatus _loginStatus = LoginStatus.signedOut;
  bool _busy = false;
  String? _loginError;
  String _userName = '';
  bool _isLoaded = false;
  bool _isLoading = false;
  String? _configLoadError;
  int _sessionRevision = 0;
  DatabaseService? _localDatabase;
  bool _disposed = false;
  Future<bool>? _syncVerification;
  CancelToken? _verificationCancellation;
  final WeReadApi Function(AppConfig) _loginApi;
  int get sessionRevision => _sessionRevision;

  AppConfigProvider(
      {required this.config, WeReadApi Function(AppConfig)? loginApi})
      : _loginApi =
            loginApi ?? ((config) => WeReadApi.forLogin(config: config)) {
    config.credentialRevalidation.addListener(_requireRevalidation);
    config.credentialsInvalid.addListener(_invalidateCredentials);
  }

  void _invalidateCredentials() {
    if (!config.credentialsInvalid.value) return;
    _loginStatus = LoginStatus.invalid;
    _loginError = const LoginExpiredException().toString();
    notifyListeners();
  }

  void _requireRevalidation() {
    final error = config.credentialRevalidation.value;
    if (error == null) return;
    _loginStatus = LoginStatus.saved;
    _loginError = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _verificationCancellation?.cancel('配置会话已结束');
    config.credentialRevalidation.removeListener(_requireRevalidation);
    config.credentialsInvalid.removeListener(_invalidateCredentials);
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get isLoggedIn => loginStatus == LoginStatus.verified;
  bool get canBrowseLocal => _localDatabase?.isActive == true;
  bool get needsOnlineSync => canBrowseLocal && !isLoggedIn;
  bool get hasSavedCredentials => config.isConfigured;
  bool get cleanupPending => config.logoutPending;
  bool get isBusy => _busy;
  bool get canVerifyForSync => !_disposed && !cleanupPending &&
      (!isBusy || _syncVerification != null);
  LoginStatus get loginStatus => _loginStatus == LoginStatus.verified && !canBrowseLocal
      ? LoginStatus.saved : _loginStatus;
  String? get loginError => _loginError;
  String get loginStatusText => switch (loginStatus) {
          LoginStatus.invalid => '凭据失效 · 请重新登录',
          _ when needsOnlineSync => '本地数据可浏览 · 需要联网验证后同步',
          LoginStatus.signedOut => '未登录',
          LoginStatus.saved => '已保存凭据',
          LoginStatus.verified => '验证成功',
          LoginStatus.cleanupPending => '清理未完成',
        };
  String get userName => _userName;
  String get cookie => config.cookie;
  bool get isLoaded => _isLoaded;
  bool get isLoading => _isLoading;
  String? get configLoadError => _configLoadError;

  /// 初始化：从存储加载配置
  Future<void> init() async {
    if (_busy || _disposed) return;
    _busy = true;
    _isLoading = true;
    _isLoaded = false;
    _configLoadError = null;
    _loginError = null;
    notifyListeners();
    try {
      await config.loadLogoutPending();
      if (_disposed) return;
      if (config.logoutPending) {
        _isLoaded = true;
        _isLoading = false;
        await _completeLogout();
        return;
      }
      Future<void> restoreLocal() async {
        await config.loadTrustedAccount();
        if (_disposed) return;
        final trustedId = config.trustedAccountId;
        if (trustedId != null) {
          final database = await DatabaseService.selectAccount(trustedId,
              isCancelled: () => _disposed);
          try {
            await database.database;
            if (_disposed || !database.isActive) {
              throw StateError('配置会话已结束');
            }
          } catch (_) {
            if (database.isActive) await DatabaseService.endSession();
            rethrow;
          }
          _localDatabase = database;
          notifyListeners();
          // Deliver the local-ready state before completing configuration load.
          await Future<void>.delayed(Duration.zero);
        }
      }
      await restoreLocal();
      if (_disposed) return;
      await config.load();
      if (_disposed) return;
      _isLoaded = true;
      _isLoading = false;
      notifyListeners();
      if (config.isConfigured) {
        _loginStatus = LoginStatus.saved;
        try {
          if (config.credentials == null) {
            config.cookie = WeReadApi.normalizeCookie(config.cookie);
          }
        } on FormatException {
          _loginStatus = LoginStatus.invalid;
          _loginError = '已保存的 Cookie 格式无效，请重新导入';
          return;
        }
        await config.save();
        await _verifyCredentials();
      }
    } catch (_) {
      if (cleanupPending) {
        _loginStatus = LoginStatus.cleanupPending;
        _loginError ??= '退出清理未完成，请继续清理';
        return;
      }
      if (!_isLoaded) _configLoadError = '配置加载失败，请重试';
      _loginError = canBrowseLocal ? '凭据或配置加载失败，本地数据可浏览；请重试后同步' : '配置加载失败，请重试';
    } finally {
      _isLoading = false;
      _busy = false;
      notifyListeners();
    }
  }

  String? _accountId(String cookie) {
    final match =
        RegExp(r'(?:^|;\s*)wr_vid=([0-9]+)(?:;|$)').firstMatch(cookie);
    final id = match?.group(1);
    return id == '0' ? null : id;
  }

  /// 从 cookie 中提取用户信息
  void _extractUserName() {
    // wr_name 字段包含用户名
    final parts = config.cookie.split(';');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.startsWith('wr_name=')) {
        try {
          _userName = Uri.decodeComponent(trimmed.substring(8));
        } on FormatException {
          _userName = '微信用户';
        } on ArgumentError {
          // Invalid percent escapes are ArgumentError; malformed UTF-8 is
          // FormatException. A display name must not invalidate a login.
          _userName = '微信用户';
        }
        break;
      }
    }
  }

  void _beginOperation() {
    if (_disposed) throw StateError('配置会话已结束');
    if (_busy) throw StateError('配置操作进行中，请稍后重试');
    _busy = true;
    notifyListeners();
  }

  Future<bool> _verifyCredentials() async {
    if (_disposed) return false;
    final revision = _sessionRevision;
    final cookie = config.cookie;
    final accountId = config.credentials?.vid ?? _accountId(config.cookie);
    if (accountId == null) {
      _loginStatus = LoginStatus.invalid;
      _loginError = 'Cookie 缺少有效的 wr_vid，请重新导入';
      return false;
    }
    if (canBrowseLocal && config.trustedAccountId != accountId) {
      _loginStatus = LoginStatus.invalid;
      _loginError = '本地数据可浏览；凭据与可信账号不匹配，请重新登录后同步';
      return false;
    }
    final api = _loginApi(config);
    final cancellation = CancelToken();
    _verificationCancellation = cancellation;
    DatabaseService? opened;
    String? localFailure;
    bool isCurrent() => !_disposed && !cancellation.isCancelled &&
        !api.syncCancelled && !cleanupPending && revision == _sessionRevision &&
        (config.credentials?.vid ?? _accountId(config.cookie)) == accountId &&
        (config.credentials != null || config.cookie == cookie);
    void checkSession() {
      if (!isCurrent()) throw StateError('配置会话已结束');
    }
    try {
      final valid = await api.checkLogin(cancelToken: cancellation);
      checkSession();
      if (!valid || api.authenticatedAccountId != accountId) {
        _loginStatus = LoginStatus.invalid;
        _loginError = '凭据失效或账号不匹配，请重新登录';
        return false;
      }
      localFailure = '本地数据库暂时无法打开，请重试';
      if (!canBrowseLocal || _localDatabase!.accountId != accountId) {
        opened = await DatabaseService.selectAccount(accountId,
            isCancelled: () => !isCurrent());
        checkSession();
        await opened.database;
      }
      checkSession();
      final database = opened ?? _localDatabase!;
      database.requireActive();
      localFailure = '登录状态保存失败，请检查本地存储后重试';
      await config.trustAccount(accountId);
      checkSession();
      database.requireActive();
      _localDatabase = database;
      _loginStatus = LoginStatus.verified;
      config.credentialsInvalid.value = false;
      _loginError = null;
      _userName = '微信用户';
      _extractUserName();
      return true;
    } catch (_) {
      // 首次验证若未能持久化可信账号，不留下可访问的数据库会话。
      // Only close the database created by this attempt, never a newer login.
      var closeFailed = false;
      if (opened?.isActive == true) {
        try {
          await DatabaseService.endSession();
        } catch (_) {
          // The inactive handle remains available for the next close attempt.
          closeFailed = true;
        }
      }
      if (!isCurrent()) return false;
      _loginStatus = config.credentialsInvalid.value ? LoginStatus.invalid : LoginStatus.saved;
      _loginError = config.credentialsInvalid.value
          ? const LoginExpiredException().toString()
          : localFailure ?? config.credentialRevalidation.value ?? (canBrowseLocal
          ? '暂时无法联网验证，本地数据可浏览；同步需要联网后重试'
          : '已保存凭据，暂时无法完成验证，请检查网络后重试');
      if (closeFailed) _loginError = '$_loginError；本地数据库关闭失败，重试时将继续清理';
      return false;
    } finally {
      if (identical(_verificationCancellation, cancellation)) {
        _verificationCancellation = null;
      }
      api.disposeAfterRefresh();
    }
  }

  /// 离线恢复网络后，可从同步入口重试验证。
  Future<bool> verifyForSync() {
    final pending = _syncVerification;
    if (pending != null) return pending;
    if (_disposed || _busy || cleanupPending) return Future.value(false);
    final done = Completer<bool>();
    // Publish before notifying listeners, including reentrant sync entries.
    _syncVerification = done.future;
    _verifyForSync().then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<bool> _verifyForSync() async {
    try {
      _beginOperation();
      if (!config.isConfigured) {
        _loginError = '本地数据可浏览；同步需要联网并重新登录';
        return false;
      }
      return await _verifyCredentials();
    } finally {
      _syncVerification = null;
      _busy = false;
      notifyListeners();
    }
  }

  /// 规范化并保存凭据，通过服务器验证后才允许访问阅读数据。
  Future<void> loginWithCookie(String cookieStr) async {
    final normalized = WeReadApi.normalizeCookie(cookieStr);
    final accountId = _accountId(normalized);
    if (accountId == null) throw const FormatException('Cookie 缺少有效的 wr_vid');
    await _login(cookie: normalized);
  }

  Future<void> loginWithCredentials(Credentials credentials) async {
    if (!credentials.isValid) throw const FormatException('移动端凭据格式无效');
    await _login(credentials: credentials);
  }

  Future<void> _login({String cookie = '', Credentials? credentials}) async {
    if (cleanupPending) throw StateError('请先完成退出清理');
    _beginOperation();
    try {
      WeReadApi.reset();
      AIService.cancelAll();
      _localDatabase = null;
      _loginStatus = LoginStatus.signedOut;
      _userName = '';
      _loginError = null;
      _sessionRevision++;
      notifyListeners();
      await DatabaseService.endSession();
      await config.clearTrustedAccount();
      config.cookie = cookie;
      config.credentials = credentials;
      config.pendingCredentials = null;
      config.credentialsInvalid.value = false;
      config.credentialRevalidation.value = null;
      await config.save();
      _loginStatus = LoginStatus.saved;
      notifyListeners();
      await _verifyCredentials();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 退出登录
  Future<void> logout() async {
    _beginOperation();
    try {
      await config.beginLogout();
      await _completeLogout();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _completeLogout() async {
    WeReadApi.reset();
    AIService.cancelAll();
    _localDatabase = null;
    _loginStatus = LoginStatus.cleanupPending;
    _userName = '';
    _loginError = null;
    config.cookie = '';
    config.credentials = null;
    config.pendingCredentials = null;
    config.credentialsInvalid.value = false;
    config.credentialRevalidation.value = null;
    config.apiKey = '';
    config.baseUrl = 'https://api.deepseek.com';
    config.modelName = 'deepseek-chat';
    _sessionRevision++;
    notifyListeners();
    final failures = <String>[];
    Future<void> clean(String label, Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        failures.add(label);
      }
    }
    await clean('可信账号', config.clearTrustedAccount);
    await clean('本地数据库', DatabaseService.clearLocalData);
    await clean('导出文件', ExportService.clearLocalExports);
    await clean('凭据和配置', config.clear);
    if (failures.isNotEmpty) {
      _loginError = '清理未完成（${failures.join('、')}），请继续清理';
      throw StateError(_loginError!);
    }
    await clean('退出标记', config.finishLogout);
    if (failures.isNotEmpty) {
      _loginError = '清理未完成（${failures.join('、')}），请继续清理';
      throw StateError(_loginError!);
    }
    _loginStatus = LoginStatus.signedOut;
    _loginError = null;
  }

  /// 更新 AI 配置
  Future<void> updateAiConfig({
    String? apiKey,
    String? baseUrl,
    String? modelName,
  }) async {
    if (!_isLoaded) throw StateError('配置尚未加载完成，请重试');
    if (baseUrl != null && !AppConfig.isHttpsUrl(baseUrl.trim())) {
      throw const FormatException('AI 服务地址必须是有效的 HTTPS 地址');
    }
    _beginOperation();
    final previousApiKey = config.apiKey;
    final previousBaseUrl = config.baseUrl;
    final previousModelName = config.modelName;
    try {
      if (apiKey != null) config.apiKey = apiKey;
      if (baseUrl != null) {
        config.baseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
      }
      if (modelName != null) config.modelName = modelName;
      await config.saveAiConfig();
    } catch (_) {
      config.apiKey = previousApiKey;
      config.baseUrl = previousBaseUrl;
      config.modelName = previousModelName;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
