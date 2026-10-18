import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ai_summary.dart';
import '../models/note_item.dart';
import '../models/reading_constants.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

String _indexText(Map<String, dynamic> row, String content) =>
    '${row[content] ?? ''}\n${row['book_title'] ?? ''}\n${row['chapter_title'] ?? ''}';

List<List<String>> _generateTrigrams(List<String> texts) => texts.map((text) {
  final terms = <String>{};
  int? first;
  int? second;
  for (var rune in text.runes) {
    // Match SQLite's built-in lower()/LIKE: ASCII case folding only.
    if (rune >= 65 && rune <= 90) rune += 32;
    if (first != null && second != null) {
      terms.add(String.fromCharCodes([first, second, rune]));
    }
    first = second;
    second = rune;
  }
  return terms.toList();
}).toList();

class _IndexChanged implements Exception {}

class DatabaseService {
  Database? _db;
  Future<Database>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  Future<bool>? _upsertSupported;

  Future<bool> _supportsUpsert(Database db) => _upsertSupported ??= (() async {
    final rows = await db.rawQuery('SELECT sqlite_version() AS version');
    final parts = (rows.single['version'] as String).split('.');
    final major = int.parse(parts[0]);
    final minor = int.parse(parts[1]);
    return major > 3 || (major == 3 && minor >= 24);
  })();

  Future<void> _writePreservingFav(Transaction txn, String table, String id,
      List<Map<String, dynamic>> rows, bool supportsUpsert) async {
    final batch = txn.batch();
    for (final row in rows) {
      final values = {'is_fav': 0, ...row};
      if (supportsUpsert) {
        final columns = values.keys.toList();
        batch.rawInsert('INSERT INTO $table (${columns.join(',')}) '
          'VALUES (${List.filled(columns.length, '?').join(',')}) '
          'ON CONFLICT($id) DO UPDATE SET ${columns.where((c) => c != id && c != 'is_fav').map((c) => '$c = excluded.$c').join(',')}',
          values.values.toList());
      } else {
        final existing = await txn.query(table, columns: [id],
          where: '$id = ?', whereArgs: [values[id]], limit: 1);
        if (existing.isEmpty) {
          // Execute immediately so repeated IDs in a delta see earlier inserts.
          await txn.insert(table, values);
        } else {
          final updates = {...values}..remove(id)..remove('is_fav');
          await txn.update(table, updates, where: '$id = ?', whereArgs: [values[id]]);
        }
      }
    }
    await batch.commit(noResult: true);
  }
  final String accountId;
  final _sessionActive = ValueNotifier<bool>(true);
  ValueListenable<bool> get sessionActive => _sessionActive;
  bool get isActive => !_closed && identical(_instance, this);

  /// Check the captured owner after every asynchronous session boundary.
  void requireActive() {
    if (!isActive) throw StateError('账号会话已结束');
  }
  static DatabaseService? _instance;
  static int _sessionRevision = 0;
  static final Set<DatabaseService> _retired = {};
  static DatabaseService get instance =>
      _instance ?? (throw StateError('请先验证登录'));
  DatabaseService._(this.accountId);

  static void _retireSession() {
    final previous = _instance;
    _instance = null;
    if (previous != null) {
      _retired.add(previous);
      previous._sessionActive.value = false;
    }
  }

