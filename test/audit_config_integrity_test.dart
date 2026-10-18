import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';

import 'mobile_auth_test.dart' show AuthAdapter, initial, jsonResponse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const credentialKey = 'weread_mobile_credentials';
  final secrets = <String, String>{};
  final operations = <String>[];
  late Future<void> Function(String, String)? beforeWrite;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets.clear();
    operations.clear();
    beforeWrite = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      operations.add('${call.method}:$key');
      switch (call.method) {
        case 'read':
          return secrets[key];
        case 'write':
          final value = args['value'] as String;
          await beforeWrite?.call(key, value);
          secrets[key] = value;
          return null;
        case 'delete':
          secrets.remove(key);
          return null;
      }
      throw UnsupportedError(call.method);
    });
  });

  tearDown(() {
    WeReadApi.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('AI 设置保存不能在刷新持久化后写回旧令牌，重启保留轮换凭据', () async {
    final config = AppConfig();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    config.credentials = initial;
    await config.saveCredentials();
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeWrite = (key, value) async {
      if (key == credentialKey && jsonDecode(value)['accessToken'] == 'new') {
        entered.complete();
        await release.future;
      }
    };
    final api = WeReadApi.forLogin(
      config: config,
      dio: Dio()
        ..httpClientAdapter = AuthAdapter((r) => jsonResponse(r.path == '/login'
            ? {'accessToken': 'new', 'refreshToken': 'rotated'}
            : r.headers['accessToken'] == 'old'
                ? {'errcode': -2012}
                : {'books': []})),
    );
    final refreshing = api.fetchBookshelf();
    await entered.future.timeout(const Duration(seconds: 5));
    final saving = provider.updateAiConfig(
        apiKey: 'ai-key',
        baseUrl: 'https://ai.example.com',
        modelName: 'model');
    // The mock platform completes in microtasks. Let the AI save reach storage
    // while the token write is still deliberately blocked.
    await Future<void>.delayed(Duration.zero);
    release.complete();
    await Future.wait([refreshing, saving]);
    expect(config.credentials!.accessToken, 'new');
    expect(jsonDecode(secrets[credentialKey]!), config.credentials!.toJson());
    final restarted = AppConfig();
    await restarted.load();
    expect(restarted.credentials!.accessToken, 'new');
    expect(restarted.credentials!.refreshToken, 'rotated');
    expect(restarted.apiKey, 'ai-key');
    expect(restarted.baseUrl, 'https://ai.example.com');
    expect(restarted.modelName, 'model');
  });

  test('仅保存 AI 设置不访问 Cookie 和登录令牌存储', () async {
    final config = AppConfig();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    config.credentials = initial;
    await config.saveCredentials();
    operations.clear();
    await provider.updateAiConfig(apiKey: 'ai-key');
    expect(
        operations.where((op) =>
            op.endsWith(':$credentialKey') || op.endsWith(':weread_cookie')),
        isEmpty);
    expect(jsonDecode(secrets[credentialKey]!), initial.toJson());
    expect(jsonDecode(secrets['weread_ai_config']!)['apiKey'], 'ai-key');
  });
}
