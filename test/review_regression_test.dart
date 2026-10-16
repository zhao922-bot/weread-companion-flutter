import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';

import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;
import 'sync_database_regression_test.dart' show FaultFactory, LegacyDatabase;
import 'support/wait_until.dart';

class _ReadProbe {
  int reads = 0;
  int largestArgumentCount = 0;
  Future<void> Function(String sql)? afterRead;

  Future<void> record(String sql, List<Object?>? arguments) async {
    reads++;
    if ((arguments?.length ?? 0) > largestArgumentCount) {
      largestArgumentCount = arguments!.length;
    }
    await afterRead?.call(sql);
  }
}

class _ProbeFactory extends FaultFactory {
  final _ReadProbe probe;
  _ProbeFactory(super.delegate, this.probe);

  @override
  Future<Database> openDatabase(String path,
          {OpenDatabaseOptions? options}) async =>
      _ProbeDatabase(await super.openDatabase(path, options: options), probe);
}

class _ProbeDatabase extends LegacyDatabase {
  final _ReadProbe probe;
  _ProbeDatabase(Database database, this.probe) : super(database, '3.40.0');

  @override
  Batch batch() => delegate.batch();

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    final rows = await super.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    await probe.record(table, whereArgs);
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    final rows = await super.rawQuery(sql, arguments);
    await probe.record(sql, arguments);
    return rows;
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      delegate.transaction((txn) => action(_ProbeTransaction(txn, probe)),
          exclusive: exclusive);
}

class _ProbeTransaction implements Transaction {
  final Transaction delegate;
  final _ReadProbe probe;
  _ProbeTransaction(this.delegate, this.probe);

