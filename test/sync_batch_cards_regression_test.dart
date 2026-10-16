import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/note_item.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';

import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;
import 'support/observed_database.dart';
import 'support/wait_until.dart';

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
    directory = await Directory.systemTemp.createTemp('weread-sync-cards-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> row(String source, String id, {String book = 'b'}) => {
        source == 'note' ? 'note_id' : 'bookmark_id': id,
        'book_id': book,
        source == 'note' ? 'content' : 'mark_text': '原文$id',
        'created_at': 1,
        'is_fav': 1,
      };

  test('异常同步游标拒绝整批更新和删除，修正为整数游标后可重试', () async {
    for (final source in ['note', 'bookmark']) {
      await db.applySyncDelta('b', source,
          [row(source, 'keep'), row(source, 'delete')], [], 'previous');
    }
    Object cursor = {};
    final api = await WeReadApi.init(
        config: AppConfig(cookie: 'wr_vid=123; wr_skey=test'),
        db: db,
        dio: Dio()
          ..httpClientAdapter =
              AuthAdapter((options) => jsonResponse(switch (options.path) {
                    '/shelf/sync' => {
                        'books': [
                          {'bookId': 'b', 'title': '书'}
                        ]
                      },
                    '/book/bookmarklist' => {
                        'updated': [
                          {'bookmarkId': 'keep', 'markText': '更新'}
                        ],
                        'deleted': ['delete'],
                        'synckey': cursor,
                      },
                    _ => {
                        'reviews': [
                          {'reviewId': 'keep', 'content': '更新'}
                        ],
                        'deleted': ['delete'],
                        'synckey': cursor,
                      },
                  })));
    final service = SyncService.forApi(api);
    for (final invalid in <Object>[{}, [], true, 1.5, '', ' \t ']) {
      cursor = invalid;
      final result = await service.syncAll();
      expect(result.failureCount, 1);
      expect(result.failures.single.reason, contains('synckey'));
      for (final source in ['note', 'bookmark']) {
        expect(await db.getSyncCursor('b', source), 'previous');
        final saved = await db.getReadingItem('keep', source, 'b');
        expect(saved!['content'], '原文keep');
        expect(saved['is_fav'], 1);
        expect(await db.getReadingItem('delete', source, 'b'), isNotNull);
      }
    }
    cursor = 42;
    expect((await service.syncAll()).failureCount, 0);
    for (final source in ['note', 'bookmark']) {
      expect(await db.getSyncCursor('b', source), '42');
      expect((await db.getReadingItem('keep', source, 'b'))!['content'], '更新');
      expect((await db.getReadingItem('keep', source, 'b'))!['is_fav'], 1);
      expect(await db.getReadingItem('delete', source, 'b'), isNull);
    }
  });

  test('纯空白更新ID不能作为有效增量提交或推进游标', () async {
    final api = await WeReadApi.init(
        config: AppConfig(cookie: 'wr_vid=123; wr_skey=test'),
        db: db,
        dio: Dio()
          ..httpClientAdapter =
              AuthAdapter((options) => jsonResponse(switch (options.path) {
                    '/shelf/sync' => {
                        'books': [
                          {'bookId': 'b', 'title': '书'}
                        ]
                      },
                    '/book/bookmarklist' => {
                        'updated': [
                          {'bookmarkId': ' \t ', 'markText': '无效'}
                        ],
                        'synckey': 'next',
                      },
                    _ => {
                        'reviews': [
                          {'reviewId': ' \t ', 'content': '无效'}
                        ],
                        'synckey': 'next',
                      },
                  })));
    final result = await SyncService.forApi(api).syncAll();
    expect(result.failureCount, 1);
    expect(await db.countReadingItems(), 0);
    expect(await db.getSyncCursor('b', 'bookmark'), '0');
    expect(await db.getSyncCursor('b', 'note'), '0');
  });

  test('1205条删除按批处理并保留其他书籍、收藏及搜索索引一致性', () async {
    for (final source in ['note', 'bookmark']) {
      await db.applySyncDelta(
          'b',
          source,
          [
            ...List.generate(1205, (i) => row(source, 'target$i')),
            row(source, 'survivor'),
          ],
          [],
          'old');
      await db.applySyncDelta('other', source,
          [row(source, 'foreign', book: 'other')], [], 'other');
    }
    probe.deletes.clear();
    for (final source in ['note', 'bookmark']) {
      await db.applySyncDelta(
          'b',
          source,
          [],
          [
            ...List.generate(1205, (i) => 'target$i'),
            'target0',
            'foreign',
          ],
          'next',
          expectedCursor: 'old');
      expect(await db.getSyncCursor('b', source), 'next');
      expect(await db.getSyncCursor('other', source), 'other');
      expect(await db.getReadingItem('foreign', source, 'other'), isNotNull);
      expect(await db.getReadingItem('survivor', source, 'b'), isNotNull);
    }
    expect(probe.deletes, hasLength(8));
    expect(probe.deletes.every((q) => q.arguments <= 401), isTrue);
    expect(await db.countReadingItems(), 4);
    expect(await db.countReadingItems(query: '原文target'), 0);
    expect(
        (await (await db.database).rawQuery(
                "SELECT COUNT(*) AS total FROM item_trigrams WHERE id LIKE 'target%'"))
            .single['total'],
        0);
    expect(await db.countReadingItems(filter: ReadingFilter.favorites), 4);
  });

  test('第三批删除失败回滚前两批及游标，修复后完整重试', () async {
    await db.applySyncDelta(
        'b', 'note', List.generate(805, (i) => row('note', 'n$i')), [], 'old');
    final connection = await db.database;
    await connection.execute('''
      CREATE TRIGGER fail_delete BEFORE DELETE ON notes
      WHEN OLD.note_id = 'n800'
      BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END
    ''');
    final ids = List.generate(805, (i) => 'n$i');
    await expectLater(db.applySyncDelta('b', 'note', [], ids, 'next'),
        throwsA(isA<DatabaseException>()));
    expect(await db.countReadingItems(), 805);
    expect(await db.countReadingItems(query: '原文'), 805);
    expect(await db.getSyncCursor('b', 'note'), 'old');
    await connection.execute('DROP TRIGGER fail_delete');
    await db.applySyncDelta('b', 'note', [], ids, 'next',
        expectedCursor: 'old');
    expect(await db.countReadingItems(), 0);
    expect(await db.getSyncCursor('b', 'note'), 'next');
  });

  Future<void> seedCards(int count) => db.insertBookmarks(List.generate(
      count,
      (i) => {
            'bookmark_id': 'bm$i',
            'book_id': 'b',
            'book_title': '测试书',
            'created_at': i,
            'mark_text': i.isEven ? '目标引文$i' : '普通引文$i',
          }));

  void narrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('卡片搜索等待期间禁用翻页，搜索结果从第一页开始', (tester) async {
    narrow(tester);
    await tester.runAsync(() => seedCards(250));
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await pumpUntil(tester, () => find.text('共 250 条').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), '目标引文');
    await tester.pump();
    final next = find.widgetWithIcon(IconButton, Icons.chevron_right_rounded);
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    expect(
        tester
            .widget<GestureDetector>(find
                .ancestor(
                    of: find.text('跳页'), matching: find.byType(GestureDetector))
                .first)
            .onTap,
        isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, () => find.text('共 125 条').evaluate().isNotEmpty);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('目标引文248'), findsOneWidget);
    await tester.tap(next);
    await pumpUntil(tester, () => find.text('目标引文48').evaluate().isNotEmpty);
    expect(find.text('2/2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片连续翻页复用计数，同步在搜索等待中到达只刷新一次', (tester) async {
    narrow(tester);
    await tester.runAsync(() => seedCards(425));
    probe.reads.clear();
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await pumpUntil(tester, () => find.text('普通引文423').evaluate().isNotEmpty);
    for (var page = 2; page <= 5; page++) {
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      final first = 424 - (page - 1) * 100;
      await pumpUntil(
          tester, () => find.text('目标引文$first').evaluate().isNotEmpty);
      expect(find.text('$page/5'), findsOneWidget);
    }
    // One initial COUNT plus five bounded data reads.
    expect(probe.reads.where((r) => r.sql == 'bookmarks'), hasLength(6));
    probe.reads.clear();
    await tester.enterText(find.byType(TextField), '目标引文');
    SyncService.changes
        .publish(db, kind: SyncChangeKind.items, sources: {'bookmark'});
    await pumpUntil(tester, () => find.text('共 213 条').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    expect(probe.reads.where((r) => r.sql == 'bookmarks'), hasLength(2));

    for (final first in [224, 24]) {
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntil(
          tester, () => find.text('目标引文$first').evaluate().isNotEmpty);
    }
    expect(find.text('3/3'), findsOneWidget);
    probe.reads.clear();
    await tester.runAsync(() async {
      await db.applySyncDelta(
          'b', 'bookmark', [], List.generate(225, (i) => 'bm$i'), 'deleted');
      SyncService.changes
          .publish(db, kind: SyncChangeKind.items, sources: {'bookmark'});
    });
    await pumpUntil(tester, () => find.text('共 100 条').evaluate().isNotEmpty);
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('目标引文424'), findsOneWidget);
    expect(probe.reads.where((r) => r.sql == 'bookmarks'), hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
