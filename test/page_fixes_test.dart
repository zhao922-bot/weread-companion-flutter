import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/ai_summary_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  setUpAll(() {
    sqfliteFfiInit();
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('page-fixes-');
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });
  Future<void> seed(int count) => db.insertNotes(List.generate(count, (i) => {
    'note_id': 'n$i', 'book_id': 'b', 'book_title': '书',
    'content': '笔记$i ${List.filled(100, '文').join()}',
    'created_at': i, 'is_fav': 1,
  }));

  test('notes筛选忽略无关列表刷新但更新划线及书架全局统计', () async {
    await seed(2);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    provider.setFilter(ReadingFilter.notes);
    await provider.loadNotes();
    final list = provider.notes;
    var loadingNotifications = 0;
    provider.addListener(() { if (provider.isLoading) loadingNotifications++; });
    await db.insertBookmark({'bookmark_id': 'bm', 'book_id': 'b',
      'mark_text': '划线', 'created_at': 3, 'is_fav': 1});
    SyncService.changes.publish(db, kind: SyncChangeKind.items,
      bookIds: {'b'}, itemIds: {'bookmark:bm'}, sources: {'bookmark'});
    await waitUntil(() => provider.totalCount == 3);
    expect(provider.bookmarkCount, 1);
    expect(provider.noteCount, 2);
    expect(provider.favCount, 3);
    expect(provider.notes, same(list));
    expect(provider.matchedCount, 2);
    await db.insertBook({'book_id': 'b', 'title': '书', 'updated_at': 1});
    SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf, bookIds: {'b'});
    await waitUntil(() => provider.bookCount == 1);
    expect(provider.notes, same(list));
    expect(provider.matchedCount, 2);
    expect(loadingNotifications, 0);
  });

  testWidgets('显式loadNotes取消待执行搜索防抖，不重复加载列表', (tester) async {
    await tester.runAsync(() => seed(2));
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    var loads = 0;
    provider.addListener(() { if (provider.isLoading) loads++; });
    provider.setSearch('笔记');
    await tester.runAsync(provider.loadNotes);
    final list = provider.notes;
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, 1);
    expect(provider.notes, same(list));
    expect(provider.matchedCount, 2);
    expect(provider.isLoading, isFalse);
  });

  test('收藏局部更新保留已加载页数且不增加数据版本，收藏筛选移除后无分页遗漏', () async {
    await seed(240);
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await provider.loadNotes();
    await provider.loadMore();
    final version = SyncService.changes.dataVersion;
    final untouched = provider.notes[1];
    await provider.toggleFavorite(provider.notes.first);
    expect(provider.notes.length, 200);
    expect(identical(untouched, provider.notes[1]), isTrue);
    expect(provider.favCount, 239);
    expect(SyncService.changes.dataVersion, version);
    provider.setFilter(ReadingFilter.favorites);
    await provider.loadNotes();
    await provider.toggleFavorite(provider.notes.first);
    expect(provider.matchedCount, 238);
    while (provider.hasMore) { await provider.loadMore(); }
    expect(provider.notes.length, 238);
    expect(provider.notes.map((n) => n.id).toSet().length, 238);
  });

  testWidgets('详情懒构建、SQL分页、总数统计和继续翻页', (tester) async {
    await tester.runAsync(() => seed(240));
    await tester.pumpWidget(MaterialApp(home: BookDetailPage(
      book: Book(bookId: 'b', title: '书'))));
    await pumpUntil(tester, () => find.text('240条').evaluate().length == 2);
    expect(find.text('240条'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('note:n0')), findsNothing);
    final list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 108);
    for (var i = 0; i < 18; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -1800));
      await pumpUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    }
    final paged = tester.widget<ListView>(find.byType(ListView));
    expect((paged.childrenDelegate as SliverChildBuilderDelegate).childCount, greaterThan(108));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收藏事件不重读报告，正式数据事件刷新报告', (tester) async {
    await tester.runAsync(() => seed(1));
    await tester.pumpWidget(const MaterialApp(home: ReportPage()));
    Finder notesStat() => find.ancestor(of: find.text('划线与笔记'), matching: find.byType(Card));
    await pumpUntil(tester, () => find.descendant(of: notesStat(), matching: find.text('1')).evaluate().isNotEmpty);
    expect(find.descendant(of: notesStat(), matching: find.text('1')), findsOneWidget);
    await tester.runAsync(() => db.insertNote({'note_id': 'new', 'book_id': 'b',
      'content': '新笔记', 'created_at': 3}));
    SyncService.changes.publish(db, favoritesOnly: true);
    await tester.runAsync(db.getReadingStats);
    await tester.pumpAndSettle();
    expect(find.descendant(of: notesStat(), matching: find.text('1')), findsOneWidget);
    SyncService.changes.publish(db);
    await pumpUntil(tester, () => find.descendant(of: notesStat(), matching: find.text('2')).evaluate().isNotEmpty);
    expect(find.descendant(of: notesStat(), matching: find.text('2')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收藏列表移除卡片后下一张保持自己的折叠状态', (tester) async {
    await tester.runAsync(() => seed(2));
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: provider,
      child: const MaterialApp(home: NotesPage())));
    await pumpUntil(tester, () => !provider.isLoading);
    await tester.tap(find.text(ReadingFilter.favorites.label));
    await pumpUntil(tester, () => !provider.isLoading);
    final first = find.byKey(const ValueKey('note:n1'));
    await tester.tap(find.descendant(of: first, matching: find.text('展开全部')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: first, matching: find.text('收起')), findsOneWidget);
    await tester.tap(find.descendant(of: first, matching: find.byIcon(Icons.star_rounded)));
    await pumpUntil(tester, () => first.evaluate().isEmpty);
    final second = find.byKey(const ValueKey('note:n0'));
    expect(find.descendant(of: second, matching: find.text('展开全部')), findsOneWidget);
    expect(find.descendant(of: second, matching: find.text('收起')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('摘要异常展示服务具体原因且关闭加载路由', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(storage,
      (call) async => call.method == 'read' && call.arguments['key'] == 'weread_api_key'
        ? 'test' : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, null));
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => generateSummary(context, '书', '', [
        NoteItem(id: 'blank', bookId: 'b', bookTitle: '书', content: '  ',
          chapterTitle: '', createdAt: 1, isFav: false, source: NoteSource.note),
      ]), child: const Text('生成'))))));
    await tester.tap(find.text('生成'));
    await pumpUntil(tester, () => find.textContaining('没有可用于生成摘要的笔记').evaluate().isNotEmpty);
    expect(find.textContaining('没有可用于生成摘要的笔记'), findsOneWidget);
    expect(find.text('AI 正在生成摘要...'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
