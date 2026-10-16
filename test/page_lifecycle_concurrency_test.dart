import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _ReadGate {
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  bool fail = false;
  Future<void> hold() async {
    entered.complete();
    try {
      await release.future;
      if (fail) throw StateError('late read failure');
    } finally {
      finished.complete();
    }
  }
}

bool _items(String sql) =>
    sql.contains('AS reading_items') && sql.contains('LIMIT');
bool _stats(String sql) => sql.contains('AS favoriteNotes');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  final gates = <_ReadGate>[];
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-lifecycle-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
  });
  tearDown(() async {
    probe.afterRead = null;
    probe.afterCommit = null;
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    gates.clear();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });
  _ReadGate gateRead(bool Function(String) matches) {
    final gate = _ReadGate();
    gates.add(gate);
    probe.afterRead = (sql) async {
      if (matches(sql)) {
        probe.afterRead = null;
        await gate.hold();
      }
    };
    return gate;
  }

  _ReadGate gateReport() {
    final gate = _ReadGate();
    gates.add(gate);
    // Hold the completed report snapshot outside SQLite's transaction lock.
    probe.afterCommit = () async {
      probe.afterCommit = null;
      await gate.hold();
    };
    return gate;
  }

  Future<void> seed([int count = 1]) => db.insertNotes(List.generate(
      count,
      (i) => {
            'note_id': 'n$i',
            'book_id': 'b',
            'book_title': '测试书',
            'content': '笔记$i',
            'created_at': i + 1
          }));
  void favoriteEvent() => SyncService.changes.publish(db,
      favoritesOnly: true,
      itemIds: {'note:n0'},
      bookIds: {'b'},
      sources: {'note'});

  for (final stage in ['stats', 'items']) {
    for (final failure in [false, true]) {
      test('笔记 $stage 查询期间隐藏，迟到${failure ? '错误' : '结果'}不更新，回来仅刷新一次', () async {
        await seed(205);
        final provider = NotesProvider();
        addTearDown(provider.dispose);
        final gate = gateRead(stage == 'stats' ? _stats : _items)
          ..fail = failure;
        final loading = provider.loadNotes();
        await gate.entered.future;
        await provider.setActive(false);
        var notifications = 0;
        provider.addListener(() => notifications++);
        final reads = probe.reads.length;
        gate.release.complete();
        await loading;
        expect(probe.reads.length, reads);
        expect(provider.notes, isEmpty);
        expect(provider.error, isNull);
        expect(notifications, 0);
        expect(provider.isLoading, isFalse);
        await provider.setActive(true);
        expect(provider.notes, hasLength(100));
        expect(provider.matchedCount, 205);
        final settled = probe.reads.length;
        await provider.setActive(true);
        expect(probe.reads.length, settled);
      });
    }
  }

  for (final stage in ['stats', 'favorite']) {
    test('笔记后台 $stage 刷新期间隐藏，不继续查询或提交过期状态', () async {
      await seed();
      final provider = NotesProvider();
      addTearDown(provider.dispose);
      await provider.loadNotes();
      final gate = gateRead(
          stage == 'stats' ? _stats : (sql) => sql.contains('WHERE id = ?'));
      if (stage == 'stats') {
        SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf);
      } else {
        favoriteEvent();
      }
      await gate.entered.future;
      await provider.setActive(false);
      var notifications = 0;
      provider.addListener(() => notifications++);
      final reads = probe.reads.length;
      gate.release.complete();
      await gate.finished.future;
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
      expect(probe.reads.length, reads);
      await db.toggleFavorite('n0', true);
      await provider.setActive(true);
      expect(provider.notes.single.isFav, isTrue);
      expect(provider.favCount, 1);
    });
  }

  test('旧局部收藏查询失败不覆盖更新列表成功后的状态', () async {
    await seed();
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    final gate = gateRead((sql) => sql.contains('WHERE id = ?'))..fail = true;
    favoriteEvent();
    await gate.entered.future;
    await provider.loadNotes();
    gate.release.complete();
    await gate.finished.future;
    await Future<void>.delayed(Duration.zero);
    expect(provider.error, isNull);
  });

  test('新列表计数尚未返回时，旧统计失败也不能覆盖新请求', () async {
    await seed();
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    final stats = gateRead(_stats)..fail = true;
    SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf);
    await stats.entered.future;
    final count = gateRead((sql) => sql.startsWith('SELECT COUNT(*) FROM ('));
    final loading = provider.loadNotes();
    await count.entered.future;
    stats.release.complete();
    await stats.finished.future;
    await Future<void>.delayed(Duration.zero);
    count.release.complete();
    await loading;
    expect(provider.error, isNull);
    expect(provider.notes, hasLength(1));
  });

  test('已完成加载且无变更时反复切换页面复用缓存，不额外查库', () async {
    await seed();
    final notes = NotesProvider();
    final shelf = BookshelfProvider();
    addTearDown(notes.dispose);
    addTearDown(shelf.dispose);
    await notes.loadNotes();
    await shelf.loadBooks();
    probe.reads.clear();
    for (var i = 0; i < 5; i++) {
      await notes.setActive(false);
      await shelf.setActive(false);
      await notes.setActive(true);
      await shelf.setActive(true);
    }
    expect(probe.reads, isEmpty);
  });

  for (final failure in [false, true]) {
    test('书架读取期间隐藏后忽略迟到${failure ? '错误' : '结果'}，回来恢复', () async {
      await db.insertBook({'book_id': 'b', 'title': '测试书', 'updated_at': 1});
      final provider = BookshelfProvider();
      addTearDown(provider.dispose);
      final gate = gateRead((sql) => sql == 'books')..fail = failure;
      final loading = provider.loadBooks();
      await gate.entered.future;
      await provider.setActive(false);
      var notifications = 0;
      provider.addListener(() => notifications++);
      gate.release.complete();
      await loading;
      expect(provider.books, isEmpty);
      expect(provider.error, isNull);
      expect(notifications, 0);
      expect(provider.isLoading, isFalse);
      await provider.setActive(true);
      expect(provider.books.single.title, '测试书');
    });
  }

  test('已释放的笔记 Provider 不再执行收藏写入', () async {
    await seed();
    final provider = NotesProvider();
    await provider.loadNotes();
    final note = provider.notes.single;
    provider.dispose();
    await provider.toggleFavorite(note);
    expect((await db.getReadingItem('n0', 'note', 'b'))!['is_fav'], 0);
  });

  for (final page in ['cards', 'report']) {
    for (final failure in [false, true]) {
      testWidgets('$page 读取中快速隐藏再显示，旧${failure ? '错误' : '结果'}不能覆盖新请求',
          (tester) async {
        await tester.runAsync(() => db.insertBookmark({
              'bookmark_id': 'm',
              'book_id': 'b',
              'book_title': '测试书',
              'mark_text': '卡片原文',
              'created_at': 1
            }));
        Widget widget(bool active) => MaterialApp(
            home: page == 'cards'
                ? CardsPage(isActive: active)
                : ReportPage(isActive: active));
        var bookmarkReads = 0;
        probe.reads.clear();
        final gate = (page == 'cards'
            ? gateRead((sql) => sql == 'bookmarks' && ++bookmarkReads == 2)
            : gateReport())
          ..fail = failure;
        await tester.pumpWidget(widget(true));
        await tester.runAsync(() => gate.entered.future);
        await tester.pumpWidget(widget(false));
        await tester.pumpWidget(widget(true));
        await tester.runAsync(() async {
          gate.release.complete();
          await gate.finished.future;
        });
        await pumpUntil(
            tester,
            () =>
                find.byType(CircularProgressIndicator).evaluate().isEmpty &&
                find
                    .byWidgetPredicate(
                        (w) => w is LinearProgressIndicator && w.value == null)
                    .evaluate()
                    .isEmpty);
        expect(find.textContaining('late read failure'), findsNothing);
        final reads = probe.reads.where((r) => page == 'cards'
            ? r.sql == 'bookmarks'
            : r.sql.contains('GROUP BY month'));
        expect(reads, hasLength(page == 'cards' ? 4 : 2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('笔记翻页失败后滚动不反复重试，手动重试成功且无重复条目', (tester) async {
    await tester.runAsync(() => seed(205));
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider, child: const MaterialApp(home: NotesPage())));
    await tester.pumpAndSettle();
    probe.afterRead = (sql) {
      if (_items(sql)) throw StateError('page read failed');
    };
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await pumpUntil(tester, () => provider.error != null);
    final reads = probe.reads.length;
    for (var i = 0; i < 4; i++) {
      scroll.jumpTo(scroll.position.maxScrollExtent - 10 - i);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(probe.reads.length, reads);
    probe.afterRead = null;
    await tester.runAsync(provider.loadMore);
    expect(provider.error, isNull);
    expect(provider.notes, hasLength(200));
    expect(provider.notes.map((n) => n.id).toSet(), hasLength(200));
    await tester.pumpWidget(const SizedBox());
  });

  for (final failure in [false, true]) {
    test('下一页${failure ? '失败' : '成功'}迟到不覆盖刷新首屏，也不追加重复记录', () async {
      await seed(205);
      final provider = NotesProvider();
      addTearDown(provider.dispose);
      await provider.loadNotes();
      final gate = gateRead(_items)..fail = failure;
      final page = provider.loadMore();
      await gate.entered.future;
      await Future.wait([provider.loadMore(), provider.loadMore()]);
      await db.insertNote({
        'note_id': 'new',
        'book_id': 'b',
        'content': '新笔记',
        'created_at': 999
      });
      await provider.loadNotes();
      gate.release.complete();
      await page;
      expect(provider.error, isNull);
      expect(provider.notes.first.id, 'new');
      expect(provider.notes, hasLength(100));
      expect(provider.matchedCount, 206);
      while (provider.hasMore) {
        await provider.loadMore();
      }
      expect(provider.notes.map((n) => n.id).toSet(), hasLength(206));
      expect(provider.notes, hasLength(206));
    });
  }

  for (final stage in ['stats', 'items']) {
    for (final failure in [false, true]) {
      test('笔记 $stage 读取中销毁，迟到${failure ? '失败' : '成功'}不通知或继续分页', () async {
        await seed();
        final provider = NotesProvider();
        final gate = gateRead(stage == 'stats' ? _stats : _items)
          ..fail = failure;
        final load = provider.loadNotes();
        await gate.entered.future;
        provider.dispose();
        final reads = probe.reads.length;
        gate.release.complete();
        await load;
        expect(probe.reads.length, reads);
      });
    }
  }

  for (final page in ['cards', 'report', 'detail']) {
    for (final failure in [false, true]) {
      testWidgets('$page 加载中销毁，迟到${failure ? '错误' : '结果'}和同步事件不再访问页面',
          (tester) async {
        await tester.runAsync(() => seed());
        final gate = (page == 'report'
            ? gateReport()
            : gateRead(page == 'cards' ? (sql) => sql == 'bookmarks' : _items))
          ..fail = failure;
        final Widget home = page == 'cards'
            ? const CardsPage()
            : page == 'report'
                ? const ReportPage()
                : BookDetailPage(book: Book(bookId: 'b', title: '测试书'));
        await tester.pumpWidget(MaterialApp(home: home));
        await tester.runAsync(() => gate.entered.future);
        await tester.pumpWidget(const SizedBox());
        final reads = probe.reads.length;
        await tester.runAsync(() async {
          gate.release.complete();
          await gate.finished.future;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          SyncService.changes.publish(db);
        });
        await tester.pumpAndSettle();
        expect(probe.reads.length, reads);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('详情局部收藏刷新中销毁，停止后续条目与计数查询', (tester) async {
    await tester.runAsync(() => seed(2));
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
    await pumpUntil(tester, () => find.text('2条').evaluate().isNotEmpty);
    final gate = (await tester.runAsync(
        () async => gateRead((sql) => sql.contains('WHERE id = ?'))))!;
    await tester.runAsync(() async {
      SyncService.changes.publish(db,
          favoritesOnly: true,
          itemIds: {'note:n0', 'note:n1'},
          sources: {'note'},
          bookIds: {'b'});
      await gate.entered.future;
    });
    await tester.pumpWidget(const SizedBox());
    final reads = probe.reads.length;
    await tester.runAsync(() async {
      gate.release.complete();
      await gate.finished.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(probe.reads.length, reads);
    expect(tester.takeException(), isNull);
  });

  testWidgets('笔记页销毁后旧收藏回调不写库或触发 setState', (tester) async {
    await tester.runAsync(() => seed());
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider, child: const MaterialApp(home: NotesPage())));
    await tester.pumpAndSettle();
    final favorite = find
        .ancestor(
            of: find.byIcon(Icons.star_border_rounded),
            matching: find.byType(GestureDetector))
        .first;
    final callback = tester.widget<GestureDetector>(favorite).onTap!;
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      callback();
    });
    expect(tester.takeException(), isNull);
    expect(
        (await tester
            .runAsync(() => db.getReadingItem('n0', 'note', 'b')))!['is_fav'],
        0);
  });

  for (final page in ['notes', 'cards']) {
    testWidgets('$page 搜索防抖中切走并回来，仅执行最后一次搜索', (tester) async {
      await tester.runAsync(() async {
        await seed();
        await db.insertBookmark({
          'bookmark_id': 'm',
          'book_id': 'b',
          'mark_text': '目标引文',
          'created_at': 1
        });
      });
      final provider = NotesProvider();
      addTearDown(provider.dispose);
      Widget widget(bool active) => ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
              home: page == 'notes'
                  ? NotesPage(isActive: active)
                  : CardsPage(isActive: active)));
      await tester.pumpWidget(widget(true));
      await pumpUntil(tester,
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
      await tester.enterText(find.byType(TextField), '目标');
      await tester.pumpWidget(widget(false));
      final reads = probe.reads.length;
      await tester.pump(const Duration(seconds: 1));
      expect(probe.reads.length, reads);
      await tester.pumpWidget(widget(true));
      await pumpUntil(
          tester,
          () =>
              !provider.isLoading &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty);
      final settled = probe.reads.length;
      await tester.pump(const Duration(seconds: 1));
      expect(probe.reads.length, settled);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
