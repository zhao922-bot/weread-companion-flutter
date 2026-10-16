import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/services/qr_login_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;

ResponseBody _reply(RequestOptions request) => switch (request.uri.path) {
      '/wxticket' => jsonResponse({'signature': 'signature', 'timeStamp': 123}),
      '/connect/sdk/qrconnect' =>
        jsonResponse({'errcode': 0, 'uuid': 'uuid/&'}),
      '/connect/l/qrconnect' =>
        jsonResponse({'wx_errcode': 405, 'wx_code': 'authorization'}),
      '/login' => jsonResponse({
          'vid': 123,
          'accessToken': 'access-token',
          'refreshToken': 'refresh-token',
        }),
      _ => throw StateError('Unexpected request ${request.uri.path}'),
    };

void main() {
  test('扫码服务完整链路返回有效凭据，回调和授权码传递正确', () async {
    final requests = <RequestOptions>[];
    final events = <String>[];
    final service = QrLoginService(
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((request) {
            requests.add(request);
            return _reply(request);
          }));
    addTearDown(service.dispose);
    final credentials = await service.login(
      cancelToken: CancelToken(),
      onQr: (qr) {
        events.add('qr');
        expect(Uri.parse(qr.confirmUrl).queryParameters['uuid'], 'uuid/&');
      },
      onStatus: (status) => events.add(status.name),
    );
    expect(events, ['qr', 'confirmed']);
    expect(requests.map((request) => request.uri.path), [
      '/wxticket',
      '/connect/sdk/qrconnect',
      '/connect/l/qrconnect',
      '/login'
    ]);
    expect(requests.every((request) => request.uri.scheme == 'https'), isTrue);
    expect(requests[1].queryParameters['signature'], 'signature');
    expect(requests[2].queryParameters['uuid'], 'uuid/&');
    expect(requests.last.method, 'POST');
    expect(requests.last.data['code'], 'authorization');
    expect(credentials.isValid, isTrue);
    expect(credentials.vid, '123');
    expect(credentials.deviceId, requests.last.data['deviceId']);
  });

  test('无效ticket不继续获取二维码或交换凭据', () async {
    for (final response in [
      <String, dynamic>{},
      {'signature': '', 'timeStamp': 123},
      {'signature': 123, 'timeStamp': 123},
      {'signature': 'signature', 'timeStamp': []},
    ]) {
      var calls = 0;
      final service = QrLoginService(
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((_) {
              calls++;
              return jsonResponse(response);
            }));
      addTearDown(service.dispose);
      await expectLater(
          service.login(cancelToken: CancelToken(), onQr: (_) => fail('无效二维码')),
          throwsA(isA<QrLoginException>()));
      expect(calls, 1);
    }
  });

  test('二维码服务报错或缺少UUID，不继续轮询', () async {
    for (final response in [
      {'errcode': 1, 'uuid': 'uuid'},
      {'errcode': 0, 'uuid': ''},
      {'errcode': 0, 'uuid': 123},
    ]) {
      var calls = 0;
      final service = QrLoginService(
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((request) {
              calls++;
              return calls == 1 ? _reply(request) : jsonResponse(response);
            }));
      addTearDown(service.dispose);
      await expectLater(
          service.login(cancelToken: CancelToken(), onQr: (_) => fail('无效二维码')),
          throwsA(isA<QrLoginException>()));
      expect(calls, 2);
    }
  });

  test('登录响应缺少字段或含无效账号令牌时不返回可保存凭据', () async {
    for (final override in [
      {'vid': 0},
      {'vid': 'not-an-account'},
      {'accessToken': null},
      {'accessToken': ''},
      {'accessToken': 'secret;header'},
      {'refreshToken': 123},
      {'refreshToken': 'secret\nheader'},
    ]) {
      final service = QrLoginService(
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((_) => jsonResponse({
                  'vid': 123,
                  'accessToken': 'access-token',
                  'refreshToken': 'refresh-token',
                  ...override,
                })));
      addTearDown(service.dispose);
      await expectLater(
          service.exchange('code', cancelToken: CancelToken()),
          throwsA(isA<QrLoginException>().having(
              (error) => error.message.contains('secret'), '不回显令牌', isFalse)));
    }
  });

  test('损坏JSON及非对象响应转为可读的登录错误', () async {
    for (final body in ['{invalid', '[]', 'null']) {
      final service = QrLoginService(
          dio: Dio()
            ..httpClientAdapter =
                AuthAdapter((_) => ResponseBody.fromString(body, 200, headers: {
                      Headers.contentTypeHeader: ['text/plain']
                    })));
      addTearDown(service.dispose);
      await expectLater(
          service.requestQr(cancelToken: CancelToken()),
          throwsA(isA<QrLoginException>()
              .having((error) => error.message, '错误内容', contains('无效数据'))));
    }
  });

  for (final stage in ['/wxticket', '/connect/sdk/qrconnect', '/login']) {
    test('在$stage阶段取消，登录链路停止且不返回凭据', () async {
      final entered = Completer<void>();
      final requests = <String>[];
      final dio = Dio()..httpClientAdapter = AuthAdapter(_reply);
      dio.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) async {
        requests.add(options.uri.path);
        if (options.uri.path == stage) {
          entered.complete();
          handler.reject(await options.cancelToken!.whenCancel);
        } else {
          handler.next(options);
        }
      }));
      final service = QrLoginService(dio: dio);
      addTearDown(service.dispose);
      final token = CancelToken();
      final assertion = expectLater(
        service.login(cancelToken: token, onQr: (_) {}),
        throwsA(isA<DioException>()
            .having((error) => error.type, '取消原因', DioExceptionType.cancel)),
      );
      await entered.future.timeout(const Duration(seconds: 2));
      token.cancel('退出扫码');
      await assertion.timeout(const Duration(seconds: 2));
      expect(requests.last, stage);
    });
  }
}
