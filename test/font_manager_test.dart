import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:weread_companion/providers/theme_controller.dart';
import 'package:weread_companion/services/font_service.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:weread_companion/widgets/settings/theme_settings_section.dart';

class _FontFakeAdapter implements HttpClientAdapter {
  _FontFakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);
  @override
  void close({bool force = false}) {}
}

class _FailingPrefStore extends InMemorySharedPreferencesStore {
  _FailingPrefStore() : super.withData({});
  bool writeOk = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!writeOk) return false;
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (!writeOk) return false;
    return super.remove(key);
  }
}

class _StubFontService extends FontService {
  _StubFontService({required super.directoryProvider})
      : super(registerFont: (_, __) async {});
  final downloaded = <String>{};
  Completer<void>? gate;
  bool failDownload = false;

  @override
  Future<Set<String>> listDownloadedIds() async => {...downloaded};

  @override
  Future<void> loadFont(OpenSourceFont font) async {}

  @override
  Future<void> downloadFont(
    OpenSourceFont font, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    onProgress?.call(0.5);
    await gate?.future;
    if (failDownload) throw StateError('download failed');
    downloaded.add(font.id);
  }

  @override
  Future<void> deleteFont(OpenSourceFont font) async {
    downloaded.remove(font.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _FailingPrefStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('readamber-fonts-');
    SharedPreferences.setMockInitialValues({});
    store = _FailingPrefStore();
    SharedPreferencesStorePlatform.instance = store;
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('FontService 下载、加载、缓存列表、损坏校验、覆盖与删除全分支覆盖', () async {
    final font = OpenSourceFont.catalog.first;
    expect(OpenSourceFont.byId(null), isNull);
    expect(OpenSourceFont.byId('nonexistent'), isNull);
    expect(OpenSourceFont.byId(font.id), font);

    final registered = <String>[];
    var failDownload = false;
    final dio = Dio()
      ..httpClientAdapter = _FontFakeAdapter((opts) async {
        if (failDownload) throw StateError('network down');
        final bytes = Uint8List.fromList([0, 1, 0, 0, 1, 2, 3, 4]);
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            Headers.contentLengthHeader: ['${bytes.length}'],
          },
        );
      });

    final service = FontService(
      dio: dio,
      directoryProvider: () async => dir,
      registerFont: (family, bytes) async => registered.add(family),
    );

    // 初始为空，加载未下载字体报错
    expect(await service.listDownloadedIds(), isEmpty);
    await expectLater(service.loadFont(font), throwsStateError);

    // 空文件报错
    final f = await service.fontFile(font);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(const []);
    expect(await service.listDownloadedIds(), isEmpty);
    await expectLater(service.loadFont(font), throwsStateError);

    // 下载失败清理残留 .tmp（覆盖存在和不存在两种分支）
    failDownload = true;
    await expectLater(service.downloadFont(font), throwsA(anything));
    await File('${f.path}.tmp').writeAsBytes([1, 2]);
    await expectLater(service.downloadFont(font), throwsA(anything));
    expect(await File('${f.path}.tmp').exists(), isFalse);

    // 正常下载并覆盖已有空文件，触发 onProgress 和自动 loadFont
    failDownload = false;
    final progresses = <double>[];
    await service.downloadFont(font, onProgress: progresses.add);
    expect(progresses, isNotEmpty);
    expect(registered, [font.family]);
    expect(await service.listDownloadedIds(), contains(font.id));

    // 二次 loadFont 命中内存缓存不重复注册
    await service.loadFont(font);
    expect(registered.length, 1);

    // 删除字体
    await service.deleteFont(font);
    expect(await service.listDownloadedIds(), isEmpty);

    // 默认 FontLoader 注册器分支（传入空/测试字节，mock 底层不抛错）
    final defaultService = FontService(directoryProvider: () async => dir);
    await f.writeAsBytes([0, 1, 0, 0]);
    await defaultService.loadFont(font);
  });

