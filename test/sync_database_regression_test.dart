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
import 'package:weread_companion/models/note_item.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;

class FaultFactory implements SqfliteDatabaseFactory {
  final DatabaseFactory delegate;
  int opens = 0;
  bool failOpen = false;
  bool failClose = false;
  bool legacySqlite = false;
  String legacyVersion = '3.22.0';
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
    if (legacySqlite) return LegacyDatabase(database, legacyVersion);
    return database;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LegacyDatabase implements Database {
  final Database delegate;
  final String version;
  LegacyDatabase(this.delegate, this.version);
  @override
  bool get isOpen => delegate.isOpen;
  @override
  Future<List<Map<String, Object?>>> query(String table, {bool? distinct,
    List<String>? columns, String? where, List<Object?>? whereArgs,
    String? groupBy, String? having, String? orderBy, int? limit, int? offset}) =>
    delegate.query(table, distinct: distinct, columns: columns, where: where,
      whereArgs: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy,
      limit: limit, offset: offset);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('sqlite_version()')) return [{'version': version}];
    if (version == '3.8.10' && RegExp(r'\(\s*(source|created_at)\s*,').hasMatch(sql)) {
      throw StateError('SQLite 3.8 does not support row values');
    }
    return delegate.rawQuery(sql, arguments);
  }
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) =>
    delegate.transaction(action, exclusive: exclusive);
  @override
  Future<void> close() => delegate.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CloseFailureDatabase implements Database {
  final Database delegate;
  int closes = 0;
  CloseFailureDatabase(this.delegate);
  @override
  bool get isOpen => delegate.isOpen;
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

  test('SQLite 3.8拒绝行值表达式时三字符搜索和笔记第二页仍可用', () async {
    databaseFactory = FaultFactory(databaseFactory)..legacySqlite = true..legacyVersion = '3.8.10';
    await db.insertNotesPreserveFav(List.generate(5, (i) => {
      'note_id': '$i', 'book_id': 'b', 'content': 'abc笔记', 'created_at': 1,
    }));
    expect(await db.countReadingItems(query: 'abc'), 5);
    final first = await db.getReadingItems(query: 'abc', filter: ReadingFilter.notes, limit: 2);
    final last = first.last;
    final second = await db.getReadingItems(query: 'abc', filter: ReadingFilter.notes,
      limit: 2, after: NoteItem(id: last['id'] as String, bookId: 'b', bookTitle: '',
        content: '', chapterTitle: '', createdAt: 1, isFav: false, source: NoteSource.note));
    expect(first.map((r) => r['id']), ['4', '3']);
    expect(second.map((r) => r['id']), ['2', '1']);
  });

  test('SQLite 3.22 两来源先查后写保留收藏、重复ID及失败回滚', () async {
    databaseFactory = FaultFactory(databaseFactory)..legacySqlite = true;
    final connection = (await db.database as LegacyDatabase).delegate;
    for (final source in ['bookmark', 'note']) {
      final id = source == 'note' ? 'note_id' : 'bookmark_id';
      final table = source == 'note' ? 'notes' : 'bookmarks';
      final content = source == 'note' ? 'content' : 'mark_text';
      final insert = source == 'note' ? db.insertNotesPreserveFav : db.insertBookmarksPreserveFav;
      Map<String, dynamic> row(String text) => {id: 'same', 'book_id': 'b', content: text, 'created_at': 1};
      await insert([{...row('原文'), 'is_fav': 1}]);
      await insert([row('中间'), row('更新')]);
      await db.applySyncDelta('b', source, [row('增量')], [], '1', expectedCursor: '0');
      expect((await connection.query(table)).single[content], '增量');
      expect((await connection.query(table)).single['is_fav'], 1);
      await expectLater(db.applySyncDelta('b', source, [row('不应写入'),
        {id: 'invalid', 'book_id': 'b', 'created_at': null}], ['same'], '2', expectedCursor: '1'),
        throwsA(isA<DatabaseException>()));
      expect((await connection.query(table)).single[content], '增量');
      expect((await connection.query('sync_cursors', where: 'source = ?', whereArgs: [source])).single['synckey'], '1');
    }
  });

  test('旧响应晚提交不得复活删除记录或回退游标', () async {
    final row = {'bookmark_id': 'old', 'book_id': 'b', 'mark_text': '旧划线', 'created_at': 1};
    await db.applySyncDelta('b', 'bookmark', [row], [], '1', expectedCursor: '0');
    await db.applySyncDelta('b', 'bookmark', [], ['old'], '2', expectedCursor: '1');
    await expectLater(db.applySyncDelta('b', 'bookmark', [row], [], '1', expectedCursor: '0'), throwsStateError);
    expect(await db.getAllBookmarks(), isEmpty);
    expect(await db.getSyncCursor('b', 'bookmark'), '2');
  });
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

  test('携带synckey的坏行响应明确失败，不提交部分数据或游标，修复后可重试', () async {
    await db.applySyncDelta('b', 'bookmark', [{
      'bookmark_id': 'bm', 'book_id': 'b', 'mark_text': '原划线', 'created_at': 1,
    }], [], 'previous');
    await db.applySyncDelta('b', 'note', [{
      'note_id': 'nt', 'book_id': 'b', 'content': '原笔记', 'created_at': 1,
    }], [], 'previous');
    final responses = <String, Object?>{
      '/shelf/sync': shelf,
      '/book/bookmarklist': {...bookmarks, 'synckey': 'next'},
      '/review/list': {...notes, 'synckey': 'next'},
    };
    final api = await apiWith(responses);
    var deltas = 0;
    await expectLater(api.fetchBookmarks('b', '真实书',
      onDelta: (_, __) => deltas++), throwsA(isA<FormatException>()));
    await expectLater(api.fetchNotes('b', '真实书',
      onDelta: (_, __) => deltas++), throwsA(isA<FormatException>()));
    expect(deltas, 0);
    final service = SyncService.forApi(api);
    final failed = await service.syncAll();
    expect(failed.failureCount, 1);
    expect(failed.failures.single.errors, hasLength(2));
    expect(failed.failures.single.reason, contains('未提交数据或推进同步游标'));
    expect(await db.getSyncCursor('b', 'bookmark'), 'previous');
    expect(await db.getSyncCursor('b', 'note'), 'previous');
    expect((await db.getAllBookmarks()).single['mark_text'], '原划线');
    expect((await db.getAllNotes()).single['content'], '原笔记');
    responses['/book/bookmarklist'] = {'updated': [(bookmarks['updated'] as List).first],
      'chapters': [(bookmarks['chapters'] as List).first], 'synckey': 'next'};
    responses['/review/list'] = {'reviews': [(notes['reviews'] as List).first], 'synckey': 'next'};
    expect((await service.retryBook(failed.books.single.book)).succeeded, isTrue);
    expect(await db.getSyncCursor('b', 'bookmark'), 'next');
    expect(await db.getSyncCursor('b', 'note'), 'next');
    expect((await db.getAllBookmarks()).single['mark_text'], '划线');
    expect((await db.getAllNotes()).single['content'], '想法');
  });

  test('无效删除拒绝整批，两来源保留数据和游标，修复响应后可重试', () async {
    final responses = <String, Object?>{'/shelf/sync': {'books': [
      {'bookId': 'b', 'title': '书'}
    ]}};
    final api = await apiWith(responses);
    final service = SyncService.forApi(api);
    for (final source in ['bookmark', 'note']) {
      final isNote = source == 'note';
      final id = isNote ? 'note_id' : 'bookmark_id';
      final content = isNote ? 'content' : 'mark_text';
      await db.applySyncDelta('b', source, [
        {id: 'old', 'book_id': 'b', content: '原文', 'created_at': 1}
      ], [], 'previous');
    }
    for (final key in ['deleted', 'removed']) {
      for (final invalid in ['', '  ', null, {}, [], {'wrongId': 'old'}]) {
        responses['/book/bookmarklist'] = {'updated': [], key: ['old', invalid], 'synckey': 'next'};
        responses['/review/list'] = {'reviews': [], key: ['old', invalid], 'synckey': 'next'};
        var callbacks = 0;
        await expectLater(api.fetchBookmarks('b', '书'), throwsA(isA<FormatException>()));
        await expectLater(api.fetchNotes('b', '书'), throwsA(isA<FormatException>()));
        await expectLater(api.fetchBookmarks('b', '书', onDelta: (_, __) => callbacks++),
          throwsA(isA<FormatException>()));
        await expectLater(api.fetchNotes('b', '书', onDelta: (_, __) => callbacks++),
          throwsA(isA<FormatException>()));
        expect(callbacks, 0);
        final failed = await service.syncAll();
        expect(failed.failures.single.errors, hasLength(2));
        expect(failed.failures.single.reason, contains('请重试'));
        for (final source in ['bookmark', 'note']) {
          expect(await db.getSyncCursor('b', source), 'previous');
          await expectLater(db.applySyncDelta('b', source, [], ['old', ' '], 'next'),
            throwsA(isA<FormatException>()));
        }
        expect(await db.getAllBookmarks(), hasLength(1));
        expect(await db.getAllNotes(), hasLength(1));
      }
    }
    responses['/book/bookmarklist'] = {'updated': [], 'deleted': [{'bookmarkId': 'old'}], 'synckey': 'next'};
    responses['/review/list'] = {'reviews': [], 'removed': [{'reviewId': 'old'}], 'synckey': 'next'};
    expect((await service.syncAll()).successCount, 1);
    expect(await db.getAllBookmarks(), isEmpty);
    expect(await db.getAllNotes(), isEmpty);
    expect(await db.getSyncCursor('b', 'bookmark'), 'next');
    expect(await db.getSyncCursor('b', 'note'), 'next');
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

  test('close失败立即结束会话，但保留句柄供重试关闭', () async {
    final factory = FaultFactory(databaseFactory)..failClose = true;
    databaseFactory = factory;
    await db.database;
    final wrapper = factory.wrapped!;
    addTearDown(wrapper.delegate.close);
    await expectLater(DatabaseService.endSession(), throwsStateError);
    expect(db.isActive, isFalse);
    expect(() => DatabaseService.instance, throwsStateError);
    await expectLater(db.database, throwsStateError);
    await expectLater(db.close(), throwsStateError);
    expect(wrapper.closes, 2);
    await wrapper.delegate.close();
    await db.close();
    expect(wrapper.closes, 2);
    factory.failClose = false;
    await DatabaseService.selectAccount('456');
    expect(DatabaseService.instance.accountId, '456');
  });
}
