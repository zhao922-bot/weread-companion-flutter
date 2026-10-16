import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/sync_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse, initial;
import 'support/observed_database.dart';
import 'support/wait_until.dart';
import 'sync_database_regression_test.dart' show LegacyDatabase;

class _RecoveryDatabase extends LegacyDatabase {
  _RecoveryDatabase(Database database, this.factory)
      : super(database, '3.40.0');
  final _RecoveryFactory factory;
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
    await factory.beforeClose?.call();
    if (factory.failedCloses > 0) {
      factory.failedCloses--;
      throw StateError('close failed');
    }
    await super.close();
  }
}

class _RecoveryFactory extends ObservedFactory {
  _RecoveryFactory(DatabaseFactory database) : super(database, DatabaseProbe());
  bool failDelete = false;
  int failedCloses = 0;
  Future<void> Function()? beforeClose;
  final handles = <_RecoveryDatabase>[];
  @override
  Future<void> deleteDatabase(String path) async {
    if (failDelete) throw StateError('delete failed');
    await super.deleteDatabase(path);
  }

  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    final handle = _RecoveryDatabase(
        await super.openDatabase(path, options: options), this);
    handles.add(handle);
    return handle;
  }
}

class _RecoveryStore extends InMemorySharedPreferencesStore {
  _RecoveryStore() : super.empty();
  bool failTrust = false;
  bool throwTrust = false;
  int trustWrites = 0;
  Future<void> Function()? afterRead;
  @override
  Future<Map<String, Object>> getAll() async {
    final snapshot = Map<String, Object>.from(await super.getAll());
    await afterRead?.call();
    return snapshot;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.weread_trusted_account_id') {
      trustWrites++;
      if (throwTrust) throw StateError('write failed');
      if (failTrust) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  late _RecoveryFactory factory;
  late _RecoveryStore store;
  late AppConfig config;
  late List<AppConfigProvider> providers;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  final secrets = <String, String>{};

  setUp(() async {
    sqfliteFfiInit();
    directory =
        await Directory.systemTemp.createTemp('weread-verification-recovery-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    factory = _RecoveryFactory(databaseFactoryFfiNoIsolate);
    databaseFactory = factory;
    SharedPreferences.setMockInitialValues({});
    store = _RecoveryStore();
    SharedPreferencesStorePlatform.instance = store;
    providers = [];
    requests = [];
    secrets.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return secrets[key];
      if (call.method == 'write') secrets[key] = args['value'] as String;
      if (call.method == 'delete') secrets.remove(key);
      return null;
    });
    config = AppConfig(credentials: initial);
    await config.saveCredentials();
    respond = (_) => jsonResponse({'books': []});
  });
  tearDown(() async {
    for (final provider in providers) {
      provider.dispose();
    }
    WeReadApi.reset();
    factory.failedCloses = 0;
    factory.failDelete = false;
    await DatabaseService.endSession();
    for (final handle in factory.handles) {
      await handle.delegate.close();
    }
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(paths, null);
  });
  WeReadApi apiFor(AppConfig value) => WeReadApi.forLogin(
      config: value,
      dio: Dio()
        ..httpClientAdapter = AuthAdapter((r) {
          requests.add(r);
          return respond(r);
        }));
  AppConfigProvider providerFor(AppConfig value) {
    final provider = AppConfigProvider(config: value, loginApi: apiFor);
    providers.add(provider);
    return provider;
  }

  for (final throws in [false, true]) {
    for (final replace in [false, true]) {
      test(
          '可信记录${throws ? '抛错' : '返回 false'}后另一配置${replace ? '换号' : '清理'}，旧 pending 不能复活',
          () async {
        store.failTrust = !throws;
        store.throwTrust = throws;
        await expectLater(config.trustAccount('123'), throwsStateError);
        store.failTrust = store.throwTrust = false;
        final next = AppConfig();
        await next.clearTrustedAccount();
        if (replace) await next.trustAccount('456');
        final writes = store.trustWrites;
        await config.loadTrustedAccount();
        expect(config.trustedAccountId, replace ? '456' : isNull);
        expect((await store.getAll())['flutter.weread_trusted_account_id'],
            replace ? '456' : isNull);
        expect(store.trustWrites, writes);
      });
    }
  }

