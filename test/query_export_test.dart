import 'dart:io';
import 'dart:ffi';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
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
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'support/wait_until.dart';

class _TestPaths extends PathProviderPlatform {
  final String path;
  _TestPaths(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _ShelfAdapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests++;
    return ResponseBody.fromString(jsonEncode({'books': []}), 200,
      headers: {Headers.contentTypeHeader: ['application/json']});
  }
  @override
  void close({bool force = false}) {}
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
    WeReadApi.reset();
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

  test('增量事务保留收藏、删除及游标原子提交，失败全部回滚且中文索引一致', () async {
    await seed(3);
    await db.applySyncDelta('old', 'bookmark', [{
      'bookmark_id': 'bm0', 'book_id': 'old', 'mark_text': '新的中文引文', 'created_at': 1,
    }], [], 'first');
    expect((await db.getReadingItem('bm0', 'bookmark', 'old'))!['is_fav'], 1);
    expect(await db.countBookmarks(query: '中文引文'), 1);
    expect(await db.countBookmarks(query: '唯一历史引文'), 0);
    expect(await db.getSyncCursor('old', 'bookmark'), 'first');
    await expectLater(db.applySyncDelta('old', 'bookmark', [
      {'bookmark_id': 'bm0', 'book_id': 'old', 'mark_text': '不应提交', 'created_at': 2},
      {'bookmark_id': 'broken', 'book_id': 'old', 'created_at': null},
    ], ['bm0'], 'broken'), throwsA(isA<DatabaseException>()));
    expect(await db.getSyncCursor('old', 'bookmark'), 'first');
    expect(await db.countBookmarks(query: '中文引文'), 1);
    expect(await db.countBookmarks(query: '不应提交'), 0);
    await db.applySyncDelta('old', 'bookmark', [], ['bm0'], 'second');
    expect(await db.countBookmarks(query: '中文引文'), 0);
    expect(await db.getSyncCursor('old', 'bookmark'), 'second');
    await db.toggleBookmarkFavorite('bm1', true);
    expect(await db.countBookmarks(query: '引文1'), 1);
    await db.deleteBook('main');
    expect(await db.countBookmarks(query: '引文'), 0);
  });

  test('cursor翻页期间插入新记录不导致重复，索引匹配书籍及收藏排序', () async {
    await seed(150);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    final firstKeys = provider.notes.map((n) => '${n.source.name}:${n.id}').toSet();
    await db.insertNote({'note_id': 'newest', 'book_id': 'main', 'created_at': 10000});
    await provider.loadMore();
    expect(provider.notes.length, 200);
    expect(provider.notes.skip(100).any((n) => firstKeys.contains('${n.source.name}:${n.id}')), isFalse);
    final plan = await (await db.database).rawQuery('EXPLAIN QUERY PLAN SELECT * FROM notes WHERE book_id = ? ORDER BY created_at DESC, note_id DESC LIMIT 100', ['main']);
    expect(plan.toString(), contains('idx_notes_book_time'));
  });

  test('摘要元数据分页按书过滤不漏旧项且正文详情单独读取', () async {
    for (var i = 0; i < 65; i++) {
      await db.saveSummary(AISummary(createdAt: i, title: '摘要$i', text: '正文$i',
        references: [SummaryReference(label: 'R1', noteId: '$i', bookId: i < 5 ? 'old' : 'main',
          bookTitle: '', chapterTitle: '', source: NoteSource.note, content: '内容')]));
    }
    final first = await db.getSummaryMetadata(limit: 50);
    final next = await db.getSummaryMetadata(before: first.last['id'] as int);
    expect(first.length + next.length, 65);
    expect(first.first.containsKey('payload'), isFalse);
    expect(first.first.containsKey('text'), isFalse);
    final old = await db.getSummaryMetadata(bookId: 'old');
    expect(old.length, 5);
    expect((await db.getSummary(old.first['id'] as int)).text, '正文4');
  });

  test('移动端登录快照单次转移至同步且凭据变化使快照失效', () async {
    const credentials = Credentials(vid: '123', accessToken: 'one', refreshToken: 'refresh', deviceId: 'device');
    final config = AppConfig(credentials: credentials);
    final adapter = _ShelfAdapter();
    final login = WeReadApi.forLogin(config: config, dio: Dio()..httpClientAdapter = adapter);
    expect(await login.checkLogin(), isTrue);
    login.dispose();
    final api = await WeReadApi.init(config: config, db: db, dio: Dio()..httpClientAdapter = adapter);
    await api.fetchBookshelf();
    expect(adapter.requests, 1);
    await api.fetchBookshelf();
    expect(adapter.requests, 2);
    final secondLogin = WeReadApi.forLogin(config: config, dio: Dio()..httpClientAdapter = adapter);
    await secondLogin.checkLogin();
    config.credentials = const Credentials(vid: '123', accessToken: 'two', refreshToken: 'refresh', deviceId: 'device');
    await api.fetchBookshelf();
    expect(adapter.requests, 4);
  });

