import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';

class _RemoveFailureStore extends InMemorySharedPreferencesStore {
  _RemoveFailureStore() : super.empty();
  String? failedKey;
  final removals = <String>[];

  @override
  Future<bool> remove(String key) async {
    removals.add(key);
    if (key == failedKey) return false;
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final secrets = <String, String>{};
  late Directory directory;
  late _RemoveFailureStore store;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('weread-cleanup-review-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({});
    store = _RemoveFailureStore();
    SharedPreferencesStorePlatform.instance = store;
    secrets.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return secrets[key];
        case 'write':
          secrets[key] = args['value'] as String;
          return null;
        case 'delete':
          secrets.remove(key);
          return null;
      }
      throw UnsupportedError(call.method);
    });
  });
  tearDown(() async {
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(paths, null);
  });

  for (final key in ['weread_cookie', 'weread_api_key']) {
    test('旧$key迁移后的明文删除返回false时报告失败并可重试', () async {
      await store.setValue('String', 'flutter.$key', 'legacy-value');
      store.failedKey = 'flutter.$key';
      final config = AppConfig();
      await expectLater(config.load(), throwsStateError);
      expect(secrets[key], 'legacy-value');
      expect((await store.getAll())['flutter.$key'], 'legacy-value');
      store.failedKey = null;
      await config.load();
      expect((await store.getAll()).containsKey('flutter.$key'), isFalse);
      expect(secrets[key], 'legacy-value');
    });
  }

  test('保存Cookie删除旧明文失败，缓存已删除也必须真正重试', () async {
    await store.setValue('String', 'flutter.weread_cookie', 'old-cookie');
    store.failedKey = 'flutter.weread_cookie';
    final config = AppConfig(cookie: 'wr_vid=123; wr_skey=new');
    await expectLater(config.save(), throwsStateError);
    store.failedKey = null;
    await config.save();
    expect(store.removals.where((key) => key == 'flutter.weread_cookie'),
        hasLength(2));
    expect(
        (await store.getAll()).containsKey('flutter.weread_cookie'), isFalse);
    expect(secrets['weread_cookie'], 'wr_vid=123; wr_skey=new');
  });

  test('退出删除旧配置返回false保留清理标记，重启重试后不能恢复旧密钥', () async {
    await store.setValue('String', 'flutter.weread_api_key', 'old-key');
    store.failedKey = 'flutter.weread_api_key';
    final provider = AppConfigProvider(config: AppConfig());
    addTearDown(provider.dispose);
    await expectLater(provider.logout(), throwsStateError);
    expect(provider.cleanupPending, isTrue);
    expect(provider.canBrowseLocal, isFalse);
    expect((await store.getAll())['flutter.weread_logout_pending'], isTrue);
    final restarted = AppConfigProvider(config: AppConfig());
    addTearDown(restarted.dispose);
    await restarted.init();
    expect(restarted.cleanupPending, isTrue);
    expect(restarted.isLoggedIn, isFalse);
    store.failedKey = null;
    await restarted.logout();
    expect(restarted.cleanupPending, isFalse);
    final restored = AppConfig();
    await restored.load();
    expect(restored.apiKey, isEmpty);
    expect(restored.cookie, isEmpty);
    expect(secrets, isEmpty);
    expect(
        (await store.getAll()).containsKey('flutter.weread_api_key'), isFalse);
  });

  test('退出标记删除失败后重新初始化读取持久化标记，不相信失败操作的缓存', () async {
    store.failedKey = 'flutter.weread_logout_pending';
    final provider = AppConfigProvider(config: AppConfig());
    addTearDown(provider.dispose);
    await expectLater(provider.logout(), throwsStateError);
    expect((await store.getAll())['flutter.weread_logout_pending'], isTrue);
    final restarted = AppConfigProvider(config: AppConfig());
    addTearDown(restarted.dispose);
    await restarted.init();
    expect(restarted.cleanupPending, isTrue);
    expect(restarted.loginStatus, LoginStatus.cleanupPending);
    store.failedKey = null;
    await restarted.logout();
    expect(restarted.cleanupPending, isFalse);
  });
}
