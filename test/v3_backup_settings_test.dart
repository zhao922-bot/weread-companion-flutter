import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/widgets/settings/backup_settings_section.dart';
import 'support/wait_until.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _FakeAppConfigProvider extends AppConfigProvider {
  _FakeAppConfigProvider() : super(config: AppConfig());
  @override
  bool get isLoaded => true;
  @override
  bool get canBrowseLocal => true;
  @override
  bool get isLoggedIn => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory dir;
  late DatabaseService db;
  late PathProviderPlatform originalPaths;
  late _FakeAppConfigProvider config;

  setUp(() async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('readamber-v3-backup-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    databaseFactory = databaseFactoryFfiNoIsolate;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, (_) async => 'ok');
    await DatabaseService.selectAccount('8009');
    db = DatabaseService.instance;
    await db.database;
    config = _FakeAppConfigProvider();
  });

  tearDown(() async {
    config.dispose();
    await DatabaseService.endSession();
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, null);
    await dir.delete(recursive: true);
  });

  Future<void> clearSnackBars(WidgetTester tester) async {
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
        .clearSnackBars();
    await tester.pump();
  }

  testWidgets('BackupSettingsSection 导出与恢复完整流程', (tester) async {
    await tester.runAsync(() async {
      await db.insertBook({'book_id': 'b1', 'title': '备份测试书', 'updated_at': 1});
      await db.insertBookmark({
        'bookmark_id': 'bm1',
        'book_id': 'b1',
        'book_title': '备份测试书',
        'mark_text': '测试划线',
        'chapter_title': '一',
        'created_at': 10,
      });
    });
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
      value: config,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BackupSettingsSection()),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Obsidian 导出
    await clearSnackBars(tester);
    await tester.tap(find.text('导出 Obsidian Markdown'));
    await pumpUntil(
      tester,
      () => find.text('已导出 Obsidian Markdown').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 15),
    );
    expect(find.text('已导出 Obsidian Markdown'), findsOneWidget);

    // JSON 导出
    await clearSnackBars(tester);
    await tester.tap(find.text('导出完整备份（JSON）'));
    await pumpUntil(
      tester,
      () => find.text('已导出完整 JSON 备份').evaluate().isNotEmpty,
    );
    expect(find.text('已导出完整 JSON 备份'), findsOneWidget);

    // JSON 恢复：取消
    await clearSnackBars(tester);
    await tester.tap(find.text('从 JSON 恢复备份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // JSON 恢复：合法内容
    await clearSnackBars(tester);
    await tester.tap(find.text('从 JSON 恢复备份'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      '{"version": 1, "books": []}',
    );
    await tester.tap(find.text('开始恢复'));
    await pumpUntil(
      tester,
      () => find.textContaining('已恢复 0 本书').evaluate().isNotEmpty,
    );
    expect(find.textContaining('已恢复 0 本书'), findsOneWidget);

    // JSON 恢复：非法内容
    await clearSnackBars(tester);
    await tester.tap(find.text('从 JSON 恢复备份'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'bad-json');
    await tester.tap(find.text('开始恢复'));
    await pumpUntil(
      tester,
      () => find.textContaining('操作失败').evaluate().isNotEmpty,
    );
    expect(find.textContaining('操作失败'), findsOneWidget);
  });
}
