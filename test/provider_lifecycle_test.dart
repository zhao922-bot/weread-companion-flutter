import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'app_config_settings_test.dart' show SettingsTestConfig;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('配置加载中释放provider，后续完成不再通知已释放监听器', () async {
    final config = SettingsTestConfig()..loadGate = Completer<void>();
    final provider = AppConfigProvider(config: config);
    final loading = provider.init();
    provider.dispose();
    config.loadGate!.complete();
    await expectLater(loading, completes);
    expect(config.saves, 0);
  });

  test('配置保存中释放provider，原始保存错误不被已释放通知异常覆盖', () async {
    final config = SettingsTestConfig();
    final provider = AppConfigProvider(config: config);
    await provider.init();
    config.saveGate = Completer<void>();
    config.failSave = true;
    final saving = provider.updateAiConfig(apiKey: 'new');
    final assertion = expectLater(
        saving,
        throwsA(
            isA<StateError>().having((e) => e.message, '原因', 'write failed')));
    provider.dispose();
    config.saveGate!.complete();
    await assertion;
    expect(config.apiKey, 'stored-key');
  });
}
