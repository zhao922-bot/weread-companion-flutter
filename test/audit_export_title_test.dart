import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_snapshot.dart';
import 'support/observed_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('快照书名按来源及时间选择且每本书只定位首条记录', () async {
    sqfliteFfiInit();
    final directory =
        await Directory.systemTemp.createTemp('readamber-titles-');
    final probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    String? titleSql;
    probe.afterExecute = (sql) {
      if (sql.contains('SET title =')) titleSql = sql;
    };
    ExportSnapshot? snapshot;
    try {
      await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
      await DatabaseService.selectAccount('123');
      final db = DatabaseService.instance;
      await db.insertBookmarks([
        {
          'bookmark_id': 'a',
          'book_id': 'mixed',
          'book_title': '旧书名',
          'created_at': 1
        },
        {
          'bookmark_id': 'b',
          'book_id': 'mixed',
          'book_title': '同时间较小ID',
          'created_at': 2
        },
        {
          'bookmark_id': 'z',
          'book_id': 'mixed',
          'book_title': '划线优先',
          'created_at': 2
        },
        {
          'bookmark_id': 'null',
          'book_id': 'null',
          'book_title': null,
          'created_at': 3
        },
        {
          'bookmark_id': 'empty',
          'book_id': 'empty',
          'book_title': '',
          'created_at': 4
        },
      ]);
      await db.insertNotes([
        {
          'note_id': 'new',
          'book_id': 'mixed',
          'book_title': '较新的笔记仍不优先',
          'created_at': 100
        },
        {
          'note_id': 'null',
          'book_id': 'null',
          'book_title': '不替换NULL',
          'created_at': 100
        },
        {
          'note_id': 'empty',
          'book_id': 'empty',
          'book_title': '不替换空字符串',
          'created_at': 100
        },
        {
          'note_id': 'a',
          'book_id': 'note',
          'book_title': '旧笔记书名',
          'created_at': 1
        },
        {
          'note_id': 'z',
          'book_id': 'note',
          'book_title': '笔记最新',
          'created_at': 2
        },
      ]);
      final path = '${directory.path}/snapshot.db';
      snapshot = await ExportSnapshot.capture(db, path);
      final connection = await db.database;
      await connection
          .execute('ATTACH DATABASE ? AS weread_export_snapshot', [path]);
      try {
        final titles = await connection.rawQuery(
            'SELECT book_id, title FROM weread_export_snapshot.books');
        expect({
          for (final row in titles) row['book_id']: row['title']
        }, {
          'mixed': '划线优先',
          'null': null,
          'empty': '',
          'note': '笔记最新',
        });
        final plan = (await connection.rawQuery('EXPLAIN QUERY PLAN $titleSql'))
            .map((r) => r['detail'])
            .join('\n');
        expect(plan, contains('idx_bookmarks_book_time (book_id=?)'));
        expect(plan, contains('idx_notes_book_time (book_id=?)'));
        expect(plan, isNot(contains('USE TEMP B-TREE FOR ORDER BY')));
      } finally {
        await connection.execute('DETACH DATABASE weread_export_snapshot');
      }
    } finally {
      await snapshot?.close();
      await DatabaseService.endSession();
      await directory.delete(recursive: true);
    }
  });
}
