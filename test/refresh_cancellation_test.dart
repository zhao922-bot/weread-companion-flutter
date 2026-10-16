import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse, initial;
import 'support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const credentialKey = 'weread_mobile_credentials';
  final secrets = <String, String>{};
  late Future<void> Function(String, String)? beforeWrite;
  late AppConfig config;
  late Dio dio;
  late WeReadApi api;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets.clear();
    beforeWrite = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (call) async {
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
    respond = (r) => jsonResponse(r.path == '/login'
        ? {'accessToken': 'new', 'refreshToken': 'rotated'}
        : r.headers['accessToken'] == 'old'
            ? {'errcode': -2012}
            : {'books': []});
    dio = Dio()
      ..httpClientAdapter = AuthAdapter((r) {
        requests.add(r);
        return respond(r);
      });
    api = WeReadApi.forLogin(config: config, dio: dio);
  });
  tearDown(() {
    WeReadApi.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
  });

  for (final status in [200, 401]) {
    test('HTTP $status 鉴权回调排队后取消，不启动无用刷新', () async {
      final token = CancelToken();
      final auth = dio.interceptors.removeLast();
      bool Function()? handled;
      // Reproduce a callback already scheduled by Dio when cancellation wins.
      dio.interceptors.add(InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.requestOptions.path != '/login') {
            token.cancel();
            handled = () => handler.isCompleted;
          }
          auth.onResponse(response, handler);
        },
        onError: (error, handler) {
          if (error.response != null && error.requestOptions.path != '/login') {
            token.cancel();
            handled = () => handler.isCompleted;
          }
          auth.onError(error, handler);
        },
      ));
      // Retain the API's normal request authentication interceptor.
      dio.interceptors
          .insert(0, InterceptorsWrapper(onRequest: auth.onRequest));
      respond = (r) => r.path == '/login'
          ? jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'})
          : jsonResponse({'errcode': -2012}, status);
      await expectLater(
          api.fetchBookshelf(cancelToken: token),
          throwsA(isA<DioException>()
              .having((e) => e.type, '取消', DioExceptionType.cancel)));
      await waitUntil(() => handled?.call() == true);
      expect(requests.map((r) => r.path), ['/shelf/sync']);
      expect(config.credentials, same(initial));
      expect(jsonDecode(secrets[credentialKey]!), initial.toJson());
    });
  }

  for (final status in [200, 401]) {
    for (final refreshFails in [false, true]) {
      test('HTTP $status 共享刷新${refreshFails ? '失败' : '成功'}时取消一个等待者，不影响另一个且可以再试',
          () async {
        final mint = Completer<ResponseBody>();
        var mints = 0;
        respond = (r) {
          if (r.path == '/login') {
            mints++;
            return mint.future;
          }
          return r.headers['accessToken'] == 'old'
              ? jsonResponse({'errcode': -2012}, status)
              : jsonResponse({'books': []});
        };
        final cancelledToken = CancelToken();
        final survivorToken = CancelToken();
        final cancelled = api.fetchBookshelf(cancelToken: cancelledToken);
        final cancelledCheck = expectLater(
            cancelled,
            throwsA(isA<DioException>()
                .having((e) => e.type, '取消', DioExceptionType.cancel)));
        final survivor = api.fetchBookshelf(cancelToken: survivorToken);
        final survivorCheck = refreshFails
            ? expectLater(survivor, throwsA(isA<DioException>()))
            : expectLater(survivor, completion(isEmpty));
        await waitUntil(() =>
            mints == 1 &&
            requests.where((r) => r.path == '/shelf/sync').length == 2);
        cancelledToken.cancel();
        await cancelledCheck.timeout(const Duration(seconds: 1));
        expect(config.credentials, same(initial));
        mint.complete(refreshFails
            ? jsonResponse({'errcode': 503}, 503)
            : jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
        await survivorCheck;
        expect(mints, 1);
        expect(requests.where((r) => identical(r.cancelToken, cancelledToken)),
            hasLength(1));
        expect(config.credentialsInvalid.value, isFalse);
        expect(config.credentials!.accessToken, refreshFails ? 'old' : 'new');
        expect(
            jsonDecode(secrets[credentialKey]!), config.credentials!.toJson());
        respond = (r) {
          if (r.path == '/login') {
            mints++;
            return jsonResponse(
                {'accessToken': 'new', 'refreshToken': 'rotated'});
          }
          return jsonResponse(r.headers['accessToken'] == 'old'
              ? {'errcode': -2012}
              : {'books': []});
        };
        expect(await api.fetchBookshelf(), isEmpty);
        expect(mints, refreshFails ? 2 : 1);
      });
    }
  }

  for (final storageFails in [false, true]) {
    test('轮换凭据落盘期间取消请求，${storageFails ? '保留待恢复凭据' : '继续保存新凭据'}且不重放请求',
        () async {
      final writing = Completer<void>();
      final release = Completer<void>();
      var writes = 0;
      beforeWrite = (key, value) async {
        if (key == credentialKey) {
          writes++;
          if (!writing.isCompleted) writing.complete();
          await release.future;
          if (storageFails) throw PlatformException(code: 'disk-failed');
        }
      };
      final token = CancelToken();
      final task = api.fetchBookshelf(cancelToken: token);
      final check = expectLater(
          task,
          throwsA(isA<DioException>()
              .having((e) => e.type, '取消', DioExceptionType.cancel)));
      await writing.future;
      token.cancel();
      await check.timeout(const Duration(seconds: 1));
      expect(config.credentials, same(initial));
      release.complete();
      await waitUntil(() => storageFails
          ? config.pendingCredentials != null
          : config.credentials!.accessToken == 'new');
      expect(writes, storageFails ? 3 : 1);
      expect(requests.where((r) => r.path == '/shelf/sync'), hasLength(1));
      expect(jsonDecode(secrets[credentialKey]!), config.credentials!.toJson());
      beforeWrite = null;
      expect(await api.checkLogin(), isTrue);
      expect(config.credentials!.refreshToken, 'rotated');
      expect(config.pendingCredentials, isNull);
      expect(config.credentialRevalidation.value, isNull);
      expect(requests.where((r) => r.path == '/login'), hasLength(1));
    });
  }

  for (final logout in [false, true]) {
    for (final writeFails in [false, true]) {
      test(
          '刷新写入未完成时${logout ? '退出清理' : '另一配置登录新账号'}，旧写入${writeFails ? '失败' : '成功'}不能覆盖最终凭据',
          () async {
        final writing = Completer<void>();
        final release = Completer<void>();
        beforeWrite = (key, value) async {
          if (key == credentialKey &&
              jsonDecode(value)['accessToken'] == 'new') {
            writing.complete();
            await release.future;
            if (writeFails) throw PlatformException(code: 'old-write-failed');
          }
        };
        final taskCheck =
            expectLater(api.fetchBookshelf(), throwsA(isA<DioException>()));
        await writing.future;
        api.dispose();
        const replacement = Credentials(
            vid: '456',
            accessToken: 'other',
            refreshToken: 'other-refresh',
            deviceId: 'other-device');
        var successorDone = false;
        final successor = (logout
                ? config.clear()
                : AppConfig(credentials: replacement).saveCredentials())
            .then((_) => successorDone = true);
        // Platform mocks complete in microtasks; let the later operation run.
        await Future<void>.delayed(Duration.zero);
        final finishedBeforeOldWrite = successorDone;
        release.complete();
        await Future.wait([taskCheck, successor]);
        expect(secrets[credentialKey],
            logout ? isNull : jsonEncode(replacement.toJson()));
        expect(finishedBeforeOldWrite, isFalse);
        expect(config.pendingCredentials, isNull);
        expect(config.credentialRevalidation.value, isNull);
        if (logout) expect(config.credentials, isNull);
      });
    }
  }

  test('跨配置实例写凭据后，旧实例缓存不能误跳过实际写入', () async {
    const other = Credentials(
        vid: '456',
        accessToken: 'other',
        refreshToken: 'refresh-other',
        deviceId: 'other-device');
    await AppConfig(credentials: other).saveCredentials();
    await config.saveCredentials();
    expect(jsonDecode(secrets[credentialKey]!), initial.toJson());
  });

  for (final disposeApi in [false, true]) {
    for (final invalidRefresh in [false, true]) {
      test(
          '刷新网络返回前${disposeApi ? '关闭会话' : '替换凭据'}，迟到${invalidRefresh ? '失效' : '成功'}响应不修改新凭据或登录状态',
          () async {
        final mint = Completer<ResponseBody>();
        respond = (r) {
          if (r.path == '/login') return mint.future;
          return jsonResponse({'errcode': -2012});
        };
        final check =
            expectLater(api.fetchBookshelf(), throwsA(isA<DioException>()));
        await waitUntil(() => requests.any((r) => r.path == '/login'));
        if (disposeApi) api.dispose();
        const replacement = Credentials(
            vid: '456',
            accessToken: 'other',
            refreshToken: 'refresh-other',
            deviceId: 'other-device');
        config.credentials = replacement;
        await config.saveCredentials();
        mint.complete(invalidRefresh
            ? jsonResponse({'errcode': -2012}, 401)
            : jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'}));
        await check;
        expect(config.credentials, same(replacement));
        expect(jsonDecode(secrets[credentialKey]!), replacement.toJson());
        expect(config.credentialsInvalid.value, isFalse);
        expect(config.credentialRevalidation.value, isNull);
        expect(config.pendingCredentials, isNull);
        expect(requests, hasLength(2));
      });
    }
  }

  test('刷新返回另一个账号时不保存、不重放，也不标记原凭据失效', () async {
    respond = (r) => jsonResponse(r.path == '/login'
        ? {
            'vid': '456',
            'accessToken': 'wrong',
            'refreshToken': 'wrong-refresh'
          }
        : {'errcode': -2012});
    await expectLater(
        api.fetchBookshelf(),
        throwsA(isA<DioException>()
            .having((e) => e.error.toString(), '账号检查', contains('账号不匹配'))));
    expect(config.credentials, same(initial));
    expect(jsonDecode(secrets[credentialKey]!), initial.toJson());
    expect(config.credentialsInvalid.value, isFalse);
    expect(requests, hasLength(2));
  });

  test('恢复待保存轮换凭据期间退出，迟到恢复不能重新发布凭据', () async {
    config.pendingCredentials = const Credentials(
        vid: '123',
        accessToken: 'new',
        refreshToken: 'rotated',
        deviceId: 'device');
    final writing = Completer<void>();
    final release = Completer<void>();
    beforeWrite = (key, value) async {
      if (key == credentialKey) {
        writing.complete();
        await release.future;
      }
    };
    final retry = config.retryPendingCredentials();
    await writing.future;
    final clear = config.clear();
    await Future<void>.delayed(Duration.zero);
    release.complete();
    await Future.wait([retry, clear]);
    expect(config.credentials, isNull);
    expect(config.pendingCredentials, isNull);
    expect(secrets[credentialKey], isNull);
  });
}
