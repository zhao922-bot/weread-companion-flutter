import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'database.dart';

/// An immutable, disk-backed export snapshot. Only one page crosses into Dart.
class ExportSnapshot {
  static const pageSize = 500;
  static Future<void> _captureQueue = Future<void>.value();
  static const _schema = 'weread_export_snapshot';
  static final _attached = <Database>{};
  final String path;
  Future<Database>? _opening;
  Future<void>? _closing;
  bool _closed = false;

  ExportSnapshot._(this.path);

  static Future<void> _detach(Database db) async {
    if (db.isOpen) await db.execute('DETACH DATABASE $_schema');
    _attached.remove(db);
  }

  static Future<void> _releaseAttachments() async {
    Object? failure;
    StackTrace? failureStack;
    for (final db in _attached.toList()) {
      try {
        await _detach(db);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  /// Failed DETACH operations retain the connection until cleanup succeeds.
  /// Queue cleanup with captures so it cannot detach an in-progress snapshot.
  static Future<void> releaseAttachments() async {
    final previous = _captureQueue;
    final done = Completer<void>();
    _captureQueue = done.future;
    try {
      await previous;
      await _releaseAttachments();
    } finally {
      done.complete();
    }
  }

  static Future<ExportSnapshot> capture(DatabaseService owner, String path,
      {String? bookId}) async {
    // Attach/detach is connection-scoped. Serialize captures so concurrent
    // exports cannot exhaust SQLite's attached-database limit.
    final previous = _captureQueue;
    final done = Completer<void>();
    _captureQueue = done.future;
    try {
      await previous;
      await _releaseAttachments();
      owner.requireActive();
      final db = await owner.database;
      owner.requireActive();
      const schema = _schema;
      await db.execute('ATTACH DATABASE ? AS $schema', [path]);
      _attached.add(db);
      try {
        await db.transaction((txn) async {
          // CTAS assigns ascending rowids in SELECT order. These tables are
          // never modified after capture, making rowid a stable paging cursor.
          // https://www.sqlite.org/lang_createtable.html#createtableas
          await txn.execute('''
            CREATE TABLE $schema.books AS
            SELECT book_id, MIN(priority) AS priority,
              COALESCE(MAX(CASE WHEN priority = 0 THEN created_at END), MAX(created_at)) AS newest
            FROM (
              SELECT book_id, created_at, 0 AS priority FROM main.bookmarks
              UNION ALL SELECT book_id, created_at, 1 AS priority FROM main.notes)
            ${bookId == null ? '' : 'WHERE book_id = ?'}
            GROUP BY book_id ORDER BY priority, newest DESC, book_id DESC
          ''', [if (bookId != null) bookId]);
          if ((await txn.rawQuery('SELECT 1 FROM $schema.books LIMIT 1'))
              .isEmpty) {
            throw Exception('暂无数据可导出');
          }
          await txn
              .execute('CREATE INDEX $schema.export_book_id ON books(book_id)');
          await txn.execute('ALTER TABLE $schema.books ADD COLUMN title TEXT');
          await txn.execute('''
            UPDATE $schema.books SET title = CASE
              WHEN EXISTS (SELECT 1 FROM main.bookmarks WHERE book_id = books.book_id)
              THEN (SELECT book_title FROM main.bookmarks WHERE book_id = books.book_id
                ORDER BY created_at DESC, bookmark_id DESC LIMIT 1)
              ELSE (SELECT book_title FROM main.notes WHERE book_id = books.book_id
                ORDER BY created_at DESC, note_id DESC LIMIT 1)
              END
          ''');
          await txn.execute('''
            CREATE TABLE $schema.entries AS
            SELECT b.rowid AS book_position, i.content, i.chapter_title, i.source
            FROM (
              SELECT book_id, bookmark_id AS id, mark_text AS content, chapter_title,
                created_at, 'bookmark' AS source FROM main.bookmarks
              UNION ALL SELECT book_id, note_id AS id, content, chapter_title,
                created_at, 'note' AS source FROM main.notes) AS i
            JOIN $schema.books AS b ON b.book_id = i.book_id
            ORDER BY b.rowid, i.created_at ASC, i.source ASC, i.id DESC
          ''');
          owner.requireActive();
        });
      } finally {
        // Session shutdown may have closed the connection after the capture.
        try {
          await _detach(db);
        } catch (_) {
          if (owner.isActive) rethrow;
        }
      }
      owner.requireActive();
      return ExportSnapshot._(path);
    } finally {
      done.complete();
    }
  }

  Future<List<Map<String, Object?>>> readPage({int after = 0}) async {
    if (_closed) throw StateError('导出快照已关闭');
    final opening =
        _opening ??= openReadOnlyDatabase(path, singleInstance: false);
    final Database db;
    try {
      db = await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
    if (_closed) throw StateError('导出快照已关闭');
    return db.rawQuery('''
      SELECT e.rowid AS position, e.book_position, e.content, e.chapter_title,
        e.source, b.title FROM entries AS e JOIN books AS b ON b.rowid = e.book_position
      WHERE e.rowid > ? ORDER BY e.rowid LIMIT ?
    ''', [after, pageSize]);
  }

  Future<void> close() =>
      _closing ??= _close().whenComplete(() => _closing = null);

  Future<void> _close() async {
    _closed = true;
    final opening = _opening;
    if (opening == null) return;
    final Database db;
    try {
      db = await opening;
    } catch (_) {
      return;
    }
    if (db.isOpen) await db.close();
    _opening = null;
  }
}
