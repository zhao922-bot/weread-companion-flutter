import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppConfig {
  static const _storage = FlutterSecureStorage();

  String cookie;
  String apiKey;
  String baseUrl;
  String modelName;

  AppConfig({
    this.cookie = '',
    this.apiKey = '',
    this.baseUrl = 'https://api.deepseek.com',
    this.modelName = 'deepseek-chat',
  });

  static const _keys = {
    'cookie': 'weread_cookie',
    'apiKey': 'weread_api_key',
    'baseUrl': 'weread_base_url',
    'modelName': 'weread_model_name',
  };

  bool get isConfigured => cookie.isNotEmpty;

  Future<void> load() async {
    cookie = await _storage.read(key: _keys['cookie']!) ?? '';
    apiKey = await _storage.read(key: _keys['apiKey']!) ?? '';
    baseUrl = await _storage.read(key: _keys['baseUrl']!) ?? 'https://api.deepseek.com';
    modelName = await _storage.read(key: _keys['modelName']!) ?? 'deepseek-chat';
  }

  Future<void> save() async {
    await _storage.write(key: _keys['cookie']!, value: cookie);
    await _storage.write(key: _keys['apiKey']!, value: apiKey);
    await _storage.write(key: _keys['baseUrl']!, value: baseUrl);
    await _storage.write(key: _keys['modelName']!, value: modelName);
  }

  Future<void> clear() async {
    await _storage.deleteAll();
    cookie = '';
    apiKey = '';
    baseUrl = 'https://api.deepseek.com';
    modelName = 'deepseek-chat';
  }

  Map<String, dynamic> toJson() => {
        'cookie': cookie,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'modelName': modelName,
      };
}