  // Failed closes retain their handles. A retry must finish closing them before
  // opening another account (including reopening the same SQLite file).
  static Future<void> _closeRetiredSessions() async {
    Object? failure;
    StackTrace? failureStack;
    for (final database in _retired.toList()) {
      try {
        await database.close();
        _retired.remove(database);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  static Future<void> endSession() async {
    _sessionRevision++;
    _retireSession();
    await _closeRetiredSessions();
  }

  static Future<DatabaseService> selectAccount(String accountId,
      {bool Function()? isCancelled}) async {
    if (!RegExp(r'^[0-9]+$').hasMatch(accountId) || accountId == '0') {
      throw ArgumentError('无效的账号 ID');
    }
    if (isCancelled?.call() == true) throw StateError('账号会话已结束');
    final revision = ++_sessionRevision;
    void checkSession() {
      if (revision != _sessionRevision || isCancelled?.call() == true) {
        throw StateError('账号会话已结束');
      }
    }
    _retireSession();
    await _closeRetiredSessions();
    checkSession();
    // 旧数据库没有账号归属，不能迁移给当前登录者。
    final path = join(await getDatabasesPath(), 'weread_companion.db');
    checkSession();
    await deleteDatabase(path);
    checkSession();
    return _instance = DatabaseService._(accountId);
  }

  static Future<void> clearLocalData() async {
    _sessionRevision++;
    Object? failure;
    StackTrace? failureStack;
    Future<void> clean(Future<void> Function() action) async {
      try { await action(); } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    _retireSession();
    await clean(_closeRetiredSessions);
    await clean(() async {
      final directory = Directory(await getDatabasesPath());
      if (!await directory.exists()) return;
      await for (final file in directory.list()) {
        final name = basename(file.path);
        if (name == 'weread_companion.db' ||
            RegExp(r'^weread_companion_account_[0-9]+\.db$').hasMatch(name)) {
          await clean(() => deleteDatabase(file.path));
        }
      }
    });
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  Future<Database> get database async {
    if (_closed) throw StateError('账号会话已结束');
    if (_db != null) return _db!;
    final opening = _opening ??= _initDb();
    late Database db;
    try {
      db = await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
    if (_closed) throw StateError('账号会话已结束');
    _db = db;
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'weread_companion_account_$accountId.db');

    return await openDatabase(
      path,
      version: 9,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 5) await _createSyncTable(db);
        if (oldVersion < 4) await _createSummaryTable(db);
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE bookmarks ADD COLUMN is_fav INTEGER DEFAULT 0');
        }
        if (oldVersion < 3) {
          await db.execute(
            'CREATE TABLE IF NOT EXISTS chapters ('
            'book_id TEXT NOT NULL,'
            'chapter_uid INTEGER NOT NULL,'
            'chapter_idx INTEGER DEFAULT 0,'
            'title TEXT DEFAULT "",'
            'PRIMARY KEY (book_id, chapter_uid))'
          );
        }
        if (oldVersion < 6) await _createItemIndexes(db);
        if (oldVersion < 7) {
          await _createSearchIndex(db);
          // Persist pending work so a failed/interrupted onOpen can retry it.
          await db.execute('CREATE TABLE search_index_backfill (pending INTEGER)');
        }
        if (oldVersion < 8) await _upgradeSummaryMetadata(db);
        if (oldVersion < 9) {
          for (final table in ['bookmarks', 'notes']) {
            for (final event in ['insert', 'update']) {
              await db.execute('DROP TRIGGER IF EXISTS search_${table}_$event');
            }
          }
        }
      },
      onOpen: (db) async {
        if (!await _tableExists(db, 'search_index_backfill')) return;
        await db.execute('CREATE TABLE IF NOT EXISTS search_index_progress '
            '(source TEXT PRIMARY KEY, last_id TEXT NOT NULL)');
        for (final table in ['bookmarks', 'notes']) {
          if (!await _tableExists(db, table)) continue;
          final id = table == 'notes' ? 'note_id' : 'bookmark_id';
          final progress = await db.query('search_index_progress',
              where: 'source = ?', whereArgs: [table]);
          String? after = progress.isEmpty ? null : progress.single['last_id'] as String;
          while (true) {
            if (_closed) throw StateError('账号会话已结束');
            final rows = await db.query(table, orderBy: '$id ASC', limit: 100,
                where: after == null ? null : '$id > ?',
                whereArgs: after == null ? null : [after]);
            if (rows.isEmpty) break;
            final last = rows.last[id] as String;
            await _writeIndexed(db, table, rows, preserveFav: false,
                after: (txn) async {
                  if (_closed) throw StateError('账号会话已结束');
                  await txn.insert('search_index_progress', {'source': table, 'last_id': last},
                      conflictAlgorithm: ConflictAlgorithm.replace);
                });
            after = last;
          }
        }
        await db.transaction((txn) async {
          await txn.execute('DROP TABLE search_index_progress');
          await txn.execute('DROP TABLE search_index_backfill');
        });
      },
    );
  }

  Future<void> _createTables(Database db) async {
    await _createSyncTable(db);
    await _createSummaryTable(db);
    await _upgradeSummaryMetadata(db);
    await db.execute('''
      CREATE TABLE books (
        book_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        author TEXT DEFAULT '',
        cover TEXT DEFAULT '',
        progress INTEGER DEFAULT 0,
        finished INTEGER DEFAULT 0,
        category TEXT DEFAULT '',
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE bookmarks (
        bookmark_id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        book_title TEXT DEFAULT '',
        book_author TEXT DEFAULT '',
        mark_text TEXT DEFAULT '',
        chapter_title TEXT DEFAULT '',
        created_at INTEGER NOT NULL,
        is_fav INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE notes (
        note_id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        book_title TEXT DEFAULT '',
        content TEXT DEFAULT '',
        chapter_title TEXT DEFAULT '',
        created_at INTEGER NOT NULL,
        is_fav INTEGER DEFAULT 0
      )
    ''');

    await db.execute('CREATE INDEX idx_bookmarks_book_id ON bookmarks(book_id)');
    await db.execute('CREATE INDEX idx_notes_book_id ON notes(book_id)');
    await _createItemIndexes(db);
    await _createSearchIndex(db);

    await db.execute('''
      CREATE TABLE chapters (
        book_id TEXT NOT NULL,
        chapter_uid INTEGER NOT NULL,
        chapter_idx INTEGER DEFAULT 0,
        title TEXT DEFAULT '',
        PRIMARY KEY (book_id, chapter_uid)
      )
    ''');
  }

  Future<void> _createSearchIndex(Database db) async {
    await db.execute('CREATE TABLE item_trigrams (term TEXT NOT NULL, source TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(term, source, id)) WITHOUT ROWID');
    await db.execute('CREATE INDEX idx_trigrams_item ON item_trigrams(source, id)');
    for (final (table, id, source) in [
      ('bookmarks', 'bookmark_id', 'bookmark'),
      ('notes', 'note_id', 'note')]) {
      if (!await _tableExists(db, table)) continue;
      // Deletions remain transactional, including cascading book deletion.
      await db.execute('''CREATE TRIGGER search_${table}_delete AFTER DELETE ON $table BEGIN
        DELETE FROM item_trigrams WHERE source = '$source' AND id = old.$id; END''');
    }
  }

  Future<void> _writeIndexed(Database db, String table,
      List<Map<String, dynamic>> input, {required bool preserveFav,
      Future<void> Function(Transaction)? before,
      Future<void> Function(Transaction)? after,
      void Function()? checkCancelled}) async {
    checkCancelled?.call();
    final id = table == 'notes' ? 'note_id' : 'bookmark_id';
    final content = table == 'notes' ? 'content' : 'mark_text';
    final source = table == 'notes' ? 'note' : 'bookmark';
    final rows = input.map((row) => Map<String, dynamic>.from(row)).toList();
    final supportsUpsert = preserveFav && await _supportsUpsert(db);
    while (true) {
      checkCancelled?.call();
      final expected = <Object?, Map<String, dynamic>>{};
      final existing = preserveFav
          ? await _readIndexRows(db, table, id, content, rows.map((row) => row[id]))
          : const <Object?, Map<String, dynamic>>{};
      checkCancelled?.call();
      for (final row in rows) {
        // Match the TEXT affinity of both primary-key columns.
        final key = row[id]?.toString();
        expected[key] = preserveFav
            ? {...?(expected[key] ?? existing[key]), ...row}
            : row;
      }
      final texts = expected.values.map((row) => _indexText(row, content)).toList();
      final terms = texts.isEmpty ? <List<String>>[] : await compute(_generateTrigrams, texts);
      try {
        await db.transaction((txn) async {
          // A task may have been cancelled while preparing the index or
          // waiting for this transaction. Once admitted, keep the batch atomic.
          checkCancelled?.call();
          await before?.call(txn);
          if (preserveFav) {
            await _writePreservingFav(txn, table, id, rows, supportsUpsert);
          } else {
            final batch = txn.batch();
            for (final row in rows) {
              batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
            }
            await batch.commit(noResult: true);
          }
          final actual = await _readIndexRows(txn, table, id, content, expected.keys);
          final batch = txn.batch();
          var i = 0;
          for (final key in expected.keys) {
            // A concurrent partial update may have changed retained metadata.
            // Roll back and regenerate outside the transaction in that case.
            if (_indexText(actual[key]!, content) != texts[i]) throw _IndexChanged();
            batch.delete('item_trigrams', where: 'source = ? AND id = ?', whereArgs: [source, key]);
            for (final term in terms[i++]) {
              batch.insert('item_trigrams', {'term': term, 'source': source, 'id': key});
            }
          }
          await batch.commit(noResult: true);
          await after?.call(txn);
        });
        return;
      } on _IndexChanged {
        // Retry only index snapshot conflicts; all other errors propagate.
      }
    }
  }

  // Bound the parameter count for older Android SQLite versions, and fetch
  // only the fields needed to generate/validate the search index.
  Future<Map<Object?, Map<String, dynamic>>> _readIndexRows(
      DatabaseExecutor executor, String table, String id, String content,
      Iterable<Object?> ids) async {
    final keys = ids.map((key) => key?.toString()).toSet().toList();
    final result = <Object?, Map<String, dynamic>>{};
    const batchSize = 400;
    for (var offset = 0; offset < keys.length; offset += batchSize) {
      final end = offset + batchSize < keys.length ? offset + batchSize : keys.length;
      final batch = keys.sublist(offset, end);
      final rows = await executor.query(table,
          columns: [id, content, 'book_title', 'chapter_title'],
          where: '$id IN (${List.filled(batch.length, '?').join(',')})',
          whereArgs: batch);
      for (final row in rows) {
        result[row[id]] = row;
      }
    }
    return result;
  }

  Future<void> _createItemIndexes(Database db) async {
    for (final (table, id) in [('bookmarks', 'bookmark_id'), ('notes', 'note_id')]) {
      if (!await _tableExists(db, table)) continue;
      for (final prefix in ['', 'book_id, ', 'is_fav, ']) {
        final name = prefix.isEmpty ? 'time' : prefix.startsWith('book') ? 'book_time' : 'fav_time';
        await db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_$name ON $table (${prefix}created_at DESC, $id DESC)');
      }
    }
  }

  Future<bool> _tableExists(Database db, String table) async =>
      (await db.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).isNotEmpty;

  Future<void> _createSyncTable(Database db) => db.execute('''
    CREATE TABLE sync_cursors (
      book_id TEXT NOT NULL, source TEXT NOT NULL, synckey TEXT NOT NULL,
      PRIMARY KEY (book_id, source))
  ''');

  Future<String> getSyncCursor(String bookId, String source) async {
    final rows = await (await database).query('sync_cursors',
        where: 'book_id = ? AND source = ?', whereArgs: [bookId, source]);
    return rows.isEmpty ? '0' : rows.single['synckey'] as String;
  }

  Future<void> applySyncDelta(String bookId, String source,
      List<Map<String, dynamic>> rows, List<String> deleted, String? cursor,
      {String? expectedCursor, void Function()? checkCancelled}) async {
    if (deleted.any((id) => id.trim().isEmpty)) {
      throw const FormatException('增量包含无效删除 ID，未提交数据或推进同步游标，请重试');
    }
    final table = source == 'note' ? 'notes' : 'bookmarks';
    final id = source == 'note' ? 'note_id' : 'bookmark_id';
    final db = await database;
    await _writeIndexed(db, table, rows, preserveFav: true,
      checkCancelled: checkCancelled, before: (txn) async {
      if (expectedCursor != null) {
        final current = await txn.query('sync_cursors',
          where: 'book_id = ? AND source = ?', whereArgs: [bookId, source]);
        final key = current.isEmpty ? '0' : current.single['synckey'];
        if (key != expectedCursor) throw StateError('同步游标已更新，请重试');
      }
    }, after: (txn) async {
      // Keep each statement below old Android SQLite's parameter limit. The
      // surrounding transaction also rolls back earlier batches on failure.
      final uniqueDeleted = deleted.toSet().toList();
      for (var start = 0; start < uniqueDeleted.length; start += 400) {
        final keys = uniqueDeleted.skip(start).take(400).toList();
        await txn.rawDelete(
            'DELETE FROM $table WHERE book_id = ? '
            'AND $id IN (${List.filled(keys.length, '?').join(',')})',
            [bookId, ...keys]);
      }
      if (cursor != null) {
        await txn.insert('sync_cursors', {'book_id': bookId, 'source': source, 'synckey': cursor},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> _createSummaryTable(Database db) => db.execute('''
    CREATE TABLE ai_summaries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      payload TEXT NOT NULL
    )
  ''');

  Future<void> saveSummary(AISummary summary) async {
    final db = await database;
    await db.transaction((txn) async {
      final id = await txn.insert('ai_summaries', {'payload': jsonEncode(summary.toJson()),
        'title': summary.title, 'coverage': summary.coverage, 'created_at': summary.createdAt});
      for (final book in summary.references.map((r) => r.bookId).toSet()) {
        await txn.insert('summary_books', {'summary_id': id, 'book_id': book});
      }
    });
  }

  Future<void> _upgradeSummaryMetadata(Database db) async {
    await db.execute('ALTER TABLE ai_summaries ADD COLUMN title TEXT');
    await db.execute('ALTER TABLE ai_summaries ADD COLUMN coverage TEXT');
    await db.execute('ALTER TABLE ai_summaries ADD COLUMN created_at INTEGER');
    await db.execute('CREATE TABLE summary_books (summary_id INTEGER NOT NULL, book_id TEXT NOT NULL, PRIMARY KEY(book_id, summary_id))');
    var last = 0;
    while (true) {
      final rows = await db.query('ai_summaries', where: 'id > ?', whereArgs: [last], orderBy: 'id', limit: 100);
      if (rows.isEmpty) break;
      for (final row in rows) {
        final summary = AISummary.fromJson(jsonDecode(row['payload'] as String));
        await db.update('ai_summaries', {'title': summary.title, 'coverage': summary.coverage,
          'created_at': summary.createdAt}, where: 'id = ?', whereArgs: [row['id']]);
        for (final book in summary.references.map((r) => r.bookId).toSet()) {
          await db.insert('summary_books', {'summary_id': row['id'], 'book_id': book});
        }
      }
      last = rows.last['id'] as int;
    }
  }

  Future<List<Map<String, dynamic>>> getSummaryMetadata({String? bookId, int? before, int limit = 50}) async {
    final clauses = <String>[
      if (bookId != null) 'id IN (SELECT summary_id FROM summary_books WHERE book_id = ?)',
      if (before != null) 'id < ?'];
    return (await database).query('ai_summaries', columns: ['id', 'title', 'coverage', 'created_at'],
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: [if (bookId != null) bookId, if (before != null) before], orderBy: 'id DESC', limit: limit);
  }

  Future<AISummary> getSummary(int id) async {
    final rows = await (await database).query('ai_summaries', columns: ['payload'], where: 'id = ?', whereArgs: [id]);
    return AISummary.fromJson(jsonDecode(rows.single['payload'] as String));
  }

  Future<List<AISummary>> getSummaries({String? bookId}) async {
    final db = await database;
    final rows = await db.query('ai_summaries', orderBy: 'id DESC');
    return rows.map((r) => AISummary.fromJson(jsonDecode(r['payload'] as String)))
        .where((s) => bookId == null || s.references.any((r) => r.bookId == bookId)).toList();
  }

  Future<Map<String, dynamic>?> getReadingItem(String id, String source, String bookId) async {
    final db = await database;
    final rows = await db.rawQuery('SELECT * FROM ($_readingItems) '
        'WHERE id = ? AND source = ? AND book_id = ?', [id, source, bookId]);
    return rows.isEmpty ? null : rows.first;
  }

  // ── Books ──

  Future<void> insertBook(Map<String, dynamic> book) async {
    final db = await database;
    await db.insert('books', book, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateBook(Map<String, dynamic> book) async {
    final db = await database;
    await db.update('books', book, where: 'book_id = ?', whereArgs: [book['book_id']]);
  }

  Future<void> insertOrUpdateBook(Map<String, dynamic> book) async {
    final db = await database;
    await db.insert('books', book, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertBooks(List<Map<String, dynamic>> books,
      {void Function()? checkCancelled}) async {
    final db = await database;
    await db.transaction((txn) async {
      checkCancelled?.call();
      final batch = txn.batch();
      for (final book in books) {
        batch.insert('books', book, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Map<String, dynamic>?> getBook(String bookId) async {
    final db = await database;
    final rows = await db.query('books', where: 'book_id = ?', whereArgs: [bookId]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<List<Map<String, dynamic>>> getAllBooks() async {
    final db = await database;
    return await db.query('books', orderBy: 'updated_at DESC');
  }

  /// 删除书籍及其关联数据（级联删除）
  Future<void> deleteBook(String bookId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('books', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('bookmarks', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('notes', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('sync_cursors', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('chapters', where: 'book_id = ?', whereArgs: [bookId]);
    });
  }

  // ── Bookmarks ──

  Future<void> insertBookmark(Map<String, dynamic> bookmark) async {
    await insertBookmarks([bookmark]);
  }

  /// 插入或更新书签，但保留已有的 is_fav 状态
  Future<void> insertBookmarkPreserveFav(Map<String, dynamic> bookmark) async {
    await insertBookmarksPreserveFav([bookmark]);
  }

  Future<void> _upsertPreserveFav(String table, String id,
      List<Map<String, dynamic>> rows) async {
    final db = await database;
    await _writeIndexed(db, table, rows, preserveFav: true);
  }

  Future<void> insertBookmarksPreserveFav(List<Map<String, dynamic>> rows) =>
      _upsertPreserveFav('bookmarks', 'bookmark_id', rows);

  Future<void> insertNotesPreserveFav(List<Map<String, dynamic>> rows) =>
      _upsertPreserveFav('notes', 'note_id', rows);

  Future<void> insertBookmarks(List<Map<String, dynamic>> bookmarks) async {
    final db = await database;
    await _writeIndexed(db, 'bookmarks', bookmarks, preserveFav: false);
  }

  Future<List<Map<String, dynamic>>> getAllBookmarks({int offset = 0, int limit = 500,
    String query = '', String? bookId}) async {
    final db = await database;
    final filter = _bookmarkFilter(query, bookId);
    return await db.query('bookmarks', where: filter.$1, whereArgs: filter.$2,
        orderBy: 'created_at DESC, bookmark_id DESC', offset: offset, limit: limit);
  }

  (String?, List<Object?>) _itemFilter(String query, String? bookId, String content) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (bookId != null) {
      clauses.add('book_id = ?');
      args.add(bookId);
    }
    if (query.isNotEmpty) {
      final escaped = query.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
      clauses.add("($content LIKE ? ESCAPE '\\' OR book_title LIKE ? ESCAPE '\\' OR chapter_title LIKE ? ESCAPE '\\')");
      args.addAll(List.filled(3, '%$escaped%'));
    }
    return (clauses.isEmpty ? null : clauses.join(' AND '), args);
  }

  (String?, List<Object?>) _bookmarkFilter(String query, String? bookId) {
    final filter = _itemFilter(query, bookId, 'mark_text');
    if (query.runes.length < 3) return filter;
    return ('${filter.$1} AND bookmark_id IN (SELECT id FROM item_trigrams WHERE term = ? AND source = \'bookmark\')',
      [...filter.$2, _searchTerm(query)]);
  }

  String _searchTerm(String query) => String.fromCharCodes(query.runes.take(3))
      .replaceAllMapped(RegExp('[A-Z]'), (m) => m[0]!.toLowerCase());

  Future<int> countBookmarks({String query = ''}) async {
    final db = await database;
    final filter = _bookmarkFilter(query, null);
    final rows = await db.query('bookmarks', columns: ['COUNT(*) AS total'],
        where: filter.$1, whereArgs: filter.$2);
    return rows.first['total'] as int;
  }

  // UNION 后统一排序和分页，保证划线/笔记同时间时也不会遗漏或重复。
  static const _bookmarkReadingItems = '''
    SELECT bookmark_id AS id, book_id, book_title, mark_text AS content,
      chapter_title, created_at, is_fav, 'bookmark' AS source FROM bookmarks
  ''';
  static const _noteReadingItems = '''
    SELECT note_id AS id, book_id, book_title, content,
      chapter_title, created_at, is_fav, 'note' AS source FROM notes
  ''';
  static const _readingItems = '$_bookmarkReadingItems UNION ALL $_noteReadingItems';

  (String, List<Object?>) _readingSource(String query) {
    if (query.runes.length < 3) return (_readingItems, []);
    // Filter inside each UNION arm. An outer correlated filter can force full
    // scans, especially when COUNT prevents SQLite from flattening the UNION.
    const candidates = 'SELECT id FROM item_trigrams WHERE term = ? AND source = ';
    return ("$_bookmarkReadingItems WHERE bookmark_id IN ($candidates'bookmark') "
      "UNION ALL $_noteReadingItems WHERE note_id IN ($candidates'note')",
      [_searchTerm(query), _searchTerm(query)]);
  }

  (String, List<Object?>) _readingFilter(String query, ReadingFilter filter, String? bookId) {
    final search = _itemFilter(query, bookId, 'content');
    final clauses = <String>[if (search.$1 != null) search.$1!];
    if (filter == ReadingFilter.notes) clauses.add("source = 'note'");
    if (filter == ReadingFilter.favorites) clauses.add('is_fav = 1');
    return (clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}', search.$2);
  }

  Future<List<Map<String, dynamic>>> getReadingItems({int offset = 0,
    int limit = 100, String query = '', ReadingFilter filter = ReadingFilter.all, String? bookId,
    NoteItem? after}) async {
    final db = await database;
    final items = _readingSource(query);
    final where = _readingFilter(query, filter, bookId);
    final cursor = after == null ? '' : '${where.$1.isEmpty ? 'WHERE' : 'AND'} '
        '(created_at < ? OR (created_at = ? AND source < ?) '
        'OR (created_at = ? AND source = ? AND id < ?))';
    return db.rawQuery('SELECT * FROM (${items.$1}) AS reading_items ${where.$1} $cursor '
        'ORDER BY created_at DESC, source DESC, id DESC LIMIT ? OFFSET ?',
        [...items.$2, ...where.$2, if (after != null) ...[after.createdAt, after.createdAt,
          after.source.name, after.createdAt, after.source.name, after.id], limit, offset]);
  }

  Future<int> countReadingItems({String query = '', ReadingFilter filter = ReadingFilter.all, String? bookId}) async {
    final db = await database;
    final items = _readingSource(query);
    final where = _readingFilter(query, filter, bookId);
    return Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM (${items.$1}) AS reading_items ${where.$1}', [...items.$2, ...where.$2])) ?? 0;
  }

  static const summaryItemLimit = 30;

  /// Match Dart String.trim whitespace, before applying the bounded selection.
  static const _summaryWhitespace = 'char(9,10,11,12,13,32,133,160,5760,'
      '8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,'
      '8232,8233,8239,8287,12288,65279)';

  Future<List<Map<String, dynamic>>> getSummaryItems({String query = '',
    ReadingFilter filter = ReadingFilter.all, String? bookId}) async {
    final items = _readingSource(query);
    final where = _readingFilter(query, filter, bookId);
    return (await database).rawQuery(
      'SELECT * FROM (${items.$1}) AS reading_items ${where.$1} '
      '${where.$1.isEmpty ? 'WHERE' : 'AND'} trim(content, $_summaryWhitespace) <> ? '
      'ORDER BY created_at DESC, source DESC, id DESC LIMIT ?',
      [...items.$2, ...where.$2, '', summaryItemLimit]);
  }

  Future<List<Map<String, dynamic>>> getBookmarksByBook(String bookId) async {
    final db = await database;
    return await db.query('bookmarks', where: 'book_id = ?', whereArgs: [bookId], orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> searchBookmarks(String query, {int limit = 50}) async {
    final db = await database;
    // 转义 LIKE 通配符，防止 % 和 _ 被误解
    final escaped = query.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
    return await db.query(
      'bookmarks',
      where: "mark_text LIKE ? ESCAPE '\\' OR book_title LIKE ? ESCAPE '\\' OR chapter_title LIKE ? ESCAPE '\\'",
      whereArgs: ['%$escaped%', '%$escaped%', '%$escaped%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<void> toggleBookmarkFavorite(String bookmarkId, bool isFav) async {
    final db = await database;
    await db.update('bookmarks', {'is_fav': isFav ? 1 : 0}, where: 'bookmark_id = ?', whereArgs: [bookmarkId]);
  }

  // ── Notes ──

  Future<void> insertNote(Map<String, dynamic> note) async {
    await insertNotes([note]);
  }

  /// 插入或更新笔记，但保留已有的 is_fav 状态
  Future<void> insertNotePreserveFav(Map<String, dynamic> note) async {
    await insertNotesPreserveFav([note]);
  }

  Future<void> insertNotes(List<Map<String, dynamic>> notes) async {
    final db = await database;
    await _writeIndexed(db, 'notes', notes, preserveFav: false);
  }

  Future<List<Map<String, dynamic>>> getNotesByBook(String bookId) async {
    final db = await database;
    return await db.query('notes', where: 'book_id = ?', whereArgs: [bookId], orderBy: 'created_at DESC');
  }

  /// 获取所有笔记（用于笔记页显示）
  Future<List<Map<String, dynamic>>> getAllNotes({int offset = 0, int limit = 500,
    String? bookId}) async {
    final db = await database;
    return await db.query('notes', where: bookId == null ? null : 'book_id = ?',
        whereArgs: bookId == null ? null : [bookId],
        orderBy: 'created_at DESC, note_id DESC', offset: offset, limit: limit);
  }

  Future<void> toggleFavorite(String noteId, bool isFav) async {
    final db = await database;
    await db.update('notes', {'is_fav': isFav ? 1 : 0}, where: 'note_id = ?', whereArgs: [noteId]);
  }

  Future<List<Map<String, dynamic>>> getFavoriteNotes() async {
    final db = await database;
    return await db.query('notes', where: 'is_fav = 1', orderBy: 'created_at DESC');
  }

  /// 获取所有收藏（bookmarks + notes 合并）
  Future<List<Map<String, dynamic>>> getAllFavorites() async {
    final db = await database;
    final favBookmarks = await db.query('bookmarks', where: 'is_fav = 1', orderBy: 'created_at DESC');
    final favNotes = await db.query('notes', where: 'is_fav = 1', orderBy: 'created_at DESC');
    return [...favBookmarks, ...favNotes];
  }

  // ── Stats ──

  Future<Map<String, dynamic>> getReportStats({DateTime? now}) async {
    final db = await database;
    final time = now ?? DateTime.now();
    // Keep totals, rankings and monthly buckets in one committed snapshot.
    return db.transaction((txn) async {
      final stats = await _readingStats(txn);
      final top = await txn.rawQuery('''
        SELECT COALESCE(NULLIF(b.title, ''), NULLIF(MAX(m.book_title), ''), '未知书籍') AS title,
          COUNT(*) AS total FROM bookmarks m LEFT JOIN books b ON b.book_id = m.book_id
        GROUP BY m.book_id ORDER BY total DESC, m.book_id ASC LIMIT 5
      ''');
      final monthly = await txn.rawQuery('''
        SELECT strftime('%Y-%m', created_at, 'unixepoch', 'localtime') AS month,
          COUNT(*) AS total FROM (
          SELECT created_at FROM bookmarks WHERE created_at BETWEEN ? AND ?
          UNION ALL SELECT created_at FROM notes WHERE created_at BETWEEN ? AND ?)
        GROUP BY month
      ''', [for (var i = 0; i < 2; i++) ...[
        DateTime(time.year, time.month - 5).millisecondsSinceEpoch ~/ 1000,
        time.millisecondsSinceEpoch ~/ 1000]]);
      return {...stats, 'top': top, 'monthly': monthly};
    });
  }

  Future<Map<String, dynamic>> getReadingStats() async =>
      _readingStats(await database);

  Future<Map<String, dynamic>> _readingStats(DatabaseExecutor db) async {
    // One statement gives every counter the same SQLite snapshot and avoids
    // seven separate calls across the platform channel.
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM books) AS totalBooks,
        (SELECT COUNT(*) FROM books WHERE progress >= ?) AS finishedBooks,
        (SELECT COUNT(*) FROM books WHERE progress >= ? AND progress < ?) AS readingBooks,
        (SELECT COUNT(*) FROM bookmarks) AS totalBookmarks,
        (SELECT COUNT(*) FROM notes) AS totalNotes,
        (SELECT COUNT(*) FROM bookmarks WHERE is_fav = 1) AS favoriteBookmarks,
        (SELECT COUNT(*) FROM notes WHERE is_fav = 1) AS favoriteNotes
    ''', [finishedProgress, readingStartedProgress, finishedProgress]);
    return Map<String, dynamic>.from(rows.single);
  }

  Future<void> close() {
    _closed = true;
    _sessionActive.value = false;
    return _closing ??= _closeDatabase().whenComplete(() => _closing = null);
  }

  Future<void> _closeDatabase() async {
    final current = _db;
    final opening = _opening;
    Database? db = current;
    if (db == null && opening != null) {
      try {
        db = await opening;
      } catch (_) {
        _opening = null;
        return; // 打开失败时没有可关闭的连接。
      }
    }
    // Keep the handle when close throws so a later session transition can retry.
    if (db?.isOpen == true) await db!.close();
    _db = null;
    _opening = null;
  }
}
