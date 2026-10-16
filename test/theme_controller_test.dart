import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:weread_companion/main.dart';
import 'package:weread_companion/providers/theme_controller.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:weread_companion/widgets/settings/theme_settings_section.dart';
import 'package:provider/provider.dart';

class _Store extends InMemorySharedPreferencesStore {
  _Store() : super.withData({});
  bool readError = false;
  bool writeError = false;
  bool writeOk = true;
  Completer<void>? writing;
  @override
  Future<Map<String, Object>> getAll() async {
    if (readError) throw StateError('read failed');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await writing?.future;
    if (writeError) throw StateError('write failed');
    if (!writeOk) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _Store();
    SharedPreferencesStorePlatform.instance = store;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
  });

  test('首次默认浅色，三种模式分别持久化并由新控制器恢复，未知值回退浅色', () async {
    final first = ThemeController();
    addTearDown(first.dispose);
    await first.load();
    expect(first.mode, ThemeMode.light);
    for (final mode in ThemeMode.values) {
      await first.setMode(mode);
      final restarted = ThemeController();
      await restarted.load();
      expect(restarted.mode, mode);
      expect(restarted.error, isNull);
      restarted.dispose();
    }
    await (await SharedPreferences.getInstance())
        .setString(ThemeController.preferenceKey, 'unknown');
    await first.load();
    expect(first.mode, ThemeMode.light);
  });

  test('读取失败可重试，写入返回false或抛错保留已生效主题，随后可再次保存', () async {
    final controller = ThemeController();
    addTearDown(controller.dispose);
    store.readError = true;
    await controller.load();
    expect(controller.error, contains('读取失败'));
    expect(controller.isBusy, isFalse);
    store.readError = false;
    await controller.load();
    expect(controller.error, isNull);
    for (final throws in [false, true]) {
      store.writeError = throws;
      store.writeOk = false;
      await controller.setMode(ThemeMode.dark);
      expect(controller.mode, ThemeMode.light);
      expect(controller.error, contains('保存失败'));
      expect(controller.isBusy, isFalse);
    }
    store.writeError = false;
    store.writeOk = true;
    await controller.setMode(ThemeMode.dark);
    expect(controller.mode, ThemeMode.dark);
    expect(controller.error, isNull);
  });

  for (final loading in [true, false]) {
    test('${loading ? "读取" : "保存"}等待打开存储时拒绝重入，销毁后无通知或写入', () async {
      final gate = Completer<SharedPreferences>();
      final controller = ThemeController(preferences: () => gate.future);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending =
          loading ? controller.load() : controller.setMode(ThemeMode.dark);
      await controller.load();
      await controller.setMode(ThemeMode.system);
      expect(notifications, 1);
      controller.dispose();
      await controller.load();
      await controller.setMode(ThemeMode.system);
      gate.complete(await SharedPreferences.getInstance());
      await pending;
      expect(notifications, 1);
      expect(controller.mode, ThemeMode.light);
      expect(
          (await SharedPreferences.getInstance())
              .getString(ThemeController.preferenceKey),
          isNull);
    });
  }

  test('写入已经开始时销毁，保存可以完成但不再通知或更新已销毁控制器', () async {
    store.writing = Completer<void>();
    final prefs = await SharedPreferences.getInstance();
    final controller = ThemeController(preferences: () async => prefs);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final pending = controller.setMode(ThemeMode.dark);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    store.writing!.complete();
    await pending;
    expect(notifications, 1);
    expect(controller.mode, ThemeMode.light);
    final restarted = ThemeController();
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.mode, ThemeMode.dark);
  });

  test('两套主题的语义文字与操作按钮达到普通文字4.5:1对比度', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
    }

    for (final colors in [ReadAmberPalette.light, ReadAmberPalette.dark]) {
      for (final bg in [
        colors.canvas,
        colors.surface,
        colors.surfaceMuted,
        colors.paper
      ]) {
        for (final fg in [
          colors.ink,
          colors.inkSoft,
          colors.muted,
          colors.amberText,
          colors.success,
          colors.error
        ]) {
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5));
        }
      }
      expect(
          contrast(colors.action, colors.onAction), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('设置错误有恢复入口，保存期间禁用选择并保留已生效主题', (tester) async {
    final controller = ThemeController();
    addTearDown(controller.dispose);
    store.readError = true;
    await controller.load();
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
            theme: ReadAmberTheme.light,
            home: const Scaffold(body: ThemeSettingsSection()))));
    expect(find.textContaining('主题读取失败'), findsOneWidget);
    store.readError = false;
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(find.textContaining('主题读取失败'), findsNothing);
    store.writing = Completer<void>();
    await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('墨青深色').last);
    await tester.pump();
    expect(
        tester
            .widget<DropdownButtonFormField<ThemeMode>>(
                find.byType(DropdownButtonFormField<ThemeMode>))
            .onChanged,
        isNull);
    expect(controller.mode, ThemeMode.light);
    store.writing!.complete();
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.dark);
    store.writeOk = false;
    await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('纸白浅色').last);
    await tester.pumpAndSettle();
    expect(find.text('主题保存失败，请重新选择'), findsOneWidget);
    expect(controller.mode, ThemeMode.dark);
    expect(
        tester
            .widget<DropdownButton<ThemeMode>>(
                find.byType(DropdownButton<ThemeMode>))
            .value,
        ThemeMode.dark);
  });

  testWidgets('应用主题入口可即时切换，跟随系统响应亮暗变化且重建应用后恢复', (tester) async {
    final dispatcher = tester.binding.platformDispatcher;
    dispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(dispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const ReadAmberApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    Future<void> choose(String label) async {
      await tester
          .ensureVisible(find.byType(DropdownButtonFormField<ThemeMode>));
      await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Brightness current() =>
        Theme.of(tester.element(find.byType(ThemeSettingsSection))).brightness;
    await choose('墨青深色');
    expect(current(), Brightness.dark);
    await choose('纸白浅色');
    expect(current(), Brightness.light);
    await choose('跟随系统');
    dispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(current(), Brightness.dark);
    dispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(current(), Brightness.light);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const ReadAmberApp());
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system);
    expect(tester.takeException(), isNull);
  });
}
