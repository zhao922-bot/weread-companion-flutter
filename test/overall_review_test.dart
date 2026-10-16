import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/models/note_item.dart';
import 'package:weread_companion/pages/ai_summary_page.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';
import 'package:weread_companion/services/export_snapshot.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'support/observed_database.dart';
import 'support/wait_until.dart';
import 'sync_database_regression_test.dart' show LegacyDatabase;

class _SnapshotDatabase extends LegacyDatabase {
  _SnapshotDatabase(Database db, this.owner) : super(db, '3.40.0');
  final _ExportFactory owner;
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
    await owner.beforeSnapshotClose?.call();
    if (owner.failSnapshotClose) throw StateError('snapshot close failed');
    await super.close();
  }
}

class _ExportFactory extends ObservedFactory {
  _ExportFactory(DatabaseFactory db) : super(db, DatabaseProbe());
  bool failSnapshotClose = false;
  Future<void> Function()? beforeSnapshotClose;
  final readers = <_SnapshotDatabase>[];
  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    final db = await super.openDatabase(path, options: options);
    if (options?.readOnly != true) return db;
    final reader = _SnapshotDatabase(db, this);
    readers.add(reader);
    return reader;
  }
}

class _RecordingAI extends AIService {
  _RecordingAI(AppConfig config, this.onCall, {this.result})
      : super(config: config);
  final void Function() onCall;
  final Future<AISummary>? result;
  @override
  Future<AISummary> summarizeBook(
      String title, String author, List<NoteItem> notes) async {
    onCall();
    if (result != null) return result!;
    return AISummary(createdAt: 1, title: title, text: '迟到摘要', references: []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory directory;
  late DatabaseService db;
  late _ExportFactory factory;
  Future<void> Function()? beforeSecret;
  final note = NoteItem(
      id: 'same',
      bookId: 'b',
      bookTitle: '旧书',
      content: '旧账号原文',
      chapterTitle: '章节',
      createdAt: 1,
      isFav: false,
      source: NoteSource.note);
  AISummary summary(String title) => AISummary(
      createdAt: 1,
      title: title,
      text: '$title观点 [R1]',
      references: [SummaryReference.fromNote(note, 0)]);
  Future<void> seed(DatabaseService database, String text) =>
      database.insertNote({
        'note_id': 'same',
        'book_id': 'b',
        'book_title': text,
        'content': text,
        'chapter_title': '章节',
        'created_at': 1,
      });
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-overall-review-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    factory = _ExportFactory(databaseFactoryFfiNoIsolate);
    databaseFactory = factory;
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await seed(db, '旧账号原文');
    SharedPreferences.setMockInitialValues({});
    beforeSecret = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'read' && call.arguments['key'] == 'weread_api_key') {
        await beforeSecret?.call();
        return 'test-key';
      }
      return null;
    });
  });
  tearDown(() async {
    AIService.cancelAll();
    factory.failSnapshotClose = false;
    factory.beforeSnapshotClose = null;
    await DatabaseService.endSession();
    await ExportService.clearLocalExports();
    for (final reader in factory.readers) {
      await reader.delegate.close();
    }
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(share, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Future<DatabaseService> switchAccount() async {
    await DatabaseService.selectAccount('456');
    final next = DatabaseService.instance;
    await seed(next, '新账号原文');
    return next;
  }

  for (final reference in [false, true]) {
    testWidgets('${reference ? '引用原笔记' : '详情页'}换号后旧收藏回调不能写入新账号',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: reference
              ? NotesPage(reference: SummaryReference.fromNote(note, 0))
              : BookDetailPage(book: Book(bookId: 'b', title: '旧书'))));
      await pumpUntil(tester,
          () => find.byIcon(Icons.star_border_rounded).evaluate().isNotEmpty);
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
                  find.widgetWithIcon(IconButton, Icons.star_border_rounded))
              .onPressed!;
      final next = (await tester.runAsync(switchAccount))!;
      callback();
      await tester.pumpAndSettle();
      final row =
          await tester.runAsync(() => next.getReadingItem('same', 'note', 'b'));
      expect(row!['is_fav'], 0);
      expect(find.text('旧账号原文'), findsNothing);
      expect(find.textContaining('账号会话已结束'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('历史摘要换号后旧条目不能打开新账号同 ID 的摘要', (tester) async {
    await db.saveSummary(summary('旧摘要'));
    await tester.pumpWidget(const MaterialApp(home: AISummaryHistoryPage()));
    await pumpUntil(tester, () => find.text('旧摘要').evaluate().isNotEmpty);
    final callback =
        tester.widget<ListTile>(find.widgetWithText(ListTile, '旧摘要')).onTap!;
    await tester.runAsync(() async {
      final next = await switchAccount();
      await next.saveSummary(summary('新摘要'));
    });
    callback();
    await tester.pumpAndSettle();
    expect(find.text('新摘要 · AI 摘要'), findsNothing);
    expect(find.text('旧摘要'), findsNothing);
    expect(find.textContaining('账号会话已结束'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AI 摘要页面在会话结束后隐藏旧内容及复制入口', (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: AISummaryPage(summary: summary('旧摘要'))));
    await tester.runAsync(DatabaseService.endSession);
    await tester.pumpAndSettle();
    expect(find.byTooltip('复制摘要'), findsNothing);
    expect(find.textContaining('账号会话已结束'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AI 配置加载期间换号，不向服务发送旧账号笔记', (tester) async {
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeSecret = () async {
      entered.complete();
      await release.future;
    };
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => generateSummary(
                          context, '旧书', '', [note],
                          serviceFactory: (config) =>
                              _RecordingAI(config, () => calls++)),
                      child: const Text('生成')),
                ))));
    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(entered.isCompleted, isTrue);
    await tester.runAsync(switchAccount);
    release.complete();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('旧书 · AI 摘要'), findsNothing);
    expect(find.text('AI 正在生成摘要...'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('导出快照关闭失败后可以重试关闭', () async {
    final snapshot =
        await ExportSnapshot.capture(db, '${directory.path}/snapshot.db');
    await snapshot.readPage();
    factory.failSnapshotClose = true;
    await expectLater(snapshot.close(), throwsStateError);
    factory.failSnapshotClose = false;
    await snapshot.close();
    expect(factory.readers.single.closes, 2);
    expect(factory.readers.single.isOpen, isFalse);
  });

  test('导出结束时关闭快照失败，退出清理仍能重新关闭遗留读连接', () async {
    factory.failSnapshotClose = true;
    await expectLater(ExportService.exportToMarkdown(), throwsA(anything));
    factory.failSnapshotClose = false;
    await ExportService.clearLocalExports();
    expect(factory.readers.single.closes, 2);
    expect(factory.readers.single.isOpen, isFalse);
    expect(
        await directory
            .list()
            .where((e) => e.path.contains('.weread-export-'))
            .toList(),
        isEmpty);
  });

  for (final page in ['详情', '引用', '摘要', '历史']) {
    testWidgets('$page 路由延迟创建时仍绑定原账号，同账号重新登录也不能复用旧页面', (tester) async {
      final owner = db;
      await tester.runAsync(() => DatabaseService.selectAccount('123'));
      final reads = factory.probe.reads.length;
      final Widget child = switch (page) {
        '详情' =>
          BookDetailPage(book: Book(bookId: 'b', title: '旧书'), database: owner),
        '引用' => NotesPage(
            reference: SummaryReference.fromNote(note, 0), database: owner),
        '摘要' => AISummaryPage(summary: summary('旧摘要'), database: owner),
        _ => AISummaryHistoryPage(database: owner),
      };
      await tester.pumpWidget(MaterialApp(home: child));
      await tester.pumpAndSettle();
      expect(find.textContaining('账号会话已结束'), findsOneWidget);
      expect(factory.probe.reads.length, reads);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('原笔记忽略无关同步和收藏事件，只为匹配条目重查一次', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: NotesPage(reference: SummaryReference.fromNote(note, 0))));
    await pumpUntil(tester,
        () => find.byIcon(Icons.star_border_rounded).evaluate().isNotEmpty);
    factory.probe.reads.clear();
    SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf);
    SyncService.changes.publish(db, bookIds: {'another'});
    SyncService.changes.publish(db, sources: {'bookmark'});
    SyncService.changes
        .publish(db, favoritesOnly: true, itemIds: {'note:another'});
    await tester.pumpAndSettle();
    expect(factory.probe.reads, isEmpty);
    await tester.runAsync(() => db.toggleFavorite('same', true));
    SyncService.changes
        .publish(db, favoritesOnly: true, itemIds: {'note:same'});
    await pumpUntil(
        tester, () => find.byIcon(Icons.star_rounded).evaluate().isNotEmpty);
    expect(factory.probe.reads.length, 1);
    final next = (await tester.runAsync(switchAccount))!;
    factory.probe.reads.clear();
    SyncService.changes.publish(next);
    await tester.pumpAndSettle();
    expect(factory.probe.reads, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in ['笔记复制', '摘要复制', '分享']) {
    testWidgets('$action 平台失败提示可重试，换号后旧回调不再访问平台', (tester) async {
      var fail = true;
      var calls = 0;
      String? output;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          action == '分享' ? share : SystemChannels.platform, (call) async {
        if (call.method == 'share' || call.method == 'Clipboard.setData') {
          calls++;
          if (fail) throw PlatformException(code: 'unavailable');
          output = call.arguments['text'];
        }
        return null;
      });
      await tester.pumpWidget(MaterialApp(
          home: action == '摘要复制'
              ? AISummaryPage(summary: summary('旧摘要'))
              : BookDetailPage(book: Book(bookId: 'b', title: '旧书'))));
      final tooltip = action == '摘要复制'
          ? '复制摘要'
          : action == '笔记复制'
              ? '复制笔记'
              : '分享';
      final button = find
          .byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);
      await pumpUntil(tester, () => button.evaluate().isNotEmpty);
      final callback = tester.widget<IconButton>(button).onPressed!;
      callback();
      await tester.pumpAndSettle();
      expect(
          find.text(action == '分享' ? '分享失败，请重试' : '复制失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      fail = false;
      callback();
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(
          output,
          contains(action == '摘要复制'
              ? '旧摘要观点'
              : action == '笔记复制'
                  ? '旧账号原文'
                  : '旧书'));
      await tester.runAsync(switchAccount);
      callback();
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final fail in [false, true]) {
    testWidgets('AI 请求期间换号，迟到${fail ? '失败' : '成功'}不弹出旧摘要或错误提示', (tester) async {
      final result = Completer<AISummary>();
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => generateSummary(
                            context, '旧书', '', [note],
                            serviceFactory: (config) => _RecordingAI(
                                config, () => calls++,
                                result: result.future)),
                        child: const Text('生成')),
                  ))));
      await tester.tap(find.text('生成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
      await tester.runAsync(switchAccount);
      if (fail) {
        result.completeError(StateError('旧请求失败'));
      } else {
        result.complete(summary('旧摘要'));
      }
      await tester.pumpAndSettle();
      expect(find.text('AI 正在生成摘要...'), findsNothing);
      expect(find.text('旧摘要 · AI 摘要'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('历史摘要连续点击只加载一次，失败和返回后均可立即重试', (tester) async {
    await db.saveSummary(summary('旧摘要'));
    await tester.pumpWidget(const MaterialApp(home: AISummaryHistoryPage()));
    await pumpUntil(tester, () => find.text('旧摘要').evaluate().isNotEmpty);
    final callback =
        tester.widget<ListTile>(find.widgetWithText(ListTile, '旧摘要')).onTap!;
    var reads = 0;
    var fail = true;
    factory.probe.afterRead = (sql) {
      if (sql != 'ai_summaries') return;
      reads++;
      if (fail) throw StateError('摘要读取失败');
    };
    callback();
    callback();
    await pumpUntil(
        tester, () => find.textContaining('摘要加载失败:').evaluate().isNotEmpty);
    expect(reads, 1);
    fail = false;
    callback();
    callback();
    await pumpUntil(
        tester, () => find.text('旧摘要 · AI 摘要').evaluate().isNotEmpty);
    expect(reads, 2);
    callback();
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.pageBack();
    await tester.pumpAndSettle();
    callback();
    await pumpUntil(
        tester, () => find.text('旧摘要 · AI 摘要').evaluate().isNotEmpty);
    expect(reads, 3);
    await tester.pumpWidget(const SizedBox());
  });

  test('导出快照并发关闭共享一次失败，恢复后仍只关闭一次', () async {
    final snapshot =
        await ExportSnapshot.capture(db, '${directory.path}/snapshot.db');
    await snapshot.readPage();
    final entered = Completer<void>();
    final release = Completer<void>();
    factory.beforeSnapshotClose = () async {
      entered.complete();
      await release.future;
    };
    factory.failSnapshotClose = true;
    final first = snapshot.close();
    final second = snapshot.close();
    final failures = Future.wait([
      expectLater(first, throwsStateError),
      expectLater(second, throwsStateError)
    ]);
    await entered.future;
    expect(factory.readers.single.closes, 1);
    await expectLater(snapshot.readPage(), throwsStateError);
    release.complete();
    await failures;
    factory.beforeSnapshotClose = null;
    factory.failSnapshotClose = false;
    await Future.wait([snapshot.close(), snapshot.close()]);
    await snapshot.close();
    expect(factory.readers.single.closes, 2);
    expect(factory.readers.single.isOpen, isFalse);
  });

  test('导出关闭和随后两次退出清理都失败，第三次清理仍能回收句柄', () async {
    factory.failSnapshotClose = true;
    await expectLater(ExportService.exportToMarkdown(), throwsA(anything));
    for (var i = 0; i < 2; i++) {
      await expectLater(ExportService.clearLocalExports(), throwsStateError);
    }
    factory.failSnapshotClose = false;
    await ExportService.clearLocalExports();
    expect(factory.readers.single.closes, 4);
    expect(factory.readers.single.isOpen, isFalse);
    expect(
        await directory
            .list()
            .where((e) => e.path.contains('.weread-export-'))
            .toList(),
        isEmpty);
    await ExportService.clearLocalExports();
    expect(factory.readers.single.closes, 4);
  });

  testWidgets('原笔记读取失败可重试，收藏后原位更新且不触发异步 setState 断言', (tester) async {
    var fail = true;
    factory.probe.afterRead = (sql) {
      if (fail) throw StateError('原笔记读取失败');
    };
    await tester.pumpWidget(MaterialApp(
        home: NotesPage(reference: SummaryReference.fromNote(note, 0))));
    await pumpUntil(tester, () => find.text('原笔记加载失败').evaluate().isNotEmpty);
    fail = false;
    await tester.tap(find.text('重试'));
    await pumpUntil(tester,
        () => find.byIcon(Icons.star_border_rounded).evaluate().isNotEmpty);
    await tester.tap(find.byIcon(Icons.star_border_rounded));
    await pumpUntil(
        tester, () => find.byIcon(Icons.star_rounded).evaluate().isNotEmpty);
    final row =
        await tester.runAsync(() => db.getReadingItem('same', 'note', 'b'));
    expect(row!['is_fav'], 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情页失效后忽略新账号的同步及收藏通知，不再查询数据库', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: BookDetailPage(book: Book(bookId: 'b', title: '旧书'))));
    await pumpUntil(tester,
        () => find.byIcon(Icons.star_border_rounded).evaluate().isNotEmpty);
    final next = (await tester.runAsync(switchAccount))!;
    factory.probe.reads.clear();
    SyncService.changes.publish(next);
    SyncService.changes
        .publish(next, favoritesOnly: true, itemIds: {'note:same'});
    await tester.pumpAndSettle();
    expect(factory.probe.reads, isEmpty);
    expect(find.textContaining('账号会话已结束'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('历史摘要读取期间换号，迟到结果不打开页面', (tester) async {
    await db.saveSummary(summary('旧摘要'));
    await tester.pumpWidget(const MaterialApp(home: AISummaryHistoryPage()));
    await pumpUntil(tester, () => find.text('旧摘要').evaluate().isNotEmpty);
    final entered = Completer<void>();
    final release = Completer<void>();
    factory.probe.afterRead = (sql) async {
      if (sql == 'ai_summaries') {
        entered.complete();
        await release.future;
      }
    };
    await tester.tap(find.text('旧摘要'));
    await tester.runAsync(() => entered.future);
    await tester.runAsync(switchAccount);
    release.complete();
    await tester.pumpAndSettle();
    expect(find.text('旧摘要 · AI 摘要'), findsNothing);
    expect(find.textContaining('账号会话已结束'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('摘要页面退出前捕获的引用回调不能在换号后访问同 ID 原笔记', (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: AISummaryPage(summary: summary('旧摘要'))));
    final callback = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '[R1]'))
        .onPressed!;
    await tester.runAsync(switchAccount);
    factory.probe.reads.clear();
    callback();
    await tester.pumpAndSettle();
    expect(factory.probe.reads, isEmpty);
    expect(find.text('原笔记'), findsNothing);
    expect(find.textContaining('账号会话已结束'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('会话已退出时触发摘要入口，不读取配置或创建 AI 请求', (tester) async {
    await tester.runAsync(DatabaseService.endSession);
    var created = 0;
    var secretReads = 0;
    beforeSecret = () async {
      secretReads++;
    };
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () =>
                          generateSummary(context, '旧书', '', [note],
                              serviceFactory: (config) {
                            created++;
                            return _RecordingAI(config, () {});
                          }),
                      child: const Text('生成')),
                ))));
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();
    expect(secretReads, 0);
    expect(created, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
