import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/bookmark.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/database.dart';

import 'support/observed_database.dart';
import 'support/wait_until.dart';

void main() {
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  final edit = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '编辑书名');

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('readamber-card-titles-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db = await DatabaseService.selectAccount('123');
  });

  tearDown(() async {
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  Bookmark quote(String id, String text, {String bookId = 'b1'}) => Bookmark(
        bookmarkId: id,
        bookId: bookId,
        bookTitle: '原书名',
        markText: text,
        chapterTitle: '',
        createdAt: 1,
      );

  bool canEdit(WidgetTester tester) =>
      edit.evaluate().isNotEmpty &&
      tester.widget<IconButton>(edit).onPressed != null;

  Future<void> openEditor(WidgetTester tester) async {
    await pumpUntil(tester, () => canEdit(tester));
    await tester.tap(edit);
    await tester.pumpAndSettle();
  }

  Future<void> typeTitle(WidgetTester tester, String title) =>
      tester.enterText(find.byType(TextFormField), title);

  Future<void> acceptTitle(WidgetTester tester, {String button = '确定'}) async {
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    await pumpUntil(tester, () => canEdit(tester));
  }

  Future<void> closeSheet(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(DraggableScrollableSheet))).pop();
    await tester.pumpAndSettle();
  }

  Widget quickCardHome({GlobalKey<NavigatorState>? navigator}) => MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => showQuoteCardSheet(context, quote('q', '笔记原文')),
            child: const Text('预览笔记卡片'),
          );
        })),
      );

  Future<void> openQuickCard(WidgetTester tester) async {
    await tester.tap(find.text('预览笔记卡片'));
    await tester.pumpAndSettle();
  }

  testWidgets('同一本书的自定义书名在宽屏、手机和笔记卡片间持久共享', (tester) async {
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      for (final bookmark in [
        quote('a', '第一条划线'),
        quote('b', '另一条划线'),
        quote('c', '同名的其他书', bookId: 'b2'),
      ]) {
        await db.insertBookmark(bookmark.toJson());
      }
      await db.insertNote({
        'note_id': 'n',
        'book_id': 'b1',
        'book_title': '原书名',
        'content': '笔记原文',
        'created_at': 2,
      });
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: notes,
      child: const MaterialApp(home: NotesPage()),
    ));
    await pumpUntil(tester, () => find.text('笔记原文').evaluate().isNotEmpty);
    await tester.tap(find.text('金句卡片'));
    await pumpUntil(tester, () => find.text('第一条划线').evaluate().isNotEmpty);
    await tester.tap(find.text('第一条划线').first);
    await openEditor(tester);
    await typeTitle(tester, '  卡片用书名  ');
    await acceptTitle(tester);
    expect(find.text('—— 卡片用书名'), findsOneWidget);
    expect(find.text('原书名'), findsWidgets);

    await tester.tap(find.text('同名的其他书').first);
    await pumpUntil(tester, () => canEdit(tester));
    expect(find.text('—— 原书名'), findsOneWidget);
    await tester.tap(find.text('另一条划线').first);
    await pumpUntil(tester, () => canEdit(tester));
    expect(find.text('—— 卡片用书名'), findsOneWidget);

    await tester.tap(find.text('笔记列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('note:n')),
      matching: find.byTooltip('做成金句卡片'),
    ));
    await tester.pumpAndSettle();
    await openEditor(tester);
    expect(find.text('卡片用书名'), findsOneWidget);
    await typeTitle(tester, '取消的修改');
    await acceptTitle(tester, button: '取消');
    expect(find.text('—— 卡片用书名'), findsOneWidget);
    await openEditor(tester);
    await typeTitle(tester, '笔记调整的书名');
    await acceptTitle(tester);
    await closeSheet(tester);

    await tester.tap(find.text('金句卡片'));
    await tester.pumpAndSettle();
    expect(find.text('—— 笔记调整的书名'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      db = await DatabaseService.selectAccount('123');
    });
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpWidget(const MaterialApp(home: CardsPage()));
    await pumpUntil(tester, () => find.text('另一条划线').evaluate().isNotEmpty);
    await tester.tap(find.text('另一条划线'));
    await openEditor(tester);
    expect(find.text('笔记调整的书名'), findsOneWidget);
    await acceptTitle(tester, button: '恢复默认');
    expect(find.text('—— 原书名'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await db.getCardBookTitle('b1'), isNull);
      expect(await db.getCardBookTitle('b2'), isNull);
    });
  });

  testWidgets('保存失败保留已有卡片书名并可重试，空白标题恢复默认', (tester) async {
    await tester.runAsync(() async {
      await db.setCardBookTitle('b1', '已有书名');
      await (await db.database).execute('''
        CREATE TRIGGER reject_title BEFORE INSERT ON card_book_titles
        BEGIN SELECT RAISE(ABORT, 'write failed'); END
      ''');
    });
    await tester.pumpWidget(quickCardHome());
    await openQuickCard(tester);
    await openEditor(tester);
    await typeTitle(tester, '未保存的新书名');
    await acceptTitle(tester);
    expect(find.text('卡片书名保存失败，请重试'), findsOneWidget);
    expect(find.text('—— 已有书名'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await db.getCardBookTitle('b1'), '已有书名');
      await (await db.database).execute('DROP TRIGGER reject_title');
    });
    await openEditor(tester);
    await typeTitle(tester, '   ');
    await acceptTitle(tester);
    expect(find.text('—— 原书名'), findsOneWidget);
  });

  testWidgets('更换账号后丢弃旧卡片编辑，并保留各自的书名', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.runAsync(() => db.setCardBookTitle('b1', '账号一书名'));
    await tester.pumpWidget(quickCardHome(navigator: navigator));
    await openQuickCard(tester);
    await openEditor(tester);
    await typeTitle(tester, '旧会话改动');
    final second =
        (await tester.runAsync(() => DatabaseService.selectAccount('456')))!;
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('账号会话已结束，请返回后重试'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await openQuickCard(tester);
    await openEditor(tester);
    expect(find.text('原书名'), findsOneWidget);
    await acceptTitle(tester, button: '取消');
    await closeSheet(tester);
    await tester.runAsync(() async {
      expect(await second.getCardBookTitle('b1'), isNull);
      db = await DatabaseService.selectAccount('123');
      expect(await db.getCardBookTitle('b1'), '账号一书名');
      await DatabaseService.endSession();
    });
    await openQuickCard(tester);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
  });

  testWidgets('并行预览保留最新的卡片书名并忽略其他书的更新', (tester) async {
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await tester.runAsync(() async {
      await db.insertBookmark(quote('a', '宽屏划线').toJson());
      await db.setCardBookTitle('b1', '读取中的旧书名');
    });
    var readPending = false;
    final release = Completer<void>();
    probe.afterRead = (table) async {
      if (table != 'card_book_titles' || readPending) return;
      readPending = true;
      await release.future;
    };
    var quickBookId = 'b2';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          Builder(builder: (context) {
            return TextButton(
              onPressed: () => showQuoteCardSheet(
                  context, quote('q', '笔记原文', bookId: quickBookId)),
              child: const Text('预览笔记卡片'),
            );
          }),
          const Expanded(child: CardsPage(embedded: true)),
        ]),
      ),
    ));
    await pumpUntil(tester, () => readPending);

    final quickEdit = find.descendant(
      of: find.byType(DraggableScrollableSheet),
      matching: edit,
    );
    for (final title in ['另一本书的新书名', '最新书名']) {
      await openQuickCard(tester);
      await pumpUntil(
          tester, () => tester.widget<IconButton>(quickEdit).onPressed != null);
      await tester.tap(quickEdit);
      await tester.pumpAndSettle();
      await typeTitle(tester, title);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await pumpUntil(
          tester, () => tester.widget<IconButton>(quickEdit).onPressed != null);
      await closeSheet(tester);
      if (quickBookId == 'b2') {
        expect(find.text('—— 原书名'), findsOneWidget);
        quickBookId = 'b1';
      }
    }
    release.complete();
    await pumpUntil(tester, () => canEdit(tester));
    expect(find.text('—— 最新书名'), findsOneWidget);
  });

  testWidgets('卡片书名读取失败时回退到源书名，关闭中的卡片丢弃迟到结果', (tester) async {
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    var failImmediately = true;
    var entered = false;
    final release = Completer<void>();
    probe.afterRead = (table) async {
      if (table != 'card_book_titles') return;
      if (!failImmediately) {
        entered = true;
        await release.future;
      }
      throw StateError('title lookup failed');
    };
    await tester.pumpWidget(quickCardHome());
    await openQuickCard(tester);
    await pumpUntil(tester, () => canEdit(tester));
    expect(find.text('卡片书名加载失败，请重新打开卡片重试'), findsOneWidget);
    expect(find.text('—— 原书名'), findsOneWidget);
    await closeSheet(tester);
    ScaffoldMessenger.of(tester.element(find.text('预览笔记卡片'))).clearSnackBars();

    failImmediately = false;
    await openQuickCard(tester);
    await pumpUntil(tester, () => entered);
    await closeSheet(tester);
    release.complete();
    await tester.pumpAndSettle();
    expect(find.text('卡片书名加载失败，请重新打开卡片重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
