import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'credentials.dart';

class AppConfig {
  static const _secureStorage = FlutterSecureStorage();
  String cookie;
  Credentials? credentials;
  // Keep server-rotated tokens until secure storage recovers; never send them
  // before persistence succeeds.
  Credentials? pendingCredentials;
  final ValueNotifier<String?> credentialRevalidation = ValueNotifier(null);
  final ValueNotifier<bool> credentialsInvalid = ValueNotifier(false);
  String apiKey;
  String baseUrl;
  String modelName;
  String? trustedAccountId;
  bool logoutPending = false;
  static const _logoutPendingKey = 'weread_logout_pending';
  static const _aiConfigKey = 'weread_ai_config';
  String? _pendingTrustedAccountId;
  final Map<String, String> _persistedSecrets = {};

  AppConfig({
    this.cookie = '',
    this.credentials,
    this.apiKey = '',
    this.baseUrl = 'https://api.deepseek.com',
    this.modelName = 'deepseek-chat',
  });

  static const _keys = {
    'cookie': 'weread_cookie',
    'credentials': 'weread_mobile_credentials',
    'apiKey': 'weread_api_key',
    'baseUrl': 'weread_base_url',
    'modelName': 'weread_model_name',
    'trustedAccountId': 'weread_trusted_account_id',
  };

  bool get isConfigured => credentials != null || cookie.isNotEmpty;

  Future<void> loadLogoutPending() async {
    final prefs = await SharedPreferences.getInstance();
    logoutPending = prefs.getBool(_logoutPendingKey) ?? false;
  }

