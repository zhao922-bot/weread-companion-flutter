import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static Database? _db;
  static final DatabaseService _instance = DatabaseService._();
  static DatabaseService get instance => _instance;
  DatabaseService._();

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'weread_companion.db');

    return await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
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
      },
    );
  }

  Future<void> _createTables(Database db) async {
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
    });
  }

  // ── Bookmarks ──

  Future<void> insertBookmark(Map<String, dynamic> bookmark) async {
    final db = await database;
    await db.insert('bookmarks', bookmark, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 插入或更新书签，但保留已有的 is_fav 状态
  Future<void> insertBookmarkPreserveFav(Map<String, dynamic> bookmark) async {
    final db = await database;
    final existing = await db.query(
      'bookmarks',
      columns: ['is_fav'],
      where: 'bookmark_id = ?',
      whereArgs: [bookmark['bookmark_id']],
    );
    if (existing.isNotEmpty) {
      bookmark['is_fav'] = existing.first['is_fav'] ?? 0;
    }
    await db.insert('bookmarks', bookmark, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertBookmarks(List<Map<String, dynamic>> bookmarks) async {
    final db = await database;
    final batch = db.batch();
    for (final bm in bookmarks) {
      batch.insert('bookmarks', bm, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getAllBookmarks({int offset = 0, int limit = 500}) async {
    final db = await database;
    return await db.query('bookmarks', orderBy: 'created_at DESC', offset: offset, limit: limit);
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
    final db = await database;
    final existing = await db.query(
      'notes',
      columns: ['is_fav'],
      where: 'note_id = ?',
      whereArgs: [note['note_id']],
    );
    if (existing.isNotEmpty) {
      note['is_fav'] = existing.first['is_fav'] ?? 0;
    }
    await db.insert('notes', note, conflictAlgorithm: ConflictAlgorithm.replace);
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
  Future<List<Map<String, dynamic>>> getAllNotes({int offset = 0, int limit = 500}) async {
    final db = await database;
    return await db.query('notes', orderBy: 'created_at DESC', offset: offset, limit: limit);
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

  Future<Map<String, dynamic>> getReadingStats() async {
    final db = await database;
    final totalBooks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books')) ?? 0;
    final finishedBooks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books WHERE finished = 1')) ?? 0;
    final totalBookmarks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM bookmarks')) ?? 0;
    final totalNotes = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM notes')) ?? 0;
    final favBookmarks = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM bookmarks WHERE is_fav = 1')) ?? 0;
    final favNotes = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM notes WHERE is_fav = 1')) ?? 0;

    return {
      'totalBooks': totalBooks,
      'finishedBooks': finishedBooks,
      'readingBooks': totalBooks - finishedBooks,
      'totalBookmarks': totalBookmarks,
      'totalNotes': totalNotes,
      'favoriteBookmarks': favBookmarks,
      'favoriteNotes': favNotes,
    };
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _db = null;
  }
}
