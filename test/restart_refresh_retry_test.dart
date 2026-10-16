import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse, initial;
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _RecoveryFactory extends ObservedFactory {
  _RecoveryFactory(super.delegate, super.probe);
  bool failFirstDelete = false;
  final deletes = <String>[];
  @override
  Future<void> deleteDatabase(String path) async {
    deletes.add(path);
    if (failFirstDelete && deletes.length == 1) {
      throw FileSystemException('busy', path);
    }
    await super.deleteDatabase(path);
  }
}

class _RecoveryStore extends InMemorySharedPreferencesStore {
  _RecoveryStore() : super.empty();
  String? failedKey;
  bool failRead = false;
  @override
  Future<bool> remove(String key) async =>
      key == failedKey ? false : await super.remove(key);
  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('preferences unavailable');
    return super.getAll();
  }
}

class _BlockedFile implements File {
  final File delegate;
  _BlockedFile(this.delegate);
  @override
  String get path => delegate.path;
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw FileSystemException('busy', path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ListedDirectory implements Directory {
  final Directory delegate;
  final List<FileSystemEntity> entries;
  _ListedDirectory(this.delegate, this.entries);
  @override
  String get path => delegate.path;
  @override
  Directory get absolute => delegate.absolute;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Stream<FileSystemEntity> list(
      {bool recursive = false, bool followLinks = true}) {
    return Stream.fromIterable(entries);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final secrets = <String, String>{};
  late Directory root;
  late Directory documents;
  late Directory temporary;
  late DatabaseProbe probe;
  late _RecoveryFactory factory;
  late _RecoveryStore store;
  late DatabaseService db;
  late AppConfig config;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  String? failedPath;
  String? failedSecret;
  var failWrite = false;
  var secretReads = 0;
  var loginInstances = 0;
  final book = Book(bookId: 'b', title: '书');

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('weread-restart-retry-');
    documents = await Directory(p.join(root.path, 'documents')).create();
    temporary = await Directory(p.join(root.path, 'temporary')).create();
    probe = DatabaseProbe();
    factory = _RecoveryFactory(databaseFactoryFfiNoIsolate, probe);
    databaseFactory = factory;
    await databaseFactoryFfiNoIsolate.setDatabasesPath(root.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
    factory.deletes.clear();
    SharedPreferences.setMockInitialValues({});
    store = _RecoveryStore();
    SharedPreferencesStorePlatform.instance = store;
    secrets.clear();
    failedPath = failedSecret = null;
    failWrite = false;
    secretReads = loginInstances = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (call) async {
      if (call.method == failedPath) {
        throw PlatformException(code: 'path_unavailable');
      }
      return call.method == 'getTemporaryDirectory'
          ? temporary.path
          : documents.path;
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          secretReads++;
          return secrets[key];
        case 'write':
          if (failWrite && key == 'weread_mobile_credentials') {
            throw PlatformException(code: 'write_failed');
          }
          secrets[key] = args['value'] as String;
          return null;
        case 'delete':
          if (key == failedSecret) {
            throw PlatformException(code: 'delete_failed');
          }
          secrets.remove(key);
          return null;
      }
      throw UnsupportedError(call.method);
    });
    config = AppConfig(credentials: initial);
    await config.saveCredentials();
    requests = [];
    respond = (r) => jsonResponse(r.path == '/login'
        ? {'accessToken': 'new', 'refreshToken': 'rotated'}
        : r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
  });
  tearDown(() async {
    probe.afterRead = null;
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await root.delete(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(paths, null);
  });

  Dio transport() => Dio()
    ..httpClientAdapter = AuthAdapter((r) {
      requests.add(r);
      return respond(r);
    });
  WeReadApi loginApi(AppConfig value) =>
      WeReadApi.forLogin(config: value, dio: transport());
  AppConfigProvider providerFor(AppConfig value) {
    final provider = AppConfigProvider(
        config: value,
        loginApi: (c) {
          loginInstances++;
          return loginApi(c);
        });
    addTearDown(provider.dispose);
    return provider;
  }

  test('不同 API 实例共享刷新，同一个 refreshToken 不被并发轮换', () async {
    final release = Completer<void>();
    respond = (r) async {
      if (r.path == '/login') {
        await release.future;
        return jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'});
      }
      return jsonResponse(r.headers['accessToken'] == 'old'
          ? {'errcode': -2012}
          : {'books': []});
    };
    final apis = [loginApi(config), loginApi(config)];
    final outcomes = apis
        .map((api) =>
            api.checkLogin().then<Object>((v) => v, onError: (Object e) => e))
        .toList();
    await waitUntil(() =>
        requests.where((r) => r.path == '/shelf/sync').length == 2 &&
        requests.any((r) => r.path == '/login'));
    // Give both authentication callbacks an opportunity to join the refresh.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    expect(await Future.wait(outcomes), [true, true]);
    expect(requests.where((r) => r.path == '/login'), hasLength(1));
    expect(jsonDecode(secrets['weread_mobile_credentials']!)['refreshToken'],
        'rotated');
  });

  test('多个同步入口同时重新验证，共享结果而不是返回忙碌失败', () async {
    final release = Completer<ResponseBody>();
    respond = (_) => release.future;
    final provider = providerFor(config);
    final retries = List.generate(3, (_) => provider.verifyForSync());
    await waitUntil(() => requests.isNotEmpty);
    release.complete(jsonResponse({'books': []}));
    expect(await Future.wait(retries), [true, true, true]);
    expect(loginInstances, 1);
    expect(provider.isBusy, isFalse);
  });

  test('重启清理中一个数据库删除失败仍尝试其余账号数据库', () async {
    for (final id in ['456', '789']) {
      await DatabaseService.selectAccount(id);
      await DatabaseService.instance.database;
    }
    await config.beginLogout();
    await config.trustAccount('123');
    factory.deletes.clear();
    factory.failFirstDelete = true;
    final restored = providerFor(AppConfig());
    final reads = secretReads;
    await restored.init();
    expect(restored.cleanupPending, isTrue);
    expect(restored.canBrowseLocal, isFalse);
    expect(loginInstances, 0);
    expect(secretReads, reads);
    expect(factory.deletes, hasLength(3));
    final remaining = (await root.list().toList())
        .where((f) => f.path.endsWith('.db'))
        .toList();
    expect(remaining, hasLength(1));
    factory.failFirstDelete = false;
    await restored.init();
    expect(restored.cleanupPending, isFalse);
    expect((await root.list().toList()).where((f) => f.path.endsWith('.db')),
        isEmpty);
  });

  for (final method in [
    'getApplicationDocumentsDirectory',
    'getTemporaryDirectory'
  ]) {
    test('重启清理 $method 不可用时仍删除另一目录的导出文件', () async {
      final doc = await File(p.join(documents.path, '微信读书笔记_1.md'))
          .writeAsString('private');
      final temp = await File(p.join(temporary.path, 'weread_card_1.png'))
          .writeAsString('private');
      await config.beginLogout();
      failedPath = method;
      final provider = providerFor(AppConfig());
      await provider.init();
      expect(provider.cleanupPending, isTrue);
      expect(await (method == 'getTemporaryDirectory' ? doc : temp).exists(),
          isFalse);
      expect(await (method == 'getTemporaryDirectory' ? temp : doc).exists(),
          isTrue);
      expect(secrets, isEmpty);
      failedPath = null;
      await provider.init();
      expect(provider.cleanupPending, isFalse);
      expect(await doc.exists(), isFalse);
      expect(await temp.exists(), isFalse);
    });
  }

  for (final failure in [
    '503',
    'timeout',
    'malformed',
    'account',
    'storage',
    'expired',
    'replay'
  ]) {
    test('共享刷新 $failure 失败后多个入口立即重试，不复用失败 Future', () async {
      final release = Completer<void>();
      var healthy = false;
      failWrite = failure == 'storage';
      respond = (r) async {
        if (r.path != '/login') {
          return jsonResponse(r.headers['accessToken'] == 'old' ||
                  (!healthy && failure == 'replay')
              ? {'errcode': -2012}
              : {'books': []});
        }
        if (!healthy) {
          await release.future;
          switch (failure) {
            case '503':
              return jsonResponse({'errcode': 503}, 503);
            case 'timeout':
              throw DioException(
                  requestOptions: r, type: DioExceptionType.connectionTimeout);
            case 'malformed':
              return jsonResponse({'accessToken': ''});
            case 'account':
              return jsonResponse({'vid': '456', 'accessToken': 'new'});
            case 'expired':
              return jsonResponse({'errcode': -2012});
          }
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'});
      };
      final apis = [loginApi(config), loginApi(config)];
      final first = apis
          .map((a) =>
              a.checkLogin().then<Object>((v) => v, onError: (Object e) => e))
          .toList();
      await waitUntil(() =>
          requests.where((r) => r.path == '/shelf/sync').length == 2 &&
          requests.any((r) => r.path == '/login'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      expect((await Future.wait(first)).every((r) => r != true), isTrue);
      expect(requests.where((r) => r.path == '/login'), hasLength(1));
      healthy = true;
      failWrite = false;
      expect(await Future.wait([for (final a in apis) a.checkLogin()]),
          [true, true]);
      expect(requests.where((r) => r.path == '/login'),
          hasLength(['storage', 'replay'].contains(failure) ? 1 : 2));
      expect(config.pendingCredentials, isNull);
      expect(config.credentialRevalidation.value, isNull);
      expect(config.credentials!.refreshToken, 'rotated');
    });
  }

  test('刷新只轮换 refreshToken 而 accessToken 不变，等待者不重复刷新', () async {
    final release = Completer<void>();
    var minted = false;
    respond = (r) async {
      if (r.path == '/login') {
        await release.future;
        minted = true;
        return jsonResponse({'accessToken': 'old', 'refreshToken': 'rotated'});
      }
      return jsonResponse(minted ? {'books': []} : {'errcode': -2012});
    };
    final first = loginApi(config).checkLogin();
    final second = loginApi(config).checkLogin();
    await waitUntil(() =>
        requests.where((r) => r.path == '/shelf/sync').length == 2 &&
        requests.any((r) => r.path == '/login'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    expect(await Future.wait([first, second]), [true, true]);
    expect(requests.where((r) => r.path == '/login'), hasLength(1));
  });

  test('只轮换 refreshToken 后收到迟到的旧鉴权错误，不再次刷新', () async {
    final lateResponse = Completer<ResponseBody>();
    var reads = 0;
    respond = (r) {
      if (r.path == '/login') {
        return jsonResponse({'accessToken': 'old', 'refreshToken': 'rotated'});
      }
      reads++;
      if (reads == 1) return jsonResponse({'errcode': -2012});
      if (reads == 2) return lateResponse.future;
      return jsonResponse({'books': []});
    };
    final first = loginApi(config).checkLogin();
    final late = loginApi(config).checkLogin();
    await waitUntil(() => reads >= 3);
    expect(await first, isTrue);
    lateResponse.complete(jsonResponse({'errcode': -2012}));
    expect(await late, isTrue);
    expect(requests.where((r) => r.path == '/login'), hasLength(1));
  });

  for (final cancelOwner in [true, false]) {
    test('跨 API 共享刷新时取消${cancelOwner ? '发起者' : '等待者'}请求，另一入口仍成功', () async {
      final release = Completer<ResponseBody>();
      respond = (r) {
        if (r.path == '/login') return release.future;
        return jsonResponse(r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
      };
      final firstToken = CancelToken();
      final secondToken = CancelToken();
      final first = loginApi(config)
          .fetchBookshelf(cancelToken: firstToken)
          .then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(() => requests.any((r) => r.path == '/login'));
      final second = loginApi(config)
          .fetchBookshelf(cancelToken: secondToken)
          .then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(
          () => requests.where((r) => r.path == '/shelf/sync').length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      (cancelOwner ? firstToken : secondToken).cancel();
      release.complete(
          jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
      final results = await Future.wait([first, second]);
      expect(results[cancelOwner ? 0 : 1], isA<DioException>());
      expect(results[cancelOwner ? 1 : 0], isEmpty);
      expect(requests.where((r) => r.path == '/login'), hasLength(1));
      expect(
          requests.where(
              (r) => r.path != '/login' && r.headers['accessToken'] == 'new'),
          hasLength(1));
    });
  }

  for (final replace in [true, false]) {
    test('${replace ? '替换凭据' : '关闭旧客户端'}后新刷新不等待旧刷新，旧回调不清除新任务', () async {
      final oldMint = Completer<ResponseBody>();
      final newMint = Completer<ResponseBody>();
      var mints = 0;
      respond = (r) {
        if (r.path == '/login') {
          return ++mints == 1 ? oldMint.future : newMint.future;
        }
        return jsonResponse(r.headers['accessToken'] == 'new'
            ? {'books': []}
            : {'errcode': -2012});
      };
      final oldApi = loginApi(config);
      final old =
          oldApi.checkLogin().then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(() => mints == 1);
      if (replace) {
        config.credentials = const Credentials(
            vid: '123',
            accessToken: 'replacement',
            refreshToken: 'replacement',
            deviceId: 'device');
      } else {
        oldApi.dispose();
      }
      final fresh = loginApi(config).checkLogin();
      await waitUntil(() => mints == 2);
      oldMint.complete(jsonResponse(
          {'accessToken': 'obsolete', 'refreshToken': 'obsolete'}));
      expect(await old, isA<DioException>());
      final joined = loginApi(config).checkLogin();
      await waitUntil(
          () => requests.where((r) => r.path == '/shelf/sync').length == 3);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      newMint.complete(
          jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
      expect(await Future.wait([fresh, joined]), [true, true]);
      expect(mints, 2);
      expect(config.credentials!.refreshToken, 'rotated');
    });
  }

  test('不同账号的验证不能共享刷新或互相发布令牌', () async {
    final other = AppConfig(
        credentials: const Credentials(
            vid: '456',
            accessToken: 'other',
            refreshToken: 'other-refresh',
            deviceId: 'other-device'));
    respond = (r) async {
      if (r.path == '/login') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final vid = (r.data as Map)['deviceId'] == 'device' ? '123' : '456';
        return jsonResponse({
          'vid': vid,
          'accessToken': 'new-$vid',
          'refreshToken': 'rotated-$vid'
        });
      }
      return jsonResponse(
          (r.headers['accessToken'] as String).startsWith('new-')
              ? {'books': []}
              : {'errcode': -2012});
    };
    expect(
        await Future.wait(
            [loginApi(config).checkLogin(), loginApi(other).checkLogin()]),
        [true, true]);
    expect(requests.where((r) => r.path == '/login'), hasLength(2));
    expect(config.credentials!.accessToken, 'new-123');
    expect(other.credentials!.accessToken, 'new-456');
  });

  test('验证失败后立即重试的多个入口共享新验证，并串行读取最新同步游标', () async {
    var available = false;
    respond = (_) => jsonResponse(
        available ? {'books': []} : {'errcode': 503}, available ? 200 : 503);
    final provider = providerFor(config);
    expect(await Future.wait(List.generate(3, (_) => provider.verifyForSync())),
        [false, false, false]);
    expect(loginInstances, 1);
    available = true;
    expect(await Future.wait(List.generate(3, (_) => provider.verifyForSync())),
        [true, true, true]);
    expect(loginInstances, 2);
    db = DatabaseService.instance;
    final api = await WeReadApi.init(config: config, db: db, dio: transport());
    var active = 0;
    var maximum = 0;
    respond = (r) async {
      active++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
      final cursor = int.parse(r.queryParameters['synckey'] as String);
      return jsonResponse({
        'updated': [
          {'bookmarkId': 'bm', 'markText': '正文${cursor + 1}'}
        ],
        'synckey': '${cursor + 1}'
      });
    };
    final results = await Future.wait(List.generate(
        3,
        (_) => SyncService.forApi(api).retryBook(book,
            previous: BookSyncResult(book, 0, 7, ['划线失败'],
                bookmarksSucceeded: false, notesSucceeded: true))));
    expect(
        results.every((r) => r.succeeded && r.notes == 7 && r.bookmarks == 1),
        isTrue);
    expect(
        requests
            .where((r) => r.path == '/book/bookmarklist')
            .map((r) => r.queryParameters['synckey']),
        ['0', '1', '2']);
    expect(await db.getSyncCursor('b', 'bookmark'), '3');
    expect(await (await db.database).query('bookmarks'), hasLength(1));
    expect(maximum, 1);
  });

  test('验证状态监听器内重入的同步请求也共享验证结果', () async {
    respond = (_) => jsonResponse({'books': []});
    final provider = providerFor(config);
    Future<bool>? nested;
    provider.addListener(() {
      if (provider.isBusy && nested == null) nested = provider.verifyForSync();
    });
    expect(await provider.verifyForSync(), isTrue);
    expect(await nested, isTrue);
    expect(loginInstances, 1);
  });

  test('已释放 Provider 拒绝验证且不挂起后续调用', () async {
    final provider = AppConfigProvider(config: config);
    provider.dispose();
    expect(await provider.verifyForSync(), isFalse);
    expect(await provider.verifyForSync(), isFalse);
    expect(requests, isEmpty);
  });

  for (final key in ['weread_mobile_credentials', 'weread_ai_config']) {
    test('退出 $key 删除失败后重启，残留损坏配置不被读取，恢复后自动清理', () async {
      secrets[key] = '{invalid-json';
      failedSecret = key;
      await config.beginLogout();
      final first = providerFor(AppConfig());
      await first.init();
      final reads = secretReads;
      final restarted = providerFor(AppConfig());
      await restarted.init();
      expect(restarted.cleanupPending, isTrue);
      expect(restarted.isLoaded, isTrue);
      expect(restarted.isBusy, isFalse);
      expect(restarted.hasSavedCredentials, isFalse);
      expect(secretReads, reads);
      expect(loginInstances, 0);
      failedSecret = null;
      await restarted.init();
      expect(restarted.cleanupPending, isFalse);
      expect(restarted.loginStatus, LoginStatus.signedOut);
      expect(secrets, isEmpty);
      expect(await store.getAll(), isEmpty);
    });
  }

  test('重启读取退出标记失败时不访问凭据或本地数据，读取恢复后继续清理', () async {
    await config.beginLogout();
    await config.trustAccount('123');
    final reads = secretReads;
    store.failRead = true;
    final provider = providerFor(AppConfig());
    await provider.init();
    expect(provider.isLoaded, isFalse);
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.configLoadError, isNotNull);
    expect(secretReads, reads);
    expect(loginInstances, 0);
    store.failRead = false;
    await provider.init();
    expect(provider.isLoaded, isTrue);
    expect(provider.cleanupPending, isFalse);
    expect(provider.configLoadError, isNull);
    expect(secrets, isEmpty);
  });

  test('重启仅退出标记删除失败，重复初始化不会验证旧账号且恢复后结束清理', () async {
    await config.beginLogout();
    store.failedKey = 'flutter.weread_logout_pending';
    for (var i = 0; i < 2; i++) {
      final provider = providerFor(AppConfig());
      await provider.init();
      expect(provider.cleanupPending, isTrue);
      expect(provider.loginError, contains('退出标记'));
      expect(provider.canBrowseLocal, isFalse);
      expect(secrets, isEmpty);
    }
    store.failedKey = null;
    final recovered = providerFor(AppConfig());
    await recovered.init();
    expect(recovered.cleanupPending, isFalse);
    expect(recovered.loginError, isNull);
    expect(loginInstances, 0);
  });

  test('单个导出文件被占用仍清理其他文件及快照，重试后只剩非应用文件', () async {
    final blocked = await File(p.join(documents.path, '微信读书笔记_1.md'))
        .writeAsString('private');
    final removable = await File(p.join(documents.path, 'weread_card_1.png'))
        .writeAsString('private');
    final untouched = await File(p.join(documents.path, 'user-document.md'))
        .writeAsString('keep');
    final snapshot =
        await Directory(p.join(documents.path, '.weread-export-snapshot-test'))
            .create();
    await File(p.join(snapshot.path, 'snapshot.db')).writeAsString('private');
    final listing = _ListedDirectory(
        documents, [_BlockedFile(blocked), removable, untouched, snapshot]);
    final nativeZone = Zone.current;
    await expectLater(
        IOOverrides.runZoned(ExportService.clearLocalExports,
            createDirectory: (path) =>
                path == documents.path ? listing : temporary,
            // Keep real file type checks outside the directory fault override.
            fseGetType: (path, follow) => nativeZone
                .run(() => FileSystemEntity.type(path, followLinks: follow))),
        throwsA(isA<FileSystemException>()));
    expect(await blocked.exists(), isTrue);
    expect(await removable.exists(), isFalse);
    expect(await snapshot.exists(), isFalse);
    expect(await untouched.readAsString(), 'keep');
    await ExportService.clearLocalExports();
    expect(await blocked.exists(), isFalse);
    expect(await untouched.readAsString(), 'keep');
  });

  test('重启清理数据库关闭失败仍尝试所有文件，恢复后能结束清理', () async {
    await DatabaseService.selectAccount('456');
    factory.failClose = true;
    await DatabaseService.instance.database;
    await config.beginLogout();
    factory.deletes.clear();
    final provider = providerFor(AppConfig());
    try {
      await provider.init();
      expect(provider.cleanupPending, isTrue);
      expect(factory.deletes, hasLength(2));
      expect(secrets, isEmpty);
    } finally {
      await factory.wrapped!.delegate.close();
      factory.failClose = false;
    }
    await provider.init();
    expect(provider.cleanupPending, isFalse);
  });

  test('多个入口验证恢复期间退出请求被明确拒绝，验证完成后可退出', () async {
    final release = Completer<ResponseBody>();
    respond = (_) => release.future;
    final provider = providerFor(config);
    final first = provider.verifyForSync();
    final second = provider.verifyForSync();
    await waitUntil(() => requests.isNotEmpty);
    await expectLater(provider.logout(), throwsStateError);
    expect(provider.cleanupPending, isFalse);
    release.complete(jsonResponse({'books': []}));
    expect(await Future.wait([first, second]), [true, true]);
    await provider.logout();
    expect(provider.isLoggedIn, isFalse);
    expect(secrets, isEmpty);
  });
}