  test('可信记录读取晚于另一配置换号，不把旧读结果发布回内存', () async {
    await config.trustAccount('123');
    final entered = Completer<void>();
    final release = Completer<void>();
    store.afterRead = () async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final loading = config.loadTrustedAccount();
    await entered.future;
    final next = AppConfig();
    final switching = next.trustAccount('456');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    await Future.wait([loading, switching]);
    expect(config.trustedAccountId, '456');
    expect(next.trustedAccountId, '456');
  });

  test('数据库切换失败后不再宣称本地可用，共享验证可重新建立原账号会话', () async {
    final provider = providerFor(config);
    expect(await provider.verifyForSync(), isTrue);
    factory.failDelete = true;
    await expectLater(DatabaseService.selectAccount('456'), throwsStateError);
    factory.failDelete = false;
    final localWasAvailable = provider.canBrowseLocal;
    final results =
        await Future.wait([provider.verifyForSync(), provider.verifyForSync()]);
    expect(localWasAvailable, isFalse);
    expect(results, [true, true]);
    expect(provider.canBrowseLocal, isTrue);
    expect(DatabaseService.instance.accountId, '123');
    expect(DatabaseService.instance.isActive, isTrue);
    expect(requests, hasLength(2));
  });

  test('关闭旧数据库失败后重试切换，先重新关闭旧连接', () async {
    await DatabaseService.selectAccount('123');
    await DatabaseService.instance.database;
    final old = factory.handles.single;
    factory.failedCloses = 1;
    await expectLater(DatabaseService.selectAccount('456'), throwsStateError);
    await DatabaseService.selectAccount('456');
    await DatabaseService.instance.database;
    expect(old.closes, 2);
    expect(DatabaseService.instance.accountId, '456');
  });

