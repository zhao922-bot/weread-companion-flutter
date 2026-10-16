import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import '../models/book.dart';
import 'api.dart';
import 'database.dart';
import 'config.dart';

class SyncCancelledException implements Exception {
  const SyncCancelledException();
  @override
  String toString() => '同步已取消';
}

class BookSyncResult {
  final Book book;
  final int bookmarks;
  final int notes;
  final List<String> errors;
  final bool bookmarksSucceeded;
  final bool notesSucceeded;

  BookSyncResult(this.book, this.bookmarks, this.notes, List<String> errors,
      {bool? bookmarksSucceeded, bool? notesSucceeded})
      : errors = List.unmodifiable(errors),
        bookmarksSucceeded = bookmarksSucceeded ?? errors.isEmpty,
        notesSucceeded = notesSucceeded ?? errors.isEmpty;

  bool get succeeded => errors.isEmpty;
  String get reason => errors.join('；');
}

class SyncResult {
  final List<BookSyncResult> books;
  final int totalBooks;
  final bool cancelled;

  SyncResult(List<BookSyncResult> books, this.totalBooks, {this.cancelled = false})
      : books = List.unmodifiable(books);

  List<BookSyncResult> get failures => books.where((b) => !b.succeeded).toList();
  int get successCount => books.where((b) => b.succeeded).length;
  int get failureCount => failures.length;
  int get bookmarks => books.fold(0, (sum, b) => sum + b.bookmarks);
  int get notes => books.fold(0, (sum, b) => sum + b.notes);
  String get summary => '${cancelled ? '同步已取消' : '同步结束'}：成功 $successCount 本 / 失败 $failureCount 本'
      '，$bookmarks 条划线，$notes 条笔记';

  SyncResult replace(BookSyncResult retried) => SyncResult(
      books.map((b) => b.book.bookId == retried.book.bookId ? retried : b).toList(),
      totalBooks, cancelled: cancelled);
}

/// 所有同步入口共享的编排与本地数据刷新通知。
enum SyncChangeKind { all, bookshelf, items, favorites }

class SyncChanges extends ChangeNotifier {
  DatabaseService? value;
  int dataVersion = 0;
  bool favoritesOnly = false;
  Set<String> bookIds = const {};
  Set<String> itemIds = const {};
  Set<String> sources = const {};
  SyncChangeKind kind = SyncChangeKind.all;

  void publish(DatabaseService db, {bool favoritesOnly = false,
      SyncChangeKind kind = SyncChangeKind.all, Set<String> bookIds = const {},
      Set<String> itemIds = const {}, Set<String> sources = const {}}) {
    value = db;
    this.favoritesOnly = favoritesOnly;
    this.kind = favoritesOnly ? SyncChangeKind.favorites : kind;
    this.bookIds = Set.unmodifiable(bookIds);
    this.itemIds = Set.unmodifiable(itemIds);
    this.sources = Set.unmodifiable(sources);
    if (!favoritesOnly) dataVersion++;
    notifyListeners();
  }
}

class _SyncCancellation {
  final signal = ValueNotifier(false);
  final requests = <CancelToken>{};
  DateTime blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void cancel() {
    blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
    signal.value = true;
    for (final token in requests.toList()) {
      token.cancel(const SyncCancelledException());
    }
  }
}

class SyncService {
  static Future<SyncService> connect({AppConfig? config,
      bool Function()? isCancelled}) async {
    final resolved = config ?? AppConfig();
    if (config == null) await resolved.load();
    if (isCancelled?.call() ?? false) throw StateError('同步已取消');
    if (resolved.logoutPending) throw StateError('请先完成退出清理');
    if (!resolved.isConfigured) throw StateError('请先登录后同步');
    final db = DatabaseService.instance;
    final account = resolved.credentials?.vid ??
        RegExp(r'(?:^|;\s*)wr_vid=([0-9]+)(?:;|$)').firstMatch(resolved.cookie)?.group(1);
    if (account != db.accountId) throw StateError('账号已切换，请重新验证登录');
    final api = await WeReadApi.init(config: resolved, db: db);
    if ((isCancelled?.call() ?? false) || api.syncCancelled || !api.db.isActive) {
      throw StateError('同步已取消');
    }
    api.updateCookie(resolved.cookie);
    return SyncService.forApi(api, isCancelled: isCancelled);
  }