  test('v4已有正文摘要和收藏升级后可筛选分页，索引回填保留数据', () async {
    await seed(3);
    await db.saveSummary(AISummary(createdAt: 1, title: '旧摘要', text: '旧正文', references: [
      SummaryReference(label: 'R1', noteId: 'nt0', bookId: 'old', bookTitle: '历史书',
        chapterTitle: '', source: NoteSource.note, content: '原文')]));
    final connection = await db.database;
    for (final table in ['bookmarks', 'notes']) {
      for (final event in ['insert', 'update', 'delete']) {
        await connection.execute('DROP TRIGGER search_${table}_$event');
      }
      for (final suffix in ['time', 'book_time', 'fav_time']) {
        await connection.execute('DROP INDEX idx_${table}_$suffix');
      }
    }
    for (final table in ['summary_books', 'sync_cursors', 'item_trigrams']) {
      await connection.execute('DROP TABLE $table');
    }
    for (final column in ['title', 'coverage', 'created_at']) {
      await connection.execute('ALTER TABLE ai_summaries DROP COLUMN $column');
    }
    await connection.setVersion(4);
    await DatabaseService.endSession();
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    expect(await db.countBookmarks(query: '唯一历史引文'), 1);
    expect((await db.getReadingItem('bm0', 'bookmark', 'old'))!['is_fav'], 1);
    expect(await db.getSyncCursor('old', 'bookmark'), '0');
    final history = await db.getSummaryMetadata(bookId: 'old');
    expect(history.single['title'], '旧摘要');
    expect((await db.getSummary(history.single['id'] as int)).text, '旧正文');
  });

  test('流式导出保持混合来源时间顺序及章节Markdown格式', () async {
    await db.insertBookmark({'bookmark_id': 'b', 'book_id': 'book', 'book_title': '书名',
      'mark_text': '第一条', 'chapter_title': '第一章', 'created_at': 1});
    await db.insertNote({'note_id': 'n', 'book_id': 'book', 'book_title': '书名',
      'content': '第二条', 'chapter_title': '第一章', 'created_at': 2});
    await db.insertNote({'note_id': 'later', 'book_id': 'book', 'book_title': '书名',
      'content': '第三条', 'chapter_title': '第二章', 'created_at': 3});
    final text = await File(await ExportService.exportToMarkdown()).readAsString();
    expect(text.substring(text.indexOf('## 📖')), '## 📖 书名\n\n\n**第一章**\n\n- 📝 第一条\n- 💭 第二条\n\n**第二章**\n\n- 💭 第三条\n');
  });

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
    provider.setFilter(ReadingFilter.notes);
    await provider.loadNotes();
    expect(provider.notes.single.id, 'nt0');
    provider.setSearch('');
    provider.setFilter(ReadingFilter.favorites);
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
    await waitUntil(() => !provider.isLoading && provider.totalCount == 1240);
    expect(provider.totalCount, 1240);
    await db.insertNote({'note_id': 'new', 'book_id': 'main',
      'content': '新增笔记', 'created_at': 1000});
    SyncService.changes.publish(db);
    await waitUntil(() => !provider.isLoading && provider.totalCount == 1241);
    expect(provider.totalCount, 1241);
    expect(provider.notes.first.id, 'new');
  });

  testWidgets('报告订阅统一同步事件，统计包含全部历史', (tester) async {
    await tester.runAsync(() => seed(620));
    await tester.pumpWidget(const MaterialApp(home: ReportPage()));
    await pumpUntil(tester, () => find.text('1240').evaluate().isNotEmpty);
    expect(find.text('1240'), findsOneWidget);
    await tester.runAsync(() => db.insertNote({'note_id': 'new',
      'book_id': 'main', 'content': '新增笔记', 'created_at': 1000}));
    SyncService.changes.publish(db);
    await pumpUntil(tester, () => find.text('1241').evaluate().isNotEmpty);
    expect(find.text('1241'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片使用数据库翻页，搜索能命中旧内容，同步事件刷新', (tester) async {
    await tester.runAsync(() => seed(620));
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await pumpUntil(tester, () => find.text('共 620 条').evaluate().isNotEmpty);
    expect(find.text('共 620 条'), findsOneWidget);
    expect(find.text('1/7'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await pumpUntil(tester, () => find.text('2/7').evaluate().isNotEmpty);
    expect(find.text('2/7'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '唯一历史引文');
    await pumpUntil(tester, () => find.text('共 1 条').evaluate().isNotEmpty);
    expect(find.text('共 1 条'), findsOneWidget);
    expect(find.text('唯一历史引文 100%_\\'), findsWidgets);
    await tester.runAsync(() => db.insertBookmark({
      'bookmark_id': 'new', 'book_id': 'old', 'book_title': '历史书',
      'mark_text': '唯一历史引文新增', 'created_at': 999,
    }));
    SyncService.changes.publish(db);
    await pumpUntil(tester, () => find.text('共 2 条').evaluate().isNotEmpty);
    expect(find.text('共 2 条'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片图片单图和超长分页都遵守像素预算并分享全部页面', (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    var shared = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        shared = List<String>.from((call.arguments as Map)['paths'] as List);
        return 'success';
      });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
    for (final long in [false, true]) {
      shared = [];
      await tester.runAsync(() => db.insertBookmark({'bookmark_id': 'image', 'book_id': 'book',
        'book_title': '图片测试', 'mark_text': long ? List.filled(100, '超长引文内容').join('\n') : '短引文',
        'chapter_title': '', 'created_at': 1}));
      await tester.pumpWidget(const MaterialApp(home: CardsPage()));
      await pumpUntil(tester, () => find.text('导出图片').evaluate().isNotEmpty);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('导出图片'));
        await waitUntil(() => shared.isNotEmpty);
      });
      expect(shared.length, long ? greaterThan(1) : 1);
      await tester.runAsync(() async {
        for (final path in shared) {
          final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
          try {
            final frame = await codec.getNextFrame();
            try { expect(frame.image.width * frame.image.height, lessThanOrEqualTo(8000000)); }
            finally { frame.image.dispose(); }
          } finally { codec.dispose(); }
        }
      });
      await tester.pumpWidget(const SizedBox());
    }
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
