import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
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
    final prefs = await SharedPreferences.getInstance();
    cookie = prefs.getString(_keys['cookie']!) ?? '';
    apiKey = prefs.getString(_keys['apiKey']!) ?? '';
    baseUrl = prefs.getString(_keys['baseUrl']!) ?? 'https://api.deepseek.com';
    modelName = prefs.getString(_keys['modelName']!) ?? 'deepseek-chat';
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keys['cookie']!, cookie);
    await prefs.setString(_keys['apiKey']!, apiKey);
    await prefs.setString(_keys['baseUrl']!, baseUrl);
    await prefs.setString(_keys['modelName']!, modelName);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keys['cookie']!);
    await prefs.remove(_keys['apiKey']!);
    await prefs.remove(_keys['baseUrl']!);
    await prefs.remove(_keys['modelName']!);
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