  test('ThemeController 字体持久化、启动恢复、下载失败与删除回退系统默认', () async {
    final font = OpenSourceFont.catalog.first;
    final dio = Dio()
      ..httpClientAdapter = _FontFakeAdapter((_) async {
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            Headers.contentLengthHeader: ['${bytes.length}'],
          },
        );
      });
    final service = FontService(
      dio: dio,
      directoryProvider: () async => dir,
      registerFont: (_, __) async {},
    );

    final controller = ThemeController(fontService: service);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.fontId, isNull);
    expect(controller.fontFamily, isNull);

    // 下载并应用
    await controller.downloadAndApplyFont(font);
    expect(controller.fontId, font.id);
    expect(controller.fontFamily, font.family);
    expect(controller.downloadedFonts, contains(font.id));

    // 重启恢复已下载字体
    final restarted = ThemeController(fontService: service);
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.fontId, font.id);

    // 切回系统默认 & 切回已下载字体
    await controller.setFont(null);
    expect(controller.fontId, isNull);
    await controller.setFont(font.id);
    expect(controller.fontId, font.id);

    // 写入偏好失败报错
    store.writeOk = false;
    await controller.setFont(null);
    expect(controller.fontError, contains('字体切换失败'));
    store.writeOk = true;

    // 删除当前使用字体自动回退系统默认
    await controller.deleteFont(font);
    expect(controller.fontId, isNull);
    expect(controller.downloadedFonts, isEmpty);

    // 删除异常分支
    final badService = FontService(
      dio: Dio()
        ..httpClientAdapter =
            _FontFakeAdapter((_) async => throw StateError('fail')),
      directoryProvider: () async => throw StateError('no dir'),
      registerFont: (_, __) async {},
    );
    final badController = ThemeController(fontService: badService);
    addTearDown(badController.dispose);
    await badController.load(); // 字体目录失败静默回退
    await badController.downloadAndApplyFont(font);
    expect(badController.fontError, contains('下载失败'));
    await badController.deleteFont(font);
    expect(badController.fontError, contains('删除失败'));
  });

  testWidgets('ThemeSettingsSection 字体库弹窗下载、进度展示、切换与删除', (tester) async {
    final font = OpenSourceFont.catalog.first;
    final gate = Completer<void>();
    final service = _StubFontService(directoryProvider: () async => dir)
      ..gate = gate;
    final controller = ThemeController(fontService: service);
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        theme: ReadAmberTheme.lightFor(fontFamily: controller.fontFamily),
        darkTheme: ReadAmberTheme.darkFor(fontFamily: controller.fontFamily),
        home: const Scaffold(body: ThemeSettingsSection()),
      ),
    ));

    expect(find.text('应用字体（开源可商用）'), findsOneWidget);
    await tester.tap(find.text('应用字体（开源可商用）'));
    await tester.pumpAndSettle();
    expect(find.text('开源可商用字体库'), findsOneWidget);

    // 点击下载，验证进度态 + 并发下载锁
    await tester.tap(find.text('下载').first);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    // 下载中重复调用被忽略
    await controller.downloadAndApplyFont(font);
    await controller.setFont(null);
    await controller.deleteFont(font);

    gate.complete();
    await tester.pumpAndSettle();
    expect(controller.fontId, font.id);

    // 切回系统默认再切回已下载字体
    await tester.tap(find.text('系统默认'));
    await tester.pumpAndSettle();
    expect(controller.fontId, isNull);
    await tester.tap(find.text(font.name));
    await tester.pumpAndSettle();
    expect(controller.fontId, font.id);

    // 删除字体
    await tester.tap(find.byTooltip('删除 ${font.name}'));
    await tester.pumpAndSettle();
    expect(controller.fontId, isNull);
    expect(controller.downloadedFonts, isEmpty);

    // 下载失败展示错误提示
    service
      ..gate = null
      ..failDownload = true;
    await tester.tap(find.text('下载').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('下载失败'), findsOneWidget);
  });
}
