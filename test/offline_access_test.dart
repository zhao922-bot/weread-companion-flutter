import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';

class _UnpersistableTrustConfig extends AppConfig {
  @override
  Future<void> trustAccount(String accountId) async {
    throw StateError('可信账号保存失败');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};
  late Directory directory;
  late AppConfigProvider provider;
  var online = false;
  var valid = true;
  var storageUnavailable = false;
  Completer<void>? responseGate;

  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    databaseFactory = databaseFactoryFfiNoIsolate;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storage, (call) async {
      if (storageUnavailable) {
        throw PlatformException(code: 'storage_unavailable');
      }
      final args = Map<String, dynamic>.from(call.arguments as Map);
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
        default:
          throw StateError('Unexpected storage call');
      }
    });
  });

  AppConfigProvider createProvider({AppConfig? config}) => AppConfigProvider(
        config: config ?? AppConfig(),
        loginApi: (config) {
          final dio = Dio();
          dio.interceptors
              .add(InterceptorsWrapper(onRequest: (request, handler) async {
            await responseGate?.future;
            if (!online) {
              handler.reject(DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError));
            } else {
              handler.resolve(Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: valid ? {'vid': '123'} : <String, dynamic>{}));
            }
          }));
          return WeReadApi.forLogin(config: config, dio: dio);
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets.clear();
    online = false;
    valid = true;
    storageUnavailable = false;
    responseGate = null;
    directory = await Directory.systemTemp.createTemp('weread-offline-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
    await databaseFactory.setDatabasesPath(directory.path);
    provider = createProvider();
  });

  tearDown(() async {
    provider.dispose();
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });

  Future<void> seedTrustedAccount() async {
    final config = AppConfig(cookie: 'wr_vid=123; wr_skey=test');
    await config.save();
    await config.trustAccount('123');
    await DatabaseService.selectAccount('123');
    await DatabaseService.instance.insertNotes([
      {
        'note_id': 'offline-note',
        'book_id': 'book',
        'content': '已同步笔记',
        'created_at': 1,
      }
    ]);
    await DatabaseService.endSession();
  }

  test('可信账号在联网验证完成前即可访问本地笔记，断网后保留访问', () async {
    await seedTrustedAccount();
    responseGate = Completer<void>();
    final localReady = Completer<void>();
    provider.addListener(() {
      if (provider.canBrowseLocal && !localReady.isCompleted) {
        localReady.complete();
      }
    });
    final initialization = provider.init();
    await localReady.future;
    expect(provider.isBusy, isTrue);
    expect(provider.isLoggedIn, isFalse);
    final db = await DatabaseService.instance.database;
    expect((await db.query('notes')).single['content'], '已同步笔记');
    responseGate!.complete();
    await initialization;
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.needsOnlineSync, isTrue);
    expect(provider.loginError, contains('本地数据可浏览'));
    online = true;
    expect(await provider.verifyForSync(), isTrue);
    expect(provider.needsOnlineSync, isFalse);
    expect(identical(db, await DatabaseService.instance.database), isTrue);
  });

  test('未验证的 Cookie 不授予离线数据库访问，验证成功才持久化账号', () async {
    await AppConfig(cookie: 'wr_vid=123; wr_skey=test').save();
    await provider.init();
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.config.trustedAccountId, isNull);
    expect(() => DatabaseService.instance, throwsStateError);
    online = true;
    expect(await provider.verifyForSync(), isTrue);
    final restored = AppConfig();
    await restored.load();
    expect(restored.trustedAccountId, '123');
  });

  test('安全存储暂时不可读不阻塞可信账号离线启动', () async {
    await seedTrustedAccount();
    storageUnavailable = true;
    await provider.init();
    expect(provider.isLoaded, isTrue);
    expect(provider.isBusy, isFalse);
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.needsOnlineSync, isTrue);
    expect(provider.loginError, contains('本地数据可浏览'));
    expect((await DatabaseService.instance.getAllNotes()).single['content'],
        '已同步笔记');
  });

  test('首次验证无法保存可信账号时关闭数据库会话', () async {
    await AppConfig(cookie: 'wr_vid=123; wr_skey=test').save();
    provider.dispose();
    provider = createProvider(config: _UnpersistableTrustConfig());
    online = true;
    await provider.init();
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.config.trustedAccountId, isNull);
    expect(() => DatabaseService.instance, throwsStateError);
  });

  test('仅有可信账号而无凭据时可离线浏览，重启和退出行为一致', () async {
    await seedTrustedAccount();
    secrets.clear();
    await provider.init();
    expect(provider.hasSavedCredentials, isFalse);
    expect(provider.canBrowseLocal, isTrue);
    expect(await provider.verifyForSync(), isFalse);
    await provider.logout();
    provider.dispose();
    provider = createProvider();
    await provider.init();
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.config.trustedAccountId, isNull);
    expect(() => DatabaseService.instance, throwsStateError);
  });

  test('已保存凭据与可信账号不匹配时不能切换本地数据或同步', () async {
    await seedTrustedAccount();
    await AppConfig(cookie: 'wr_vid=456; wr_skey=other').save();
    online = true;
    await provider.init();
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.loginStatus, LoginStatus.invalid);
    expect(await provider.verifyForSync(), isFalse);
    expect(DatabaseService.instance.accountId, '123');
    expect(provider.config.trustedAccountId, '123');
  });

  test('凭据失效仍可浏览本地，但不能同步；退出清除可信账号', () async {
    await seedTrustedAccount();
    online = true;
    valid = false;
    await provider.init();
    expect(provider.loginStatus, LoginStatus.invalid);
    expect(provider.canBrowseLocal, isTrue);
    expect(await provider.verifyForSync(), isFalse);
    await provider.logout();
    expect(provider.canBrowseLocal, isFalse);
    final restored = AppConfig();
    await restored.load();
    expect(restored.trustedAccountId, isNull);
    expect(restored.isConfigured, isFalse);
    expect(() => DatabaseService.instance, throwsStateError);
  });

  test('更换账号失败不继承旧可信账号访问权', () async {
    await seedTrustedAccount();
    await provider.init();
    await provider.loginWithCookie('wr_vid=456; wr_skey=other');
    expect(provider.canBrowseLocal, isFalse);
    final restored = AppConfig();
    await restored.load();
    expect(restored.trustedAccountId, isNull);
    expect(() => DatabaseService.instance, throwsStateError);
  });
}
