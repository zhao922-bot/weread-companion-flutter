import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';

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
    directory = await Directory.systemTemp.createTemp('weread-page-review-');
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

  Future<void> seedNotes(int count) => db.insertNotes(List.generate(
      count,
      (i) => {
            'note_id': 'n$i',
            'book_id': 'b',
            'content': '笔记$i',
            'created_at': i,
          }));

  int loadedItems(WidgetTester tester) =>
      (tester.widget<ListView>(find.byType(ListView)).childrenDelegate
              as SliverChildBuilderDelegate)
          .childCount! -
      8;

  testWidgets('详情刷新失败后的重试重载首屏，不遗漏新增的最新笔记', (tester) async {
    await tester.runAsync(() => seedNotes(2));
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
    await pumpUntil(tester, () => loadedItems(tester) == 2);
    var failed = false;
    probe.afterRead = (sql) {
      if (sql.startsWith('SELECT COUNT(*) AS total')) {
        probe.afterRead = null;
        failed = true;
        throw StateError('模拟首屏刷新失败');
      }
    };
    await tester.runAsync(() async {
      await db.insertNote({
        'note_id': 'new',
        'book_id': 'b',
        'content': '最新笔记',
        'created_at': 999
      });
      SyncService.changes
          .publish(db, kind: SyncChangeKind.items, bookIds: {'b'});
    });
    await pumpUntil(tester, () => failed);
    await tester.scrollUntilVisible(find.text('重试'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await pumpUntil(tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(loadedItems(tester), 3);
    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('note:new')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('最新笔记'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情三页加载只统计一次，刷新重新计数', (tester) async {
    await tester.runAsync(() => seedNotes(205));
    probe.reads.clear();
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
    await pumpUntil(tester, () => loadedItems(tester) == 100);
    for (var i = 0; i < 12 && loadedItems(tester) < 205; i++) {
      final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await pumpUntil(tester,
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    }
    expect(loadedItems(tester), 205);
    expect(
        probe.reads.where((r) => r.sql.startsWith('SELECT COUNT(*) AS total')),
        hasLength(1));
    await tester.runAsync(() async {
      await db.insertNote({
        'note_id': 'new',
        'book_id': 'b',
        'content': '最新',
        'created_at': 999
      });
      SyncService.changes
          .publish(db, kind: SyncChangeKind.items, bookIds: {'b'});
    });
    await pumpUntil(tester, () => loadedItems(tester) == 100);
    expect(
        probe.reads.where((r) => r.sql.startsWith('SELECT COUNT(*) AS total')),
        hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> bookmark(String id, int time) => db.insertBookmark({
        'bookmark_id': id,
        'book_id': 'b',
        'book_title': '书$id',
        'mark_text': '引文$id',
        'created_at': time,
      });

  testWidgets('同步插入引文后预览保留选中的ID，删除该项后选择有效引文', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await bookmark('A', 2);
      await bookmark('B', 1);
    });
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await pumpUntil(tester, () => find.text('引文B').evaluate().isNotEmpty);
    await tester.tap(find.text('引文B'));
    await tester.pumpAndSettle();
    expect(find.text('—— 书B'), findsOneWidget);
    await tester.runAsync(() async {
      await bookmark('C', 3);
      SyncService.changes
          .publish(db, kind: SyncChangeKind.items, sources: {'bookmark'});
    });
    await pumpUntil(tester, () => find.text('共 3 条').evaluate().isNotEmpty);
    expect(find.text('—— 书B'), findsOneWidget);
    await tester.runAsync(() async {
      await db.applySyncDelta('b', 'bookmark', [], ['B'], 'next');
      SyncService.changes
          .publish(db, kind: SyncChangeKind.items, sources: {'bookmark'});
    });
    await pumpUntil(tester, () => find.text('共 2 条').evaluate().isNotEmpty);
    expect(find.text('—— 书C'), findsOneWidget);
    expect(find.text('选择一条引文'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片搜索无结果显示无匹配，而非要求用户重新同步', (tester) async {
    await tester.runAsync(() => bookmark('A', 1));
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await pumpUntil(tester, () => find.text('共 1 条').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), '不存在的引文');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, () => find.text('共 0 条').evaluate().isNotEmpty);
    expect(find.text('没有匹配的引文'), findsOneWidget);
    expect(find.text('暂无引文，请先同步书架'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('报告总数、Top和月度使用同一读取快照', () async {
    final connection = await db.database;
    Future<void>? insertion;
    var committedDuringStats = false;
    probe.afterRead = (sql) async {
      if (!sql.contains('AS totalBooks')) return;
      probe.afterRead = null;
      var committed = false;
      insertion = connection.insert('bookmarks', {
        'bookmark_id': 'new',
        'book_id': 'b',
        'book_title': '测试书',
        'mark_text': '新引文',
        'created_at': DateTime(2026, 10, 1).millisecondsSinceEpoch ~/ 1000,
      }).then((_) {
        committed = true;
      });
      // Let a queued write try to execute while the first result is held.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      committedDuringStats = committed;
    };
    final stats = await db.getReportStats(now: DateTime(2026, 10, 16));
    await insertion;
    expect(committedDuringStats, isFalse);
    expect(stats['totalBookmarks'], 0);
    expect(stats['top'], isEmpty);
    expect(stats['monthly'], isEmpty);
    final next = await db.getReportStats(now: DateTime(2026, 10, 16));
    expect(next['totalBookmarks'], 1);
    expect((next['top'] as List).single['total'], 1);
    expect((next['monthly'] as List).single['total'], 1);
  });
}
