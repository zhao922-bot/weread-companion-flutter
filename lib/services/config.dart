import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'credentials.dart';

class AppConfig {
  static const _secureStorage = FlutterSecureStorage();
  String cookie;
  Credentials? credentials;
  String apiKey;
  String baseUrl;
  String modelName;
  String? trustedAccountId;
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

  Future<void> saveCredentials() => _saveSecret(_keys['credentials']!,
      credentials == null ? '' : jsonEncode(credentials!.toJson()));

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
    final prefs = await SharedPreferences.getInstance();
    final trustedId = prefs.getString(_keys['trustedAccountId']!);
    trustedAccountId = trustedId != null &&
            RegExp(r'^[0-9]+$').hasMatch(trustedId) &&
            trustedId != '0'
        ? trustedId
        : null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final values = await Future.wait<String?>([
      _loadSecret(prefs, _keys['cookie']!),
      _secureStorage.read(key: _keys['credentials']!),
      _loadSecret(prefs, _keys['apiKey']!),
      loadTrustedAccount().then((_) => null),
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
  }

  Future<void> save() async {
    if (baseUrl.isNotEmpty && !isHttpsUrl(baseUrl)) {
      throw const FormatException('AI 服务地址必须是有效的 HTTPS 地址');
    }
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      _saveSecret(_keys['cookie']!, cookie), saveCredentials(),
      _saveSecret(_keys['apiKey']!, apiKey),
    ]);
    if (prefs.containsKey(_keys['cookie']!)) await prefs.remove(_keys['cookie']!);
    if (prefs.containsKey(_keys['apiKey']!)) await prefs.remove(_keys['apiKey']!);
    if (prefs.getString(_keys['baseUrl']!) != baseUrl) await prefs.setString(_keys['baseUrl']!, baseUrl);
    if (prefs.getString(_keys['modelName']!) != modelName) await prefs.setString(_keys['modelName']!, modelName);
  }

  Future<void> clear() async {
    await clearTrustedAccount();
    cookie = '';
    credentials = null;
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
    _persistedSecrets.clear();
  }

  /// 仅在服务器确认账号归属后调用，不从 Cookie 推导可信记录。
  Future<void> trustAccount(String accountId) async {
    if (!RegExp(r'^[0-9]+$').hasMatch(accountId) || accountId == '0') {
      throw ArgumentError('无效的账号 ID');
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_keys['trustedAccountId']!) == accountId) {
      trustedAccountId = accountId;
      return;
    }
    if (!await prefs.setString(_keys['trustedAccountId']!, accountId)) {
      throw StateError('可信账号保存失败');
    }
    trustedAccountId = accountId;
  }

  Future<void> clearTrustedAccount() async {
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