  static SyncService current({bool Function()? isCancelled}) =>
      SyncService.forApi(WeReadApi.instance, isCancelled: isCancelled);
  static final SyncChanges changes = SyncChanges();
  final Future<List<Book>> Function() loadBooks;
  final Future<int> Function(Book) loadBookmarks;
  final Future<int> Function(Book) loadNotes;
  final bool Function() isCancelled;
  final VoidCallback onChanged;
  final Duration requestInterval;
  _SyncCancellation _cancellation = _SyncCancellation();
  _SyncCancellation get _operation =>
      Zone.current[this] as _SyncCancellation? ?? _cancellation;
  DateTime get _blockedUntil => _operation.blockedUntil;
  set _blockedUntil(DateTime value) => _operation.blockedUntil = value;
  bool get _isCancelled => _operation.signal.value || isCancelled();

  // Async continuations, database checks and queued retries retain the state
  // captured at entry. Resetting for a new attempt cannot revive an old one.
  Future<T> _run<T>(Future<T> Function() task) =>
      runZoned(task, zoneValues: {this: _cancellation});

  void cancel() {
    // Only cancel this operation's requests; the API is shared by other entries.
    _cancellation.cancel();
  }

  void resetCancellation() {
    if (_cancellation.signal.value) _cancellation = _SyncCancellation();
  }

  Future<T> _withRequestCancellation<T>(Future<T> Function(CancelToken) load) async {
    _checkCancelled();
    final operation = _operation;
    final token = CancelToken();
    operation.requests.add(token);
    try {
      return await load(token);
    } finally {
      // Dio registers callbacks on whenCancel. A token per request keeps
      // completed requests out of the service's retained cancellation state.
      operation.requests.remove(token);
    }
  }

  void _checkCancelled() {
    if (_isCancelled) throw const SyncCancelledException();
  }

