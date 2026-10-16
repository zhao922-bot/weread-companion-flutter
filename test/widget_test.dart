import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:weread_companion/main.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'weread_base_url': 'https://api.deepseek.com',
      'weread_model_name': 'smoke-test-model',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
  });

  test('从存储加载 AppConfig 并初始化未登录 provider', () async {
    final provider = AppConfigProvider(config: AppConfig());
    addTearDown(provider.dispose);
    await provider.init();
    expect(provider.isLoaded, isTrue);
    expect(provider.isBusy, isFalse);
    expect(provider.loginStatus, LoginStatus.signedOut);
    expect(provider.canBrowseLocal, isFalse);
    expect(provider.config.modelName, 'smoke-test-model');
  });

  testWidgets('应用未登录入口及设置页显示平台真实版本', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: '阅珀 ReadAmber',
      packageName: 'com.example.weread_companion',
      version: '9.8.7',
      buildNumber: '42',
      buildSignature: '',
    );
    await tester.pumpWidget(const ReadAmberApp());
    await tester.pumpAndSettle();
    expect(find.text('请先在设置中验证登录'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('v9.8.7'), 400,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('v9.8.7'), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
        '阅珀 ReadAmber');
    expect(find.text('阅珀'), findsOneWidget);
    expect(find.text('ReadAmber · 让读过的，留下来。'), findsOneWidget);
    expect(find.image(const AssetImage(
        'assets/branding/readamber-v1/readamber-icon-128.png')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
