import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;
import 'sync_cancellation_windows_test.dart' show shelfService;
import 'support/observed_database.dart';
import 'support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  late WeReadApi api;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  final book = Book(bookId: 'b', title: '书');
  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-db-cancel-');
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
    requests = [];
    respond = (r) => jsonResponse(switch (r.path) {
          '/shelf/sync' => {
              'books': [
                {'bookId': 'b', 'title': '书'}
              ]
            },
          '/book/bookmarklist' => {
              'updated': [
                {'bookmarkId': 'keep', 'markText': '新正文'}
              ],
              'deleted': ['remove'],
              'synckey': 'next'
            },
          _ => {
              'reviews': [
                {'reviewId': 'keep', 'content': '新正文'}
              ],
              'deleted': ['remove'],
              'synckey': 'next'
            },
        });
    api = await WeReadApi.init(
        config: AppConfig(cookie: 'wr_vid=123; wr_skey=test'),
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((r) {
            requests.add(r);
            return respond(r);
          }));
  });
  tearDown(() async {
    probe.beforeCommit = null;
    probe.afterCommit = null;
    probe.afterRead = null;
    probe.onTransactionStart = null;
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  BookSyncResult previous(String source) => BookSyncResult(book, 0, 0, ['失败'],
      bookmarksSucceeded: source != 'bookmark',
      notesSucceeded: source != 'note');
  Future<void> seed(String source) => db.applySyncDelta(
      'b',
      source,
      [
        for (final id in ['keep', 'remove'])
          {
            source == 'note' ? 'note_id' : 'bookmark_id': id,
            'book_id': 'b',
            'book_title': '书',
            source == 'note' ? 'content' : 'mark_text': '旧正文',
            'created_at': 1,
            'is_fav': 1,
          }
      ],
      [],
      'previous');

  for (final source in ['bookmark', 'note']) {
    test('$source 索引快照冲突回滚后取消，不重新生成索引或重开事务', () async {
      await seed(source);
      final table = source == 'note' ? 'notes' : 'bookmarks';
      final id = source == 'note' ? 'note_id' : 'bookmark_id';
      final content = source == 'note' ? 'content' : 'mark_text';
      var cancelled = false;
      var indexReads = 0;
      Future<void> observe(String sql) async {
        if (sql != table) return;
        indexReads++;
        if (indexReads == 1) {
          probe.afterRead = null;
          // Change retained metadata after the first snapshot was read.
          await db.applySyncDelta(
              'b',
              source,
              [
                {
                  id: 'keep',
                  'book_id': 'b',
                  'book_title': '并发书名',
                  'created_at': 1
                }
              ],
              [],
              null);
          probe.afterRead = observe;
        } else {
          cancelled = true;
        }
      }

      probe.afterRead = observe;
      await expectLater(
          db.applySyncDelta(
              'b',
              source,
              [
                {id: 'keep', 'book_id': 'b', content: '应回滚', 'created_at': 1}
              ],
              ['remove'],
              'next', checkCancelled: () {
            if (cancelled) throw const SyncCancelledException();
          }),
          throwsA(isA<SyncCancelledException>()));
      probe.afterRead = null;
      expect(indexReads, 2);
      expect(await db.getSyncCursor('b', source), 'previous');
      final saved = (await db.getReadingItem('keep', source, 'b'))!;
      expect(saved['content'], '旧正文');
      expect(saved['book_title'], '并发书名');
      expect(await db.countReadingItems(query: '并发书名'), 1);
      expect(await db.countReadingItems(query: '应回滚'), 0);
      expect(await db.getReadingItem('remove', source, 'b'), isNotNull);
    });

    test('$source 索引准备中取消，不再写入或推进游标', () async {
      await seed(source);
      final read = Completer<void>();
      final release = Completer<void>();
      final table = source == 'note' ? 'notes' : 'bookmarks';
      probe.afterRead = (sql) async {
        if (sql == table) {
          probe.afterRead = null;
          read.complete();
          await release.future;
        }
      };
      final service = SyncService.forApi(api);
      final task = service.retryBook(book, previous: previous(source));
      await read.future;
      service.cancel();
      release.complete();
      final result = await task;
      expect(
          source == 'note' ? result.notesSucceeded : result.bookmarksSucceeded,
          isFalse);
      expect(await db.getSyncCursor('b', source), 'previous');
      expect(await db.countReadingItems(query: '旧正文'), 2);
      expect(await db.countReadingItems(query: '新正文'), 0);
      expect((await db.getReadingItem('keep', source, 'b'))!['is_fav'], 1);
      expect(
          (await SyncService.forApi(api)
                  .retryBook(book, previous: previous(source)))
              .succeeded,
          isTrue);
    });

    for (final failCommit in [false, true]) {
      test('$source 事务已写入但尚未提交时取消，${failCommit ? '异常整体回滚' : '成功整体提交'}且队列等待提交结束',
          () async {
        await seed(source);
        final written = Completer<void>();
        final release = Completer<void>();
        probe.beforeCommit = () async {
          probe.beforeCommit = null;
          written.complete();
          await release.future;
          if (failCommit) throw StateError('commit failed');
        };
        var changes = 0;
        void changed() => changes++;
        SyncService.changes.addListener(changed);
        addTearDown(() => SyncService.changes.removeListener(changed));
        final service = SyncService.forApi(api);
        var finished = false;
        final task =
            service.retryBook(book, previous: previous(source)).then((value) {
          finished = true;
          return value;
        });
        await written.future;
        service.cancel();
        var successorStarted = false;
        final next = shelfService(() async {
          successorStarted = true;
          return [];
        }, account: db.accountId)
            .syncAll();
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        expect(successorStarted, isFalse);
        release.complete();
        final result = await task;
        await next;
        expect(result.succeeded, isFalse);
        expect(
            source == 'note'
                ? result.notesSucceeded
                : result.bookmarksSucceeded,
            !failCommit);
        expect(result.notes + result.bookmarks, failCommit ? 0 : 1);
        expect(await db.getSyncCursor('b', source),
            failCommit ? 'previous' : 'next');
        expect(await db.countReadingItems(query: '旧正文'), failCommit ? 2 : 0);
        expect(await db.countReadingItems(query: '新正文'), failCommit ? 0 : 1);
        expect((await db.getReadingItem('keep', source, 'b'))!['is_fav'], 1);
        expect(changes, failCommit ? 0 : 1);
        if (failCommit) {
          expect(result.reason, contains('commit failed'));
          expect(
              (await SyncService.forApi(api).retryBook(book, previous: result))
                  .succeeded,
              isTrue);
        }
      });
    }
  }

  for (final failCommit in [false, true]) {
    test('书架事务中取消后${failCommit ? '失败保留原数据' : '成功保留书架但不启动逐书请求'}', () async {
      await db.insertBooks([Book(bookId: 'b', title: '原书名').toJson()]);
      final writing = Completer<void>();
      final release = Completer<void>();
      probe.beforeCommit = () async {
        probe.beforeCommit = null;
        writing.complete();
        await release.future;
        if (failCommit) throw StateError('shelf commit failed');
      };
      final service = SyncService.forApi(api);
      final task = service.syncAll();
      final check =
          failCommit ? expectLater(task, throwsA(isA<StateError>())) : null;
      await writing.future;
      service.cancel();
      release.complete();
      if (check != null) {
        await check;
      } else {
        final result = await task;
        expect(result.cancelled, isTrue);
        expect(result.totalBooks, 1);
        expect(result.books, isEmpty);
      }
      expect((await db.getBook('b'))!['title'], failCommit ? '原书名' : '书');
      expect(requests.map((r) => r.path), ['/shelf/sync']);
      expect((await SyncService.forApi(api).syncAll()).cancelled, isFalse);
    });
  }

  test('增量提交期间 API 会话结束，保留本地原子提交但不再发布旧通知', () async {
    final writing = Completer<void>();
    final release = Completer<void>();
    probe.beforeCommit = () async {
      probe.beforeCommit = null;
      writing.complete();
      await release.future;
    };
    var changes = 0;
    void changed() => changes++;
    SyncService.changes.addListener(changed);
    addTearDown(() => SyncService.changes.removeListener(changed));
    final task =
        SyncService.forApi(api).retryBook(book, previous: previous('note'));
    await writing.future;
    api.dispose();
    release.complete();
    final result = await task;
    expect(result.succeeded, isFalse);
    expect(result.notesSucceeded, isTrue);
    expect(await db.getSyncCursor('b', 'note'), 'next');
    expect(changes, 0);
  });

  for (final source in ['shelf', 'bookmark', 'note']) {
    test('$source 等待数据库事务锁时取消，获得锁后不再提交', () async {
      await db.insertNotesPreserveFav([]); // Warm up SQLite capability lookup.
      final raw = await db.database;
      final response = Completer<ResponseBody>();
      respond = (_) => response.future;
      final service = SyncService.forApi(api);
      final Future<Object> task = source == 'shelf'
          ? service.syncAll()
          : service.retryBook(book, previous: previous(source));
      await waitUntil(() => requests.length == 1);
      final locked = Completer<void>();
      final release = Completer<void>();
      final holder = raw.transaction((txn) async {
        locked.complete();
        await release.future;
      });
      await locked.future;
      final queued = Completer<void>();
      probe.onTransactionStart = () {
        probe.onTransactionStart = null;
        queued.complete();
      };
      response.complete(jsonResponse(switch (source) {
        'shelf' => {
            'books': [
              {'bookId': 'b', 'title': '书'}
            ]
          },
        'bookmark' => {'updated': [], 'synckey': 'next'},
        _ => {'reviews': [], 'synckey': 'next'},
      }));
      await queued.future;
      service.cancel();
      release.complete();
      await holder;
      await task;
      expect(await db.getAllBooks(), isEmpty);
      expect(await db.getSyncCursor('b', 'bookmark'), '0');
      expect(await db.getSyncCursor('b', 'note'), '0');
    });

    test('$source 本地提交完成但回调尚未返回时切换账号，不覆盖新账号变更通知', () async {
      final committed = Completer<void>();
      final release = Completer<void>();
      probe.afterCommit = () async {
        probe.afterCommit = null;
        committed.complete();
        await release.future;
      };
      final service = SyncService.forApi(api);
      final Future<Object> task = source == 'shelf'
          ? service.syncAll()
          : service.retryBook(book, previous: previous(source));
      await committed.future;
      await DatabaseService.selectAccount('456');
      final nextDb = DatabaseService.instance;
      await nextDb.database;
      SyncService.changes.publish(nextDb, bookIds: {'new-account'});
      final version = SyncService.changes.dataVersion;
      release.complete();
      await task;
      expect(SyncService.changes.value, same(nextDb));
      expect(SyncService.changes.dataVersion, version);
      expect(SyncService.changes.bookIds, {'new-account'});
      expect(await nextDb.getAllBooks(), isEmpty);
      expect(await nextDb.getAllBookmarks(), isEmpty);
      expect(await nextDb.getAllNotes(), isEmpty);
    });
  }
}
