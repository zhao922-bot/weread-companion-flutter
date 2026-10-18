import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/services/database.dart';
import 'support/observed_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('选择性中文搜索通过主键读取候选，跨来源同ID不产生错误匹配', () async {
    sqfliteFfiInit();
    final directory =
        await Directory.systemTemp.createTemp('readamber-search-');
    final probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    try {
      await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
      await DatabaseService.selectAccount('123');
      final db = DatabaseService.instance;
      await db.insertNotes(List.generate(
          100,
          (i) => {
                'note_id': '$i',
                'book_id': 'b',
                'created_at': i,
                'content': i == 20 ? '琥珀记忆笔记' : '普通笔记',
              }));
      await db.insertBookmarks(List.generate(
          100,
          (i) => {
                'bookmark_id': '$i',
                'book_id': 'b',
                'created_at': i,
                'mark_text': i == 40 ? '琥珀记忆划线' : '普通划线',
              }));
      final rows = await db.getReadingItems(query: '琥珀记忆');
      expect(rows.map((r) => '${r['source']}:${r['id']}'),
          ['bookmark:40', 'note:20']);
      final select = probe.reads.last.sql;
      expect(await db.countReadingItems(query: '琥珀记忆'), 2);
      final count = probe.reads.last.sql;
      expect((await db.getSummaryItems(query: '琥珀记忆')).length, 2);
      final summary = probe.reads.last.sql;
      final connection = await db.database;
      for (final (sql, tail) in [
        (select, <Object>[100, 0]),
        (count, <Object>[]),
        (summary, <Object>['', 30])
      ]) {
        final plan = await connection.rawQuery('EXPLAIN QUERY PLAN $sql', [
          '琥珀记',
          '琥珀记',
          ...List.filled(3, '%琥珀记忆%'),
          ...tail,
        ]);
        final detail = plan.map((r) => r['detail']).join('\n');
        expect(
            detail,
            contains(
                'SEARCH notes USING INDEX sqlite_autoindex_notes_1 (note_id=?)'));
        expect(
            detail,
            contains(
                'SEARCH bookmarks USING INDEX sqlite_autoindex_bookmarks_1 (bookmark_id=?)'));
        expect(detail, isNot(contains('CORRELATED')));
      }
    } finally {
      await DatabaseService.endSession();
      await directory.delete(recursive: true);
    }
  });
}
