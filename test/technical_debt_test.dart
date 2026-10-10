import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/models/bookshelf_filter.dart';
import 'package:weread_companion/models/note_item.dart';
import 'package:weread_companion/models/reading_constants.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/pages/ai_summary_page.dart';
import 'package:weread_companion/providers/notes_provider.dart' show NotesProvider;
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-debt-test-');
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });

  NoteItem item(int i) => NoteItem(id: 'n$i', bookId: 'b${i % 2}',
    bookTitle: '书${i % 2}', content: '原文$i', chapterTitle: '章节$i',
    createdAt: i, isFav: false, source: NoteSource.note);

  test('摘要传递结构化来源，覆盖范围与实际30条一致，历史重开和账号隔离', () async {
    final dio = Dio();
    late String prompt;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      prompt = options.data['messages'].last['content'];
      handler.resolve(Response(requestOptions: options, data: {
        'choices': [{'message': {'content': '观点 [R1]；另一个观点 [R30]'}}],
      }));
    }));
    final summary = await AIService(config: AppConfig(apiKey: 'test'), dio: dio)
        .summarizeBook('合集', '', List.generate(35, item));
    expect(summary.coverage, contains('2 本书 30 条笔记'));
    expect(summary.references.first.noteId, 'n34');
    expect(summary.references.last.noteId, 'n5');
    expect(prompt, contains('"note_id":"n34"'));
    expect(prompt, contains('"book_title":"书0"'));
    expect(prompt, contains('"chapter_title":"章节34"'));
    expect(prompt, isNot(contains('"note_id":"n4"')));
    expect(jsonEncode((await db.getSummaries()).single.toJson()),
        jsonEncode(summary.toJson()));
    await DatabaseService.selectAccount('456');
    expect(await DatabaseService.instance.getSummaries(), isEmpty);
    await DatabaseService.selectAccount('123');
    expect((await DatabaseService.instance.getSummaries(bookId: 'b0')).length, 1);
    expect(await DatabaseService.instance.getSummaries(bookId: 'missing'), isEmpty);
  });

  testWidgets('历史摘要引用跳转到原笔记，来源类型相同ID不混淆，全文显示', (tester) async {
    await tester.runAsync(() => db.insertBookmarks([{'bookmark_id': 'same', 'book_id': 'b0',
      'mark_text': '不应跳到这条划线', 'created_at': 1}]));
    final content = List.filled(40, '目标原笔记全文').join();
    await tester.runAsync(() => db.insertNote({'note_id': 'same', 'book_id': 'b0',
      'book_title': '原书', 'chapter_title': '原章节', 'content': content, 'created_at': 1}));
    final summary = AISummary(createdAt: 1, title: '原书', text: '观点 [R1]',
      references: [SummaryReference(label: 'R1', noteId: 'same', bookId: 'b0',
        bookTitle: '原书', chapterTitle: '原章节', source: NoteSource.note, content: content)]);
    await tester.runAsync(() => db.saveSummary(summary));
    await tester.pumpWidget(const MaterialApp(home: AISummaryHistoryPage()));
    await pumpUntil(tester, () => find.text('原书').evaluate().isNotEmpty);
    await tester.tap(find.text('原书'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('summary-coverage')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '[R1]'));
    await tester.pump();
    await pumpUntil(tester, () => find.text('笔记 ID：same').evaluate().isNotEmpty);
    expect(find.text('原笔记'), findsOneWidget);
    expect(find.text('笔记 ID：same'), findsOneWidget);
    expect(find.text(content), findsOneWidget);
    expect(find.text('不应跳到这条划线'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final status in [401, 429, 500]) {
    test('AI HTTP $status 保留失败原因且不保存历史', () async {
      final dio = Dio();
      late DioException cause;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        cause = DioException(requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: status),
          message: '服务端拒绝请求');
        handler.reject(cause);
      }));
      final ai = AIService(config: AppConfig(apiKey: 'test'), dio: dio);
      await expectLater(ai.summarizeBook('测试', '', [item(1)]),
        throwsA(isA<AIServiceException>()
          .having((e) => e.message, 'HTTP状态', contains('$status'))
          .having((e) => identical(e.cause, cause), '原始异常', isTrue)));
      expect(await db.getSummaries(), isEmpty);
    });
  }

  test('AI超时保留原因，阅读分析和金句解读均不吞错', () async {
    final dio = Dio();
    final causes = <DioException>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      final cause = DioException(requestOptions: options,
        type: DioExceptionType.receiveTimeout, message: '读取超时');
      causes.add(cause);
      handler.reject(cause);
    }));
    final ai = AIService(config: AppConfig(apiKey: 'test'), dio: dio);
    for (final call in <Future<String> Function()>[
      () => ai.analyzeReading(['测试'], 1),
      () => ai.interpretQuote('金句', '测试'),
    ]) {
      await expectLater(call(), throwsA(isA<AIServiceException>()
        .having((e) => e.cause, '超时原因', isA<DioException>()
          .having((e) => e.type, '类型', DioExceptionType.receiveTimeout))));
    }
    expect(causes, hasLength(2));
  });

  for (final data in <Object?>[
    null, {}, {'choices': []}, {'choices': [{}]},
    {'choices': [{'message': {'content': null}}]},
    {'choices': [{'message': {'content': '  \n'}}]},
  ]) {
    test('AI响应无效 $data 明确抛错且不保存历史', () async {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) =>
        handler.resolve(Response(requestOptions: options, data: data))));
      final ai = AIService(config: AppConfig(apiKey: 'test'), dio: dio);
      await expectLater(ai.summarizeBook('测试', '', [item(1)]),
        throwsA(isA<AIServiceException>()
          .having((e) => e.cause, '响应原因', isA<FormatException>())));
      expect(await db.getSummaries(), isEmpty);
    });
  }

  test('AI未配置或没有笔记明确报错，不发送请求', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests++;
      handler.reject(DioException(requestOptions: options));
    }));
    await expectLater(AIService(config: AppConfig(), dio: dio)
        .summarizeBook('测试', '', [item(1)]), throwsA(isA<AIServiceException>()
          .having((e) => e.message, '配置提示', contains('配置'))));
    await expectLater(AIService(config: AppConfig(apiKey: 'test'), dio: dio)
        .summarizeBook('测试', '', []), throwsA(isA<AIServiceException>()
          .having((e) => e.message, '笔记提示', contains('没有'))));
    expect(requests, 0);
    expect(await db.getSummaries(), isEmpty);
  });

  test('AI全空白笔记抛错，不发请求也不保存', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests++;
      handler.reject(DioException(requestOptions: options));
    }));
    final blank = NoteItem(id: 'blank', bookId: 'b', bookTitle: '书',
      content: ' \n\t ', chapterTitle: '', createdAt: 1,
      isFav: false, source: NoteSource.note);
    await expectLater(AIService(config: AppConfig(apiKey: 'test'), dio: dio)
      .summarizeBook('书', '', [blank]), throwsA(isA<AIServiceException>()
        .having((e) => e.message, '空内容提示', contains('没有可用于'))));
    expect(requests, 0);
    expect(await db.getSummaries(), isEmpty);
  });

  test('AI取消与失败区分且不保存历史', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      AIService.cancelAll();
      handler.reject(options.cancelToken!.cancelError!);
    }));
    final ai = AIService(config: AppConfig(apiKey: 'test'), dio: dio);
    await expectLater(ai.summarizeBook('测试', '', [item(1)]),
      throwsA(isA<AICancelledException>()
        .having((e) => e.cause, '取消原因', isA<DioException>())));
    expect(await db.getSummaries(), isEmpty);
  });

  test('AI响应期间账号结束抛取消异常，禁止保存到新账号', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      await DatabaseService.selectAccount('456');
      handler.resolve(Response(requestOptions: options, data: {
        'choices': [{'message': {'content': '旧账号摘要 [R1]'}}],
      }));
    }));
    await expectLater(AIService(config: AppConfig(apiKey: 'test'), dio: dio)
        .summarizeBook('测试', '', [item(1)]), throwsA(isA<AICancelledException>()));
    expect(await DatabaseService.instance.getSummaries(), isEmpty);
  });

  test('旧版数据库升级新增摘要历史并保留已有数据', () async {
    final legacy = await openDatabase('${directory.path}/weread_companion_account_123.db',
      version: 3, onCreate: (database, _) async {
        await database.execute('CREATE TABLE books (book_id TEXT PRIMARY KEY, title TEXT)');
        await database.insert('books', {'book_id': 'old', 'title': '已有书籍'});
      });
    await legacy.close();
    expect((await db.getBook('old'))!['title'], '已有书籍');
    final summary = AISummary(createdAt: 1, title: '历史', text: '观点 [R1]',
      references: [SummaryReference.fromNote(item(1), 0)]);
    await db.saveSummary(summary);
    expect((await db.getSummaries()).single.text, '观点 [R1]');
  });

  testWidgets('详情长笔记展开收起、复制全文、收藏持久化并广播刷新', (tester) async {
    final content = List.filled(10, '长笔记全文\n').join();
    await tester.runAsync(() => db.insertNote({'note_id': 'long', 'book_id': 'b0',
      'book_title': '测试书', 'content': content, 'created_at': 1}));
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(home: BookDetailPage(
      book: Book(bookId: 'b0', title: '测试书'))));
    await pumpUntil(tester, () => find.text(content).evaluate().isNotEmpty);
    final expand = find.byKey(const ValueKey('expand-note:long'));
    await tester.ensureVisible(expand);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(content)).maxLines, 3);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(content)).maxLines, isNull);
    await tester.ensureVisible(expand);
    await tester.pumpAndSettle();
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(content)).maxLines, 3);
    final copy = find.byKey(const ValueKey('copy-note:long'));
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, content);
    final favorite = find.byKey(const ValueKey('favorite-note:long'));
    await tester.ensureVisible(favorite);
    await tester.pumpAndSettle();
    await tester.tap(favorite);
    await tester.pump();
    await pumpUntil(tester, () => provider.notes.single.isFav &&
      find.descendant(of: favorite, matching: find.byIcon(Icons.star_rounded)).evaluate().isNotEmpty);
    expect(provider.notes.single.isFav, isTrue);
    expect(find.descendant(of: favorite, matching: find.byIcon(Icons.star_rounded)), findsOneWidget);
    await tester.runAsync(() => db.insertNotePreserveFav({'note_id': 'long',
      'book_id': 'b0', 'content': '同步更新内容', 'created_at': 2}));
    SyncService.changes.publish(db);
    await pumpUntil(tester, () => find.text('同步更新内容').evaluate().isNotEmpty);
    expect(find.text('同步更新内容'), findsOneWidget);
    expect(provider.notes.single.isFav, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情异步加载过程中退出不会在dispose后更新状态', (tester) async {
    await tester.runAsync(() => db.database);
    await tester.pumpWidget(MaterialApp(home: BookDetailPage(
      book: Book(bookId: 'b0', title: '测试书'))));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async { await db.getNotesByBook('b0'); });
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  Future<void> seedProgress() => db.insertBooks([for (final p in [0, 4, 5, 84, 85, 99, 100])
    {'book_id': 'b$p', 'title': '进度$p', 'progress': p,
      'finished': 1, 'updated_at': p}]); // 模拟旧缓存全部带 finished=1

  test('读完边界、旧finished缓存、书架筛选与数据库统计口径一致', () async {
    await seedProgress();
    final shelf = BookshelfProvider();
    addTearDown(shelf.dispose);
    await shelf.loadBooks();
    expect(shelf.readCount, 1);
    expect(shelf.readingCount, 4);
    expect(shelf.unreadCount, 2);
    shelf.setFilter(BookshelfFilter.finished);
    expect(shelf.books.single.progress, 100);
    shelf.setFilter(BookshelfFilter.reading);
    expect(shelf.books.map((b) => b.progress).toSet(), {5, 84, 85, 99});
    shelf.setFilter(BookshelfFilter.unread);
    expect(shelf.books.map((b) => b.progress).toSet(), {0, 4});
    final stats = await db.getReadingStats();
    expect(stats['finishedBooks'], shelf.readCount);
    expect(stats['readingBooks'], shelf.readingCount);
    expect(Book(bookId: 'b99', title: '', progress: 99, finished: 1).readingStatus, '接近读完');
    expect(Book(bookId: 'b85', title: '', progress: 85).readingStatus, '接近读完');
    expect(Book(bookId: 'b100', title: '', progress: 100).toJson()['finished'], 1);
    expect(readingStartedProgress, 5);
    expect(nearlyFinishedProgress, 85);
    expect(finishedProgress, 100);
    expect(ReadingFilter.values.map((f) => f.label), ['全部划线', '全部笔记', '收藏']);
    shelf.setFilter(BookshelfFilter.all);
    shelf.setSearch('进度99');
    expect(shelf.books.single.progress, 99);
    shelf.setFilter(BookshelfFilter.finished);
    expect(shelf.books, isEmpty);
    expect(shelf.totalCount, 7);
    shelf.setSearch('');
    expect(shelf.books.single.progress, 100);
  });

  testWidgets('书架99%标注接近读完，读完筛选与报告统计一致', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(seedProgress);
    final shelf = BookshelfProvider();
    final config = AppConfigProvider(config: AppConfig());
    addTearDown(shelf.dispose);
    addTearDown(config.dispose);
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider.value(value: shelf),
      ChangeNotifierProvider.value(value: config),
    ], child: const MaterialApp(home: BookshelfPage())));
    await pumpUntil(tester, () => find.text('99% · 接近读完').evaluate().isNotEmpty);
    expect(find.text('99% · 接近读完'), findsOneWidget);
    expect(find.text('100% · 已读完'), findsOneWidget);
    await tester.tap(find.text('读完'));
    await tester.pumpAndSettle();
    expect(shelf.filter, BookshelfFilter.finished);
    expect(find.text('100% · 已读完'), findsOneWidget);
    expect(find.text('进度99'), findsNothing);
    await tester.enterText(find.byType(TextField), '进度99');
    await tester.pumpAndSettle();
    expect(shelf.searchQuery, '进度99');
    expect(find.text('没有匹配的书籍'), findsOneWidget);
    expect(find.text('暂无书籍，请先登录同步'), findsNothing);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(shelf.searchQuery, isEmpty);
    expect(find.text('100% · 已读完'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: ReportPage()));
    await pumpUntil(tester, () => find.byType(PieChart).evaluate().isNotEmpty);
    Finder stat(String label) => find.ancestor(of: find.text(label), matching: find.byType(Card));
    expect(find.descendant(of: stat('已读完'), matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: stat('在读中'), matching: find.text('4')), findsOneWidget);
    expect(tester.widget<PieChart>(find.byType(PieChart)).data.sections
        .map((s) => s.value).toList(), [1.0, 4.0, 2.0]);
    await tester.pumpWidget(const SizedBox());
  });
}
