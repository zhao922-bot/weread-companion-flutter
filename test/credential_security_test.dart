import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weread_companion/pages/cookie_login_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};
  bool failWrites = false;
  int writes = 0;

  setUp(() {
    secrets.clear();
    failWrites = false;
    writes = 0;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return secrets[key];
        case 'write':
          writes++;
          if (failWrites) throw PlatformException(code: 'storage_unavailable');
          secrets[key] = args['value'] as String;
          return null;
        case 'delete':
          secrets.remove(key);
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('迁移旧凭据并删除 SharedPreferences 明文', () async {
    SharedPreferences.setMockInitialValues({
      'weread_cookie': 'wr_vid=123; wr_skey=secret',
      'weread_api_key': 'legacy-key',
    });
    final config = AppConfig();
    await config.load();
    final prefs = await SharedPreferences.getInstance();
    expect(secrets['weread_cookie'], config.cookie);
    expect(secrets['weread_api_key'], 'legacy-key');
    expect(prefs.containsKey('weread_cookie'), isFalse);
    expect(prefs.containsKey('weread_api_key'), isFalse);
    await config.clear();
    expect(secrets, isEmpty);
    expect(config.cookie, isEmpty);
    expect(config.apiKey, isEmpty);
  });

  test('安全存储已有凭据时不被旧明文覆盖', () async {
    secrets['weread_cookie'] = 'wr_vid=456; wr_skey=new';
    SharedPreferences.setMockInitialValues({'weread_cookie': 'old-cookie'});
    final config = AppConfig();
    await config.load();
    expect(config.cookie, 'wr_vid=456; wr_skey=new');
    expect((await SharedPreferences.getInstance()).containsKey('weread_cookie'),
        isFalse);
  });

  test('迁移失败保留旧值供重试', () async {
    SharedPreferences.setMockInitialValues({'weread_cookie': 'legacy-cookie'});
    failWrites = true;
    await expectLater(AppConfig().load(), throwsA(isA<PlatformException>()));
    expect((await SharedPreferences.getInstance()).getString('weread_cookie'),
        'legacy-cookie');
  });

  test('保存敏感信息仅写入安全存储', () async {
    await AppConfig(cookie: 'wr_vid=123', apiKey: 'key').save();
    final prefs = await SharedPreferences.getInstance();
    expect(secrets['weread_cookie'], 'wr_vid=123');
    expect(secrets['weread_api_key'], 'key');
    expect(prefs.containsKey('weread_cookie'), isFalse);
    expect(prefs.containsKey('weread_api_key'), isFalse);
  });

  test('重复保存无安全存储写入，仅持久化发生变化的字段', () async {
    final config = AppConfig(cookie: 'wr_vid=123', apiKey: 'key');
    await config.save();
    expect(writes, 2);
    await config.save();
    expect(writes, 2);
    final restored = AppConfig();
    await restored.load();
    await restored.save();
    expect(writes, 2);
    restored.apiKey = 'changed';
    await restored.save();
    expect(writes, 3);
  });

  test('三个独立安全配置读取并发启动', () async {
    final gate = Completer<void>();
    final keys = <String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') {
          keys.add((call.arguments as Map)['key'] as String);
          await gate.future;
        }
        return null;
      });
    final load = AppConfig().load();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final started = keys.length;
    gate.complete();
    await load;
    expect(started, 3);
  });

  test('拒绝不安全 AI 地址并停用旧 HTTP 配置', () async {
    for (final url in [
      'http://example.com',
      'https:///api',
      'https://key@example.com',
      'https://example.com#fragment'
    ]) {
      expect(AppConfig.isHttpsUrl(url), isFalse);
      await expectLater(AppConfig(baseUrl: url).save(), throwsFormatException);
    }
    SharedPreferences.setMockInitialValues(
        {'weread_base_url': 'http://example.com'});
    final config = AppConfig();
    await config.load();
    expect(config.baseUrl, isEmpty);
    expect(AppConfig.isHttpsUrl('https://example.com/v1'), isTrue);
  });

  test('Cookie 导出格式规范化并过滤其他域', () {
    expect(WeReadApi.normalizeCookie(' Cookie: wr_vid = 123; wr_skey=a=b; '),
        'wr_vid=123; wr_skey=a=b');
    expect(
        WeReadApi.normalizeCookie(
            '[{"name":"wr_vid","value":"123","domain":".weread.qq.com"},{"name":"token","value":"other","domain":"example.com"}]'),
        'wr_vid=123');
    expect(WeReadApi.normalizeCookie('{"wr_vid":"123","wr_skey":"abc"}'),
        'wr_vid=123; wr_skey=abc');
    expect(
        WeReadApi.normalizeCookie(
            '# Netscape HTTP Cookie File\n.weread.qq.com\tTRUE\t/\tTRUE\t0\twr_vid\t123'),
        'wr_vid=123');
    expect(() => WeReadApi.normalizeCookie('[invalid JSON]'),
        throwsFormatException);
    expect(() => WeReadApi.normalizeCookie('wr_vid=123\r\nX-Header=injected'),
        throwsFormatException);
  });

  testWidgets('隐藏和显示 Cookie 均不触发多行密码断言', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppConfigProvider(config: AppConfig()),
      child: const MaterialApp(home: CookieLoginPage()),
    ));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byIcon(Icons.visibility_off));
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byIcon(Icons.visibility));
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
