import 'dart:async';
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
  static Future<void>? _credentialWriteTail;
  static Future<void>? _trustedAccountWriteTail;
  int _trustedAccountRevision = 0;
  static int _trustedAccountGeneration = 0;
  int? _pendingTrustedAccountGeneration;

  static Future<void> _serializeTrustedAccountWrite(Future<void> Function() action) async {
    final previous = _trustedAccountWriteTail;
    final done = Completer<void>();
    _trustedAccountWriteTail = done.future;
    try {
      if (previous != null) await previous;
      await action();
    } finally {
      if (identical(_trustedAccountWriteTail, done.future)) _trustedAccountWriteTail = null;
      done.complete();
    }
  }

  // Secure storage is shared even by distinct AppConfig instances. Logout and
  // a new login must run after an older refresh write has settled.
  static Future<void> _serializeCredentialWrite(Future<void> Function() action) async {
    final previous = _credentialWriteTail;
    final done = Completer<void>();
    _credentialWriteTail = done.future;
    try {
      if (previous != null) await previous;
      await action();
    } finally {
      if (identical(_credentialWriteTail, done.future)) _credentialWriteTail = null;
      done.complete(); // Failure must not poison the next write or cleanup.
    }
  }

  Future<void> _saveCredentials(String value) => _serializeCredentialWrite(() async {
    // Another config instance may have changed this shared record.
    _persistedSecrets.remove(_keys['credentials']!);
    await _saveSecret(_keys['credentials']!, value);
  });

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
    await prefs.reload();
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

  Future<void> saveCredentials() => _saveCredentials(
      credentials == null ? '' : jsonEncode(credentials!.toJson()));

  /// Persist a rotated credential before publishing it to request interceptors.
  Future<void> persistCredentials(Credentials next) =>
      _saveCredentials(jsonEncode(next.toJson()));

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
    if (legacy != null) await _removePreference(prefs, key);
    final value = stored ?? legacy ?? '';
    _persistedSecrets[key] = value;
    return value;
  }

  Future<void> _removePreference(SharedPreferences prefs, String key) async {
    // A false result still removes the cached value. Always retry the actual
    // removal so logout/migration cannot report success with plaintext on disk.
    if (!await prefs.remove(key)) {
      throw StateError('本地配置清除失败，请重试');
    }
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
    while (true) {
      // Join an in-flight write instead of enqueueing the same pending value.
      final writing = _trustedAccountWriteTail;
      if (writing != null) { await writing; continue; }
      final pending = _pendingTrustedAccountId;
      if (pending != null &&
          _pendingTrustedAccountGeneration == _trustedAccountGeneration) {
        await trustAccount(pending);
        continue;
      }
      _pendingTrustedAccountId = null;
      _pendingTrustedAccountGeneration = null;
      final generation = _trustedAccountGeneration;
      await _serializeTrustedAccountWrite(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        if (generation != _trustedAccountGeneration) return;
        final trustedId = prefs.getString(_keys['trustedAccountId']!);
        trustedAccountId = trustedId != null &&
                RegExp(r'^[0-9]+$').hasMatch(trustedId) && trustedId != '0'
            ? trustedId : null;
      });
      // A newer login/cleanup queued while reload was pending. Read its result.
      if (generation == _trustedAccountGeneration) return;
    }
  }

  Future<void> load() async {
    await loadLogoutPending();
    if (logoutPending) throw StateError('请先完成退出清理');
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

  void _validateAiUrl() {
    if (baseUrl.isNotEmpty && !isHttpsUrl(baseUrl)) {
      throw const FormatException('AI 服务地址必须是有效的 HTTPS 地址');
    }
  }

  /// AI edits must not enqueue an old login credential behind a token refresh.
  Future<void> saveAiConfig() async {
    _validateAiUrl();
    await _saveAiConfig(await SharedPreferences.getInstance());
  }

  Future<void> save() async {
    _validateAiUrl();
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      _saveSecret(_keys['cookie']!, cookie), saveCredentials(),
    ]);
    await _removePreference(prefs, _keys['cookie']!);
    await _saveAiConfig(prefs);
  }

  Future<void> clear() async {
    cookie = '';
    credentials = null;
    pendingCredentials = null;
    credentialsInvalid.value = false;
    credentialRevalidation.value = null;
    apiKey = '';
    baseUrl = 'https://api.deepseek.com';
    modelName = 'deepseek-chat';
    final failures = <Object>[];
    Future<void> clean(Future<void> Function() action) async {
      try { await action(); } catch (error) { failures.add(error); }
    }
    // Each store/key is independent. An unavailable preference or secret must
    // not prevent deleting the remaining credentials, including mobile tokens.
    await clean(clearTrustedAccount);
    for (final name in ['cookie', 'apiKey', 'baseUrl', 'modelName']) {
      await clean(() async => _removePreference(
          await SharedPreferences.getInstance(), _keys[name]!));
    }
    await clean(() => _secureStorage.delete(key: _keys['cookie']!));
    await clean(() => _serializeCredentialWrite(() => _secureStorage.delete(key: _keys['credentials']!)));
    await clean(() => _secureStorage.delete(key: _keys['apiKey']!));
    await clean(() => _secureStorage.delete(key: _aiConfigKey));
    _persistedSecrets.clear();
    if (failures.isNotEmpty) throw StateError('凭据和配置清理未完成，请重试');
  }

  /// 仅在服务器确认账号归属后调用，不从 Cookie 推导可信记录。
  Future<void> trustAccount(String accountId) async {
    if (!RegExp(r'^[0-9]+$').hasMatch(accountId) || accountId == '0') {
      throw ArgumentError('无效的账号 ID');
    }
    final revision = ++_trustedAccountRevision;
    final generation = ++_trustedAccountGeneration;
    _pendingTrustedAccountId = accountId;
    _pendingTrustedAccountGeneration = generation;
    await _serializeTrustedAccountWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_keys['trustedAccountId']!, accountId)) {
        throw StateError('可信账号保存失败');
      }
    });
    if (revision == _trustedAccountRevision && generation == _trustedAccountGeneration) {
      _pendingTrustedAccountId = null;
      _pendingTrustedAccountGeneration = null;
      trustedAccountId = accountId;
    }
  }

  Future<void> clearTrustedAccount() async {
    final revision = ++_trustedAccountRevision;
    final generation = ++_trustedAccountGeneration;
    _pendingTrustedAccountId = null;
    _pendingTrustedAccountGeneration = null;
    await _serializeTrustedAccountWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_keys['trustedAccountId']!)) {
        throw StateError('可信账号清除失败');
      }
    });
    if (revision == _trustedAccountRevision && generation == _trustedAccountGeneration) {
      trustedAccountId = null;
    }
  }

  Map<String, dynamic> toJson() => {
        'cookie': cookie,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'modelName': modelName,
      };
}
