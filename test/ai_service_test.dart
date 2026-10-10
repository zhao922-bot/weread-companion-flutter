import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/config.dart';

void main() {
  tearDown(AIService.cancelAll);

  test('无账号会话时摘要抛取消异常并保留会话原因', () async {
    await expectLater(AIService(config: AppConfig(apiKey: 'test'))
        .summarizeBook('测试', '', []), throwsA(isA<AICancelledException>()
          .having((e) => e.cause, '会话原因', isA<StateError>())));
  });

  test('无效AI配置明确报错且不发送网络请求', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests++;
      handler.reject(DioException(requestOptions: options));
    }));
    for (final config in [
      AppConfig(),
      AppConfig(apiKey: 'test', baseUrl: 'http://example.com'),
    ]) {
      await expectLater(AIService(config: config, dio: dio)
          .interpretQuote('金句', '书名'), throwsA(isA<AIServiceException>()
            .having((e) => e.message, '配置提示', contains('HTTPS'))));
    }
    expect(requests, 0);
  });

  test('阅读分析和金句解读成功返回内容，传递模型与认证信息', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      handler.resolve(Response(requestOptions: options, data: {
        'choices': [{'message': {'content': '生成内容'}}],
      }));
    }));
    final ai = AIService(config: AppConfig(apiKey: 'test'), dio: dio);
    expect(await ai.analyzeReading(['书名'], 12), '生成内容');
    expect(await ai.interpretQuote('金句', '书名'), '生成内容');
    expect(requests, hasLength(2));
    expect(requests.first.headers['Authorization'], 'Bearer test');
    expect(requests.first.data['messages'].last['content'], contains('总划线数: 12'));
    expect(requests.last.data['messages'].last['content'], contains('「金句」'));
  });

  test('取消当前AI请求后可以正常重新请求', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (requests++ == 0) {
        AIService.cancelAll();
        handler.reject(options.cancelToken!.cancelError!);
      } else {
        handler.resolve(Response(requestOptions: options, data: {
          'choices': [{'message': {'content': '重试成功'}}],
        }));
      }
    }));
    final ai = AIService(config: AppConfig(apiKey: 'test'), dio: dio);
    await expectLater(ai.interpretQuote('金句', '书名'),
      throwsA(isA<AICancelledException>()));
    expect(await ai.interpretQuote('金句', '书名'), '重试成功');
  });

  test('内容类型无效保留格式异常和原始堆栈', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) =>
      handler.resolve(Response(requestOptions: options, data: {
        'choices': [{'message': {'content': 123}}],
      }))));
    try {
      await AIService(config: AppConfig(apiKey: 'test'), dio: dio)
          .interpretQuote('金句', '书名');
      fail('无效响应应抛异常');
    } on AIServiceException catch (e, stack) {
      expect(e, isNot(isA<AICancelledException>()));
      expect(e.cause, isA<FormatException>());
      expect(e.toString(), contains('格式无效'));
      expect(stack.toString(), contains('_callApi'));
    }
  });
}
