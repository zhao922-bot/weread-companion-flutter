import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';

import 'mobile_auth_test.dart' show AuthAdapter, initial, jsonResponse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const databaseChannel = MethodChannel('com.tekartik.sqflite');
  late AppConfig config;
  late int requests;

  Dio transport() => Dio()
    ..httpClientAdapter = AuthAdapter((_) {
      requests++;
      return jsonResponse({
        'books': [
          {'bookId': 'b', 'title': requests == 1 ? '验证快照' : '额外请求'},
        ]
      });
    });

  setUp(() {
    config = AppConfig(credentials: initial);
    requests = 0;
    databaseFactory = databaseFactorySqflitePlugin;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(databaseChannel, (call) async {
      if (call.method == 'getDatabasesPath') return '/tmp/audit-cached-request';
      if (call.method == 'deleteDatabase') return null;
      throw UnsupportedError(call.method);
    });
  });
  tearDown(() async {
    WeReadApi.reset();
    await DatabaseService.endSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(databaseChannel, null);
  });

  test('已取消的书架请求不能通过验证快照返回成功，也不能消耗重试缓存', () async {
    final verifier = WeReadApi.forLogin(config: config, dio: transport());
    expect(await verifier.checkLogin(), isTrue);
    final db = await DatabaseService.selectAccount('123');
    final api = await WeReadApi.init(config: config, db: db, dio: transport());
    final token = CancelToken()..cancel('离开页面');
    await expectLater(
        api.fetchBookshelf(cancelToken: token),
        throwsA(isA<DioException>()
            .having((e) => e.type, '取消类型', DioExceptionType.cancel)));
    expect(requests, 1);
    final books = await api.fetchBookshelf(cancelToken: CancelToken());
    expect(books.single.title, '验证快照');
    expect(requests, 1);
  });

  test('已关闭客户端的迟到书架请求不能清空当前会话的验证快照', () async {
    final retired = WeReadApi.forLogin(config: config, dio: transport());
    retired.dispose();
    final verifier = WeReadApi.forLogin(config: config, dio: transport());
    expect(await verifier.checkLogin(), isTrue);
    await expectLater(retired.fetchBookshelf(), throwsA(isA<DioException>()));
    final db = await DatabaseService.selectAccount('123');
    final api = await WeReadApi.init(config: config, db: db, dio: transport());
    final books = await api.fetchBookshelf();
    expect(books.single.title, '验证快照');
    expect(requests, 1);
  });
}
