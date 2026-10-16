import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/pages/sync_page.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse, initial;
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _SessionFactory extends ObservedFactory {
  _SessionFactory(super.delegate, super.probe);
  Future<void> Function(String)? beforeDelete;
  @override
  Future<void> deleteDatabase(String path) async {
    await beforeDelete?.call(path);
    await super.deleteDatabase(path);
  }
}

class _SessionStore extends InMemorySharedPreferencesStore {
  _SessionStore() : super.empty();
  Future<void> Function(String, Object)? beforeSet;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await beforeSet?.call(key, value);
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const replacement = Credentials(
      vid: '456',
      accessToken: 'other',
      refreshToken: 'other-refresh',
      deviceId: 'other-device');
  late Directory directory;
  late _SessionFactory factory;
  late _SessionStore store;
  late AppConfig config;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  final secrets = <String, String>{};
  late List<AppConfigProvider> providers;
  Future<void> Function(String, String)? beforeWrite;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-shared-auth-');
    factory = _SessionFactory(databaseFactoryFfiNoIsolate, DatabaseProbe());
    databaseFactory = factory;
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({});
    store = _SessionStore();
    SharedPreferencesStorePlatform.instance = store;
    providers = [];
    secrets.clear();
    beforeWrite = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return secrets[key];
      if (call.method == 'write') {
        final value = args['value'] as String;
        await beforeWrite?.call(key, value);
        secrets[key] = value;
      }
      if (call.method == 'delete') secrets.remove(key);
      return null;
    });
    config = AppConfig(credentials: initial);
    await config.saveCredentials();
    requests = [];
    respond = (_) => jsonResponse({'books': []});
  });
  tearDown(() async {
    for (final provider in providers) {
      provider.dispose();
    }
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
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
  WeReadApi apiFor(AppConfig value) =>
      WeReadApi.forLogin(config: value, dio: transport());
  AppConfigProvider providerFor(AppConfig value) {
    final provider = AppConfigProvider(config: value, loginApi: apiFor);
    providers.add(provider);
    return provider;
  }

  void disposeProvider(AppConfigProvider provider) {
    providers.remove(provider);
    provider.dispose();
  }

  for (final mobile in [true, false]) {
    test('${mobile ? '移动端' : 'Cookie'} 验证响应晚于退出/换号，不能认证旧会话', () async {
      if (!mobile) config = AppConfig(cookie: 'wr_vid=123; wr_skey=old');
      final release = Completer<ResponseBody>();
      respond = (_) => release.future;
      final oldApi = apiFor(config);
      final old =
          oldApi.checkLogin().then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(() => requests.isNotEmpty);
      oldApi.dispose();
      config.credentials = mobile ? replacement : null;
      config.cookie = mobile ? '' : 'wr_vid=456; wr_skey=new';
      release.complete(jsonResponse(mobile
          ? {
              'books': [
                {'bookId': 'old', 'title': '旧账号书'}
              ]
            }
          : {'vid': '123'}));
      expect(await old, isNot(true));
      expect(oldApi.authenticatedAccountId, isNull);
      await DatabaseService.selectAccount('456');
      final freshRequests = <RequestOptions>[];
      final fresh = await WeReadApi.init(
          config: config,
          db: DatabaseService.instance,
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((r) {
              freshRequests.add(r);
              return jsonResponse({'books': []});
            }));
      expect(await fresh.fetchBookshelf(), isEmpty);
      expect(freshRequests, hasLength(1));
    });
  }

  test('已结束的验证不能清空新账号可复用的书架缓存', () async {
    final oldApi = apiFor(config);
    oldApi.dispose();
    final next = AppConfig(credentials: replacement);
    expect(await apiFor(next).checkLogin(), isTrue);
    await expectLater(oldApi.checkLogin(), throwsA(anything));
    await DatabaseService.selectAccount('456');
    final count = requests.length;
    final fresh = await WeReadApi.init(
        config: next, db: DatabaseService.instance, dio: transport());
    expect(await fresh.fetchBookshelf(), isEmpty);
    expect(requests.length, count);
  });

  test('共享验证等待可信账号写入时释放 Provider，旧写入不能覆盖新账号', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeSet = (key, value) async {
      if (key == 'flutter.weread_trusted_account_id' && value == '123') {
        entered.complete();
        await release.future;
      }
    };
    final provider = providerFor(config);
    final first = provider.verifyForSync();
    final second = provider.verifyForSync();
    await entered.future;
    disposeProvider(provider);
    final next = AppConfig(credentials: replacement);
    final replacing = () async {
      await next.clearTrustedAccount();
      await next.trustAccount('456');
    }();
    await DatabaseService.selectAccount('456');
    final active = DatabaseService.instance;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    expect(await Future.wait([first, second]), [false, false]);
    await replacing;
    expect((await store.getAll())['flutter.weread_trusted_account_id'], '456');
    expect(active.isActive, isTrue);
  });

  test('旧验证选择数据库的等待窗口切换账号，不能恢复旧库或关闭新库', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    factory.beforeDelete = (_) async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final provider = providerFor(config);
    final old = provider.verifyForSync();
    await entered.future;
    disposeProvider(provider);
    final next = providerFor(AppConfig());
    await next.loginWithCredentials(replacement);
    final active = DatabaseService.instance;
    release.complete();
    expect(await old, isFalse);
    expect(DatabaseService.instance, same(active));
    expect(active.accountId, '456');
    expect(active.isActive, isTrue);
    expect(next.isLoggedIn, isTrue);
  });

  for (final mobile in [true, false]) {
    test('${mobile ? '移动端' : 'Cookie'} 验证期间配置被替换，即使未关闭客户端也拒绝旧结果', () async {
      if (!mobile) config = AppConfig(cookie: 'wr_vid=123; wr_skey=old');
      final release = Completer<ResponseBody>();
      respond = (_) => release.future;
      final api = apiFor(config);
      final checking =
          api.checkLogin().then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(() => requests.isNotEmpty);
      config.credentials = mobile ? replacement : null;
      config.cookie = mobile ? '' : 'wr_vid=456; wr_skey=new';
      release.complete(jsonResponse(mobile ? {'books': []} : {'vid': '123'}));
      expect(
          await checking,
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.cancel));
      expect(api.authenticatedAccountId, isNull);
    });
  }

  test('释放共享验证会及时取消请求，迟到鉴权失败不启动刷新', () async {
    final release = Completer<ResponseBody>();
    respond = (_) => release.future;
    final provider = providerFor(config);
    final first = provider.verifyForSync();
    final second = provider.verifyForSync();
    await waitUntil(() => requests.isNotEmpty);
    disposeProvider(provider);
    // Completion must not depend on the remote response.
    expect(await Future.wait([first, second]), [false, false]);
    release.complete(jsonResponse({'errcode': -2012}));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, hasLength(1));
    expect(config.trustedAccountId, isNull);
    expect(() => DatabaseService.instance, throwsStateError);
  });

  for (final fail in [false, true]) {
    for (final ownsRefresh in [true, false]) {
      test(
          '释放${ownsRefresh ? '发起刷新' : '等待刷新'}的 Provider，另一验证可收到${fail ? '失败并立即重试' : '成功'}结果',
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
        final provider = providerFor(config);
        final otherApi = apiFor(config);
        late Future<bool> checking;
        late Future<Object> surviving;
        if (ownsRefresh) {
          checking = provider.verifyForSync();
          await waitUntil(() => mints == 1);
          surviving = otherApi
              .checkLogin()
              .then<Object>((v) => v, onError: (Object e) => e);
        } else {
          surviving = otherApi
              .checkLogin()
              .then<Object>((v) => v, onError: (Object e) => e);
          await waitUntil(() => mints == 1);
          checking = provider.verifyForSync();
        }
        final joined = provider.verifyForSync();
        await waitUntil(
            () => requests.where((r) => r.path == '/shelf/sync').length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        disposeProvider(provider);
        expect(await Future.wait([checking, joined]), [false, false]);
        release.complete(fail
            ? jsonResponse({}, 503)
            : jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
        expect(await surviving, fail ? isA<DioException>() : isTrue);
        expect(config.trustedAccountId, isNull);
        expect(() => DatabaseService.instance, throwsStateError);
        if (fail) expect(await otherApi.checkLogin(), isTrue);
        expect(mints, fail ? 2 : 1);
        expect(config.credentials!.refreshToken, 'rotated');
        expect(
            jsonDecode(secrets['weread_mobile_credentials']!)['refreshToken'],
            'rotated');
      });
    }
  }

  for (final switchAccount in [false, true]) {
    test('共享刷新等待响应时${switchAccount ? '切换账号' : '退出登录'}，所有旧验证均失败且不恢复旧凭据',
        () async {
      final release = Completer<ResponseBody>();
      respond = (r) {
        if (r.path == '/login') return release.future;
        return jsonResponse(r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
      };
      final owner = apiFor(config);
      final waiting = apiFor(config);
      final first =
          owner.checkLogin().then<Object>((v) => v, onError: (Object e) => e);
      final second =
          waiting.checkLogin().then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(() => requests.any((r) => r.path == '/login'));
      final provider = providerFor(config);
      if (switchAccount) {
        await provider.loginWithCredentials(replacement);
      } else {
        await provider.logout();
      }
      release.complete(jsonResponse(
          {'accessToken': 'late', 'refreshToken': 'late-rotated'}));
      expect(await first, isA<DioException>());
      expect(await second, isA<DioException>());
      expect(owner.authenticatedAccountId, isNull);
      expect(waiting.authenticatedAccountId, isNull);
      expect(requests.where((r) => r.path == '/login'), hasLength(1));
      if (switchAccount) {
        expect(provider.isLoggedIn, isTrue);
        expect(config.credentials, replacement);
        expect(DatabaseService.instance.accountId, '456');
        expect(jsonDecode(secrets['weread_mobile_credentials']!)['vid'], '456');
      } else {
        expect(config.isConfigured, isFalse);
        expect(secrets['weread_mobile_credentials'], isNull);
        expect(() => DatabaseService.instance, throwsStateError);
      }
    });
  }

  test('取消发生在待恢复令牌落盘期间，完成写入后不发送验证请求', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    config.pendingCredentials = const Credentials(
        vid: '123',
        accessToken: 'new',
        refreshToken: 'rotated',
        deviceId: 'device');
    beforeWrite = (key, value) async {
      if (key == 'weread_mobile_credentials') {
        entered.complete();
        await release.future;
      }
    };
    final provider = providerFor(config);
    final checking = provider.verifyForSync();
    await entered.future;
    disposeProvider(provider);
    release.complete();
    expect(await checking, isFalse);
    expect(requests, isEmpty);
    expect(config.credentials!.refreshToken, 'rotated');
    expect(config.trustedAccountId, isNull);
  });

  for (final init in [false, true]) {
    test('${init ? '启动恢复' : '共享验证'}打开数据库期间释放 Provider，数据库最终关闭', () async {
      if (init) await config.trustAccount('123');
      final entered = Completer<void>();
      final release = Completer<void>();
      factory.probe.afterRead = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final provider = providerFor(config);
      final checking = init ? provider.init() : provider.verifyForSync();
      await entered.future;
      final old = DatabaseService.instance;
      disposeProvider(provider);
      release.complete();
      await checking;
      expect(old.isActive, isFalse);
      expect(() => DatabaseService.instance, throwsStateError);
      expect(provider.isLoggedIn, isFalse);
      expect(provider.canBrowseLocal, isFalse);
    });
  }

  for (final clear in [false, true]) {
    test('数据库选择等待期间${clear ? '清理数据' : '结束会话'}，旧选择不能重新激活', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      factory.beforeDelete = (_) async {
        entered.complete();
        await release.future;
      };
      final selecting = DatabaseService.selectAccount('123')
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      if (clear) {
        await DatabaseService.clearLocalData();
      } else {
        await DatabaseService.endSession();
      }
      release.complete();
      expect(await selecting, isA<StateError>());
      expect(() => DatabaseService.instance, throwsStateError);
    });
  }

  for (final fail in [false, true]) {
    test('旧可信账号${fail ? '写入失败' : '写入完成'}后清理仍执行，新账号不被旧 pending 恢复', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      store.beforeSet = (key, value) async {
        if (key == 'flutter.weread_trusted_account_id' && value == '123') {
          entered.complete();
          await release.future;
          if (fail) throw StateError('storage unavailable');
        }
      };
      final old = config
          .trustAccount('123')
          .then<Object?>((_) => null, onError: (Object e) => e);
      await entered.future;
      final clearing = config.clearTrustedAccount();
      final replacing = config.trustAccount('456');
      release.complete();
      expect(await old, fail ? isA<StateError>() : isNull);
      await clearing;
      await replacing;
      await config.loadTrustedAccount();
      expect(config.trustedAccountId, '456');
      expect(
          (await store.getAll())['flutter.weread_trusted_account_id'], '456');
    });
  }

  test('旧账号鉴权失败迟到时，不能用新账号令牌重放旧请求', () async {
    final release = Completer<ResponseBody>();
    respond = (_) {
      if (requests.length == 1) return release.future;
      return jsonResponse({'books': []});
    };
    final checking = apiFor(config)
        .checkLogin()
        .then<Object>((v) => v, onError: (Object e) => e);
    await waitUntil(() => requests.isNotEmpty);
    config.credentials = replacement;
    release.complete(jsonResponse({'errcode': -2012}));
    expect(await checking, isA<DioException>());
    expect(requests, hasLength(1));
  });

  for (final leavePage in [false, true]) {
    testWidgets('${leavePage ? '离开同步页' : '点击取消'}不终止另一个入口共享的真实登录验证',
        (tester) async {
      final release = Completer<ResponseBody>();
      respond = (_) => release.future;
      final provider = providerFor(config);
      var connections = 0;
      await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
        value: provider,
        child: MaterialApp(
            home: SyncPage(serviceConnector: ({config, isCancelled}) async {
          connections++;
          return SyncService(
              loadBooks: () async => [],
              loadBookmarks: (_) async => 0,
              loadNotes: (_) async => 0,
              isCancelled: () => false,
              onChanged: () {});
        })),
      ));
      await tester.tap(find.text('开始同步'));
      for (var i = 0; i < 20 && requests.isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(requests, hasLength(1));
      final other = provider.verifyForSync();
      if (leavePage) {
        await tester.pumpWidget(const SizedBox());
      } else {
        await tester.tap(find.text('取消同步'));
        await tester.pump();
      }
      release.complete(jsonResponse({'books': []}));
      await pumpUntil(tester, () => !provider.isBusy);
      expect(await other, isTrue);
      expect(provider.isLoggedIn, isTrue);
      expect(requests, hasLength(1));
      expect(connections, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('释放刷新发起者发生在令牌落盘期间，保留一次写入并服务另一入口', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var writes = 0;
    beforeWrite = (key, value) async {
      if (key == 'weread_mobile_credentials') {
        writes++;
        entered.complete();
        await release.future;
      }
    };
    respond = (r) => jsonResponse(r.path == '/login'
        ? {'accessToken': 'new', 'refreshToken': 'rotated'}
        : r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
    final provider = providerFor(config);
    final first = provider.verifyForSync();
    await entered.future;
    final other = apiFor(config).checkLogin();
    await waitUntil(
        () => requests.where((r) => r.path == '/shelf/sync').length == 2);
    disposeProvider(provider);
    expect(await first, isFalse);
    release.complete();
    expect(await other, isTrue);
    expect(writes, 1);
    expect(requests.where((r) => r.path == '/login'), hasLength(1));
    expect(config.credentials!.refreshToken, 'rotated');
    expect(config.trustedAccountId, isNull);
    expect(() => DatabaseService.instance, throwsStateError);
  });

  for (final switchAccount in [false, true]) {
    test('已取消验证的共享刷新仍在落盘时${switchAccount ? '切换账号' : '退出登录'}，清理或新凭据最后生效',
        () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      beforeWrite = (key, value) async {
        if (key == 'weread_mobile_credentials' &&
            jsonDecode(value)['accessToken'] == 'new') {
          entered.complete();
          await release.future;
        }
      };
      respond = (r) => jsonResponse(r.path == '/login'
          ? {'accessToken': 'new', 'refreshToken': 'rotated'}
          : r.headers['accessToken'] == 'old'
              ? {'errcode': -2012}
              : {'books': []});
      final oldProvider = providerFor(config);
      final first = oldProvider.verifyForSync();
      await entered.future;
      final other = apiFor(config)
          .checkLogin()
          .then<Object>((v) => v, onError: (Object e) => e);
      await waitUntil(
          () => requests.where((r) => r.path == '/shelf/sync').length == 2);
      disposeProvider(oldProvider);
      expect(await first, isFalse);
      final provider = providerFor(config);
      final mutation = switchAccount
          ? provider.loginWithCredentials(replacement)
          : provider.logout();
      await waitUntil(() => provider.sessionRevision == 1);
      release.complete();
      await mutation;
      expect(await other, isA<DioException>());
      expect(requests.where((r) => r.path == '/login'), hasLength(1));
      expect(config.pendingCredentials, isNull);
      expect(config.credentialRevalidation.value, isNull);
      final loaded = AppConfig();
      await loaded.load();
      expect(loaded.credentials?.vid, switchAccount ? '456' : isNull);
      expect(loaded.trustedAccountId, switchAccount ? '456' : isNull);
      expect(provider.isLoggedIn, switchAccount);
      if (switchAccount) {
        expect(DatabaseService.instance.accountId, '456');
      } else {
        expect(() => DatabaseService.instance, throwsStateError);
      }
    });
  }

  for (final switchAccount in [false, true]) {
    test('共享验证刷新期间${switchAccount ? '换号' : '退出'}被忙碌状态拒绝，验证完成后可立即执行', () async {
      final release = Completer<ResponseBody>();
      respond = (r) {
        if (r.path == '/login') return release.future;
        return jsonResponse(r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
      };
      final provider = providerFor(config);
      final first = provider.verifyForSync();
      final second = provider.verifyForSync();
      await waitUntil(() => requests.any((r) => r.path == '/login'));
      await expectLater(
          switchAccount
              ? provider.loginWithCredentials(replacement)
              : provider.logout(),
          throwsStateError);
      expect(config.credentials, initial);
      expect(config.logoutPending, isFalse);
      expect(provider.sessionRevision, 0);
      release.complete(
          jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
      expect(await Future.wait([first, second]), [true, true]);
      if (switchAccount) {
        await provider.loginWithCredentials(replacement);
      } else {
        await provider.logout();
      }
      expect(provider.isLoggedIn, switchAccount);
      expect(config.credentials?.vid, switchAccount ? '456' : isNull);
    });
  }
}