  @override
  Batch batch() => delegate.batch();

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    final rows = await delegate.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    await probe.record(table, whereArgs);
    return rows;
  }

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      delegate.delete(table, where: where, whereArgs: whereArgs);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late _ReadProbe probe;

  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-review-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = _ReadProbe();
    databaseFactory = _ProbeFactory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  test('迟到的外部收藏查询不得覆盖后续收藏操作', () async {
    await db.insertNote(
        {'note_id': 'n', 'book_id': 'b', 'content': '笔记', 'created_at': 1});
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    final readStarted = Completer<void>();
    final releaseRead = Completer<void>();
    probe.afterRead = (sql) async {
      if (sql.contains('WHERE id = ? AND source = ? AND book_id = ?')) {
        probe.afterRead = null;
        readStarted.complete();
        await releaseRead.future;
      }
    };
    await db.toggleFavorite('n', true);
    SyncService.changes.publish(db,
        favoritesOnly: true,
        bookIds: {'b'},
        itemIds: {'note:n'},
        sources: {'note'});
    await readStarted.future;
    try {
      await provider.toggleFavorite(provider.notes.single);
      await provider.toggleFavorite(provider.notes.single);
      expect(provider.notes.single.isFav, isFalse);
    } finally {
      final refreshed = Completer<void>();
      void listener() {
        if (!refreshed.isCompleted) refreshed.complete();
      }

      provider.addListener(listener);
      releaseRead.complete();
      await refreshed.future.timeout(const Duration(seconds: 5));
      provider.removeListener(listener);
    }
    expect(provider.error, isNull);
    expect(provider.notes.single.isFav, isFalse);
    expect(provider.favCount, 0);
    expect((await db.getReadingItem('n', 'note', 'b'))!['is_fav'], 0);
  });

  test('书架事件触发的旧统计查询不得覆盖新收藏计数', () async {
    await db.insertNote(
        {'note_id': 'n', 'book_id': 'b', 'content': '笔记', 'created_at': 1});
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    final readStarted = Completer<void>();
    final releaseRead = Completer<void>();
    probe.afterRead = (sql) async {
      if (sql.contains('SELECT COUNT(*) FROM notes WHERE is_fav = 1')) {
        probe.afterRead = null;
        readStarted.complete();
        await releaseRead.future;
      }
    };
    SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf);
    await readStarted.future;
    try {
      await provider.toggleFavorite(provider.notes.single);
      expect(provider.favCount, 1);
    } finally {
      releaseRead.complete();
      // Drain the released query's microtasks before observing the result.
      await Future<void>.delayed(Duration.zero);
    }
    expect(provider.favCount, 1);
    expect(provider.notes.single.isFav, isTrue);
  });

  test('异常章节列表拒绝整批增量并保留原数据与游标，修复后可重试', () async {
    await db.applySyncDelta(
        'b',
        'bookmark',
        [
          {
            'bookmark_id': 'bm',
            'book_id': 'b',
            'mark_text': '原文',
            'chapter_title': '原章节',
            'created_at': 1,
          }
        ],
        [],
        'previous');
    Object chapters = {'chapterUid': 7, 'title': '新章节'};
    final dio = Dio()
      ..httpClientAdapter =
          AuthAdapter((options) => jsonResponse(switch (options.path) {
                '/shelf/sync' => {
                    'books': [
                      {'bookId': 'b', 'title': '书'}
                    ]
                  },
                '/book/bookmarklist' => {
                    'updated': [
                      {
                        'bookmarkId': 'bm',
                        'markText': '新文',
                        'chapterUid': 7,
                        'createTime': 2
                      }
                    ],
                    'chapters': chapters,
                    'synckey': 'next'
                  },
                _ => {'reviews': []},
              }));
    final api = await WeReadApi.init(
        config: AppConfig(cookie: 'wr_vid=123; wr_skey=test'),
        db: db,
        dio: dio);
    final service = SyncService.forApi(api);
    for (final invalid in <Object>[{}, 'bad', 42]) {
      chapters = invalid;
      final result = await service.syncAll();
      expect(result.failureCount, 1);
      expect(result.failures.single.reason, contains('chapters'));
      expect(await db.getSyncCursor('b', 'bookmark'), 'previous');
      final saved = (await db.getAllBookmarks()).single;
      expect(saved['mark_text'], '原文');
      expect(saved['chapter_title'], '原章节');
    }
    chapters = [
      {'chapterUid': 7, 'title': '新章节'}
    ];
    expect((await service.syncAll()).failureCount, 0);
    expect(await db.getSyncCursor('b', 'bookmark'), 'next');
    expect((await db.getAllBookmarks()).single['chapter_title'], '新章节');
  });

  testWidgets('详情页迟到的收藏刷新不得反转用户的新操作', (tester) async {
    await tester.runAsync(() => db.insertNote({
          'note_id': 'n',
          'book_id': 'b',
          'content': '笔记',
          'created_at': 1,
        }));
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(
      book: Book(bookId: 'b', title: '书'),
    )));
    final card = find.byKey(const ValueKey('note:n'));
    await pumpUntil(tester, () => card.evaluate().isNotEmpty);
    await tester.ensureVisible(card);
    final readStarted = Completer<void>();
    final releaseRead = Completer<void>();
    probe.afterRead = (sql) async {
      if (sql.contains('WHERE id = ? AND source = ? AND book_id = ?')) {
        probe.afterRead = null;
        readStarted.complete();
        await releaseRead.future;
      }
    };
    await tester.runAsync(() async {
      await db.toggleFavorite('n', true);
      SyncService.changes.publish(db,
          favoritesOnly: true,
          bookIds: {'b'},
          itemIds: {'note:n'},
          sources: {'note'});
    });
    await pumpUntil(tester, () => readStarted.isCompleted);
    final button =
        find.descendant(of: card, matching: find.byType(IconButton)).last;
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    try {
      await tester.tap(button);
      await tester.pump();
      await pumpUntil(
          tester, () => tester.widget<IconButton>(button).onPressed != null);
      await tester.tap(button);
      await tester.pump();
      await pumpUntil(
          tester, () => tester.widget<IconButton>(button).onPressed != null);
    } finally {
      var counted = false;
      probe.afterRead = (sql) async {
        if (sql.contains('SELECT COUNT(*)') && sql.contains('is_fav = 1')) {
          counted = true;
        }
      };
      releaseRead.complete();
      await pumpUntil(tester, () => counted);
      await tester.pumpAndSettle();
    }
    expect(
        find.descendant(
            of: card, matching: find.byIcon(Icons.star_border_rounded)),
        findsOneWidget);
    expect(find.text('0条'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('批量索引读取遵循TEXT主键规则，兼容数字ID与重复的字符串ID', () async {
    for (final source in ['note', 'bookmark']) {
      final id = source == 'note' ? 'note_id' : 'bookmark_id';
      final content = source == 'note' ? 'content' : 'mark_text';
      await db.applySyncDelta(
          'b',
          source,
          [
            {id: 123, 'book_id': 'b', content: '更新正文', 'created_at': 1},
            {
              id: '123',
              'book_id': 'b',
              'chapter_title': '最终章节',
              'created_at': 1
            },
          ],
          [],
          'next');
      final saved = (await db.getReadingItem('123', source, 'b'))!;
      expect(saved['content'], '更新正文');
      expect(saved['chapter_title'], '最终章节');
      expect(await db.getSyncCursor('b', source), 'next');
    }
    expect(await db.countReadingItems(query: '最终章节'), 2);
  });

  test('大批量索引更新限制查询次数及SQL参数，同时保留收藏和部分字段', () async {
    await db.insertNotes(List.generate(
        1205,
        (i) => {
              'note_id': '$i',
              'book_id': 'b',
              'content': '初始笔记$i',
              'book_title': '测试书籍',
              'chapter_title': '原章节',
              'created_at': i,
              'is_fav': i == 5 ? 1 : 0,
            }));
    // Warm up the per-connection SQLite capability check.
    await db.insertNotesPreserveFav([]);
    probe.reads = 0;
    probe.largestArgumentCount = 0;
    await db.insertNotesPreserveFav([
      ...List.generate(
          1205,
          (i) => {
                'note_id': '$i',
                'book_id': 'b',
                'content': '批量更新$i',
                'created_at': i
              }),
      {
        'note_id': '5',
        'book_id': 'b',
        'chapter_title': '最终章节',
        'created_at': 5
      },
    ]);
    final readCount = probe.reads;
    debugPrint('1,205 条笔记索引更新读取查询次数：$readCount');
    expect(probe.largestArgumentCount, lessThanOrEqualTo(999));
    expect(readCount, lessThan(20), reason: '读操作应按批次增长，不能每条执行两次查询');
    final saved = (await db.getReadingItem('5', 'note', 'b'))!;
    expect(saved['is_fav'], 1);
    expect(saved['book_title'], '测试书籍');
    expect(saved['chapter_title'], '最终章节');
    expect(saved['content'], '批量更新5');
    expect(await db.countReadingItems(query: '批量更新'), 1205);
    expect(await db.countReadingItems(query: '最终章节'), 1);
    expect(await db.countReadingItems(query: '初始笔记'), 0);
  });
}
