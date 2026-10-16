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
import 'support/observed_database.dart';
import 'support/wait_until.dart';

SyncService shelfService(Future<List<Book>> Function() load,
        {String? account, void Function()? onChanged}) =>
    SyncService(
        accountId: account,
        loadBooks: load,
        loadBookmarks: (_) async => 0,
        loadNotes: (_) async => 0,
        isCancelled: () => false,
        onChanged: onChanged ?? () {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('API 连接和本地准备阶段的取消', () {
    late Directory directory;
    late DatabaseService db;
    late DatabaseProbe probe;
    late WeReadApi api;
    late Dio dio;
    late AppConfig config;
    late List<RequestOptions> requests;
    late FutureOr<ResponseBody> Function(RequestOptions) respond;
    final book = Book(bookId: 'b', title: '书');
    setUpAll(() {
      sqfliteFfiInit();
      if (Platform.isLinux) {
        open.overrideFor(OperatingSystem.linux,
            () => DynamicLibrary.open('libsqlite3.so.0'));
      }
    });
    setUp(() async {
      directory =
          await Directory.systemTemp.createTemp('weread-cancel-windows-');
      probe = DatabaseProbe();
      databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
      await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
      await DatabaseService.selectAccount('123');
      db = DatabaseService.instance;
      await db.database;
      config = AppConfig(cookie: 'wr_vid=123; wr_skey=original');
      requests = [];
      respond = (request) => jsonResponse(request.path == '/shelf/sync'
          ? {'books': []}
          : {
              if (request.path == '/book/bookmarklist') 'updated': [],
              if (request.path == '/review/list') 'reviews': [],
              'synckey': 'next'
            });
      dio = Dio()
        ..httpClientAdapter = AuthAdapter((request) {
          requests.add(request);
          return respond(request);
        });
      api = await WeReadApi.init(config: config, db: db, dio: dio);
    });
    tearDown(() async {
      WeReadApi.reset();
      await DatabaseService.endSession();
      databaseFactory = databaseFactoryFfiNoIsolate;
      await directory.delete(recursive: true);
    });

    test('API 初始化的异步返回窗口取消，不改共享 Cookie 且共享连接可继续使用', () async {
      var cancelled = false;
      final connecting = SyncService.connect(
          config: AppConfig(cookie: 'wr_vid=123; wr_skey=replacement'),
          isCancelled: () => cancelled);
      cancelled = true;
      await expectLater(connecting,
          throwsA(isA<StateError>().having((e) => e.message, '原因', '同步已取消')));
      expect(config.cookie, 'wr_vid=123; wr_skey=original');
      expect(api.syncCancelled, isFalse);
      expect((await SyncService.forApi(api).syncAll()).cancelled, isFalse);
      expect(requests, hasLength(1));
    });

    test('连接刚返回就取消，不请求书架且不影响随后连接', () async {
      final service = await SyncService.connect(config: config);
      service.cancel();
      expect((await service.syncAll()).cancelled, isTrue);
      expect(requests, isEmpty);
      expect((await SyncService.forApi(api).syncAll()).cancelled, isFalse);
      expect(requests, hasLength(1));
    });

    for (final endApi in [true, false]) {
      test('初始化返回前${endApi ? 'API' : '数据库'}会话结束，不能返回过期连接或改 Cookie', () async {
        final connecting = SyncService.connect(
            config: AppConfig(cookie: 'wr_vid=123; wr_skey=replacement'));
        Future<void>? ending;
        if (endApi) {
          api.dispose();
        } else {
          ending = DatabaseService.endSession();
        }
        await expectLater(connecting,
            throwsA(isA<StateError>().having((e) => e.message, '原因', '同步已取消')));
        await ending;
        expect(config.cookie, 'wr_vid=123; wr_skey=original');
        expect(requests, isEmpty);
      });
    }

    test('取消结束后重置服务，新的同步使用新的取消令牌', () async {
      final service = SyncService.forApi(api);
      service.cancel();
      expect((await service.syncAll()).cancelled, isTrue);
      service.resetCancellation();
      expect((await service.syncAll()).cancelled, isFalse);
      expect(requests, hasLength(1));
    });

    test('完成的请求不保留在取消集合，取消只通知当前在途请求', () async {
      respond = (request) => jsonResponse(switch (request.path) {
            '/shelf/sync' => {
                'books':
                    List.generate(20, (i) => {'bookId': '$i', 'title': '书$i'})
              },
            '/book/bookmarklist' => {'updated': []},
            _ => {'reviews': []},
          });
      final service = SyncService.forApi(api);
      expect((await service.syncAll()).successCount, 20);
      final completedTokens = requests.map((r) => r.cancelToken!).toSet();
      expect(completedTokens, hasLength(41));
      final response = Completer<ResponseBody>();
      respond = (_) => response.future;
      final task = service.syncAll();
      await waitUntil(() => requests.length == 42);
      service.cancel();
      expect(
          (await task.timeout(const Duration(seconds: 1))).cancelled, isTrue);
      expect(completedTokens.any((token) => token.isCancelled), isFalse);
      expect(requests.last.cancelToken!.isCancelled, isTrue);
      response.complete(jsonResponse({'books': []}));
    });

    test('Dio 已接受请求、尚未交给传输层时取消，不发送旧请求且连接可复用', () async {
      final intercepted = Completer<void>();
      final release = Completer<void>();
      dio.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) async {
        intercepted.complete();
        await release.future;
        handler.next(options);
      }));
      final service = SyncService.forApi(api);
      final task = service.syncAll();
      await intercepted.future;
      service.cancel();
      release.complete();
      expect((await task).cancelled, isTrue);
      expect(requests, isEmpty);
      dio.interceptors.removeLast();
      expect((await SyncService.forApi(api).syncAll()).cancelled, isFalse);
      expect(requests, hasLength(1));
    });

    for (final external in [false, true]) {
      test('账号队列刚开始读取游标时${external ? '外部' : '显式'}取消，不发送两类增量请求', () async {
        final releaseFirst = Completer<List<Book>>();
        final firstStarted = Completer<void>();
        final first = shelfService(() {
          firstStarted.complete();
          return releaseFirst.future;
        }, account: db.accountId)
            .syncAll();
        await firstStarted.future;
        final releaseReads = Completer<void>();
        var reads = 0;
        probe.afterRead = (table) async {
          if (table == 'sync_cursors') {
            reads++;
            await releaseReads.future;
          }
        };
        var cancelled = false;
        final service = SyncService.forApi(api, isCancelled: () => cancelled);
        final queued = service.retryBook(book);
        expect(reads, 0);
        releaseFirst.complete([]);
        await first;
        await waitUntil(() => reads == 2);
        if (external) {
          cancelled = true;
        } else {
          service.cancel();
        }
        releaseReads.complete();
        final result = await queued;
        probe.afterRead = null;
        expect(result.succeeded, isFalse);
        expect(result.bookmarksSucceeded, isFalse);
        expect(result.notesSucceeded, isFalse);
        expect(requests, isEmpty);
        expect(await db.getSyncCursor('b', 'bookmark'), '0');
        expect(await db.getSyncCursor('b', 'note'), '0');
        expect(
            (await SyncService.forApi(api).retryBook(book)).succeeded, isTrue);
        expect(requests, hasLength(2));
      });
    }

    for (final external in [false, true]) {
      for (final source in ['shelf', 'bookmark', 'note']) {
        test('$source 响应抵达前${external ? '外部' : '显式'}取消，不写入迟到数据、不推进游标或发布变更',
            () async {
          final started = Completer<void>();
          final response = Completer<ResponseBody>();
          respond = (_) {
            started.complete();
            return response.future;
          };
          var cancelled = false;
          final service = SyncService.forApi(api, isCancelled: () => cancelled);
          var changes = 0;
          void changed() => changes++;
          SyncService.changes.addListener(changed);
          addTearDown(() => SyncService.changes.removeListener(changed));
          final Future<Object> task = source == 'shelf'
              ? service.syncAll()
              : service.retryBook(book,
                  previous: BookSyncResult(book, 0, 0, ['失败'],
                      bookmarksSucceeded: source != 'bookmark',
                      notesSucceeded: source != 'note'));
          await started.future;
          if (external) {
            cancelled = true;
          } else {
            service.cancel();
            // The adapter is still waiting: cancellation must finish without a response.
            await task.timeout(const Duration(seconds: 1));
          }
          response.complete(jsonResponse({
            if (source == 'shelf')
              'books': [
                {'bookId': 'b', 'title': '迟到的书'}
              ],
            if (source == 'bookmark')
              'updated': [
                {'bookmarkId': 'bm', 'markText': '迟到的划线'}
              ],
            if (source == 'note')
              'reviews': [
                {'reviewId': 'nt', 'content': '迟到的笔记'}
              ],
            'synckey': 'next'
          }));
          final result = await task;
          await Future<void>.delayed(Duration.zero);
          if (result is SyncResult) {
            expect(result.cancelled, isTrue);
          } else {
            expect((result as BookSyncResult).succeeded, isFalse);
          }
          expect(await db.getAllBooks(), isEmpty);
          expect(await db.getAllBookmarks(), isEmpty);
          expect(await db.getAllNotes(), isEmpty);
          expect(await db.getSyncCursor('b', 'bookmark'), '0');
          expect(await db.getSyncCursor('b', 'note'), '0');
          expect(changes, 0);
          expect(api.syncCancelled, isFalse);
        });
      }
    }

    test('部分数据已提交后取消待响应来源，保留成功数量并释放账号队列', () async {
      final noteResponse = Completer<ResponseBody>();
      respond = (request) async => request.path == '/book/bookmarklist'
          ? jsonResponse({
              'updated': [
                {'bookmarkId': 'bm', 'markText': '已提交'}
              ],
              'synckey': 'next'
            })
          : await noteResponse.future;
      final service = SyncService.forApi(api);
      var changes = 0;
      void changed() => changes++;
      SyncService.changes.addListener(changed);
      addTearDown(() => SyncService.changes.removeListener(changed));
      final task = service.retryBook(book);
      await waitUntil(() => requests.length == 2);
      await (() async {
        while (await db.getSyncCursor('b', 'bookmark') != 'next') {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      })()
          .timeout(const Duration(seconds: 5));
      var nextStarted = false;
      final next = shelfService(() async {
        nextStarted = true;
        return [];
      }, account: db.accountId)
          .syncAll();
      expect(nextStarted, isFalse);
      service.cancel();
      final result = await task.timeout(const Duration(seconds: 1));
      await next.timeout(const Duration(seconds: 1));
      expect(result.bookmarks, 1);
      expect(result.bookmarksSucceeded, isTrue);
      expect(result.notesSucceeded, isFalse);
      expect(changes, 1);
      expect(SyncService.changes.itemIds, {'bookmark:bm'});
      noteResponse.complete(jsonResponse({
        'reviews': [
          {'reviewId': 'late', 'content': '不应写入'}
        ],
        'synckey': 'late'
      }));
      await Future<void>.delayed(Duration.zero);
      expect(await db.getAllBookmarks(), hasLength(1));
      expect(await db.getAllNotes(), isEmpty);
      expect(await db.getSyncCursor('b', 'note'), '0');
      expect(changes, 1);
      expect(api.syncCancelled, isFalse);
    });
  });

  test('账号锁交接后、排队任务恢复前取消，后继按序执行且锁可复用', () async {
    final release = Completer<List<Book>>();
    final calls = <String>[];
    SyncService make(String name) => shelfService(() {
          calls.add(name);
          return name == 'first' ? release.future : Future.value([]);
        }, account: 'handoff');
    final first = make('first').syncAll();
    await waitUntil(() => calls.isNotEmpty);
    final secondService = make('second');
    final second = secondService.syncAll();
    final third = make('third').syncAll();
    release.complete([]);
    await first;
    secondService.cancel();
    expect((await second).cancelled, isTrue);
    await third;
    await make('next').syncAll();
    expect(calls, ['first', 'third', 'next']);
  });

  for (final synchronousCompletion in [false, true]) {
    for (final cancelBeforeGrant in [false, true]) {
      test(
          '${synchronousCompletion ? '同步' : '异步'}完成释放请求槽${cancelBeforeGrant ? '交接前' : '刚交接后'}取消，后继可用且全局仍只有四个槽',
          () async {
        final gates = List.generate(
            4,
            (_) => synchronousCompletion
                ? Completer<List<Book>>.sync()
                : Completer<List<Book>>());
        var started = 0;
        SyncService? cancelledService;
        final holders = gates
            .map((gate) => shelfService(() {
                  started++;
                  return gate.future;
                }).syncAll(onBooks: (_) {
                  // _request has returned its permit before publishing the shelf.
                  if (identical(gate, gates.first) && !cancelBeforeGrant) {
                    cancelledService!.cancel();
                  }
                }))
            .toList();
        await waitUntil(() => started == 4);
        var cancelledCalls = 0;
        cancelledService = shelfService(() async {
          cancelledCalls++;
          return [];
        });
        final queued = cancelledService.syncAll();
        final nextGate = Completer<List<Book>>();
        var nextStarted = false;
        final next = shelfService(() {
          nextStarted = true;
          return nextGate.future;
        }).syncAll();
        addTearDown(() async {
          for (final gate in [...gates, nextGate]) {
            if (!gate.isCompleted) gate.complete([]);
          }
          await Future.wait([...holders, queued, next]);
        });
        if (cancelBeforeGrant) cancelledService.cancel();
        gates.first.complete([]);
        expect((await queued).cancelled, isTrue);
        await waitUntil(() => nextStarted);
        expect(cancelledCalls, 0);
        for (final gate in gates.skip(1)) {
          gate.complete([]);
        }
        nextGate.complete([]);
        await Future.wait([...holders, next]);

        // Detect both a leaked permit (<4) and a double release (>4).
        final waveGate = Completer<List<Book>>();
        var active = 0;
        var peak = 0;
        var waveStarted = 0;
        final wave = List.generate(
            8,
            (_) => shelfService(() async {
                  waveStarted++;
                  active++;
                  if (active > peak) peak = active;
                  try {
                    return await waveGate.future;
                  } finally {
                    active--;
                  }
                }).syncAll());
        await waitUntil(() => waveStarted >= 4);
        expect(waveStarted, 4);
        waveGate.complete([]);
        await Future.wait(wave);
        expect(peak, 4);
        expect(waveStarted, 8);
      });
    }
  }
}