  // Legacy entry points expose a predicate (including account-session changes).
  // Observe it while waiting; explicit UI cancellation wakes the wait immediately.
  Future<T> _waitFor<T>(Future<T> future) async {
    final operation = _operation;
    if (_isCancelled) { operation.cancel(); throw const SyncCancelledException(); }
    final cancelled = Completer<T>();
    void check() {
      if ((operation.signal.value || isCancelled()) && !cancelled.isCompleted) {
        cancelled.completeError(const SyncCancelledException());
        operation.cancel();
      }
    }
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => check());
    operation.signal.addListener(check);
    try {
      return await Future.any([future, cancelled.future]);
    } finally {
      timer.cancel();
      operation.signal.removeListener(check);
    }
  }

  Future<void> _delay(Duration duration) async {
    final done = Completer<void>();
    final timer = Timer(duration, () => done.complete());
    try { await _waitFor(done.future); } finally { timer.cancel(); }
  }
  static int _activeRequests = 0;
  static final _waiting = <Completer<void>>[];
  static final _accountTasks = <String, List<Completer<void>>>{};
  final String? accountId;

  Future<T> _exclusive<T>(Future<T> Function() task) async {
    final account = accountId;
    if (account == null) return task();
    final queue = _accountTasks.putIfAbsent(account, () => []);
    final gate = Completer<void>();
    queue.add(gate);
    if (queue.length == 1) gate.complete();
    try {
      await _waitFor(gate.future);
      if (_isCancelled) throw const SyncCancelledException();
      return await task();
    } finally {
      final wasHead = identical(queue.first, gate);
      queue.remove(gate);
      if (queue.isEmpty) {
        _accountTasks.remove(account);
      } else if (wasHead) {
        queue.first.complete();
      }
    }
  }

  SyncService({
    required this.loadBooks,
    required this.loadBookmarks,
    required this.loadNotes,
    required this.isCancelled,
    required this.onChanged,
    this.requestInterval = const Duration(milliseconds: 300),
    this.accountId,
  });

  factory SyncService.forApi(WeReadApi api, {bool Function()? isCancelled}) {
    final db = api.db;
    late final SyncService service;
    void checkCancelled() {
      service._checkCancelled();
    }
    final changedBooks = <String>{};
    final changedItems = <String>{};
    final changedSources = <String>{};
    void record(String book, String source, Iterable<String> ids) {
      final keys = ids.toList();
      if (keys.isEmpty) return;
      changedBooks.add(book);
      changedSources.add(source);
      changedItems.addAll(keys.map((id) => '$source:$id'));
    }
    service = SyncService(
      accountId: db.accountId,
      loadBooks: () async {
        checkCancelled();
        final books = await service._withRequestCancellation(
            (token) => api.fetchBookshelf(cancelToken: token));
        checkCancelled();
        await db.insertBooks(books.map((b) => b.toJson()).toList(),
            checkCancelled: checkCancelled);
        if (!db.isActive || api.syncCancelled) throw const SyncCancelledException();
        changes.publish(db, kind: SyncChangeKind.bookshelf,
          bookIds: books.map((b) => b.bookId).toSet());
        return books;
      },
      loadBookmarks: (book) async {
        String? cursor;
        var deleted = <String>[];
        final expectedCursor = await db.getSyncCursor(book.bookId, 'bookmark');
        checkCancelled();
        final rows = await service._withRequestCancellation(
            (token) => api.fetchBookmarks(book.bookId, book.title,
            synckey: expectedCursor,
            cancelToken: token,
            onDelta: (key, ids) { cursor = key; deleted = ids; }));
        checkCancelled();
        await db.applySyncDelta(book.bookId, 'bookmark', rows.map((r) => r.toJson()).toList(), deleted, cursor,
          expectedCursor: expectedCursor, checkCancelled: checkCancelled);
        record(book.bookId, 'bookmark', [...rows.map((r) => r.bookmarkId), ...deleted]);
        return rows.length;
      },
      loadNotes: (book) async {
        String? cursor;
        var deleted = <String>[];
        final expectedCursor = await db.getSyncCursor(book.bookId, 'note');
        checkCancelled();
        final rows = await service._withRequestCancellation(
            (token) => api.fetchNotes(book.bookId, book.title,
            synckey: expectedCursor,
            cancelToken: token,
            onDelta: (key, ids) { cursor = key; deleted = ids; }));
        checkCancelled();
        await db.applySyncDelta(book.bookId, 'note', rows, deleted, cursor,
          expectedCursor: expectedCursor, checkCancelled: checkCancelled);
        record(book.bookId, 'note', [...rows.map((r) => r['note_id'] as String), ...deleted]);
        return rows.length;
      },
      isCancelled: () => api.syncCancelled || !db.isActive || (isCancelled?.call() ?? false),
      onChanged: () {
        if (db.isActive && !api.syncCancelled && changedItems.isNotEmpty) {
          changes.publish(db, kind: SyncChangeKind.items, bookIds: changedBooks,
            itemIds: changedItems, sources: changedSources);
          changedBooks.clear(); changedItems.clear(); changedSources.clear();
        }
      },
    );
    return service;
  }

  Future<T> _request<T>(Future<T> Function() load) async {
    if (_activeRequests < 4) {
      _activeRequests++;
    } else {
      final gate = Completer<void>();
      _waiting.add(gate);
      try {
        await _waitFor(gate.future);
      } catch (_) {
        if (!_waiting.remove(gate)) _releaseRequest();
        rethrow;
      }
    }
    try {
      return await _retryRequest(load);
    } finally {
      _releaseRequest();
    }
  }

  static void _releaseRequest() {
    if (_waiting.isEmpty) {
      _activeRequests--;
    } else {
      _waiting.removeAt(0).complete();
    }
  }

  Future<T> _retryRequest<T>(Future<T> Function() load) async {
    for (var attempt = 0; ; attempt++) {
      while (_blockedUntil.isAfter(DateTime.now())) {
        await _delay(_blockedUntil.difference(DateTime.now()));
      }
      if (_isCancelled) throw const SyncCancelledException();
      try {
        return await load();
      } on DioException catch (e) {
        if (_isCancelled) throw const SyncCancelledException();
        final status = e.response?.statusCode;
        if (attempt >= 2 || (status != 429 && status != 503 &&
            e.type != DioExceptionType.connectionTimeout &&
            e.type != DioExceptionType.receiveTimeout)) {
          rethrow;
        }
        final seconds = int.tryParse(e.response?.headers.value('retry-after') ?? '');
        final delay = seconds != null ? Duration(seconds: seconds) :
            (status == 429 ? requestInterval : const Duration(milliseconds: 500)) * (1 << attempt);
        final until = DateTime.now().add(delay);
        if (until.isAfter(_blockedUntil)) _blockedUntil = until;
      }
    }
  }

  Future<BookSyncResult> _syncBook(Book book, {BookSyncResult? previous}) async {
    final errors = <String>[];
    var bookmarksSucceeded = previous?.bookmarksSucceeded ?? false;
    var notesSucceeded = previous?.notesSucceeded ?? false;
    var bookmarks = bookmarksSucceeded ? previous!.bookmarks : 0;
    var notes = notesSucceeded ? previous!.notes : 0;
    Future<void> bookmarksTask() async {
      if (bookmarksSucceeded) return;
      try {
        bookmarks = await _request(() => loadBookmarks(book));
        bookmarksSucceeded = true;
      } catch (e) {
        errors.add('划线：$e');
      }
    }
    final first = bookmarksTask();
    Future<void> notesTask() async {
      if (_isCancelled || notesSucceeded) return;
      try {
        notes = await _request(() => loadNotes(book));
        notesSucceeded = true;
      } catch (e) {
        errors.add('笔记：$e');
      }
    }
    await Future.wait([first, notesTask()]);
    if (_isCancelled) errors.add('同步已取消');
    return BookSyncResult(book, bookmarks, notes, errors,
        bookmarksSucceeded: bookmarksSucceeded, notesSucceeded: notesSucceeded);
  }

  Future<SyncResult> syncAll({
    void Function(int total)? onBooks,
    void Function(BookSyncResult result, int processed)? onProgress,
  }) => _run(() async {
    try {
      return await _exclusive(() => _syncAll(onBooks: onBooks, onProgress: onProgress));
    } on SyncCancelledException {
      return SyncResult([], 0, cancelled: true);
    }
  });

  Future<SyncResult> _syncAll({void Function(int total)? onBooks,
    void Function(BookSyncResult result, int processed)? onProgress}) async {
    if (_isCancelled) return SyncResult([], 0, cancelled: true);
    try {
      final books = await _request(loadBooks);
      onBooks?.call(books.length);
      final results = <BookSyncResult>[];
      var next = 0;
      Future<void> worker() async {
        while (!_isCancelled && next < books.length) {
          final book = books[next++];
          final result = await _syncBook(book);
          results.add(result);
          onProgress?.call(result, results.length);
        }
      }
      // Two books, each with two overlapping requests: at most four in flight.
      await Future.wait([worker(), worker()]);
      return SyncResult(results, books.length, cancelled: _isCancelled);
    } on SyncCancelledException {
      return SyncResult([], 0, cancelled: true);
    } finally {
      onChanged();
    }
  }

  Future<BookSyncResult> retryBook(Book book, {BookSyncResult? previous}) {
    if (previous != null && previous.book.bookId != book.bookId) {
      throw ArgumentError('重试结果与书籍不匹配');
    }
    return _run(() => _exclusive(() => _retryBook(book, previous: previous)));
  }

  Future<BookSyncResult> _retryBook(Book book, {BookSyncResult? previous}) async {
    if (_isCancelled) throw const SyncCancelledException();
    try {
      return await _syncBook(book, previous: previous);
    } finally {
      onChanged();
    }
  }
}