  Future<void> beginLogout() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_logoutPendingKey, true)) {
      throw StateError('退出标记保存失败，请重试');
    }
    logoutPending = true;
  }

  Future<void> finishLogout() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_logoutPendingKey)) {
      throw StateError('退出标记清除失败，请重试');
    }
    logoutPending = false;
  }

  Future<void> saveCredentials() => _saveSecret(_keys['credentials']!,
      credentials == null ? '' : jsonEncode(credentials!.toJson()));

  /// Persist a rotated credential before publishing it to request interceptors.
  Future<void> persistCredentials(Credentials next) =>
      _saveSecret(_keys['credentials']!, jsonEncode(next.toJson()));

  Future<void> retryPendingCredentials() async {
    final pending = pendingCredentials;
    if (pending == null) return;
    await persistCredentials(pending);
    if (!identical(pendingCredentials, pending)) return;
    credentials = pending;
    pendingCredentials = null;
    credentialRevalidation.value = null;
  }

  static bool isHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  Future<String> _loadSecret(SharedPreferences prefs, String key) async {
    final stored = await _secureStorage.read(key: key);
    final legacy = prefs.getString(key);
    if (stored == null && legacy != null) {
      // 写入成功后才删除旧值，迁移失败时可重试。
      await _secureStorage.write(key: key, value: legacy);
    }
    if (legacy != null) await prefs.remove(key);
    final value = stored ?? legacy ?? '';
    _persistedSecrets[key] = value;
    return value;
  }

  Future<void> _saveSecret(String key, String value) async {
    final previous = _persistedSecrets[key] ?? await _secureStorage.read(key: key) ?? '';
    if (previous == value) { _persistedSecrets[key] = value; return; }
    if (value.isEmpty) {
      await _secureStorage.delete(key: key);
    } else {
      await _secureStorage.write(key: key, value: value);
    }
    _persistedSecrets[key] = value;
  }

  /// 本地账号恢复独立于安全存储，凭据暂时不可读时仍可浏览缓存。
  Future<void> loadTrustedAccount() async {
    final pending = _pendingTrustedAccountId;
    if (pending != null) {
      await trustAccount(pending);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final trustedId = prefs.getString(_keys['trustedAccountId']!);
    trustedAccountId = trustedId != null &&
            RegExp(r'^[0-9]+$').hasMatch(trustedId) &&
            trustedId != '0'
        ? trustedId
        : null;
  }

  Future<void> load() async {
    await retryPendingCredentials();
    final prefs = await SharedPreferences.getInstance();
    // Reload preferences before secret migration removes legacy plaintext.
    // A concurrent reload could otherwise restore stale cache entries.
    await loadTrustedAccount();
    final values = await Future.wait<String?>([
      _loadSecret(prefs, _keys['cookie']!),
      _secureStorage.read(key: _keys['credentials']!),
      _loadSecret(prefs, _keys['apiKey']!),
    ]);
    cookie = values[0] ?? '';
    final mobile = values[1];
    _persistedSecrets[_keys['credentials']!] = mobile ?? '';
    credentials = mobile == null
        ? null
        : Credentials.fromJson(jsonDecode(mobile) as Map<String, dynamic>);
    if (credentials != null) cookie = '';
    apiKey = values[2] ?? '';
    baseUrl = prefs.getString(_keys['baseUrl']!) ?? 'https://api.deepseek.com';
    if (!isHttpsUrl(baseUrl)) baseUrl = '';
    modelName = prefs.getString(_keys['modelName']!) ?? 'deepseek-chat';
    final committedAi = await _secureStorage.read(key: _aiConfigKey);
    if (committedAi != null) _restoreAiConfig(committedAi);
  }

  void _restoreAiConfig(String value) {
    final ai = jsonDecode(value) as Map<String, dynamic>;
    apiKey = ai['apiKey'] as String;
    baseUrl = ai['baseUrl'] as String;
    if (baseUrl.isNotEmpty && !isHttpsUrl(baseUrl)) baseUrl = '';
    modelName = ai['modelName'] as String;
  }

  Future<void> _saveAiConfig(SharedPreferences prefs) async {
    final next = jsonEncode({
      'apiKey': apiKey, 'baseUrl': baseUrl, 'modelName': modelName,
    });
    var previous = await _secureStorage.read(key: _aiConfigKey);
    // Establish a committed legacy snapshot before modifying preferences.
    // The single secure record is authoritative, even if a mirror write or
    // its rollback fails. Never persist a new key separately from its URL.
    if (previous == null) {
      await prefs.reload();
      previous = jsonEncode({
        'apiKey': await _secureStorage.read(key: _keys['apiKey']!) ??
            prefs.getString(_keys['apiKey']!) ?? '',
        'baseUrl': prefs.getString(_keys['baseUrl']!) ?? 'https://api.deepseek.com',
        'modelName': prefs.getString(_keys['modelName']!) ?? 'deepseek-chat',
      });
      await _secureStorage.write(key: _aiConfigKey, value: previous);
    }
    try {
      // Always retry actual writes: SharedPreferences caches failed writes.
      if (!await prefs.setString(_keys['baseUrl']!, baseUrl)) {
        throw StateError('AI 服务地址保存失败，请重试');
      }
      if (!await prefs.setString(_keys['modelName']!, modelName)) {
        throw StateError('AI 模型名称保存失败，请重试');
      }
      if (next != previous) {
        await _secureStorage.write(key: _aiConfigKey, value: next);
      }
    } catch (_) {
      _restoreAiConfig(previous);
      // Mirrors are best-effort; load() always uses the committed record.
      try {
        await prefs.setString(_keys['baseUrl']!, baseUrl);
        await prefs.setString(_keys['modelName']!, modelName);
        await prefs.reload();
      } catch (_) {
        // A storage outage cannot change the committed key/URL pair.
      }
      rethrow;
    }
  }

  Future<void> save() async {
    if (baseUrl.isNotEmpty && !isHttpsUrl(baseUrl)) {
      throw const FormatException('AI 服务地址必须是有效的 HTTPS 地址');
    }
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      _saveSecret(_keys['cookie']!, cookie), saveCredentials(),
    ]);
    if (prefs.containsKey(_keys['cookie']!)) await prefs.remove(_keys['cookie']!);
    await _saveAiConfig(prefs);
  }

  Future<void> clear() async {
    await clearTrustedAccount();
    cookie = '';
    credentials = null;
    pendingCredentials = null;
    credentialsInvalid.value = false;
    apiKey = '';
    baseUrl = 'https://api.deepseek.com';
    modelName = 'deepseek-chat';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keys['cookie']!);
    await prefs.remove(_keys['apiKey']!);
    await prefs.remove(_keys['baseUrl']!);
    await prefs.remove(_keys['modelName']!);
    await _secureStorage.delete(key: _keys['cookie']!);
    await _secureStorage.delete(key: _keys['credentials']!);
    await _secureStorage.delete(key: _keys['apiKey']!);
    await _secureStorage.delete(key: _aiConfigKey);
    _persistedSecrets.clear();
  }

  /// 仅在服务器确认账号归属后调用，不从 Cookie 推导可信记录。
  Future<void> trustAccount(String accountId) async {
    if (!RegExp(r'^[0-9]+$').hasMatch(accountId) || accountId == '0') {
      throw ArgumentError('无效的账号 ID');
    }
    final prefs = await SharedPreferences.getInstance();
    _pendingTrustedAccountId = accountId;
    if (!await prefs.setString(_keys['trustedAccountId']!, accountId)) {
      throw StateError('可信账号保存失败');
    }
    _pendingTrustedAccountId = null;
    trustedAccountId = accountId;
  }

  Future<void> clearTrustedAccount() async {
    _pendingTrustedAccountId = null;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_keys['trustedAccountId']!)) {
      throw StateError('可信账号清除失败');
    }
    trustedAccountId = null;
  }

  Map<String, dynamic> toJson() => {
        'cookie': cookie,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'modelName': modelName,
      };
}
