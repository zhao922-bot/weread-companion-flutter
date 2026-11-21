import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';

import 'support/observed_database.dart';
import 'support/wait_until.dart';

Map<String, dynamic> _bookmark(
  String id, {
  String bookId = 'book',
  String text = '划线正文',
  bool favorite = false,
  int createdAt = 10,
}) =>
    {
      'bookmark_id': id,
      'book_id': bookId,
      'book_title': '同一本书',
      'mark_text': text,
      'created_at': createdAt,
      'is_fav': favorite ? 1 : 0,
    };

Map<String, dynamic> _note(
  String id, {
  String text = '笔记正文',
  bool favorite = false,
  int createdAt = 20,
}) =>
    {
      'note_id': id,
      'book_id': 'book',
      'book_title': '同一本书',
      'content': text,
      'created_at': createdAt,
      'is_fav': favorite ? 1 : 0,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseProbe probe;
  late DatabaseService db;
  late NotesProvider notes;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('readamber-organize-');
    probe = DatabaseProbe();
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    db = await DatabaseService.selectAccount('8123');
    await db.database;
    notes = NotesProvider();
  });

  tearDown(() async {
    notes.dispose();
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });

  Future<List<NoteItem>> items() async =>
      (await db.getReadingItems()).map(NoteItem.fromRow).toList();

  Future<void> mountNotes(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: notes,
      child: const MaterialApp(home: NotesPage()),
    ));
    await pumpUntil(tester, () => !notes.isLoading);
  }

  test('标签跨分页、来源和同步更新保持隔离，按搜索和书籍组合筛选', () async {
    await db.insertBookmark(_bookmark('same', text: '共同关键字 划线'));
    await db.insertNote(_note('same', text: '共同关键字 笔记', favorite: true));
    await db
        .insertBookmark(_bookmark('other', bookId: 'other', text: '共同关键字 外书'));
    final [note, bookmark, other] = await items();
    await db.setReadingTags(bookmark, [' 项目 ', '重点', '重点', ' ', '带"引号,标签']);
    await db.setReadingTags(note, ['任务']);
    await db.setReadingTags(other, ['项目']);
    expect(await db.getReadingTags(),
        unorderedEquals(['项目', '重点', '任务', '带"引号,标签']));
    expect((await items())[1].tags, unorderedEquals(['项目', '重点', '带"引号,标签']));
    expect((await items()).first.tags, ['任务']);
    expect(await db.countReadingItems(tag: '项目', query: '共同关键字'), 2);
    expect(
        await db.countReadingItems(tag: '项目', query: '共同关键字', bookId: 'book'),
        1);
    expect(
        await db.countReadingItems(tag: '项目', filter: ReadingFilter.favorites),
        0);
    final first = await db.getReadingItems(tag: '项目', limit: 1);
    final next = await db.getReadingItems(
        tag: '项目', limit: 1, after: NoteItem.fromRow(first.single));
    expect([first.single['id'], next.single['id']], ['same', 'other']);
    expect(
        (await db.getSummaryItems(tag: '任务', filter: ReadingFilter.notes))
            .single['id'],
        'same');

    await notes.setTagFilter('项目');
    await notes.setTagFilter('项目');
    expect(notes.matchedCount, 2);
    expect((await notes.getAllMatchingNotes()).map((item) => item.id),
        ['same', 'other']);
    expect(await notes.getSummaryNotes(), hasLength(2));
    notes.resetSession(10);
    expect(notes.selectedTag, isNull);

    await db.applySyncDelta(
        'book', 'bookmark', [_bookmark('same', text: '重新同步')], [], '1');
    expect((await db.getReadingItems(tag: '重点')).single['content'], '重新同步');
    final otherAccount = await DatabaseService.selectAccount('8124');
    await otherAccount.insertBookmark(_bookmark('same'));
    expect(await otherAccount.getReadingTags(), isEmpty);
    expect((await otherAccount.getReadingItems(tag: '重点')), isEmpty);

    db = await DatabaseService.selectAccount('8123');
    expect(await db.countReadingItems(tag: '重点'), 1);
    await db.applySyncDelta('book', 'bookmark', [], ['same'], '2');
    expect(await db.getReadingTags(), unorderedEquals(['项目', '任务']));
    await expectLater(db.setReadingTags(bookmark, ['残留']), throwsStateError);
    await db.insertBookmark(_bookmark('same'));
    expect(await db.countReadingItems(tag: '重点'), 0);
    expect((await db.getReadingItems(tag: '任务')).single['source'], 'note');

    // The original write may already have committed when the session changes.
    probe.afterCommit = () async {
      probe.afterCommit = null;
      db = await DatabaseService.selectAccount('8124');
    };
    await notes.setTags(db, bookmark, ['刚保存']);
    expect(notes.notes, isEmpty);
    expect(await db.getReadingTags(), isEmpty);
    db = await DatabaseService.selectAccount('8123');
    expect(await db.getReadingTags(), contains('刚保存'));
  });

  testWidgets('编辑多个标签并筛选、取消、清除和删除标签', (tester) async {
    await tester.runAsync(() async {
      await db.insertBookmark(_bookmark('bookmark'));
      await db.insertNote(_note('note'));
    });
    await mountNotes(tester);

    await tester.tap(find.text('按标签筛选'));
    await pumpUntil(tester, () => find.text('暂无标签').evaluate().isNotEmpty);
    await tester.tap(find.text('全部标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑标签').first);
    await tester.pumpAndSettle();
    final input = find.widgetWithText(TextField, '新标签');
    await tester.tap(find.byTooltip('添加标签'));
    await tester.enterText(input, '重要');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(input, '新项目');
    await tester.tap(find.text('保存'));
    await pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    expect(notes.notes.first.tags, unorderedEquals(['重要', '新项目']));
    expect(find.text('新项目'), findsOneWidget);

    await tester.tap(find.text('按标签筛选'));
    await pumpUntil(tester,
        () => find.widgetWithText(ListTile, '新项目').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(ListTile, '新项目'));
    await pumpUntil(tester, () => notes.matchedCount == 1);
    expect(find.text('标签：新项目'), findsOneWidget);
    expect(find.text('划线正文'), findsNothing);

    await tester.tap(find.byTooltip('编辑标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除 新项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(notes.notes.single.tags, contains('新项目'));

    await tester.tap(find.byTooltip('编辑标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除 新项目'));
    await tester.tap(find.text('保存'));
    await pumpUntil(tester, () => notes.matchedCount == 0);
    expect(find.text('没有匹配的笔记'), findsOneWidget);

    await tester.tap(find.text('按标签筛选'));
    await pumpUntil(tester,
        () => find.widgetWithText(ListTile, '重要').evaluate().isNotEmpty);
    await tester.tap(find.text('全部标签'));
    await pumpUntil(tester, () => notes.matchedCount == 2);
    expect(notes.selectedTag, isNull);
    expect(find.text('划线正文'), findsOneWidget);
  });

  testWidgets('标签读取和保存失败后可以重试', (tester) async {
    await tester.runAsync(() => db.insertNote(_note('note')));
    await mountNotes(tester);

    probe.afterRead = (sql) {
      if (sql == 'reading_tags') throw StateError('标签查询失败');
    };
    await tester.tap(find.text('按标签筛选'));
    final retry = find.text('标签加载失败，点击重试');
    await pumpUntil(tester, () => retry.evaluate().isNotEmpty);
    probe.afterRead = null;
    await tester.tap(retry);
    await pumpUntil(tester, () => find.text('暂无标签').evaluate().isNotEmpty);
    Navigator.of(tester.element(find.text('全部标签'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '新标签'), '计划');
    probe.beforeCommit = () => throw StateError('离线存储暂不可写');
    final save =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    save.onPressed!();
    save.onPressed!();
    final error = find.textContaining('保存标签失败');
    await pumpUntil(tester, () => error.evaluate().isNotEmpty);
    expect(notes.notes.single.tags, isEmpty);
    expect(find.widgetWithText(InputChip, '计划'), findsOneWidget);
    probe.beforeCommit = null;
    await tester.tap(find.text('保存'));
    await pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    expect(notes.notes.single.tags, ['计划']);
  });

  testWidgets('每日回顾换一批时保留未确认条目，确认后可继续当天回顾', (tester) async {
    await tester.runAsync(() async {
      await db
          .insertBookmark(_bookmark('favorite', text: '收藏划线', favorite: true));
      await db.insertNotes(List.generate(
          5,
          (index) => _note(
                'n$index',
                text: '回顾笔记 $index',
                createdAt: index,
              )));
    });
    await mountNotes(tester);
    Finder reviewText(String text) => find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(text),
        );
    Future<void> openReview() => tester.tap(find.byTooltip('每日回顾'));

    probe.afterRead = (sql) {
      if (sql.contains('JOIN reading_reviews')) throw StateError('读失败');
    };
    await openReview();
    final retry = reviewText('每日回顾更新失败，点击重试');
    await pumpUntil(tester, () => retry.evaluate().isNotEmpty);
    probe.afterRead = null;
    await tester.tap(retry);
    await pumpUntil(tester, () => reviewText('收藏划线').evaluate().isNotEmpty);
    expect(tester.getTopLeft(reviewText('收藏划线')).dy,
        lessThan(tester.getTopLeft(reviewText('回顾笔记 4')).dy));

    final nextBatch = find.widgetWithText(TextButton, '换一批');
    final fetch = tester.widget<TextButton>(nextBatch).onPressed!;
    fetch();
    fetch();
    await pumpUntil(tester, () => reviewText('回顾笔记 0').evaluate().isNotEmpty);
    expect(reviewText('收藏划线'), findsNothing);
    await tester.tap(nextBatch);
    await pumpUntil(tester, () => reviewText('收藏划线').evaluate().isNotEmpty);
    await tester.tap(reviewText('已回顾').first);
    await pumpUntil(
        tester,
        () =>
            reviewText('回顾笔记 4').evaluate().isNotEmpty &&
            reviewText('收藏划线').evaluate().isEmpty);
    Navigator.of(tester.element(reviewText('每日回顾'))).pop();
    await tester.pumpAndSettle();
    await openReview();
    await pumpUntil(tester, () => reviewText('回顾笔记 4').evaluate().isNotEmpty);
    expect(reviewText('收藏划线'), findsNothing);
    expect(reviewText('回顾笔记 0'), findsOneWidget);
  });
}
