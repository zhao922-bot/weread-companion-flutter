import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqlite3/open.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/widgets/settings/account_settings_section.dart';

class _MobileAdapter implements HttpClientAdapter {
  bool expired = false;
  int mints = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body,
      Future<void>? cancel) async {
    if (options.path == '/login') mints++;
    return ResponseBody.fromString(expired ? '{"errCode":-2012}' : '{"books":[]}', 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }
  @override
  void close({bool force = false}) {}
}


class _UnpersistableTrustConfig extends AppConfig {
  @override
  Future<void> trustAccount(String accountId) async {
    throw StateError('可信账号保存失败');
  }
}

class _TrustPreferencesStore extends InMemorySharedPreferencesStore {
  _TrustPreferencesStore() : super.empty();
  bool failTrust = true;
  int trustWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.weread_trusted_account_id') {
      trustWrites++;
      if (failTrust) return false;
    }
    return super.setValue(valueType, key, value);
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
    expect(provider.isLoaded, isFalse);
    expect(provider.isLoading, isTrue);
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
    expect(provider.isLoaded, isFalse);
    expect(provider.configLoadError, isNotNull);
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

  test('可信账号首次落盘返回false，同账号重验证必须真写入，离线重启恢复笔记', () async {
    final store = _TrustPreferencesStore();
    SharedPreferencesStorePlatform.instance = store;
    await AppConfig(cookie: 'wr_vid=123; wr_skey=test').save();
    online = true;
    await provider.init();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('weread_trusted_account_id'), '123');
    expect((await store.getAll())['flutter.weread_trusted_account_id'], isNull);
    expect(provider.config.trustedAccountId, isNull);
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.isLoggedIn, isFalse);
    expect(() => DatabaseService.instance, throwsStateError);
    expect(store.trustWrites, 1);

    // The cache contains the same ID, but another failed write is not success.
    expect(await provider.verifyForSync(), isFalse);
    expect(store.trustWrites, 2);
    expect(provider.canBrowseLocal, isFalse);
    expect(() => DatabaseService.instance, throwsStateError);
    store.failTrust = false;
    expect(await provider.verifyForSync(), isTrue);
    expect(store.trustWrites, 3);
    expect((await store.getAll())['flutter.weread_trusted_account_id'], '123');
    await DatabaseService.instance.insertNotes([
      {'note_id': 'retry-note', 'book_id': 'book', 'content': '重试后持久化的笔记', 'created_at': 1},
    ]);

    // No unrelated preferences write occurs between trust persistence and death.
    provider.dispose();
    await DatabaseService.endSession();
    await prefs.reload();
    online = false;
    provider = createProvider();
    await provider.init();
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.config.trustedAccountId, '123');
    expect((await DatabaseService.instance.getAllNotes()).single['content'],
        '重试后持久化的笔记');
  });

  test('未落盘可信账号不能由缓存恢复，启动加载会重试待保存账号', () async {
    final store = _TrustPreferencesStore();
    SharedPreferencesStorePlatform.instance = store;
    final config = AppConfig();
    await expectLater(config.trustAccount('123'), throwsStateError);
    expect((await SharedPreferences.getInstance()).getString('weread_trusted_account_id'), '123');
    final fresh = AppConfig();
    await fresh.loadTrustedAccount();
    expect(fresh.trustedAccountId, isNull);
    await expectLater(config.loadTrustedAccount(), throwsStateError);
    expect(store.trustWrites, 2);
    store.failTrust = false;
    await config.loadTrustedAccount();
    expect(store.trustWrites, 3);
    expect(config.trustedAccountId, '123');
    await fresh.loadTrustedAccount();
    expect(fresh.trustedAccountId, '123');
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

  test('退出标记落盘后中断，重启先完成清理且不恢复旧账号', () async {
    await seedTrustedAccount();
    final interrupted = AppConfig();
    await interrupted.beginLogout();
    // Simulate process death before either credentials or cached data is removed.
    expect(secrets['weread_cookie'], isNotNull);
    online = true;
    await provider.init();
    expect(provider.isLoaded, isTrue);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.hasSavedCredentials, isFalse);
    expect(secrets, isEmpty);
    expect(() => DatabaseService.instance, throwsStateError);
    expect((await SharedPreferences.getInstance())
        .containsKey('weread_logout_pending'), isFalse);
    expect(await directory.list().isEmpty, isTrue);
  });

  test('已验证账号在同步刷新失效后立即降级，下一次同步重新验证', () async {
    final config = AppConfig(credentials: const Credentials(
        vid: '123', accessToken: 'old', refreshToken: 'refresh', deviceId: 'device'));
    await config.save();
    final adapter = _MobileAdapter();
    provider.dispose();
    provider = AppConfigProvider(config: config, loginApi: (config) =>
        WeReadApi.forLogin(config: config, dio: Dio()..httpClientAdapter = adapter));
    await provider.init();
    expect(provider.isLoggedIn, isTrue);
    adapter.expired = true;
    final syncApi = WeReadApi.forLogin(config: config,
        dio: Dio()..httpClientAdapter = adapter);
    await expectLater(syncApi.fetchNotes('book', '书名'), throwsA(isA<DioException>()));
    expect(provider.loginStatus, LoginStatus.invalid);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.loginStatusText, contains('凭据失效'));
    expect(await provider.verifyForSync(), isFalse);
    expect(adapter.mints, 2);
    syncApi.dispose();
  });

  testWidgets('数据库清理失败但凭据已清除，重启保留继续清理入口并可重试成功', (tester) async {
    await tester.runAsync(() async {
    await seedTrustedAccount();
    await provider.init();
    await DatabaseService.endSession();
    final originalFactory = databaseFactory;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.tekartik.sqflite'), (call) async {
      if (call.method == 'getDatabasesPath') return directory.path;
      if (call.method == 'deleteDatabase') throw PlatformException(code: 'delete-failed');
      throw UnsupportedError(call.method);
    });
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() { databaseFactory = originalFactory; });
    await expectLater(provider.logout(), throwsStateError);
    expect(provider.cleanupPending, isTrue);
    expect(provider.loginStatus, LoginStatus.cleanupPending);
    expect(provider.loginError, contains('本地数据库'));
    expect(provider.hasSavedCredentials, isFalse);
    expect(secrets, isEmpty);
    expect(await directory.list().isEmpty, isFalse);

    provider.dispose();
    provider = createProvider();
    await provider.init();
    expect(provider.cleanupPending, isTrue);
    expect(provider.canBrowseLocal, isFalse);
    expect(await provider.verifyForSync(), isFalse);
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(home: Scaffold(body: AccountSettingsSection())),
    ));
    expect(find.text('继续清理'), findsOneWidget);
    expect(find.text('登录'), findsNothing);

    databaseFactory = databaseFactoryFfiNoIsolate;
    await tester.runAsync(() async {
      await tester.tap(find.text('继续清理'));
      // Wait for the asynchronous filesystem/database cleanup to finish.
      while (provider.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(provider.cleanupPending, isFalse);
    expect(provider.loginStatus, LoginStatus.signedOut);
    expect(await tester.runAsync(() => directory.list().isEmpty), isTrue);
    expect(find.text('继续清理'), findsNothing);
    expect(find.text('登录'), findsOneWidget);
  });
}
