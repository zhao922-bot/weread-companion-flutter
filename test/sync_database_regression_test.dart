import 'dart:ffi';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
// sqflite's global setter requires its internal factory interface, even when
// all actual database operations are delegated to a supported FFI factory.
// ignore: implementation_imports
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;

class FaultFactory implements SqfliteDatabaseFactory {
  final DatabaseFactory delegate;
  int opens = 0;
  bool failOpen = false;
  bool failClose = false;
  CloseFailureDatabase? wrapped;
  FaultFactory(this.delegate);
  @override
  Future<String> getDatabasesPath() => delegate.getDatabasesPath();
  @override
  Future<void> deleteDatabase(String path) => delegate.deleteDatabase(path);
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    opens++;
    if (failOpen) { failOpen = false; throw StateError('open failed'); }
    final database = await delegate.openDatabase(path, options: options);
    if (failClose) return wrapped = CloseFailureDatabase(database);
    return database;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CloseFailureDatabase implements Database {
  final Database delegate;
  int closes = 0;
  CloseFailureDatabase(this.delegate);
  @override
  Future<void> close() async { closes++; throw StateError('close failed'); }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  setUpAll(() {
    sqfliteFfiInit();
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('sync-regression-');
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  final shelf = {'books': [
    {'book': {'bookId': 'b', 'title': '真实书', 'author': '作者', 'updateTime': 12}},
    null, {'book': 'bad'}, {'bookId': [], 'title': '非法'},
    {'bookId': 'bad-title', 'title': 42},
  ], 'bookProgress': [
    {'bookId': 'b', 'progress': 99}, {'bookId': 'ignored', 'progress': 'bad'},
  ]};
  final bookmarks = {'chapters': [
    {'chapterUid': 7, 'title': '第七章'}, {'chapterUid': [], 'title': 42},
  ], 'updated': [
    {'bookmarkId': 'bm', 'markText': '划线', 'chapterUid': 7, 'createTime': 13},
    null, {'bookmarkId': [], 'markText': '非法'},
    {'bookmarkId': 'bad-text', 'markText': 42},
    {'bookmarkId': 'bad-time', 'markText': '非法', 'createTime': []},
  ]};
  final notes = {'reviews': [
    {'review': {'reviewId': 'nt', 'content': '想法', 'chapterName': '第七章', 'createTime': 14}},
    null, {'review': 'bad'}, {'reviewId': [], 'content': '非法'},
    {'reviewId': 'bad-text', 'content': 42},
    {'reviewId': 'bad-time', 'content': '非法', 'createTime': []},
  ]};

  Future<WeReadApi> apiWith(Map<String, Object?> responses) => WeReadApi.init(
    config: AppConfig(cookie: 'wr_vid=123'), db: db,
    dio: Dio()..httpClientAdapter = AuthAdapter((options) => jsonResponse(responses[options.path]!)));

  test('真实嵌套响应纯解析不落库，SyncService批量落库并跳过非法字段', () async {
    final api = await apiWith({'/shelf/sync': shelf,
      '/book/bookmarklist': bookmarks, '/review/list': notes});
    final parsed = await api.fetchBookshelf();
    expect(parsed.single.progress, 99);
    expect(parsed.single.finished, 0);
    expect((await api.fetchBookmarks('b', '真实书')).single.chapterTitle, '第七章');
    expect((await api.fetchNotes('b', '真实书')).single['content'], '想法');
    expect(await db.getAllBooks(), isEmpty);
    expect(await db.getAllBookmarks(), isEmpty);
    expect(await db.getAllNotes(), isEmpty);
    final result = await SyncService.forApi(api).syncAll();
    expect(result.successCount, 1);
    expect(result.bookmarks, 1);
    expect(result.notes, 1);
    expect((await db.getAllBooks()).single['title'], '真实书');
    expect((await db.getAllBookmarks()).single['chapter_title'], '第七章');
    expect((await db.getAllNotes()).single['created_at'], 14);
  });

  for (final field in ['books', 'updated', 'reviews']) {
    test('$field非列表明确失败而非空成功', () async {
      final api = await apiWith({
        '/shelf/sync': field == 'books' ? {'books': {}} : shelf,
        '/book/bookmarklist': field == 'updated' ? {'updated': 'bad'} : bookmarks,
        '/review/list': field == 'reviews' ? {'reviews': 42} : notes,
      });
      if (field == 'books') {
        await expectLater(SyncService.forApi(api).syncAll(),
            throwsA(isA<FormatException>()));
        expect(await db.getAllBooks(), isEmpty);
      } else {
        final result = await SyncService.forApi(api).syncAll();
        expect(result.failureCount, 1);
        expect(result.failures.single.reason, contains(field));
      }
    });
    test('缺少$field明确失败而非空成功', () async {
      final api = await apiWith({'/shelf/sync': field == 'books' ? {} : shelf,
        '/book/bookmarklist': field == 'updated' ? {} : bookmarks,
        '/review/list': field == 'reviews' ? {} : notes});
      if (field == 'books') {
        await expectLater(SyncService.forApi(api).syncAll(), throwsA(isA<FormatException>()));
        expect(await db.getAllBooks(), isEmpty);
      } else {
        final result = await SyncService.forApi(api).syncAll();
        expect(result.failureCount, 1);
        expect(result.failures.single.reason, contains(field));
      }
    });
  }

  for (final isNote in [false, true]) {
    test('${isNote ? 'notes' : 'bookmarks'}批量失败回滚已有更新和新插入', () async {
      final id = isNote ? 'note_id' : 'bookmark_id';
      final content = isNote ? 'content' : 'mark_text';
      final Future<void> Function(List<Map<String, dynamic>>) insert =
        isNote ? db.insertNotesPreserveFav : db.insertBookmarksPreserveFav;
      await insert([{id: 'existing', 'book_id': 'b', content: '原文', 'created_at': 1, 'is_fav': 1}]);
      await expectLater(insert([
        {id: 'existing', 'book_id': 'b', content: '更新', 'created_at': 2},
        {id: 'new', 'book_id': 'b', content: '新增', 'created_at': 2},
        {id: 'invalid', 'book_id': 'b', 'created_at': null},
      ]), throwsA(isA<DatabaseException>()));
      final rows = isNote ? await db.getAllNotes() : await db.getAllBookmarks();
      expect(rows, hasLength(1));
      expect(rows.single[content], '原文');
      expect(rows.single['is_fav'], 1);
    });

    test('${isNote ? 'notes' : 'bookmarks'}同步与收藏并发不丢收藏，不修改输入', () async {
      final id = isNote ? 'note_id' : 'bookmark_id';
      final content = isNote ? 'content' : 'mark_text';
      final Future<void> Function(List<Map<String, dynamic>>) insert =
        isNote ? db.insertNotesPreserveFav : db.insertBookmarksPreserveFav;
      final toggle = isNote ? db.toggleFavorite : db.toggleBookmarkFavorite;
      await insert([{id: 'same', 'book_id': 'b', content: '原文', 'created_at': 1}]);
      for (final favoriteFirst in [false, true]) {
        await toggle('same', false);
        final update = Map<String, dynamic>.unmodifiable({id: 'same', 'book_id': 'b',
          content: '更新', 'created_at': 2, 'is_fav': 0});
        await Future.wait(favoriteFirst
          ? [toggle('same', true), insert([update])]
          : [insert([update]), toggle('same', true)]);
        final rows = isNote ? await db.getAllNotes() : await db.getAllBookmarks();
        expect(rows.single['is_fav'], 1);
        expect(rows.single[content], '更新');
        expect(update['is_fav'], 0);
      }
    });
  }

  test('数据库打开失败后同一会话可重试，成功后复用连接', () async {
    final factory = FaultFactory(databaseFactory)..failOpen = true;
    databaseFactory = factory;
    await expectLater(db.database, throwsStateError);
    final connection = await db.database;
    expect(await db.database, same(connection));
    expect(factory.opens, 2);
    expect(db.isActive, isTrue);
  });

  test('close失败仍清理连接和会话，重复close不再关闭旧连接', () async {
    final factory = FaultFactory(databaseFactory)..failClose = true;
    databaseFactory = factory;
    await db.database;
    final wrapper = factory.wrapped!;
    addTearDown(wrapper.delegate.close);
    await expectLater(DatabaseService.endSession(), throwsStateError);
    expect(db.isActive, isFalse);
    expect(() => DatabaseService.instance, throwsStateError);
    await expectLater(db.database, throwsStateError);
    await db.close();
    expect(wrapper.closes, 1);
    factory.failClose = false;
    await DatabaseService.selectAccount('456');
    expect(DatabaseService.instance.accountId, '456');
  });
}
