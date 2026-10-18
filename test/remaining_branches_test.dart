import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/ai_summary_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';
import 'package:weread_companion/services/export_snapshot.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  Future<void> Function()? onTemporary;
  Future<void> Function()? onDocuments;
  int temporaryCalls = 0;
  @override
  Future<String?> getTemporaryPath() async {
    temporaryCalls++;
    await onTemporary?.call();
    return path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    await onDocuments?.call();
    return path;
  }
}

class _Factory extends ObservedFactory {
  _Factory(super.delegate, super.probe);
  Future<void> Function()? beforeReaderOpen;
  bool failReaderOpen = false;
  final readers = <Database>[];
  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    if (options?.readOnly == true) {
      await beforeReaderOpen?.call();
      if (failReaderOpen) throw StateError('snapshot reader open failed');
    }
    final result = await super.openDatabase(path, options: options);
    if (options?.readOnly == true) readers.add(result);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory directory;
  late DatabaseService db;
  late _Factory factory;
  late DatabaseProbe probe;
  late PathProviderPlatform originalPaths;
  late _Paths paths;
  var shares = 0;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-remaining-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = factory = _Factory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.insertNote({
      'note_id': 'n',
      'book_id': 'b',
      'book_title': '测试书',
      'content': '测试笔记',
      'created_at': 1
    });
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = paths = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    shares = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(share, (_) async {
      shares++;
      return null;
    });
    messenger.setMockMethodCallHandler(secure, (_) async => null);
  });
  tearDown(() async {
    probe.beforeExecute = null;
    probe.afterRead = null;
    paths.onTemporary = null;
    paths.onDocuments = null;
    factory.beforeReaderOpen = null;
    await DatabaseService.endSession();
    for (final reader in factory.readers) {
      if (reader.isOpen) await reader.close();
    }
    await ExportService.clearLocalExports();
    PathProviderPlatform.instance = originalPaths;
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(share, null);
    messenger.setMockMethodCallHandler(secure, null);
  });

  Future<void> notesPage(WidgetTester tester) async {
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    await tester.pumpWidget(ChangeNotifierProvider<NotesProvider>.value(
        value: provider, child: const MaterialApp(home: NotesPage())));
    await tester.pumpAndSettle();
  }

  test('快照 DETACH 失败后，下一次导出先释放残留挂载并恢复', () async {
    probe.beforeExecute = (sql) {
      if (sql.startsWith('DETACH')) throw StateError('detach failed');
    };
    await expectLater(ExportSnapshot.capture(db, '${directory.path}/one.db'),
        throwsStateError);
    probe.beforeExecute = null;
    final snapshot =
        await ExportSnapshot.capture(db, '${directory.path}/two.db');
    expect((await snapshot.readPage()).single['content'], '测试笔记');
    await snapshot.close();
    final attached = await (await db.database).rawQuery('PRAGMA database_list');
    expect(attached.where((row) => row['name'] == 'weread_export_snapshot'),
        isEmpty);
  });

  test('导出失败留下挂载时，清理先解除挂载再删除临时目录', () async {
    probe.beforeExecute = (sql) {
      if (sql.startsWith('DETACH')) throw StateError('detach failed');
    };
    await expectLater(ExportService.exportToMarkdown(), throwsA(anything));
    probe.beforeExecute = null;
    await ExportService.clearLocalExports();
    final attached = await (await db.database).rawQuery('PRAGMA database_list');
    expect(attached.where((row) => row['name'] == 'weread_export_snapshot'),
        isEmpty);
    expect(
        await directory
            .list()
            .where((e) => e.path.contains('.weread-export-'))
            .toList(),
        isEmpty);
  });

  test('快照首次打开失败后可以重新读取，不永久缓存失败任务', () async {
    final snapshot =
        await ExportSnapshot.capture(db, '${directory.path}/read.db');
    factory.failReaderOpen = true;
    await expectLater(snapshot.readPage(), throwsStateError);
    factory.failReaderOpen = false;
    expect((await snapshot.readPage()).single['content'], '测试笔记');
    await snapshot.close();
  });

  testWidgets('笔记页连续导出仅启动一个任务，完成后恢复入口', (tester) async {
    await notesPage(tester);
    final release = Completer<void>();
    paths.onTemporary = () => release.future;
    final button =
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '导出笔记');
    final callback = tester.widget<IconButton>(button).onPressed!;
    await tester.runAsync(() async {
      callback();
      callback();
    });
    await tester.pump();
    final started = paths.temporaryCalls;
    release.complete();
    await pumpUntil(tester, () => shares >= started);
    expect(started, 1);
    expect(shares, 1);
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final failure in [false, true]) {
    testWidgets('笔记摘要准备期间换号，旧查询${failure ? "失败" : "成功"}不显示过期结果',
        (tester) async {
      await notesPage(tester);
      final entered = Completer<void>();
      final release = Completer<void>();
      probe.afterRead = (sql) async {
        if (sql.contains('trim(content,')) {
          entered.complete();
          await release.future;
          if (failure) throw StateError('stale summary read failure');
        }
      };
      await tester.tap(find.byTooltip('AI 摘要'));
      await tester.runAsync(() => entered.future);
      await tester.runAsync(() => DatabaseService.selectAccount('456'));
      release.complete();
      await pumpUntil(
          tester,
          () =>
              tester
                  .widget<IconButton>(find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == 'AI 摘要'))
                  .onPressed !=
              null);
      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('详情收藏局部刷新失败后重试，重新加载已有条目和收藏计数', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
    await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('favorite-note:n'))
            .evaluate()
            .isNotEmpty);
    await tester.runAsync(() => db.toggleFavorite('n', true));
    var failed = false;
    probe.afterRead = (sql) {
      if (sql.contains('WHERE id = ? AND source = ?')) {
        failed = true;
        throw StateError('favorite read failed');
      }
    };
    SyncService.changes.publish(db, favoritesOnly: true, itemIds: {'note:n'});
    await pumpUntil(tester, () => failed);
    probe.afterRead = null;
    await tester.scrollUntilVisible(find.text('重试'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('重试'));
    await pumpUntil(tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('0条'), findsNothing);
    expect(find.text('1条'), findsNWidgets(2));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('favorite-note:n')),
            matching: find.byIcon(Icons.star_rounded)),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('残留挂载连续清理失败不再次 ATTACH，恢复后排队导出均成功', () async {
    var attaches = 0;
    var fail = true;
    probe.beforeExecute = (sql) {
      if (sql.startsWith('ATTACH')) attaches++;
      if (sql.startsWith('DETACH') && fail) {
        throw StateError('detach unavailable');
      }
    };
    await expectLater(ExportSnapshot.capture(db, '${directory.path}/first.db'),
        throwsStateError);
    await expectLater(ExportSnapshot.capture(db, '${directory.path}/second.db'),
        throwsStateError);
    await expectLater(ExportService.clearLocalExports(), throwsStateError);
    expect(attaches, 1);
    fail = false;
    final snapshots = await Future.wait(List.generate(
        3, (i) => ExportSnapshot.capture(db, '${directory.path}/retry$i.db')));
    expect(attaches, 4);
    for (final snapshot in snapshots) {
      expect(await snapshot.readPage(), hasLength(1));
      await snapshot.close();
    }
  });

  test('解除挂载清理等待正在生成的快照，不在事务中途 DETACH', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var detaches = 0;
    probe.beforeExecute = (sql) async {
      if (sql.contains('CREATE TABLE weread_export_snapshot.entries')) {
        entered.complete();
        await release.future;
      }
      if (sql.startsWith('DETACH')) detaches++;
    };
    final capture = ExportSnapshot.capture(db, '${directory.path}/queued.db');
    await entered.future;
    var cleaned = false;
    final cleanup =
        ExportSnapshot.releaseAttachments().then((_) => cleaned = true);
    await Future<void>.delayed(Duration.zero);
    expect(cleaned, isFalse);
    expect(detaches, 0);
    release.complete();
    final snapshot = await capture;
    await cleanup;
    expect(detaches, 1);
    expect(await snapshot.readPage(), hasLength(1));
    await snapshot.close();
  });

  test('快照事务中退出使当前和排队捕获失效，新的账号仍可导出', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    probe.beforeExecute = (sql) async {
      if (sql.contains('CREATE TABLE weread_export_snapshot.entries')) {
        entered.complete();
        await release.future;
      }
    };
    final first = expectLater(
        ExportSnapshot.capture(db, '${directory.path}/old1.db'),
        throwsA(anything));
    await entered.future;
    final second = expectLater(
        ExportSnapshot.capture(db, '${directory.path}/old2.db'),
        throwsStateError);
    final closing = DatabaseService.endSession();
    release.complete();
    await Future.wait([first, second, closing]);
    probe.beforeExecute = null;
    await DatabaseService.selectAccount('456');
    final next = DatabaseService.instance;
    await next.insertNote(
        {'note_id': 'n', 'book_id': 'b', 'content': '新账号内容', 'created_at': 1});
    final snapshot =
        await ExportSnapshot.capture(next, '${directory.path}/new.db');
    expect((await snapshot.readPage()).single['content'], '新账号内容');
    await snapshot.close();
  });

  for (final failOpen in [false, true]) {
    test('快照读连接打开期间关闭，${failOpen ? '打开失败也完成清理' : '迟到连接关闭且不读取数据'}', () async {
      final snapshot =
          await ExportSnapshot.capture(db, '${directory.path}/opening.db');
      final entered = Completer<void>();
      final release = Completer<void>();
      factory.beforeReaderOpen = () async {
        entered.complete();
        await release.future;
      };
      factory.failReaderOpen = failOpen;
      final read = expectLater(snapshot.readPage(), throwsStateError);
      await entered.future;
      final close = snapshot.close();
      release.complete();
      await Future.wait([read, close]);
      expect(factory.readers.every((reader) => !reader.isOpen), isTrue);
      expect(probe.reads.where((r) => r.sql.contains('FROM entries AS e')),
          isEmpty);
      await snapshot.close();
      await expectLater(snapshot.readPage(), throwsStateError);
    });
  }

  test('读取临时目录期间退出，不创建快照或发布文件', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    paths.onTemporary = () async {
      entered.complete();
      await release.future;
    };
    final export =
        expectLater(ExportService.exportToMarkdown(), throwsStateError);
    await entered.future;
    await DatabaseService.endSession();
    release.complete();
    await export;
    expect(
        await directory
            .list()
            .where((e) =>
                e.path.contains('.weread-export-') || e.path.endsWith('.md'))
            .toList(),
        isEmpty);
  });

  testWidgets('笔记导出失败后恢复按钮，立即重试只导出一次', (tester) async {
    await notesPage(tester);
    var fail = true;
    paths.onDocuments = () async {
      if (fail) throw StateError('directory unavailable');
    };
    final button =
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '导出笔记');
    final callback = tester.widget<IconButton>(button).onPressed!;
    await tester.runAsync(() async {
      callback();
    });
    await pumpUntil(
        tester, () => find.textContaining('导出失败:').evaluate().isNotEmpty);
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    expect(shares, 0);
    fail = false;
    await tester.runAsync(() async {
      callback();
      callback();
    });
    await pumpUntil(tester, () => shares == 1);
    expect(paths.temporaryCalls, 2);
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final detail in [false, true]) {
    testWidgets('${detail ? '详情' : '笔记'}摘要准备失败可立即重试，重复点击不重复查询', (tester) async {
      if (detail) {
        await tester.pumpWidget(MaterialApp(
            home: BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
        await pumpUntil(
            tester,
            () => find
                .byKey(const ValueKey('favorite-note:n'))
                .evaluate()
                .isNotEmpty);
      } else {
        await notesPage(tester);
      }
      var reads = 0;
      var fail = true;
      probe.afterRead = (sql) {
        if (sql.contains('trim(content,')) {
          reads++;
          if (fail) throw StateError('summary read failed');
        }
      };
      final button = find
          .byWidgetPredicate((w) => w is IconButton && w.tooltip == 'AI 摘要');
      final callback = tester.widget<IconButton>(button).onPressed!;
      callback();
      callback();
      await pumpUntil(
          tester, () => find.textContaining('摘要准备失败:').evaluate().isNotEmpty);
      expect(reads, 1);
      fail = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      callback();
      callback();
      await pumpUntil(
          tester, () => find.text('请先在设置中配置 AI API').evaluate().isNotEmpty);
      expect(reads, 2);
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('历史摘要列表读取失败后重试可恢复并打开摘要', (tester) async {
    await db.saveSummary(
        AISummary(createdAt: 1, title: '已保存摘要', text: '摘要内容', references: []));
    var fail = true;
    probe.afterRead = (sql) {
      if (sql == 'ai_summaries' && fail) throw StateError('metadata failed');
    };
    await tester.pumpWidget(const MaterialApp(home: AISummaryHistoryPage()));
    await pumpUntil(
        tester, () => find.textContaining('历史摘要加载失败:').evaluate().isNotEmpty);
    fail = false;
    await tester.tap(find.textContaining('历史摘要加载失败:'));
    await pumpUntil(tester, () => find.text('已保存摘要').evaluate().isNotEmpty);
    await tester.tap(find.text('已保存摘要'));
    await pumpUntil(
        tester, () => find.text('已保存摘要 · AI 摘要').evaluate().isNotEmpty);
    expect(find.text('摘要内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reference in [false, true]) {
    testWidgets('${reference ? '原笔记' : '详情'}划线收藏写入失败可重试，不会重复写入',
        (tester) async {
      await tester.runAsync(() => db.insertBookmark({
            'bookmark_id': 'm',
            'book_id': 'b',
            'book_title': '测试书',
            'mark_text': '划线内容',
            'created_at': 2
          }));
      final connection = await db.database;
      await tester.runAsync(() => connection.execute(
          "CREATE TEMP TRIGGER fail_fav BEFORE UPDATE OF is_fav ON bookmarks BEGIN SELECT RAISE(ABORT, 'favorite failed'); END"));
      final ref = SummaryReference(
          label: 'R1',
          noteId: 'm',
          bookId: 'b',
          bookTitle: '测试书',
          chapterTitle: '',
          source: NoteSource.bookmark,
          content: '划线内容');
      await tester.pumpWidget(MaterialApp(
          home: reference
              ? NotesPage(reference: ref)
              : BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
      await pumpUntil(tester, () => find.text('划线内容').evaluate().isNotEmpty);
      final callback = reference
          ? tester
              .widget<GestureDetector>(find
                  .ancestor(
                      of: find.byIcon(Icons.star_border_rounded),
                      matching: find.byType(GestureDetector))
                  .first)
              .onTap!
          : tester
              .widget<IconButton>(
                  find.byKey(const ValueKey('favorite-bookmark:m')))
              .onPressed!;
      callback();
      callback();
      await pumpUntil(
          tester, () => find.textContaining('收藏保存失败').evaluate().isNotEmpty);
      var row =
          await tester.runAsync(() => db.getReadingItem('m', 'bookmark', 'b'));
      expect(row!['is_fav'], 0);
      await tester.runAsync(() => connection.execute('DROP TRIGGER fail_fav'));
      var writes = 0;
      probe.afterUpdate = (table) {
        if (table == 'bookmarks') writes++;
      };
      callback();
      callback();
      await pumpUntil(
          tester,
          () =>
              find.byIcon(Icons.star_rounded).evaluate().length >
              (reference ? 0 : 1));
      row =
          await tester.runAsync(() => db.getReadingItem('m', 'bookmark', 'b'));
      expect(row!['is_fav'], 1);
      expect(writes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('引用原笔记已删除时显示缺失提示，不提供收藏操作', (tester) async {
    final ref = SummaryReference(
        label: 'R1',
        noteId: 'missing',
        bookId: 'b',
        bookTitle: '测试书',
        chapterTitle: '',
        source: NoteSource.note,
        content: '旧内容');
    await tester.pumpWidget(MaterialApp(home: NotesPage(reference: ref)));
    await pumpUntil(
        tester, () => find.textContaining('原笔记已不存在').evaluate().isNotEmpty);
    expect(find.byIcon(Icons.star_border_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情旧收藏查询迟到失败不能覆盖新一次成功刷新', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(book: Book(bookId: 'b', title: '测试书'))));
    final favorite = find.byKey(const ValueKey('favorite-note:n'));
    await pumpUntil(tester, () => favorite.evaluate().isNotEmpty);
    final entered = Completer<void>();
    final release = Completer<void>();
    var first = true;
    probe.afterRead = (sql) async {
      if (sql.contains('WHERE id = ? AND source = ?') && first) {
        first = false;
        entered.complete();
        await release.future;
        throw StateError('stale favorite failure');
      }
    };
    SyncService.changes.publish(db, favoritesOnly: true, itemIds: {'note:n'});
    await tester.runAsync(() => entered.future);
    await tester.runAsync(() => db.toggleFavorite('n', true));
    SyncService.changes.publish(db, favoritesOnly: true, itemIds: {'note:n'});
    await pumpUntil(
        tester,
        () => find
            .descendant(of: favorite, matching: find.byIcon(Icons.star_rounded))
            .evaluate()
            .isNotEmpty);
    release.complete();
    await tester.pumpAndSettle();
    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(1000);
    await tester.pumpAndSettle();
    expect(find.textContaining('stale favorite failure'), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
