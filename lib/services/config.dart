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
  };

  bool get isConfigured => credentials != null || cookie.isNotEmpty;

  Future<void> saveCredentials() => _saveSecret(
      _keys['credentials']!,
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
    await prefs.remove(key);
    return stored ?? legacy ?? '';
  }

  Future<void> _saveSecret(String key, String value) async {
    if (value.isEmpty) {
      await _secureStorage.delete(key: key);
    } else {
      await _secureStorage.write(key: key, value: value);
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    cookie = await _loadSecret(prefs, _keys['cookie']!);
    final mobile = await _secureStorage.read(key: _keys['credentials']!);
    credentials = mobile == null
        ? null
        : Credentials.fromJson(jsonDecode(mobile) as Map<String, dynamic>);
    if (credentials != null) cookie = '';
    apiKey = await _loadSecret(prefs, _keys['apiKey']!);
    baseUrl = prefs.getString(_keys['baseUrl']!) ?? 'https://api.deepseek.com';
    if (!isHttpsUrl(baseUrl)) baseUrl = '';
    modelName = prefs.getString(_keys['modelName']!) ?? 'deepseek-chat';
  }

  Future<void> save() async {
    if (baseUrl.isNotEmpty && !isHttpsUrl(baseUrl)) {
      throw const FormatException('AI 服务地址必须是有效的 HTTPS 地址');
    }
    final prefs = await SharedPreferences.getInstance();
    await _saveSecret(_keys['cookie']!, cookie);
    await saveCredentials();
    await _saveSecret(_keys['apiKey']!, apiKey);
    await prefs.remove(_keys['cookie']!);
    await prefs.remove(_keys['apiKey']!);
    await prefs.setString(_keys['baseUrl']!, baseUrl);
    await prefs.setString(_keys['modelName']!, modelName);
  }

  Future<void> clear() async {
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
  }

  Map<String, dynamic> toJson() => {
        'cookie': cookie,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'modelName': modelName,
      };
}
