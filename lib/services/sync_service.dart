import 'package:flutter/foundation.dart';
import '../models/book.dart';
import 'api.dart';
import 'database.dart';

class BookSyncResult {
  final Book book;
  final int bookmarks;
  final int notes;
  final List<String> errors;

  BookSyncResult(this.book, this.bookmarks, this.notes, List<String> errors)
      : errors = List.unmodifiable(errors);

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
class SyncChanges extends ChangeNotifier {
  DatabaseService? value;

  void publish(DatabaseService db) {
    value = db;
    notifyListeners();
  }
}

class SyncService {
  static final SyncChanges changes = SyncChanges();
  final Future<List<Book>> Function() loadBooks;
  final Future<int> Function(Book) loadBookmarks;
  final Future<int> Function(Book) loadNotes;
  final bool Function() isCancelled;
  final VoidCallback onChanged;
  final Duration requestInterval;

  SyncService({
    required this.loadBooks,
    required this.loadBookmarks,
    required this.loadNotes,
    required this.isCancelled,
    required this.onChanged,
    this.requestInterval = const Duration(milliseconds: 300),
  });

  factory SyncService.forApi(WeReadApi api, {bool Function()? isCancelled}) {
    final db = api.db;
    return SyncService(
      loadBooks: api.fetchBookshelf,
      loadBookmarks: (book) async => (await api.fetchBookmarks(book.bookId, book.title)).length,
      loadNotes: (book) async => (await api.fetchNotes(book.bookId, book.title)).length,
      isCancelled: () => api.syncCancelled || !db.isActive || (isCancelled?.call() ?? false),
      onChanged: () {
        if (db.isActive) {
          changes.publish(db);
        }
      },
    );
  }

  Future<BookSyncResult> _syncBook(Book book) async {
    final errors = <String>[];
    var bookmarks = 0;
    var notes = 0;
    try {
      bookmarks = await loadBookmarks(book);
    } catch (e) {
      errors.add('划线：$e');
    }
    if (!isCancelled()) {
      try {
        notes = await loadNotes(book);
      } catch (e) {
        errors.add('笔记：$e');
      }
    }
    if (isCancelled()) errors.add('同步已取消');
    return BookSyncResult(book, bookmarks, notes, errors);
  }

  Future<SyncResult> syncAll({
    void Function(int total)? onBooks,
    void Function(BookSyncResult result, int processed)? onProgress,
  }) async {
    if (isCancelled()) return SyncResult([], 0, cancelled: true);
    try {
      final books = await loadBooks();
      onBooks?.call(books.length);
      final results = <BookSyncResult>[];
      for (final book in books) {
        if (isCancelled()) break;
        final result = await _syncBook(book);
        results.add(result);
        onProgress?.call(result, results.length);
        if (results.length < books.length && !isCancelled()) {
          await Future<void>.delayed(requestInterval);
        }
      }
      return SyncResult(results, books.length, cancelled: isCancelled());
    } finally {
      onChanged();
    }
  }

  Future<BookSyncResult> retryBook(Book book) async {
    if (isCancelled()) throw StateError('同步已取消');
    try {
      return await _syncBook(book);
    } finally {
      onChanged();
    }
  }
}
