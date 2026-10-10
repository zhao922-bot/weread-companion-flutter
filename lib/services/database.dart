import 'dart:io';
import 'dart:convert';
import '../models/ai_summary.dart';
import '../models/note_item.dart';
import '../models/reading_constants.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  Database? _db;
  Future<Database>? _opening;
  bool _closed = false;
  final String accountId;
  bool get isActive => !_closed && identical(_instance, this);
  static DatabaseService? _instance;
  static DatabaseService get instance =>
      _instance ?? (throw StateError('请先验证登录'));
  DatabaseService._(this.accountId);

  static Future<void> endSession() async {
    final previous = _instance;
    _instance = null;
    await previous?.close();
  }

  static Future<void> selectAccount(String accountId) async {
    if (!RegExp(r'^[0-9]+$').hasMatch(accountId) || accountId == '0') {
      throw ArgumentError('无效的账号 ID');
    }
    await _instance?.close();
    _instance = null;
    // 旧数据库没有账号归属，不能迁移给当前登录者。
    await deleteDatabase(join(await getDatabasesPath(), 'weread_companion.db'));
    _instance = DatabaseService._(accountId);
  }

  static Future<void> clearLocalData() async {
    final previous = _instance;
    _instance = null;
    await previous?.close();
    final directory = Directory(await getDatabasesPath());
    if (!await directory.exists()) return;
    await for (final file in directory.list()) {
      final name = basename(file.path);
      if (name == 'weread_companion.db' ||
          RegExp(r'^weread_companion_account_[0-9]+\.db$').hasMatch(name)) {
        await deleteDatabase(file.path);
      }
    }
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
      version: 8,
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
        if (oldVersion < 7) await _createSearchIndex(db);
        if (oldVersion < 8) await _upgradeSummaryMetadata(db);
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
    for (final (table, id, content, source) in [
      ('bookmarks', 'bookmark_id', 'mark_text', 'bookmark'),
      ('notes', 'note_id', 'content', 'note')]) {
      if (!await _tableExists(db, table)) continue;
      String terms(String prefix) => '''
        SELECT DISTINCT lower(substr(text, n, 3)), '$source', $prefix$id FROM (
          WITH RECURSIVE positions(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM positions
            WHERE n < length($prefix$content || char(10) || $prefix book_title || char(10) || $prefix chapter_title) - 2)
          SELECT n, $prefix$content || char(10) || $prefix book_title || char(10) || $prefix chapter_title AS text FROM positions
        ) WHERE length(substr(text, n, 3)) = 3
      '''.replaceAll('$prefix ', prefix);
      // Ordinary SQLite tables/triggers work on Android without FTS5 extensions.
      // Backfill needs a row from the source table for each term.
      // Trigger inserts and updates are in the same transaction as the source row.
      for (final event in ['INSERT', 'UPDATE']) {
        await db.execute('''CREATE TRIGGER search_${table}_${event.toLowerCase()}
          AFTER ${event == 'UPDATE' ? 'UPDATE OF $content, book_title, chapter_title, $id' : event} ON $table BEGIN
          DELETE FROM item_trigrams WHERE source = '$source' AND id = new.$id;
          INSERT OR IGNORE INTO item_trigrams ${terms('new.')}; END''');
      }
      await db.execute('''CREATE TRIGGER search_${table}_delete AFTER DELETE ON $table BEGIN
        DELETE FROM item_trigrams WHERE source = '$source' AND id = old.$id; END''');
      await db.execute('UPDATE $table SET $content = $content');
    }
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
      List<Map<String, dynamic>> rows, List<String> deleted, String? cursor) async {
    final table = source == 'note' ? 'notes' : 'bookmarks';
    final id = source == 'note' ? 'note_id' : 'bookmark_id';
    await (await database).transaction((txn) async {
      for (final row in rows) {
        final values = {'is_fav': 0, ...row};
        final columns = values.keys.toList();
        await txn.rawInsert('INSERT INTO $table (${columns.join(',')}) '
            'VALUES (${List.filled(columns.length, '?').join(',')}) '
            'ON CONFLICT($id) DO UPDATE SET ${columns.where((c) => c != id && c != 'is_fav').map((c) => '$c = excluded.$c').join(',')}',
            values.values.toList());
      }
      for (final key in deleted) {
        await txn.delete(table, where: 'book_id = ? AND $id = ?', whereArgs: [bookId, key]);
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

  Future<void> insertBooks(List<Map<String, dynamic>> books) async {
    final db = await database;
    final batch = db.batch();
    for (final book in books) {
      batch.insert('books', book, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
    final db = await database;
    await db.insert('bookmarks', bookmark, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 插入或更新书签，但保留已有的 is_fav 状态
  Future<void> insertBookmarkPreserveFav(Map<String, dynamic> bookmark) async {
    await insertBookmarksPreserveFav([bookmark]);
  }

  Future<void> _upsertPreserveFav(String table, String id,
      List<Map<String, dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        final values = {'is_fav': 0, ...row};
        final columns = values.keys.toList();
        final updates = columns.where((c) => c != 'is_fav' && c != id)
            .map((c) => '$c = excluded.$c').join(', ');
        batch.rawInsert('INSERT INTO $table (${columns.join(', ')}) '
            'VALUES (${List.filled(columns.length, '?').join(', ')}) '
            'ON CONFLICT($id) DO UPDATE SET $updates', values.values.toList());
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> insertBookmarksPreserveFav(List<Map<String, dynamic>> rows) =>
      _upsertPreserveFav('bookmarks', 'bookmark_id', rows);

  Future<void> insertNotesPreserveFav(List<Map<String, dynamic>> rows) =>
      _upsertPreserveFav('notes', 'note_id', rows);

  Future<void> insertBookmarks(List<Map<String, dynamic>> bookmarks) async {
    final db = await database;
    final batch = db.batch();
    for (final bm in bookmarks) {
      batch.insert('bookmarks', bm, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
  static const _readingItems = '''
    SELECT bookmark_id AS id, book_id, book_title, mark_text AS content,
      chapter_title, created_at, is_fav, 'bookmark' AS source FROM bookmarks
    UNION ALL
    SELECT note_id AS id, book_id, book_title, content,
      chapter_title, created_at, is_fav, 'note' AS source FROM notes
  ''';

  (String, List<Object?>) _readingFilter(String query, ReadingFilter filter, String? bookId) {
    final search = _itemFilter(query, bookId, 'content');
    final clauses = <String>[if (search.$1 != null) search.$1!];
    if (filter == ReadingFilter.notes) clauses.add("source = 'note'");
    if (filter == ReadingFilter.favorites) clauses.add('is_fav = 1');
    final args = [...search.$2];
    if (query.runes.length >= 3) {
      clauses.add('(source, id) IN (SELECT source, id FROM item_trigrams WHERE term = ?)');
      args.add(_searchTerm(query));
    }
    return (clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}', args);
  }

  Future<List<Map<String, dynamic>>> getReadingItems({int offset = 0,
    int limit = 100, String query = '', ReadingFilter filter = ReadingFilter.all, String? bookId,
    NoteItem? after}) async {
    final db = await database;
    final where = _readingFilter(query, filter, bookId);
    final cursor = after == null ? '' : '${where.$1.isEmpty ? 'WHERE' : 'AND'} '
        '(created_at, source, id) < (?, ?, ?)';
    return db.rawQuery('SELECT * FROM ($_readingItems) ${where.$1} $cursor '
        'ORDER BY created_at DESC, source DESC, id DESC LIMIT ? OFFSET ?',
        [...where.$2, if (after != null) ...[after.createdAt, after.source.name, after.id], limit, offset]);
  }

  Future<int> countReadingItems({String query = '', ReadingFilter filter = ReadingFilter.all, String? bookId}) async {
    final db = await database;
    final where = _readingFilter(query, filter, bookId);
    return Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM ($_readingItems) ${where.$1}', where.$2)) ?? 0;
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
    final db = await database;
    await db.insert('notes', note, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 插入或更新笔记，但保留已有的 is_fav 状态
  Future<void> insertNotePreserveFav(Map<String, dynamic> note) async {
    await insertNotesPreserveFav([note]);
  }

  Future<void> insertNotes(List<Map<String, dynamic>> notes) async {
    final db = await database;
    final batch = db.batch();
    for (final note in notes) {
      batch.insert('notes', note, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
    final stats = await getReadingStats();
    final top = await db.rawQuery('''
      SELECT COALESCE(NULLIF(b.title, ''), NULLIF(MAX(m.book_title), ''), '未知书籍') AS title,
        COUNT(*) AS total FROM bookmarks m LEFT JOIN books b ON b.book_id = m.book_id
      GROUP BY m.book_id ORDER BY total DESC, m.book_id ASC LIMIT 5
    ''');
    final monthly = await db.rawQuery('''
      SELECT strftime('%Y-%m', created_at, 'unixepoch', 'localtime') AS month,
        COUNT(*) AS total FROM (
        SELECT created_at FROM bookmarks WHERE created_at BETWEEN ? AND ?
        UNION ALL SELECT created_at FROM notes WHERE created_at BETWEEN ? AND ?)
      GROUP BY month
    ''', [for (var i = 0; i < 2; i++) ...[
      DateTime(time.year, time.month - 5).millisecondsSinceEpoch ~/ 1000,
      time.millisecondsSinceEpoch ~/ 1000]]);
    return {...stats, 'top': top, 'monthly': monthly};
  }

  Future<Map<String, dynamic>> getReadingStats() async {
    final db = await database;
    final totalBooks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books')) ?? 0;
    final finishedBooks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books WHERE progress >= ?', [finishedProgress])) ?? 0;
    final readingBooks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books WHERE progress >= ? AND progress < ?', [readingStartedProgress, finishedProgress])) ?? 0;
    final totalBookmarks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM bookmarks')) ?? 0;
    final totalNotes = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM notes')) ?? 0;
    final favBookmarks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM bookmarks WHERE is_fav = 1')) ?? 0;
    final favNotes = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM notes WHERE is_fav = 1')) ?? 0;

    return {
      'totalBooks': totalBooks,
      'finishedBooks': finishedBooks,
      'readingBooks': readingBooks,
      'totalBookmarks': totalBookmarks,
      'totalNotes': totalNotes,
      'favoriteBookmarks': favBookmarks,
      'favoriteNotes': favNotes,
    };
  }

  Future<void> close() async {
    _closed = true;
    final current = _db;
    final opening = _opening;
    _db = null;
    _opening = null;
    Database? db = current;
    if (db == null && opening != null) {
      try {
        db = await opening;
      } catch (_) {
        return; // 打开失败时没有可关闭的连接。
      }
    }
    await db?.close();
  }
}
