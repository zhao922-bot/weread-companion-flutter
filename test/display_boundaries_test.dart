import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';
import 'support/observed_database.dart';
import 'support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-display-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    probe.afterRead = null;
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  Future<void> seed(String content) => db.insertNote({
        'note_id': 'n',
        'book_id': 'b',
        'book_title': '边界测试书',
        'content': content,
        'created_at': 1,
      });
  Widget app(Widget home, {double scale = 1}) => MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home);
  void smallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<NotesProvider> notes(WidgetTester tester, {double scale = 1}) async {
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadNotes);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider, child: app(const NotesPage(), scale: scale)));
    await tester.pumpAndSettle();
    return provider;
  }

  for (final grapheme in ['😀', 'e\u0301', '👩‍👩‍👧‍👦']) {
    testWidgets('80 字预览保持完整字符：$grapheme，展开收起不丢失内容', (tester) async {
      final preview = '${'a' * 79}$grapheme';
      final content = '$preview结尾';
      await tester.runAsync(() => seed(content));
      await notes(tester);
      expect(find.text('$preview...'), findsOneWidget);
      await tester.tap(find.text('展开全部'));
      await tester.pump();
      expect(find.text(content), findsOneWidget);
      await tester.tap(find.text('收起'));
      await tester.pump();
      expect(find.text('$preview...'), findsOneWidget);
    });
  }

  testWidgets('正好80个多码元字符不截断，也不显示展开入口', (tester) async {
    final content = '😀' * 80;
    await tester.runAsync(() => seed(content));
    await notes(tester);
    expect(find.text(content), findsOneWidget);
    expect(find.text('展开全部'), findsNothing);
  });

  testWidgets('不足一屏的笔记列表仍可下拉刷新更新内容', (tester) async {
    await tester.runAsync(() => seed('刷新前内容'));
    final provider = await notes(tester);
    await tester.runAsync(() => seed('刷新后内容'));
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await pumpUntil(tester, () => provider.notes.single.content == '刷新后内容');
    expect(find.text('刷新后内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏大字体空状态可完整展示并通过下拉刷新恢复数据', (tester) async {
    smallScreen(tester);
    final provider = await notes(tester, scale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('暂无笔记，请先同步书架'), findsOneWidget);
    await tester.runAsync(() => seed('刷新后新增'));
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await pumpUntil(tester, () => provider.notes.isNotEmpty);
    expect(find.text('刷新后新增'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏大字体长错误可滚动至重试，重试后正常展示', (tester) async {
    smallScreen(tester);
    probe.afterRead = (_) async => throw StateError('数据库暂时不可用，稍后重试。' * 30);
    final provider = await notes(tester, scale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('加载失败'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('重试'), 200,
        scrollable: find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    probe.afterRead = null;
    await tester.runAsync(() => seed('恢复后数据'));
    await tester.tap(find.text('重试'));
    await pumpUntil(
        tester, () => !provider.isLoading && provider.notes.isNotEmpty);
    expect(find.text('恢复后数据'), findsOneWidget);
  });

  for (final progress in [0, 10, 99, 100]) {
    testWidgets('小屏大字体书籍进度 $progress 的统计、标签及笔记无溢出', (tester) async {
      smallScreen(tester);
      await tester.runAsync(() => seed('书籍笔记'));
      await tester.pumpWidget(app(
          BookDetailPage(
              book: Book(
                  bookId: 'b',
                  title: '很长的书名' * 10,
                  author: '很长的作者名' * 10,
                  category: '很长的分类名' * 10,
                  progress: progress)),
          scale: 2));
      await pumpUntil(
          tester, () => probe.reads.any((r) => r.sql.contains('LIMIT')));
      await tester.scrollUntilVisible(find.text('1条'), 150);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('$progress% 已完成'), 150);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('书籍笔记'), 150);
      expect(tester.takeException(), isNull);
    });
  }
}