  for (final singleBook in [false, true]) {
    testWidgets('共享验证中取消后立即${singleBook ? '重试单书' : '重新同步'}，复用验证且只执行最新操作',
        (tester) async {
      final release = Completer<ResponseBody>();
      respond = (_) => release.future;
      final provider = providerFor(config);
      var connections = 0;
      final previous = SyncResult([
        BookSyncResult(Book(bookId: 'b', title: '失败书'), 0, 0, ['失败'])
      ], 1);
      await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
        value: provider,
        child: MaterialApp(
            home: SyncPage(
          initialResult: singleBook ? previous : null,
          serviceConnector: ({config, isCancelled}) async {
            connections++;
            return SyncService(
                loadBooks: () async => [],
                loadBookmarks: (_) async => 0,
                loadNotes: (_) async => 0,
                isCancelled: isCancelled ?? () => false,
                onChanged: () {});
          },
        )),
      ));
      await tester.pumpAndSettle();
      await tester
          .tap(singleBook ? find.textContaining('点击重试此书') : find.text('开始同步'));
      for (var i = 0; i < 20 && requests.isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(requests, hasLength(1));
      var started = true;
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.tap(find.text('取消同步'));
        await tester.pump();
        await tester.tap(
            singleBook ? find.textContaining('点击重试此书') : find.text('重新同步'));
        await tester.pump();
        if (find.text('取消同步').evaluate().isEmpty) {
          started = false;
          break;
        }
      }
      release.complete(jsonResponse({'books': []}));
      await pumpUntil(tester, () => !provider.isBusy);
      await tester.pumpAndSettle();
      expect(started, isTrue);
      expect(connections, 1);
      expect(requests, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final closeFails in [false, true]) {
    for (final throws in [false, true]) {
      test(
          '共享验证可信写入${throws ? '抛错' : '返回 false'}${closeFails ? '且关闭失败' : ''}，所有入口得到失败并可立即恢复',
          () async {
        store.failTrust = !throws;
        store.throwTrust = throws;
        factory.failedCloses = closeFails ? 1 : 0;
        final provider = providerFor(config);
        Future<Object> verify() => provider
            .verifyForSync()
            .then<Object>((v) => v, onError: (Object e) => e);
        final failed = await Future.wait([verify(), verify(), verify()]);
        final status = provider.loginStatus;
        final error = provider.loginError;
        expect(provider.isBusy, isFalse);
        expect(provider.canBrowseLocal, isFalse);
        expect(() => DatabaseService.instance, throwsStateError);
        store.failTrust = store.throwTrust = false;
        expect(
            await Future.wait(
                [provider.verifyForSync(), provider.verifyForSync()]),
            [true, true]);
        expect(failed, [false, false, false]);
        expect(status, LoginStatus.saved);
        expect(error, contains('保存'));
        expect(provider.isLoggedIn, isTrue);
        expect(provider.loginError, isNull);
        expect(config.trustedAccountId, '123');
        expect(requests, hasLength(2));
        expect(store.trustWrites, 2);
        expect(factory.handles.first.closes, closeFails ? 2 : 1);
      });
    }
  }

  for (final stage in ['delete', 'open', 'close']) {
    test('数据库 $stage 失败后的共享验证重试不会遗留失败任务或旧连接', () async {
      await DatabaseService.selectAccount('456');
      await DatabaseService.instance.database;
      final old = factory.handles.single;
      factory.failDelete = stage == 'delete';
      factory.failOpen = stage == 'open';
      factory.failedCloses = stage == 'close' ? 1 : 0;
      final provider = providerFor(config);
      expect(
          await Future.wait(
              [provider.verifyForSync(), provider.verifyForSync()]),
          [false, false]);
      expect(provider.isBusy, isFalse);
      expect(provider.canBrowseLocal, isFalse);
      expect(provider.loginStatus, LoginStatus.saved);
      expect(provider.loginError, contains('本地'));
      expect(() => DatabaseService.instance, throwsStateError);
      factory.failDelete = false;
      expect(
          await Future.wait(
              [provider.verifyForSync(), provider.verifyForSync()]),
          [true, true]);
      expect(DatabaseService.instance.accountId, '123');
      expect(provider.isLoggedIn, isTrue);
      expect(requests, hasLength(2));
      expect(old.closes, stage == 'close' ? 2 : 1);
      expect(store.trustWrites, 1);
    });
  }

  test('可信写入失败后启动恢复重试，断网时仍能恢复已验证账号的本地数据', () async {
    final provider = providerFor(config);
    store.failTrust = true;
    expect(await provider.verifyForSync(), isFalse);
    store.failTrust = false;
    respond = (r) => throw DioException(
        requestOptions: r, type: DioExceptionType.connectionError);
    await provider.init();
    expect(provider.isLoaded, isTrue);
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.needsOnlineSync, isTrue);
    expect(config.trustedAccountId, '123');
    expect(store.trustWrites, 2);
  });

