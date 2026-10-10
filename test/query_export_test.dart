import 'dart:io';
import 'dart:ffi';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';
import 'package:weread_companion/services/sync_service.dart';

class _TestPaths extends PathProviderPlatform {
  final String path;
  _TestPaths(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late PathProviderPlatform originalPaths;

  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-query-test-');
    await databaseFactory.setDatabasesPath(directory.path);
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });

  tearDown(() async {
    await DatabaseService.endSession();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  Future<void> seed(int count) async {
    await db.insertBookmarks(List.generate(count, (i) => {
      'bookmark_id': 'bm$i', 'book_id': i == 0 ? 'old' : 'main',
      'book_title': i == 0 ? '历史书' : '测试书',
      'mark_text': i == 0 ? '唯一历史引文 100%_\\' : '引文$i',
      'chapter_title': '', 'created_at': i ~/ 3, 'is_fav': i == 0 ? 1 : 0,
    }));
    await db.insertNotes(List.generate(count, (i) => {
      'note_id': 'nt$i', 'book_id': i == 0 ? 'old' : 'main',
      'book_title': i == 0 ? '历史书' : '测试书',
      'content': i == 0 ? '唯一历史笔记' : '想法$i',
      'chapter_title': '', 'created_at': i ~/ 3, 'is_fav': i == 0 ? 1 : 0,
    }));
  }

  test('全库搜索与收藏包含500条以外的历史；同时间分页无遗漏重复', () async {
    await seed(620);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    expect(provider.notes.length, 100);
    expect(provider.totalCount, 1240);
    expect((await provider.getAllMatchingNotes()).length, 1240);
    expect(provider.notes.length, 100); // 批量操作不把列表一次性加载到内存
    final ids = <String>{};
    do {
      for (final item in provider.notes) {
        ids.add('${item.source}:${item.id}');
      }
      if (!provider.hasMore) break;
      await provider.loadMore();
    } while (true);
    expect(provider.notes.length, 1240);
    expect(ids.length, 1240);

    provider.setSearch('唯一历史');
    await provider.loadNotes();
    expect(provider.matchedCount, 2);
    expect(provider.notes.map((n) => n.id).toSet(), {'bm0', 'nt0'});
    provider.setFilter('全部笔记');
    await provider.loadNotes();
    expect(provider.notes.single.id, 'nt0');
    provider.setSearch('');
    provider.setFilter('收藏');
    await provider.loadNotes();
    expect(provider.matchedCount, 2);
    await provider.toggleFavorite(provider.notes.first);
    expect(provider.matchedCount, 1);
    expect(await db.countBookmarks(query: '100%_\\'), 1);
    expect((await db.getAllBookmarks(query: '100%_\\')).single['bookmark_id'], 'bm0');
  });

  test('快速更换搜索时旧请求不覆盖最新查询', () async {
    await seed(620);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    provider.setSearch('引文');
    provider.setSearch('唯一历史笔记');
    await provider.loadNotes();
    expect(provider.matchedCount, 1);
    expect(provider.notes.single.id, 'nt0');
  });

  test('笔记订阅统一同步事件，两次同步均刷新全库计数', () async {
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    expect(provider.totalCount, 0);
    await seed(620);
    SyncService.changes.publish(db);
    while (provider.isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(provider.totalCount, 1240);
    await db.insertNote({'note_id': 'new', 'book_id': 'main',
      'content': '新增笔记', 'created_at': 1000});
    SyncService.changes.publish(db);
    while (provider.isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(provider.totalCount, 1241);
    expect(provider.notes.first.id, 'new');
  });

  testWidgets('报告订阅统一同步事件，统计包含全部历史', (tester) async {
    await tester.runAsync(() => seed(620));
    await tester.pumpWidget(const MaterialApp(home: ReportPage()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('1240'), findsOneWidget);
    await tester.runAsync(() => db.insertNote({'note_id': 'new',
      'book_id': 'main', 'content': '新增笔记', 'created_at': 1000}));
    SyncService.changes.publish(db);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('1241'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片使用数据库翻页，搜索能命中旧内容，同步事件刷新', (tester) async {
    await tester.runAsync(() => seed(620));
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('共 620 条'), findsOneWidget);
    expect(find.text('1/7'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('2/7'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '唯一历史引文');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('共 1 条'), findsOneWidget);
    expect(find.text('唯一历史引文 100%_\\'), findsWidgets);
    await tester.runAsync(() => db.insertBookmark({
      'bookmark_id': 'new', 'book_id': 'old', 'book_title': '历史书',
      'mark_text': '唯一历史引文新增', 'created_at': 999,
    }));
    SyncService.changes.publish(db);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('共 2 条'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('Markdown分批导出超过9999条的两表全部数据，单书导出包含最旧记录', () async {
    await seed(10005);
    final path = await ExportService.exportToMarkdown();
    final markdown = await File(path).readAsString();
    expect(RegExp(r'^- 📝 ', multiLine: true).allMatches(markdown).length, 10005);
    expect(RegExp(r'^- 💭 ', multiLine: true).allMatches(markdown).length, 10005);
    expect(markdown, contains('唯一历史引文'));
    expect(markdown, contains('唯一历史笔记'));
    final single = await File(await ExportService.exportToMarkdown(bookId: 'old')).readAsString();
    expect(single, contains('唯一历史引文'));
    expect(single, contains('唯一历史笔记'));
    expect(RegExp(r'^- ', multiLine: true).allMatches(single).length, 2);
  });
}
