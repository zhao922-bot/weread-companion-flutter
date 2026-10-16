import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';

import 'support/observed_database.dart';
import 'support/wait_until.dart';

bool isMatchCount(String sql) =>
    sql.startsWith('SELECT COUNT(*) FROM (') &&
    sql.contains('AS reading_items');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;

  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-pagination-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  Future<void> seed(int count) => db.insertNotes(List.generate(
      count,
      (i) => {
            'note_id': 'n$i',
            'book_id': 'b',
            'content': i.isEven ? '目标笔记$i' : '普通笔记$i',
            'created_at': i,
            'is_fav': i.isEven ? 1 : 0,
          }));

  testWidgets('搜索防抖期间滚动不会混合新旧结果或使用旧分页游标', (tester) async {
    await tester.runAsync(() => seed(250));
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    final previous = provider.notes;
    probe.reads.clear();
    provider.setSearch('目标笔记');
    await tester.runAsync(provider.loadMore);
    expect(provider.notes, same(previous));
    expect(provider.matchedCount, 250);
    expect(probe.reads, isEmpty);

    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, () => !provider.isLoading);
    expect(provider.error, isNull);
    expect(provider.matchedCount, 125);
    expect(provider.notes.first.id, 'n248');
    await tester.runAsync(provider.loadMore);
    expect(provider.notes, hasLength(125));
    expect(provider.notes.map((n) => n.id).toSet(), hasLength(125));
    expect(provider.notes.every((n) => n.content.startsWith('目标笔记')), isTrue);
  });

  test('连续翻页复用匹配总数，数据事件及筛选变化重新计数', () async {
    await seed(505);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    probe.reads.clear();
    await provider.loadNotes();
    while (provider.hasMore) {
      await provider.loadMore();
    }
    expect(provider.notes, hasLength(505));
    expect(provider.notes.map((n) => n.id).toSet(), hasLength(505));
    expect(probe.reads.where((r) => isMatchCount(r.sql)), hasLength(1));

    await db.insertNote({
      'note_id': 'new',
      'book_id': 'b',
      'content': '新笔记',
      'created_at': 1000,
    });
    SyncService.changes
        .publish(db, kind: SyncChangeKind.items, sources: {'note'});
    await waitUntil(() => !provider.isLoading);
    expect(provider.matchedCount, 506);
    expect(provider.notes.first.id, 'new');
    expect(probe.reads.where((r) => isMatchCount(r.sql)), hasLength(2));
    provider.setFilter(ReadingFilter.favorites);
    await waitUntil(() => !provider.isLoading);
    expect(provider.matchedCount, 253);
    while (provider.hasMore) {
      await provider.loadMore();
    }
    expect(provider.notes, hasLength(253));
    expect(provider.notes.every((n) => n.isFav), isTrue);
    expect(probe.reads.where((r) => isMatchCount(r.sql)), hasLength(3));
  });

  test('过期的计数请求不能废弃较新请求的统计', () async {
    await seed(1);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    final counted = Completer<void>();
    final releaseCount = Completer<void>();
    final statsRead = Completer<void>();
    final releaseStats = Completer<void>();
    addTearDown(() {
      if (!releaseCount.isCompleted) releaseCount.complete();
      if (!releaseStats.isCompleted) releaseStats.complete();
    });
    probe.afterRead = (sql) async {
      if (isMatchCount(sql)) {
        probe.afterRead = null;
        counted.complete();
        await releaseCount.future;
      }
    };
    final oldLoad = provider.loadNotes();
    await counted.future;
    probe.afterRead = (sql) async {
      if (sql.contains('SELECT COUNT(*) FROM notes WHERE is_fav = 1')) {
        probe.afterRead = null;
        statsRead.complete();
        await releaseStats.future;
      }
    };
    final newLoad = provider.loadNotes();
    await statsRead.future;
    releaseCount.complete();
    await oldLoad;
    releaseStats.complete();
    await newLoad;
    expect(provider.error, isNull);
    expect(provider.notes, hasLength(1));
    expect(provider.noteCount, 1);
    expect(provider.favCount, 1);
  });

  test('新搜索首屏失败后重试重新计数，不复用旧查询总数', () async {
    await seed(250);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    provider.setSearch('目标笔记');
    probe.afterRead = (sql) {
      if (isMatchCount(sql)) {
        probe.afterRead = null;
        throw StateError('模拟计数失败');
      }
    };
    await provider.loadNotes();
    expect(provider.error, contains('模拟计数失败'));
    await provider.loadMore();
    expect(provider.error, isNull);
    expect(provider.matchedCount, 125);
    await provider.loadMore();
    expect(provider.notes, hasLength(125));
    expect(provider.notes.map((n) => n.id).toSet(), hasLength(125));
    expect(provider.hasMore, isFalse);
  });

  test('收藏列表刷新失败后重试首屏，保留期间的旧列表不作为续页', () async {
    await seed(250);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    provider.setFilter(ReadingFilter.favorites);
    await waitUntil(() => !provider.isLoading);
    expect(provider.matchedCount, 125);
    await db.toggleFavorite('n249', true);
    probe.afterRead = (sql) {
      if (isMatchCount(sql)) {
        probe.afterRead = null;
        throw StateError('模拟计数失败');
      }
    };
    SyncService.changes.publish(db,
        favoritesOnly: true, itemIds: {'note:n249'}, sources: {'note'});
    await waitUntil(() => !provider.isLoading);
    expect(provider.error, contains('模拟计数失败'));
    expect(provider.notes.first.id, 'n248');
    await provider.loadMore();
    expect(provider.error, isNull);
    expect(provider.notes.first.id, 'n249');
    expect(provider.matchedCount, 126);
    await provider.loadMore();
    expect(provider.notes, hasLength(126));
    expect(provider.notes.map((n) => n.id).toSet(), hasLength(126));
    expect(provider.hasMore, isFalse);
  });

  test('统计读取中插入书籍不产生总数小于已读数的混合快照', () async {
    await db.database;
    probe.reads.clear();
    probe.afterRead = (sql) async {
      if (sql.contains('SELECT COUNT(*) FROM books')) {
        probe.afterRead = null;
        await db.insertBook({
          'book_id': 'b',
          'title': '新书',
          'progress': 100,
          'updated_at': 1,
        });
      }
    };
    final stats = await db.getReadingStats();
    expect(stats, {
      'totalBooks': 0,
      'finishedBooks': 0,
      'readingBooks': 0,
      'totalBookmarks': 0,
      'totalNotes': 0,
      'favoriteBookmarks': 0,
      'favoriteNotes': 0,
    });
    expect(probe.reads, hasLength(1));
    final next = await db.getReadingStats();
    expect(next['totalBooks'], 1);
    expect(next['finishedBooks'], 1);
  });

  test('收藏写入被统计刷新抢先读到时不重复增减收藏计数', () async {
    await seed(1);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    for (final expected in [0, 1]) {
      probe.afterUpdate = (_) async {
        probe.afterUpdate = null;
        SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf);
        await waitUntil(() => provider.favCount == expected);
      };
      await provider.toggleFavorite(provider.notes.single);
      expect(provider.notes.single.isFav, expected == 1);
      expect(provider.favCount, expected);
      expect((await db.getReadingStats())['favoriteNotes'], expected);
    }
  });
}