  test('并发读取等待当前可信写入，避免重复持久化同一账号', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    // Hold getInstance/reload before a trust write can enter the queue.
    store.afterRead = () async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final trusting = config.trustAccount('123');
    await entered.future;
    final first = config.loadTrustedAccount();
    final second = config.loadTrustedAccount();
    release.complete();
    await Future.wait([trusting, first, second]);
    expect(config.trustedAccountId, '123');
    expect(store.trustWrites, 1);
  });

  for (final stage in ['delete', 'open', 'close']) {
    test('启动恢复数据库 $stage 失败后再次初始化，恢复本地与在线状态', () async {
      await config.trustAccount('123');
      await DatabaseService.selectAccount('123');
      await DatabaseService.instance.database;
      factory.failDelete = stage == 'delete';
      factory.failOpen = stage == 'open';
      factory.failedCloses = stage == 'close' ? 1 : 0;
      final provider = providerFor(AppConfig());
      await provider.init();
      expect(provider.isLoaded, isFalse);
      expect(provider.configLoadError, isNotNull);
      expect(provider.canBrowseLocal, isFalse);
      expect(provider.isLoggedIn, isFalse);
      expect(requests, isEmpty);
      factory.failDelete = false;
      await provider.init();
      expect(provider.isLoaded, isTrue);
      expect(provider.configLoadError, isNull);
      expect(provider.canBrowseLocal, isTrue);
      expect(provider.isLoggedIn, isTrue);
      expect(DatabaseService.instance.accountId, '123');
      expect(requests, hasLength(1));
    });
  }

  for (final failedMint in [false, true]) {
    test('取消共享验证后立即创建新 Provider，${failedMint ? '刷新失败后仍可重试' : '继续共享同一次刷新'}',
        () async {
      final release = Completer<ResponseBody>();
      var mints = 0;
      respond = (r) {
        if (r.path == '/login') {
          if (++mints == 1) return release.future;
          return jsonResponse(
              {'accessToken': 'new', 'refreshToken': 'rotated'});
        }
        return jsonResponse(r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
      };
      final oldProvider = providerFor(config);
      final old = oldProvider.verifyForSync();
      final oldJoined = oldProvider.verifyForSync();
      await waitUntil(() => mints == 1);
      providers.remove(oldProvider);
      oldProvider.dispose();
      final current = providerFor(config);
      final fresh = current.verifyForSync();
      final joined = current.verifyForSync();
      await waitUntil(
          () => requests.where((r) => r.path == '/shelf/sync').length == 2);
      expect(await Future.wait([old, oldJoined]), [false, false]);
      release.complete(failedMint
          ? jsonResponse({}, 503)
          : jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
      expect(await Future.wait([fresh, joined]), [!failedMint, !failedMint]);
      if (failedMint) {
        expect(
            await Future.wait(
                [current.verifyForSync(), current.verifyForSync()]),
            [true, true]);
      }
      expect(mints, failedMint ? 2 : 1);
      expect(config.credentials!.refreshToken, 'rotated');
      expect(current.isLoggedIn, isTrue);
      expect(current.isBusy, isFalse);
      expect(config.trustedAccountId, '123');
      expect(store.trustWrites, 1);
    });
  }

  test('关闭失败后并发结束和换号，只重试关闭一次且可打开新账号', () async {
    await DatabaseService.selectAccount('123');
    await DatabaseService.instance.database;
    final old = factory.handles.single;
    factory.failedCloses = 1;
    await expectLater(DatabaseService.endSession(), throwsStateError);
    final entered = Completer<void>();
    final release = Completer<void>();
    factory.beforeClose = () async {
      entered.complete();
      await release.future;
    };
    final ending = DatabaseService.endSession();
    await entered.future;
    final switching = DatabaseService.selectAccount('456');
    release.complete();
    await Future.wait([ending, switching]);
    factory.beforeClose = null;
    expect(old.closes, 2);
    expect(DatabaseService.instance.accountId, '456');
    await DatabaseService.instance.database;
  });

  testWidgets('登录保存期间不允许同步入口加入，完成后可用', (tester) async {
    final release = Completer<ResponseBody>();
    respond = (_) => release.future;
    final provider = providerFor(config);
    final login = provider.loginWithCredentials(initial);
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
      value: provider,
      child: const MaterialApp(home: SyncPage()),
    ));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始同步'))
            .onPressed,
        isNull);
    expect(await provider.verifyForSync(), isFalse);
    release.complete(jsonResponse({'books': []}));
    await pumpUntil(tester, () => !provider.isBusy);
    await login;
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始同步'))
            .onPressed,
        isNotNull);
    expect(provider.isLoggedIn, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
