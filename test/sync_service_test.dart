import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/services/sync_service.dart';

void main() {
  test('四个长退避占满请求槽后取消，排队请求获得释放槽', () async {
    var failures = 0;
    final services = List.generate(4, (i) => SyncService(accountId: 'slots-$i',
      loadBooks: () async {
        failures++;
        final options = RequestOptions(path: '/shelf');
        throw DioException(requestOptions: options, response: Response(
          requestOptions: options, statusCode: 503,
          headers: Headers.fromMap({'retry-after': ['3600']})));
      }, loadBookmarks: (_) async => 0, loadNotes: (_) async => 0,
      isCancelled: () => false, onChanged: () {}));
    final tasks = services.map((s) => s.syncAll()).toList();
    while (failures < 4) { await Future<void>.delayed(Duration.zero); }
    var nextStarted = false;
    final next = SyncService(loadBooks: () async { nextStarted = true; return []; },
      loadBookmarks: (_) async => 0, loadNotes: (_) async => 0,
      isCancelled: () => false, onChanged: () {}).syncAll();
    await Future<void>.delayed(Duration.zero);
    expect(nextStarted, isFalse);
    for (final service in services) { service.cancel(); }
    expect((await Future.wait(tasks).timeout(const Duration(seconds: 1)))
      .every((r) => r.cancelled), isTrue);
    await next.timeout(const Duration(seconds: 1));
    expect(nextStarted, isTrue);
  });

  test('取消队列中间任务立即返回且后继不越过运行中任务', () async {
    final running = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    SyncService service(String name) => SyncService(accountId: 'queue-cancel',
      loadBooks: () async {
        calls.add(name);
        if (name == 'first') { started.complete(); await running.future; }
        return [];
      }, loadBookmarks: (_) async => 0, loadNotes: (_) async => 0,
      isCancelled: () => false, onChanged: () {});
    final first = service('first').syncAll();
    await started.future;
    final middleService = service('middle');
    final middle = middleService.syncAll();
    final last = service('last').syncAll();
    middleService.cancel();
    expect((await middle.timeout(const Duration(seconds: 1))).cancelled, isTrue);
    expect(calls, ['first']);
    running.complete();
    await Future.wait([first, last]);
    expect(calls, ['first', 'last']);
    await service('next').syncAll();
    expect(calls, ['first', 'last', 'next']);
  });

  test('长Retry-After取消立即释放账号锁和请求槽，新账号不继承退避', () async {
    var requests = 0;
    var cancelled = false;
    final started = Completer<void>();
    final service = SyncService(accountId: 'backoff',
      loadBooks: () async {
        requests++;
        started.complete();
        final options = RequestOptions(path: '/shelf');
        throw DioException(requestOptions: options, response: Response(
          requestOptions: options, statusCode: 429,
          headers: Headers.fromMap({'retry-after': ['3600']})));
      }, loadBookmarks: (_) async => 0, loadNotes: (_) async => 0,
      isCancelled: () => cancelled, onChanged: () {});
    final first = service.syncAll();
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancelled = true; // Also covers session revision / old account invalidation.
    expect((await first.timeout(const Duration(seconds: 1))).cancelled, isTrue);
    expect(requests, 1);
    for (final account in ['backoff', 'new-account']) {
      final next = SyncService(accountId: account, loadBooks: () async => [],
        loadBookmarks: (_) async => 0, loadNotes: (_) async => 0,
        isCancelled: () => false, onChanged: () {});
      expect((await next.syncAll().timeout(const Duration(seconds: 1))).cancelled, isFalse);
    }
  });

  test('同账号两入口及重试排队，前一个结束后才读取游标', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final itemCalls = <String>[];
    final book = Book(bookId: 'b', title: '', author: '', cover: '', updatedAt: 0);
    SyncService service(String name) => SyncService(accountId: '123',
      loadBooks: () async { calls.add(name); return [book]; },
      loadBookmarks: (_) async {
        itemCalls.add(name);
        if (name == 'shelf') { started.complete(); await gate.future; }
        return 0;
      }, loadNotes: (_) async => 0, isCancelled: () => false, onChanged: () {});
    final first = service('shelf').syncAll();
    await started.future;
    final second = service('page').syncAll();
    final retry = service('retry').retryBook(book);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['shelf']);
    expect(itemCalls, ['shelf']);
    gate.complete();
    await Future.wait([first, second]);
    await retry;
    expect(calls, ['shelf', 'page']);
    expect(itemCalls, ['shelf', 'page', 'retry']);
  });
  test('429保留状态并重试，取消后不重试', () async {
    var requests = 0;
    var cancelled = false;
    final book = Book(bookId: '1', title: '', author: '', cover: '', updatedAt: 0);
    final service = SyncService(loadBooks: () async => [book],
      loadBookmarks: (_) async {
        requests++;
        if (requests == 1) {
          final options = RequestOptions(path: '/bookmark');
          throw DioException(requestOptions: options, response: Response(
            requestOptions: options, statusCode: 429, headers: Headers.fromMap({'retry-after': ['0']})));
        }
        return 1;
      }, loadNotes: (_) async => 1,
      isCancelled: () => cancelled, onChanged: () {}, requestInterval: Duration.zero);
    expect((await service.syncAll()).successCount, 1);
    expect(requests, 2);
    cancelled = true;
    expect((await service.syncAll()).cancelled, isTrue);
    expect(requests, 2);
  });
  test('请求重叠且全局并发不超过四个', () async {
    var active = 0;
    var peak = 0;
    Future<int> load(Book _) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return 1;
    }
    final service = SyncService(
      loadBooks: () async => List.generate(12, (i) => Book(
        bookId: '$i', title: '', author: '', cover: '', updatedAt: 0)),
      loadBookmarks: load, loadNotes: load,
      isCancelled: () => false, onChanged: () {},
    );
    expect((await service.syncAll()).successCount, 12);
    expect(peak, 4);
  });
  final books = [
    Book(bookId: '1', title: '成功书', author: '', cover: '', updatedAt: 0),
    Book(bookId: '2', title: '失败书', author: '', cover: '', updatedAt: 0),
  ];

  test('单书任一请求失败明确记录，继续其他请求，重试只执行指定书', () async {
    var fail = true;
    var changed = 0;
    final requested = <String>[];
    final service = SyncService(
      loadBooks: () async => books,
      loadBookmarks: (book) async {
        requested.add('bm:${book.bookId}');
        if (book.bookId == '2' && fail) throw StateError('网络超时');
        return 3;
      },
      loadNotes: (book) async {
        requested.add('nt:${book.bookId}');
        return 2;
      },
      isCancelled: () => false,
      onChanged: () => changed++,
      requestInterval: Duration.zero,
    );
    final result = await service.syncAll();
    expect(result.successCount, 1);
    expect(result.failureCount, 1);
    expect(result.failures.single.book.title, '失败书');
    expect(result.failures.single.reason, contains('网络超时'));
    expect(result.summary, contains('成功 1 本 / 失败 1 本'));
    expect(result.notes, 4);
    expect(changed, 1);
    requested.clear();
    fail = false;
    final retried = await service.retryBook(result.failures.single.book);
    expect(requested, ['bm:2', 'nt:2']);
    final updated = result.replace(retried);
    expect(updated.failureCount, 0);
    expect(updated.successCount, 2);
    expect(updated.notes, 4); // 不重复累加重试数据
    expect(changed, 2);
  });

  test('取消不报完成，不再请求后续书，仍通知刷新已写入数据', () async {
    var cancelled = false;
    var changed = false;
    var requests = 0;
    final service = SyncService(
      loadBooks: () async => books,
      loadBookmarks: (_) async {
        requests++;
        cancelled = true;
        return 1;
      },
      loadNotes: (_) async => throw StateError('不应请求'),
      isCancelled: () => cancelled,
      onChanged: () => changed = true,
      requestInterval: Duration.zero,
    );
    final result = await service.syncAll();
    expect(result.cancelled, isTrue);
    expect(result.summary, startsWith('同步已取消'));
    expect(result.successCount, 0);
    expect(requests, 1);
    expect(changed, isTrue);
  });

  test('两类请求均失败只计失败一本，重试仍失败时保留完整原因', () async {
    final service = SyncService(
      loadBooks: () async => [books.last],
      loadBookmarks: (_) async => throw StateError('划线超时'),
      loadNotes: (_) async => throw StateError('笔记限流'),
      isCancelled: () => false,
      onChanged: () {},
      requestInterval: Duration.zero,
    );
    final result = await service.syncAll();
    expect(result.successCount, 0);
    expect(result.failureCount, 1);
    expect(result.failures.single.errors.length, 2);
    final retried = await service.retryBook(books.last);
    final updated = result.replace(retried);
    expect(updated.failureCount, 1);
    expect(updated.failures.single.reason, contains('划线超时'));
    expect(updated.failures.single.reason, contains('笔记限流'));
  });
}
