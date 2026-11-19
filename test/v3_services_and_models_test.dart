import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/models/bookshelf_filter.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/backup_service.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';

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

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?, Future<void>?) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options, requestStream, cancelFuture);
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory dir;
  late DatabaseService db;
  late PathProviderPlatform originalPaths;

  setUp(() async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('readamber-v3-services-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    databaseFactory = databaseFactoryFfiNoIsolate;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, (_) async => 'ok');
    await DatabaseService.selectAccount('9001');
    db = DatabaseService.instance;
    await db.database;
  });

  tearDown(() async {
    await DatabaseService.endSession();
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, null);
    await dir.delete(recursive: true);
  });

  test('BookshelfSort 与 BookshelfProvider.setSort 覆盖全部排序方式', () async {
    final a = Book(bookId: '1', title: 'B书', progress: 20, updatedAt: 100);
    final b = Book(bookId: '2', title: 'A书', progress: 80, updatedAt: 200);
    expect(BookshelfSort.recent.label, '最近更新');
    expect(BookshelfSort.progressDesc.label, '进度从高到低');
    expect(BookshelfSort.progressAsc.label, '进度从低到高');
    expect(BookshelfSort.title.label, '书名排序');
    expect(BookshelfSort.recent.compare(a, b), greaterThan(0));
    expect(BookshelfSort.progressDesc.compare(a, b), greaterThan(0));
    expect(BookshelfSort.progressAsc.compare(a, b), lessThan(0));
    expect(BookshelfSort.title.compare(a, b), greaterThan(0));

    await db.insertBooks([a.toJson(), b.toJson()]);
    final provider = BookshelfProvider();
    addTearDown(provider.dispose);
    await provider.loadBooks();
    expect(provider.books.map((e) => e.bookId), ['2', '1']);
    provider.setSort(BookshelfSort.progressAsc);
    expect(provider.books.map((e) => e.bookId), ['1', '2']);
    provider.setSort(BookshelfSort.progressAsc); // no-op branch
    provider.setSort(BookshelfSort.title);
    expect(provider.books.map((e) => e.bookId), ['2', '1']);
    provider.setSort(BookshelfSort.progressDesc);
    expect(provider.books.map((e) => e.bookId), ['2', '1']);
  });

  test('NotesProvider.setBookFilter 与 DatabaseService 新查询方法正常', () async {
    await db.insertBook({'book_id': 'b1', 'title': '第一本', 'updated_at': 10});
    await db.insertBook({'book_id': 'b2', 'title': '第二本', 'updated_at': 20});
    await db.insertBookmark({
      'bookmark_id': 'bm1',
      'book_id': 'b1',
      'book_title': '第一本',
      'mark_text': '苹果香蕉橘子',
      'chapter_title': '第一章',
      'created_at': 100,
    });
    await db.insertNote({
      'note_id': 'n2',
      'book_id': 'b2',
      'book_title': '第二本',
      'content': '葡萄西瓜哈密瓜',
      'chapter_title': '第二章',
      'created_at': 200,
    });

    final booksWithItems = await db.getBooksWithItems();
    expect(booksWithItems.map((e) => e.bookId), ['b2', 'b1']);

    final randomItems = await db.getRandomReadingItems(limit: 5);
    expect(randomItems.length, 2);

    final counts = await db.getBookItemCounts('b1', query: '苹果');
    expect(counts.total, 1);

    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    expect(provider.notes.length, 2);
    provider.setBookFilter('b1');
    provider.setBookFilter('b1'); // no-op branch
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(provider.selectedBookId, 'b1');
    expect(provider.notes.length, 1);
    expect(provider.notes.first.bookId, 'b1');
  });

  test('ExportService 支持 Obsidian YAML Frontmatter（单书与全库）', () async {
    await db.insertBook({
      'book_id': 'b1',
      'title': '读 "好书"',
      'author': '作者"甲"',
      'progress': 65,
      'updated_at': 10,
    });
    await db.insertBookmark({
      'bookmark_id': 'bm1',
      'book_id': 'b1',
      'book_title': '读 "好书"',
      'mark_text': '好句子',
      'chapter_title': '第一章',
      'created_at': 100,
    });

    final bookPath = await ExportService.exportToMarkdown(
      bookId: 'b1',
      obsidianFrontmatter: true,
    );
    final bookContent = await File(bookPath).readAsString();
    expect(bookContent, contains('---\nsource: ReadAmber'));
    expect(bookContent, contains('title: "读 \\"好书\\""'));
    expect(bookContent, contains('progress: 65%'));

    final allPath = await ExportService.exportToMarkdown(
      obsidianFrontmatter: true,
    );
    final allContent = await File(allPath).readAsString();
    expect(allContent, contains('source: ReadAmber'));
    expect(allContent, isNot(contains('progress:')));
  });

  test('BackupService 完整 JSON 备份与恢复（含异常校验）', () async {
    await db.insertBook({'book_id': 'b1', 'title': '书1', 'progress': 50, 'updated_at': 10});
    await db.insertBookmark({
      'bookmark_id': 'bm1',
      'book_id': 'b1',
      'book_title': '书1',
      'mark_text': '划线内容',
      'chapter_title': '一',
      'created_at': 100,
      'is_fav': 1,
    });
    await db.insertNote({
      'note_id': 'n1',
      'book_id': 'b1',
      'book_title': '书1',
      'content': '笔记内容',
      'chapter_title': '一',
      'created_at': 101,
      'is_fav': 1,
    });
    await db.saveSummary(AISummary(
      createdAt: 1000,
      title: '书1',
      text: '摘要 [R1]',
      references: [
        SummaryReference(
          label: 'R1',
          bookId: 'b1',
          bookTitle: '书1',
          chapterTitle: '一',
          noteId: 'bm1',
          source: NoteSource.bookmark,
          content: '划线内容',
        ),
      ],
    ));

    final backupPath = await BackupService.exportBackupFile();
    final jsonText = await File(backupPath).readAsString();
    await BackupService.exportAndShare();

    // 切换到新账号恢复
    await DatabaseService.selectAccount('9002');
    final db2 = DatabaseService.instance;
    final res = await BackupService.restoreFromJson(jsonText);
    expect(res.summary, contains('1 本书'));
    expect((await db2.getAllBooks()).length, 1);
    expect((await db2.getAllBookmarks()).first['is_fav'], 1);
    expect((await db2.getSummaries()).length, 1);

    // 恢复空/非列表字段的合法版本 JSON
    final emptyRes = await BackupService.restoreFromJson(
      jsonEncode({'version': 1, 'books': 'invalid'}),
    );
    expect(emptyRes.books, 0);

    // 格式/版本非法
    await expectLater(
      BackupService.restoreFromJson('{"version": 99}'),
      throwsFormatException,
    );
  });

  test('AIService SummaryStyle、testConnection 与 SSE 流式全分支覆盖', () async {
    for (final s in SummaryStyle.values) {
      expect(s.label, isNotEmpty);
      expect(s.instruction, isNotEmpty);
    }

    final cfg = AppConfig()
      ..apiKey = 'sk-test'
      ..baseUrl = 'https://api.example.com/v1'
      ..modelName = 'test-model';
    final sampleNotes = [
      NoteItem(
        id: '1',
        bookId: 'b1',
        bookTitle: '书',
        content: '原文',
        chapterTitle: '章',
        createdAt: 1,
        isFav: false,
        source: NoteSource.bookmark,
      ),
    ];

    // 1. 未配置时流式报错
    final unconfigured = AIService(config: AppConfig());
    await expectLater(
      unconfigured.summarizeBook('书', '', sampleNotes, onDelta: (_) {}),
      throwsA(isA<AIServiceException>()),
    );

    // 2. testConnection 成功
    final okDio = Dio()
      ..httpClientAdapter = _FakeAdapter((opts, _, __) async =>
          ResponseBody.fromString(
            jsonEncode({
              'choices': [
                {'message': {'content': 'OK'}}
              ]
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ));
    expect(await AIService(config: cfg, dio: okDio).testConnection(), 'OK');

    // 3. 正常 SSE 流式（含注释行、无 choices、空 choices、有效 delta、空 delta、[DONE]）
    final ssePayload = [
      ': comment',
      'data: {"no_choices": true}',
      'data: {"choices": []}',
      'data: {"choices": [{"delta": {"content": ""}}]}',
      'data: {"choices": [{"delta": {"content": "你好"}}]}',
      'data: {"choices": [{"delta": {"content": " [R1]"}}]}',
      'data: [DONE]',
    ].join('\n');
    final streamDio = Dio()
      ..httpClientAdapter = _FakeAdapter((opts, _, __) async =>
          ResponseBody.fromString(ssePayload, 200));
    final chunks = <String>[];
    final summary = await AIService(config: cfg, dio: streamDio).summarizeBook(
      '书',
      '作者',
      sampleNotes,
      style: SummaryStyle.keyPoints,
      onDelta: chunks.add,
    );
    expect(chunks, ['你好', ' [R1]']);
    expect(summary.text, '你好 [R1]');

    // 4. finish_reason == length 截断报错
    final truncDio = Dio()
      ..httpClientAdapter = _FakeAdapter((opts, _, __) async =>
          ResponseBody.fromString(
            'data: {"choices": [{"delta": {"content": "半截"}, "finish_reason": "length"}]}\n',
            200,
          ));
    await expectLater(
      AIService(config: cfg, dio: truncDio)
          .summarizeBook('书', '', sampleNotes, onDelta: (_) {}),
      throwsA(isA<AIServiceException>()),
    );

    // 5. 流式返回空内容报错
    final emptyDio = Dio()
      ..httpClientAdapter = _FakeAdapter((opts, _, __) async =>
          ResponseBody.fromString('data: [DONE]\n', 200));
    await expectLater(
      AIService(config: cfg, dio: emptyDio)
          .summarizeBook('书', '', sampleNotes, onDelta: (_) {}),
      throwsA(isA<AIServiceException>()),
    );

    // 6. 流式返回 null body 报错
    final nullDio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) =>
            handler.resolve(Response<ResponseBody?>(requestOptions: options, data: null)),
      ));
    await expectLater(
      AIService(config: cfg, dio: nullDio)
          .summarizeBook('书', '', sampleNotes, onDelta: (_) {}),
      throwsA(isA<AIServiceException>()),
    );

    // 7. 流式中途取消（同一块内第二行检测到已取消）
    final cancelToken = CancelToken();
    final cancelStreamDio = Dio()
      ..httpClientAdapter = _FakeAdapter((opts, _, __) async =>
          ResponseBody.fromString(
            'data: {"choices": [{"delta": {"content": "A"}}]}\n'
            'data: {"choices": [{"delta": {"content": "B"}}]}\n',
            200,
          ));
    await expectLater(
      AIService(config: cfg, dio: cancelStreamDio).summarizeBook(
        '书',
        '',
        sampleNotes,
        cancelToken: cancelToken,
        onDelta: (_) => cancelToken.cancel('stop'),
      ),
      throwsA(isA<AICancelledException>()),
    );

    // 8. 流式 HTTP 500 错误 & 无状态码网络错误
    final http500Dio = Dio()
      ..httpClientAdapter = _FakeAdapter((opts, _, __) async =>
          ResponseBody.fromString('err', 500));
    await expectLater(
      AIService(config: cfg, dio: http500Dio)
          .summarizeBook('书', '', sampleNotes, onDelta: (_) {}),
      throwsA(isA<AIServiceException>()
          .having((e) => e.message, 'msg', contains('HTTP 500'))),
    );
    final cancelDioErr = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        )),
      ));
    await expectLater(
      AIService(config: cfg, dio: cancelDioErr)
          .summarizeBook('书', '', sampleNotes, onDelta: (_) {}),
      throwsA(isA<AICancelledException>()),
    );
  });
}
