import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/providers/app_config_provider.dart';

class AuthAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  AuthAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      respond(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object body, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(body), status,
        headers: {Headers.contentTypeHeader: ['application/json']});

const initial = Credentials(vid: '123', accessToken: 'old',
    refreshToken: 'refresh', deviceId: 'device');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};

  setUp(() {
    secrets.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String;
      if (call.method == 'read') return secrets[key];
      if (call.method == 'write') secrets[key] = args['value'] as String;
      if (call.method == 'delete') secrets.remove(key);
      return null;
    });
  });

  tearDown(() {
    WeReadApi.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  WeReadApi apiFor(AppConfig config, AuthAdapter adapter) =>
      WeReadApi.forLogin(config: config, dio: Dio()..httpClientAdapter = adapter);

  test('移动端凭据安全保存、恢复并随退出清理', () async {
    await AppConfig(credentials: initial).save();
    final saved = jsonDecode(secrets['weread_mobile_credentials']!);
    expect(saved, initial.toJson());
    expect((await SharedPreferences.getInstance())
        .containsKey('weread_mobile_credentials'), isFalse);
    final restored = AppConfig();
    await restored.load();
    expect(restored.credentials!.toJson(), initial.toJson());
    expect(restored.isConfigured, isTrue);
    await restored.clear();
    expect(secrets, isEmpty);
    expect(restored.isConfigured, isFalse);
  });

  for (final status in [200, 401]) {
    test('HTTP $status 鉴权失败刷新并只重试一次，持久化轮换凭据', () async {
      var mints = 0;
      var reads = 0;
      final config = AppConfig(credentials: initial, cookie: 'must-not-send');
      final api = apiFor(config, AuthAdapter((options) {
        expect(options.uri.host, 'i.weread.qq.com');
        expect(options.headers.containsKey('Cookie'), isFalse);
        expect(options.headers['baseapi'], '30');
        if (options.path == '/login') {
          mints++;
          expect(options.headers.containsKey('accessToken'), isFalse);
          final body = options.data as Map;
          expect(body['refreshToken'], 'refresh');
          expect(body['deviceId'], 'device');
          expect(body['signature'], sha256.convert(utf8.encode(
              '${body['timestamp']}device${body['random']}')).toString());
          return jsonResponse({'vid': 123, 'accessToken': 'new',
            'refreshToken': 'rotated'});
        }
        reads++;
        expect(options.headers['vid'], '123');
        if (options.headers['accessToken'] == 'old') {
          return jsonResponse({'errcode': -2012}, status);
        }
        return jsonResponse({'books': []});
      }));
      expect(await api.checkLogin(), isTrue);
      expect(api.authenticatedAccountId, '123');
      expect(mints, 1);
      expect(reads, 2);
      expect(jsonDecode(secrets['weread_mobile_credentials']!)['refreshToken'],
          'rotated');
      api.dispose();
      expect(config.credentials!.accessToken, 'new');
    });
  }

  test('并发鉴权失败合并刷新', () async {
    var mints = 0;
    final api = apiFor(AppConfig(credentials: initial), AuthAdapter((options) async {
      if (options.path == '/login') {
        mints++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return jsonResponse({'accessToken': 'new'});
      }
      return options.headers['accessToken'] == 'old'
          ? jsonResponse({'errCode': -2012}) : jsonResponse({'books': []});
    }));
    expect(await Future.wait([api.checkLogin(), api.checkLogin()]), [true, true]);
    expect(mints, 1);
  });

  for (final permanent in [false, true]) {
    test('刷新落盘${permanent ? '持续失败降级登录' : '失败两次后成功'}且内存不提前发布', () async {
      final config = AppConfig(credentials: initial);
      await config.saveCredentials();
      final provider = AppConfigProvider(config: config);
      addTearDown(provider.dispose);
      var writes = 0;
      var newTokenRequests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (call.method == 'read') return secrets[args['key']];
        if (call.method == 'write') {
          writes++;
          expect(config.credentials, same(initial));
          if (permanent || writes < 3) throw PlatformException(code: 'write-failed');
          secrets[args['key'] as String] = args['value'] as String;
        }
        return null;
      });
      final api = apiFor(config, AuthAdapter((options) {
        if (options.path == '/login') {
          return jsonResponse({'accessToken': 'new', 'refreshToken': 'rotated'});
        }
        if (options.headers['accessToken'] == 'new') {
          newTokenRequests++;
          return jsonResponse({'books': []});
        }
        return jsonResponse({'errCode': -2012});
      }));
      if (permanent) {
        await expectLater(api.checkLogin(), throwsA(isA<DioException>().having(
          (e) => e.error, '明确落盘异常', isA<CredentialPersistenceException>())));
        expect(config.credentials, same(initial));
        expect(provider.isLoggedIn, isFalse);
        expect(provider.loginStatus, LoginStatus.saved);
        expect(provider.loginError, contains('刷新凭据保存失败'));
        expect(api.authenticatedAccountId, isNull);
        expect(newTokenRequests, 0);
      } else {
        expect(await api.checkLogin(), isTrue);
        expect(config.credentials!.accessToken, 'new');
        expect(newTokenRequests, 1);
      }
      expect(writes, 3);
      expect(jsonDecode(secrets['weread_mobile_credentials']!), config.credentials!.toJson());
      if (permanent) {
        expect(config.pendingCredentials!.refreshToken, 'rotated');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          if (call.method == 'read') return secrets[args['key']];
          if (call.method == 'write') {
            secrets[args['key'] as String] = args['value'] as String;
          }
          return null;
        });
        api.dispose();
        final retryApi = apiFor(config, AuthAdapter((options) {
          expect(options.path, '/shelf/sync');
          expect(options.headers['accessToken'], 'new');
          expect(jsonDecode(secrets['weread_mobile_credentials']!)['refreshToken'],
              'rotated');
          return jsonResponse({'books': []});
        }));
        expect(await retryApi.checkLogin(), isTrue);
        expect(config.pendingCredentials, isNull);
        expect(config.credentialRevalidation.value, isNull);
      }
    });
  }

  test('refreshToken 失效才返回登录失效', () async {
    final config = AppConfig(credentials: initial);
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    final api = apiFor(config, AuthAdapter((options) =>
        jsonResponse({'errCode': -2012})));
    await expectLater(api.fetchBookshelf(), throwsA(isA<DioException>().having(
        (e) => e.error, '刷新明确失效', isA<LoginExpiredException>())));
    expect(provider.loginStatus, LoginStatus.invalid);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.loginStatusText, contains('凭据失效'));
    expect(provider.loginError, contains('重新登录'));
    expect(await api.checkLogin(), isFalse);
  });

  test('刷新网络失败保留凭据，不判登录失效', () async {
    final config = AppConfig(credentials: initial);
    final api = apiFor(config, AuthAdapter((options) {
      if (options.path == '/login') {
        throw DioException(requestOptions: options,
            type: DioExceptionType.connectionTimeout);
      }
      return jsonResponse({'errCode': -2012});
    }));
    await expectLater(api.checkLogin(), throwsA(isA<DioException>()));
    expect(config.credentials, same(initial));
    expect(config.credentialsInvalid.value, isFalse);
  });

  test('刷新后仍拒绝认证不循环重试', () async {
    var mints = 0;
    var reads = 0;
    final api = apiFor(AppConfig(credentials: initial), AuthAdapter((options) {
      if (options.path == '/login') {
        mints++;
        return jsonResponse({'accessToken': 'new'});
      }
      reads++;
      return jsonResponse({'errCode': -2012});
    }));
    await expectLater(api.checkLogin(), throwsA(isA<DioException>()));
    expect(mints, 1);
    expect(reads, 2);
  });

  test('Cookie 模式保持网页地址与账号验证', () async {
    final api = apiFor(AppConfig(cookie: 'wr_vid=123; wr_skey=web'),
        AuthAdapter((options) {
      expect(options.uri.toString(), 'https://weread.qq.com/web/user?userVid=0');
      expect(options.headers['Cookie'], 'wr_vid=123; wr_skey=web');
      expect(options.headers.containsKey('accessToken'), isFalse);
      return jsonResponse({'vid': 123});
    }));
    expect(await api.checkLogin(), isTrue);
    expect(api.authenticatedAccountId, '123');
  });
}
