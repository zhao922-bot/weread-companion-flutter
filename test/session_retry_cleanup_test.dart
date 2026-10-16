import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse, initial;
import 'support/observed_database.dart';
import 'support/wait_until.dart';
import 'sync_cancellation_windows_test.dart' show shelfService;

class _CleanupFactory extends ObservedFactory {
  _CleanupFactory(super.delegate, super.probe);
  bool failDelete = false;
  @override
  Future<void> deleteDatabase(String path) async {
    if (failDelete) throw FileSystemException('delete_failed', path);
    await super.deleteDatabase(path);
  }
}

class _CleanupStore extends InMemorySharedPreferencesStore {
  _CleanupStore() : super.empty();
  String? failedRemove;
  bool failBeginLogout = false;
  Future<void> Function(String)? beforeRemove;
  @override
  Future<bool> remove(String key) async {
    await beforeRemove?.call(key);
    if (key == failedRemove) return false;
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failBeginLogout && key == 'flutter.weread_logout_pending') return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final secrets = <String, String>{};
  final book = Book(bookId: 'b', title: '书');
  late Directory directory;
  late DatabaseProbe probe;
  late _CleanupFactory factory;
  late DatabaseService db;
  late AppConfig config;
  late WeReadApi api;
  late _CleanupStore store;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  String? failedDelete;
  var failExportPaths = false;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-session-retry-');
    probe = DatabaseProbe();
    factory = _CleanupFactory(databaseFactoryFfiNoIsolate, probe);
    databaseFactory = factory;
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
    SharedPreferences.setMockInitialValues({});
    store = _CleanupStore();
    SharedPreferencesStorePlatform.instance = store;
    secrets.clear();
    failedDelete = null;
    failExportPaths = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async {
      if (failExportPaths) throw PlatformException(code: 'paths_failed');
      return directory.path;
    });
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
          if (key == failedDelete) {
            throw PlatformException(code: 'delete_failed');
          }
          secrets.remove(key);
          return null;
      }
      throw UnsupportedError(call.method);
    });
    config = AppConfig(cookie: 'wr_vid=123; wr_skey=test');
    requests = [];
    respond = (r) => jsonResponse(switch (r.path) {
          '/shelf/sync' => {'books': []},
          '/book/bookmarklist' => {'updated': [], 'synckey': 'next'},
          _ => {'reviews': [], 'synckey': 'next'},
        });
    api = await WeReadApi.init(
        config: config,
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((r) {
            requests.add(r);
            return respond(r);
          }));
  });
  tearDown(() async {
    probe.afterRead = null;
    probe.beforeCommit = null;
    probe.afterCommit = null;
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(paths, null);
  });

  BookSyncResult previous(String source) => BookSyncResult(book, 0, 0, ['失败'],
      bookmarksSucceeded: source != 'bookmark',
      notesSucceeded: source != 'note');

  AppConfigProvider providerFor(AppConfig value) {
    final provider = AppConfigProvider(
        config: value,
        loginApi: (c) => WeReadApi.forLogin(
            config: c,
            dio: Dio()
              ..httpClientAdapter = AuthAdapter((_) => jsonResponse({
                    'vid': RegExp(r'wr_vid=([0-9]+)')
                        .firstMatch(c.cookie)!
                        .group(1)
                  }))));
    addTearDown(provider.dispose);
    return provider;
  }

  for (final source in ['bookmark', 'note']) {
    test('$source 游标读取中连续取消并立即重试，旧操作不能复活', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      probe.afterRead = (table) async {
        if (table == 'sync_cursors' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final service = SyncService.forApi(api);
      final old = service.retryBook(book, previous: previous(source));
      await entered.future;
      service.cancel();
      service.resetCancellation();
      final cancelledRetry = service.syncAll();
      service.cancel();
      service.resetCancellation();
      final fresh = service.retryBook(book, previous: previous(source));
      release.complete();
      final oldResult = await old;
      expect((await cancelledRetry).cancelled, isTrue);
      expect((await fresh).succeeded, isTrue);
      expect(oldResult.succeeded, isFalse);
      expect(oldResult.reason, contains('同步已取消'));
      expect(requests, hasLength(1));
      expect(await db.getSyncCursor('b', source), 'next');
    });

    test('$source 事务提交期间取消并立即重试，保留原子提交且旧结果仍为取消', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      probe.beforeCommit = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final service = SyncService.forApi(api);
      final old = service.retryBook(book, previous: previous(source));
      await entered.future;
      service.cancel();
      service.resetCancellation();
      final fresh = service.retryBook(book, previous: previous(source));
      release.complete();
      expect((await old).reason, contains('同步已取消'));
      expect((await fresh).succeeded, isTrue);
      expect(requests, hasLength(2));
      expect(requests.last.queryParameters['synckey'], 'next');
      expect(await db.getSyncCursor('b', source), 'next');
    });
  }

  test('连续取消排队任务后立即重试，不泄漏全局四个请求槽', () async {
    final release = Completer<List<Book>>();
    var starts = 0;
    final occupied = List.generate(
        4,
        (_) => shelfService(() {
              starts++;
              return release.future;
            }).syncAll());
    await waitUntil(() => starts == 4);
    var freshCalls = 0;
    final service = shelfService(() async {
      freshCalls++;
      return [];
    });
    final cancelled = <Future<SyncResult>>[];
    for (var i = 0; i < 5; i++) {
      cancelled.add(service.syncAll());
      service.cancel();
      service.resetCancellation();
    }
    final fresh = service.syncAll();
    release.complete([]);
    await Future.wait(occupied);
    expect((await Future.wait(cancelled)).every((r) => r.cancelled), isTrue);
    expect((await fresh).cancelled, isFalse);
    expect(freshCalls, 1);
    final nextRelease = Completer<List<Book>>();
    var nextStarts = 0;
    final next = List.generate(
        4,
        (_) => shelfService(() {
              nextStarts++;
              return nextRelease.future;
            }).syncAll());
    await waitUntil(() => nextStarts == 4);
    nextRelease.complete([]);
    await Future.wait(next);
  });

  for (final lateResponse in [false, true]) {
    test('${lateResponse ? '迟到429' : '退避等待'}取消后重置，旧操作不污染重试的退避时间', () async {
      final release = Completer<void>();
      var calls = 0;
      final service = shelfService(() async {
        if (++calls > 1) return [];
        if (lateResponse) await release.future;
        final r = RequestOptions(path: '/shelf');
        throw DioException(
            requestOptions: r,
            response: Response(
                requestOptions: r,
                statusCode: 429,
                headers: Headers.fromMap({
                  'retry-after': ['3600']
                })));
      }, account: 'retry-backoff');
      final old = service.syncAll();
      await waitUntil(() => calls == 1);
      service
          .resetCancellation(); // Resetting a live generation must do nothing.
      service.cancel();
      service.resetCancellation();
      final fresh = service.syncAll();
      release.complete();
      expect((await old.timeout(const Duration(seconds: 1))).cancelled, isTrue);
      expect(
          (await fresh.timeout(const Duration(seconds: 1))).cancelled, isFalse);
      expect(calls, 2);
    });
  }

  test('共享令牌刷新期间连续取消并立即重试，只刷新一次且只重放最后一次请求', () async {
    WeReadApi.reset();
    config = AppConfig(credentials: initial);
    await config.saveCredentials();
    final mint = Completer<ResponseBody>();
    api = await WeReadApi.init(
        config: config,
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((r) {
            requests.add(r);
            if (r.path == '/login') return mint.future;
            return jsonResponse(r.headers['accessToken'] == 'old'
                ? {'errcode': -2012}
                : {'updated': [], 'synckey': 'new'});
          }));
    final service = SyncService.forApi(api);
    final cancelled = <Future<BookSyncResult>>[];
    for (var i = 0; i < 3; i++) {
      cancelled.add(service.retryBook(book, previous: previous('bookmark')));
      await waitUntil(() =>
          requests.where((r) => r.path == '/book/bookmarklist').length ==
          i + 1);
      await waitUntil(() => requests.any((r) => r.path == '/login'));
      service.cancel();
      service.resetCancellation();
    }
    final fresh = service.retryBook(book, previous: previous('bookmark'));
    await waitUntil(() =>
        requests.where((r) => r.path == '/book/bookmarklist').length == 4);
    mint.complete(
        jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
    expect((await Future.wait(cancelled)).every((r) => !r.succeeded), isTrue);
    expect((await fresh).succeeded, isTrue);
    expect(requests.where((r) => r.path == '/login'), hasLength(1));
    expect(
        requests.where((r) => r.headers['accessToken'] == 'new'), hasLength(1));
    expect(config.credentials!.refreshToken, 'rotated');
    expect(await db.getSyncCursor('b', 'bookmark'), 'new');
  });

  for (final key in [
    'weread_trusted_account_id',
    'weread_cookie',
    'weread_api_key',
    'weread_base_url',
    'weread_model_name'
  ]) {
    test('退出删除偏好 $key 失败仍清除其余凭据，保留标记并可重试', () async {
      final value = AppConfig(
          credentials: initial, cookie: 'wr_vid=123', apiKey: 'secret');
      await value.save();
      await value.trustAccount('123');
      final prefs = await SharedPreferences.getInstance();
      for (final name in ['weread_cookie', 'weread_api_key']) {
        await prefs.setString(name, 'legacy');
      }
      store.failedRemove = 'flutter.$key';
      final provider = AppConfigProvider(config: value);
      addTearDown(provider.dispose);
      await expectLater(provider.logout(), throwsStateError);
      expect(secrets, isEmpty);
      expect(value.isConfigured, isFalse);
      expect(provider.cleanupPending, isTrue);
      expect(provider.canBrowseLocal, isFalse);
      expect(provider.loginError, contains('清理未完成'));
      final persisted = await store.getAll();
      expect(persisted.keys.toSet(),
          {'flutter.$key', 'flutter.weread_logout_pending'});
      await expectLater(
          provider.loginWithCredentials(initial), throwsStateError);
      store.failedRemove = null;
      await provider.logout();
      expect(provider.loginStatus, LoginStatus.signedOut);
      expect(await store.getAll(), isEmpty);
    });
  }

  for (final key in [
    'weread_cookie',
    'weread_mobile_credentials',
    'weread_api_key',
    'weread_ai_config'
  ]) {
    test('安全存储 $key 删除失败不跳过其他密钥，重启可继续清理', () async {
      final value = AppConfig(
          credentials: initial, cookie: 'wr_vid=123', apiKey: 'secret');
      await value.save();
      secrets['weread_api_key'] = 'legacy-ai';
      failedDelete = key;
      final provider = AppConfigProvider(config: value);
      addTearDown(provider.dispose);
      await expectLater(provider.logout(), throwsStateError);
      expect(secrets.keys.toSet(), {key});
      final restarted = AppConfigProvider(config: AppConfig());
      addTearDown(restarted.dispose);
      await restarted.init();
      expect(restarted.cleanupPending, isTrue);
      expect(restarted.hasSavedCredentials, isFalse);
      failedDelete = null;
      await restarted.logout();
      expect(secrets, isEmpty);
      expect(restarted.cleanupPending, isFalse);
    });
  }

  test('默认配置加载不能在退出清理失败后恢复残留凭据', () async {
    await AppConfig(credentials: initial).save();
    await config.beginLogout();
    final restored = AppConfig();
    await expectLater(restored.load(), throwsStateError);
    expect(restored.isConfigured, isFalse);
    await expectLater(SyncService.connect(), throwsStateError);
    expect(requests, isEmpty);
  });

  for (final failure in ['数据库', '导出路径', '退出标记']) {
    test('$failure 清理失败仍删除凭据，错误可见并可继续清理', () async {
      await config.save();
      final provider = providerFor(config);
      if (failure == '数据库') factory.failDelete = true;
      if (failure == '导出路径') failExportPaths = true;
      if (failure == '退出标记') {
        store.failedRemove = 'flutter.weread_logout_pending';
      }
      await expectLater(provider.logout(), throwsStateError);
      expect(secrets, isEmpty);
      expect(provider.cleanupPending, isTrue);
      expect(provider.loginError, contains('清理未完成'));
      expect(db.isActive, isFalse);
      expect(await provider.verifyForSync(), isFalse);
      factory.failDelete = false;
      failExportPaths = false;
      store.failedRemove = null;
      await provider.logout();
      expect(provider.loginError, isNull);
      expect(provider.cleanupPending, isFalse);
      expect(await directory.list().toList(), isEmpty);
    });
  }

  test('退出标记保存失败保持当前会话可用，下一次退出可完成', () async {
    final provider = providerFor(config);
    expect(await provider.verifyForSync(), isTrue);
    final revision = provider.sessionRevision;
    final active = DatabaseService.instance;
    store.failBeginLogout = true;
    await expectLater(provider.logout(), throwsStateError);
    expect(provider.isLoggedIn, isTrue);
    expect(provider.isBusy, isFalse);
    expect(provider.sessionRevision, revision);
    expect(provider.cleanupPending, isFalse);
    expect(active.isActive, isTrue);
    store.failBeginLogout = false;
    await provider.logout();
    expect(active.isActive, isFalse);
    expect(provider.cleanupPending, isFalse);
  });

  for (final trustFails in [false, true]) {
    test('切换账号清除可信记录${trustFails ? '失败' : '等待'}时立即使旧同步重试失效', () async {
      final provider = providerFor(config);
      expect(await provider.verifyForSync(), isTrue);
      db = DatabaseService.instance;
      api = await WeReadApi.init(
          config: config,
          db: db,
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((r) {
              requests.add(r);
              return respond(r);
            }));
      final revision = provider.sessionRevision;
      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      probe.afterRead = (table) async {
        if (table == 'sync_cursors' && !readEntered.isCompleted) {
          readEntered.complete();
          await releaseRead.future;
        }
      };
      final service = SyncService.forApi(api);
      final old = service.retryBook(book, previous: previous('bookmark'));
      await readEntered.future;
      final queued = service.syncAll();
      final clearing = Completer<void>();
      final releaseClear = Completer<void>();
      store.beforeRemove = (key) async {
        if (key == 'flutter.weread_trusted_account_id') {
          clearing.complete();
          await releaseClear.future;
        }
      };
      if (trustFails) store.failedRemove = 'flutter.weread_trusted_account_id';
      final switching = provider.loginWithCookie('wr_vid=456; wr_skey=new');
      final checkedSwitch =
          trustFails ? expectLater(switching, throwsStateError) : switching;
      await clearing.future;
      // Capture state before releasing the storage operation, avoiding test deadlocks.
      final invalidated = provider.sessionRevision != revision &&
          !provider.isLoggedIn &&
          !db.isActive;
      final verification = await provider.verifyForSync();
      releaseClear.complete();
      await checkedSwitch;
      store.beforeRemove = null;
      store.failedRemove = null;
      if (trustFails) await provider.loginWithCookie('wr_vid=456; wr_skey=new');
      final nextDb = DatabaseService.instance;
      final nextApi = await WeReadApi.init(
          config: config,
          db: nextDb,
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((r) {
              expect(r.headers['Cookie'], contains('wr_vid=456'));
              return jsonResponse({'updated': [], 'synckey': 'fresh'});
            }));
      final next = await SyncService.forApi(nextApi)
          .retryBook(book, previous: previous('bookmark'));
      SyncService.changes.publish(nextDb, bookIds: {'new-account'});
      final version = SyncService.changes.dataVersion;
      releaseRead.complete();
      expect((await old).succeeded, isFalse);
      expect((await queued).cancelled, isTrue);
      expect(invalidated, isTrue);
      expect(verification, isFalse);
      expect(provider.isLoggedIn, isTrue);
      expect(next.succeeded, isTrue);
      expect(await nextDb.getSyncCursor('b', 'bookmark'), 'fresh');
      expect(SyncService.changes.dataVersion, version);
      expect(SyncService.changes.value, same(nextDb));
      expect(requests, isEmpty);
    });
  }

  test('切换数据库会话后新连接不能复用旧 API', () async {
    await DatabaseService.selectAccount('456');
    final nextDb = DatabaseService.instance;
    final nextConfig = AppConfig(cookie: 'wr_vid=456; wr_skey=new');
    final nextApi = await WeReadApi.init(
        config: nextConfig,
        db: nextDb,
        dio: Dio()
          ..httpClientAdapter =
              AuthAdapter((_) => jsonResponse({'books': []})));
    expect(nextApi.db, same(nextDb));
    expect(api.syncCancelled, isTrue);
    final service = await SyncService.connect(config: nextConfig);
    expect((await service.syncAll()).cancelled, isFalse);
    await expectLater(SyncService.connect(config: config), throwsStateError);
    expect(nextConfig.cookie, 'wr_vid=456; wr_skey=new');
    expect((await service.syncAll()).cancelled, isFalse);
    expect(requests, isEmpty);
  });
}
