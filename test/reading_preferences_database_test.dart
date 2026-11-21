import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/note_item.dart';
import 'package:weread_companion/services/backup_service.dart';
import 'package:weread_companion/services/database.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('reading-preferences-');
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });

  tearDown(() async {
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });

  Future<void> seedItems() async {
    await db.insertBook({'book_id': 'b', 'title': '原书名', 'updated_at': 1});
    await db.insertBookmark({
      'bookmark_id': 'same',
      'book_id': 'b',
      'mark_text': '收藏的原文',
      'is_fav': 1,
      'created_at': 1,
    });
    await db.insertNote({
      'note_id': 'same',
      'book_id': 'b',
      'content': '另一条笔记',
      'created_at': 2,
    });
  }

  test('标签区分划线与笔记，结合搜索和筛选，并随同步删除', () async {
    await seedItems();
    final items = (await db.getReadingItems()).map(NoteItem.fromRow).toList();
    final bookmark = items.last;
    await db.setReadingTags(bookmark, ['  写作  ', '', '写作', '带引号"的标签']);
    await db.setReadingTags(items.first, ['待实践']);
    expect(
        await db.getReadingTags(), unorderedEquals(['写作', '待实践', '带引号"的标签']));
    expect(await db.countReadingItems(query: '收藏的', tag: '写作'), 1);
    expect(
        await db.countReadingItems(filter: ReadingFilter.notes, tag: '写作'), 0);
    expect((await db.getSummaryItems(tag: '待实践')).single['source'], 'note');
    final filtered =
        (await db.getReadingItems(tag: '写作')).map(NoteItem.fromRow).single;
    expect(filtered.source, NoteSource.bookmark);
    expect(filtered.tags, unorderedEquals(['写作', '带引号"的标签']));
    await db.applySyncDelta('b', 'bookmark', [], ['same'], '1');
    expect(await db.getReadingTags(), ['待实践']);
    await expectLater(db.setReadingTags(bookmark, ['不应复活']), throwsStateError);
    await db.setReadingTags(items.first, []);
    expect(await db.getReadingTags(), isEmpty);
  });

  test('完整备份恢复卡片书名、标签和回顾顺序', () async {
    await seedItems();
    expect(await db.getCardBookTitle('b'), isNull);
    await db.setCardBookTitle('b', '卡片书名');
    final bookmark = NoteItem.fromRow((await db.getReadingItems()).last);
    await db.setReadingTags(bookmark, ['精选']);
    expect(
        (await db.getDailyReviewItems(dayStart: 100, limit: 1)).single['source'], 'bookmark');
    await db.markReadingItemReviewed(bookmark, 101);
    final backup = await BackupService.buildBackupJson(db);
    await DatabaseService.selectAccount('456');
    db = DatabaseService.instance;
    expect(await db.getCardBookTitle('b'), isNull);
    await BackupService.restoreFromJson(backup, database: db);
    expect(await db.getCardBookTitle('b'), '卡片书名');
    expect(await db.getReadingTags(), ['精选']);
    expect((await db.getDailyReviewItems(dayStart: 100, limit: 1)).single['source'], 'note');
    expect((await db.getBook('b'))!['title'], '原书名');
    await db.setCardBookTitle('b', null);
    expect(await db.getCardBookTitle('b'), isNull);
  });

  test('版本 9 数据库升级保留原书架和阅读条目', () async {
    await seedItems();
    final nativeDb = await db.database;
    await nativeDb.execute('DROP TRIGGER reading_bookmark_delete');
    await nativeDb.execute('DROP TRIGGER reading_note_delete');
    await nativeDb.execute('DROP TABLE reading_tags');
    await nativeDb.execute('DROP TABLE reading_reviews');
    await nativeDb.execute('DROP TABLE card_book_titles');
    await nativeDb.setVersion(9);
    await DatabaseService.endSession();
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    expect((await db.getAllBooks()).single['title'], '原书名');
    expect(await db.countReadingItems(), 2);
    expect(await db.getReadingTags(), isEmpty);
    expect(await db.getCardBookTitle('b'), isNull);
  });
}
