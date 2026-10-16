import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/services/qr_login_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;

class _ObservedCancelToken extends CancelToken {
  int subscriptions = 0;
  @override
  Future<DioException> get whenCancel {
    subscriptions++;
    return super.whenCancel;
  }
}

void main() {
  test('连续50次轮询只连接一次外部取消信号', () async {
    var calls = 0;
    final token = _ObservedCancelToken();
    final service = QrLoginService(
        pollInterval: Duration.zero,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((_) => jsonResponse({
                'wx_errcode': ++calls < 50 ? 408 : 405,
                'wx_code': 'code',
              })));
    addTearDown(service.dispose);
    expect(await service.pollForCode('uuid', cancelToken: token), 'code');
    expect(calls, 50);
    expect(token.subscriptions, 1);
    token.cancel();
    await Future<void>.delayed(Duration.zero);
  });

  test('立即失败的超时请求遵守重试间隔，避免忙循环', () async {
    final starts = <int>[];
    final elapsed = Stopwatch()..start();
    final dio = Dio()
      ..httpClientAdapter = AuthAdapter((options) {
        starts.add(elapsed.elapsedMilliseconds);
        if (starts.length == 1) {
          throw DioException(
              requestOptions: options, type: DioExceptionType.receiveTimeout);
        }
        return jsonResponse({'wx_errcode': 405, 'wx_code': 'code'});
      });
    final service = QrLoginService(
        dio: dio, pollInterval: const Duration(milliseconds: 50));
    addTearDown(service.dispose);
    expect(
        await service.pollForCode('uuid', cancelToken: CancelToken()), 'code');
    expect(starts[1] - starts[0], greaterThanOrEqualTo(45));
  });

  test('等待、扫码、确认状态与last参数，扫码后408不回退等待', () async {
    final replies = [408, 404, 408, 405];
    final lasts = <Object?>[];
    final states = <QrLoginStatus>[];
    final dio = Dio()
      ..httpClientAdapter = AuthAdapter((options) {
        lasts.add(options.queryParameters['last']);
        return jsonResponse(
            {'wx_errcode': replies.removeAt(0), 'wx_code': 'code'});
      });
    final service = QrLoginService(dio: dio, pollInterval: Duration.zero);
    addTearDown(service.dispose);
    expect(
        await service.pollForCode('uuid',
            cancelToken: CancelToken(), onStatus: states.add),
        'code');
    expect(lasts, [null, 408, 404, 408]);
    expect(states, [
      QrLoginStatus.waiting,
      QrLoginStatus.scanned,
      QrLoginStatus.confirmed
    ]);
  });

  for (final code in [402, 403, 999, 405]) {
    test('状态$code无授权码明确失败', () async {
      final service = QrLoginService(
          dio: Dio()
            ..httpClientAdapter =
                AuthAdapter((_) => jsonResponse({'wx_errcode': code})));
      addTearDown(service.dispose);
      await expectLater(
          service.pollForCode('uuid', cancelToken: CancelToken()),
          throwsA(isA<QrLoginException>()
              .having((e) => e.expired, '过期', code == 402)));
    });
  }

  test('长轮询单次超时重试，总时限到达报过期', () async {
    var requests = 0;
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      requests++;
      handler.reject(await options.cancelToken!.whenCancel);
    }));
    final service = QrLoginService(
        dio: dio,
        pollDeadline: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 5),
        requestTimeout: const Duration(milliseconds: 20));
    addTearDown(service.dispose);
    await expectLater(
        service
            .pollForCode('uuid', cancelToken: CancelToken())
            .timeout(const Duration(seconds: 2)),
        throwsA(
            isA<QrLoginException>().having((e) => e.expired, '过期', isTrue)));
    expect(requests, greaterThan(1));
  });

  test('轮询请求期间取消，传播取消且不继续请求', () async {
    final entered = Completer<void>();
    var requests = 0;
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      requests++;
      entered.complete();
      handler.reject(await options.cancelToken!.whenCancel);
    }));
    final service = QrLoginService(dio: dio);
    addTearDown(service.dispose);
    final token = CancelToken();
    final pending = service.pollForCode('uuid', cancelToken: token);
    final assertion = expectLater(
        pending,
        throwsA(isA<DioException>()
            .having((e) => e.type, '取消', DioExceptionType.cancel)));
    await entered.future;
    token.cancel('退出');
    await assertion.timeout(const Duration(seconds: 2));
    expect(requests, 1);
  });

  test('扫码后等待期间取消，不进入下一次轮询', () async {
    var requests = 0;
    final token = CancelToken();
    final service = QrLoginService(
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((_) {
            requests++;
            return jsonResponse({'wx_errcode': 404});
          }));
    addTearDown(service.dispose);
    await expectLater(
        service.pollForCode('uuid',
            cancelToken: token,
            onStatus: (_) => Timer.run(() => token.cancel('退出'))),
        throwsA(isA<DioException>()
            .having((e) => e.type, '取消', DioExceptionType.cancel)));
    expect(requests, 1);
  });
}
