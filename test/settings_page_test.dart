import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:weread_companion/pages/settings_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/widgets/settings/account_settings_section.dart';
import 'package:weread_companion/widgets/settings/ai_settings_section.dart';
import 'package:weread_companion/widgets/settings/about_settings_section.dart';

import 'app_config_settings_test.dart' show SettingsTestConfig;

class _LogoutFailureProvider extends AppConfigProvider {
  _LogoutFailureProvider() : super(config: SettingsTestConfig()..cookie = 'invalid-cookie');
  @override
  Future<void> logout() async {
    config.logoutPending = true;
    notifyListeners();
    throw StateError('delete failed');
  }
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: '阅珀 ReadAmber', packageName: 'test', version: '9.8.7',
      buildNumber: '42', buildSignature: '',
    );
  });

  Future<void> showSettings(WidgetTester tester, AppConfigProvider provider,
      {bool isActive = true}) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(home: SettingsPage(isActive: isActive)),
    ));
    await tester.pump();
  }

  Future<void> expandAi(WidgetTester tester) async {
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置'));
    await tester.pump();
  }

  testWidgets('加载完成前不展示AI值和表单，完成后读取持久化配置', (tester) async {
    final config = SettingsTestConfig()..loadGate = Completer<void>();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    final loading = provider.init();
    await showSettings(tester, provider);
    expect(find.text('正在加载配置…'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('保存配置'), findsNothing);
    expect(find.text('DeepSeek · deepseek-chat'), findsNothing);
    config.loadGate!.complete();
    await loading;
    await tester.pumpAndSettle();
    await expandAi(tester);
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.map((field) => field.controller!.text),
      ['stored-key', 'https://example.com/v1', 'stored-model']);
    expect(config.saves, 0);
  });

  testWidgets('加载失败显示重试，不读取部分配置，重试后恢复表单', (tester) async {
    final config = SettingsTestConfig()..failLoad = true;
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    await showSettings(tester, provider);
    expect(find.text('配置加载失败，请重试'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    config.failLoad = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await expandAi(tester);
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'stored-key');
  });

  testWidgets('保存中禁用编辑及重复保存，失败反馈并保留草稿，可重试成功', (tester) async {
    final config = SettingsTestConfig();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    await showSettings(tester, provider);
    await expandAi(tester);
    await tester.enterText(find.byType(TextField).first, 'draft-key');
    config.failSave = true;
    config.saveGate = Completer<void>();
    await tapSave(tester);
    expect(provider.isBusy, isTrue);
    expect(tester.widgetList<TextField>(find.byType(TextField))
      .every((field) => field.enabled == false), isTrue);
    final saveButton = find.descendant(of: find.byType(AiSettingsSection),
      matching: find.byType(ElevatedButton));
    expect(tester.widget<ElevatedButton>(saveButton).onPressed, isNull);
    config.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('AI 配置保存失败，请重试'), findsOneWidget);
    expect(find.text('AI 配置已保存'), findsNothing);
    expect(config.apiKey, 'stored-key');
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'draft-key');
    config.failSave = false;
    config.saveGate = null;
    ScaffoldMessenger.of(tester.element(saveButton)).clearSnackBars();
    await tapSave(tester);
    await tester.pumpAndSettle();
    expect(config.apiKey, 'draft-key');
    expect(find.text('AI 配置已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出失败有反馈且busy复位，不误报退出成功', (tester) async {
    final provider = _LogoutFailureProvider();
    addTearDown(provider.dispose);
    await provider.init();
    await showSettings(tester, provider);
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录失败，部分本地数据可能未清除，请重试'), findsOneWidget);
    expect(find.text('已退出登录'), findsNothing);
    expect(provider.isBusy, isFalse);
    expect(provider.cleanupPending, isTrue);
    expect(find.text('继续清理'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法服务地址给出反馈，不触发配置保存', (tester) async {
    final config = SettingsTestConfig();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    await showSettings(tester, provider);
    await expandAi(tester);
    await tester.enterText(find.byType(TextField).at(1), 'http://example.com');
    await tapSave(tester);
    await tester.pumpAndSettle();
    expect(find.text('AI 服务地址必须是有效的 HTTPS 地址'), findsOneWidget);
    expect(config.saves, 0);
    expect(config.baseUrl, 'https://example.com/v1');
  });

  testWidgets('配置加载期间离开页面，加载完成不访问已销毁widget', (tester) async {
    final config = SettingsTestConfig()..loadGate = Completer<void>();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    final loading = provider.init();
    await showSettings(tester, provider);
    await tester.pumpWidget(const SizedBox());
    config.loadGate!.complete();
    await loading;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个独立section展示版本，重新进入设置时AI面板折叠', (tester) async {
    final provider = AppConfigProvider(config: SettingsTestConfig());
    addTearDown(provider.dispose);
    await provider.init();
    await showSettings(tester, provider);
    expect(find.byType(AccountSettingsSection), findsOneWidget);
    expect(find.byType(AiSettingsSection), findsOneWidget);
    await expandAi(tester);
    await showSettings(tester, provider, isActive: false);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await showSettings(tester, provider);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.scrollUntilVisible(find.text('v9.8.7'), 400,
      scrollable: find.byType(Scrollable).first);
    expect(find.byType(AboutSettingsSection), findsOneWidget);
    expect(find.text('v9.8.7'), findsOneWidget);
  });

  testWidgets('保存期间离开设置，完成时不更新已销毁widget', (tester) async {
    final config = SettingsTestConfig();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    await showSettings(tester, provider);
    await expandAi(tester);
    config.saveGate = Completer<void>();
    await tapSave(tester);
    expect(provider.isBusy, isTrue);
    await tester.pumpWidget(const SizedBox());
    config.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
