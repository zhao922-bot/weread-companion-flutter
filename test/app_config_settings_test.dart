import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/config.dart';

class SettingsTestConfig extends AppConfig {
  Completer<void>? loadGate;
  Completer<void>? saveGate;
  bool failLoad = false;
  bool failSave = false;
  int saves = 0;

  @override
  Future<void> loadTrustedAccount() async {}

  @override
  Future<void> load() async {
    await loadGate?.future;
    // 模拟安全存储读取到一半失败。
    apiKey = 'stored-key';
    if (failLoad) throw StateError('storage unavailable');
    baseUrl = 'https://example.com/v1';
    modelName = 'stored-model';
  }

  @override
  Future<void> save() async {
    saves++;
    await saveGate?.future;
    if (failSave) throw StateError('write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('完整加载前不允许保存AI配置，加载状态通知监听者', () async {
    final config = SettingsTestConfig()..loadGate = Completer<void>();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    final states = <bool>[];
    provider.addListener(() => states.add(provider.isLoading));
    await expectLater(provider.updateAiConfig(apiKey: 'early'), throwsStateError);
    final loading = provider.init();
    expect(provider.isLoading, isTrue);
    expect(provider.isLoaded, isFalse);
    await expectLater(provider.updateAiConfig(apiKey: 'early'), throwsStateError);
    expect(config.saves, 0);
    config.loadGate!.complete();
    await loading;
    expect(provider.isLoaded, isTrue);
    expect(provider.isLoading, isFalse);
    expect(states.first, isTrue);
    expect(states.last, isFalse);
    await provider.updateAiConfig(apiKey: 'new');
    expect(config.apiKey, 'new');
    expect(config.saves, 1);
  });

  test('部分加载失败不能误判成功，重试完整加载后才能保存', () async {
    final config = SettingsTestConfig()..failLoad = true;
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    expect(provider.isLoaded, isFalse);
    expect(provider.isLoading, isFalse);
    expect(provider.isBusy, isFalse);
    expect(provider.configLoadError, isNotNull);
    await expectLater(provider.updateAiConfig(apiKey: 'new'), throwsStateError);
    expect(config.saves, 0);
    config.failLoad = false;
    await provider.init();
    expect(provider.isLoaded, isTrue);
    expect(provider.configLoadError, isNull);
    expect(provider.loginError, isNull);
  });

  test('保存失败恢复内存AI配置并结束busy状态，可再次保存', () async {
    final config = SettingsTestConfig();
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await provider.init();
    config.failSave = true;
    await expectLater(
      provider.updateAiConfig(apiKey: 'new', baseUrl: 'https://new.com', modelName: 'new'),
      throwsStateError,
    );
    expect(config.apiKey, 'stored-key');
    expect(config.baseUrl, 'https://example.com/v1');
    expect(config.modelName, 'stored-model');
    expect(provider.isBusy, isFalse);
    config.failSave = false;
    await provider.updateAiConfig(apiKey: 'new');
    expect(config.apiKey, 'new');
  });
}
