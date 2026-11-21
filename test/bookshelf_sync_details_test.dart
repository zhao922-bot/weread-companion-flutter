import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/pages/sync_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/sync_service.dart';

class _Config extends AppConfigProvider {
  _Config() : super(config: AppConfig());

  int revision = 0;

  @override
  int get sessionRevision => revision;

  @override
  bool get isLoggedIn => true;
}

class _Shelf extends BookshelfProvider {
  _Shelf(SyncResult result) {
    lastSyncResult = result;
  }

  @override
  final books = [Book(bookId: 'shelf', title: '当前书架')];

  @override
  Future<void> setActive(bool active) async {}

  @override
  Future<String> syncFromServer({AppConfig? config}) async =>
      lastSyncResult!.summary;
}

void main() {
  final changes = (
    added: [Book(bookId: 'added', title: '新增书')],
    updated: [Book(bookId: 'updated', title: '新书名')],
    removed: [
      Book(bookId: 'removed', title: '移除书'),
      Book(bookId: 'untitled', title: ''),
    ],
  );

  testWidgets('书架同步反馈显示数量并可展开具体书名', (tester) async {
    final config = _Config();
    final shelf = _Shelf(SyncResult([], 2,
        bookshelf: BookshelfSyncResult(changes, complete: true)));
    addTearDown(config.dispose);
    addTearDown(shelf.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppConfigProvider>.value(value: config),
        ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
      ],
      child: const MaterialApp(home: BookshelfPage()),
    ));
    await tester.pumpAndSettle();
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    const counts = '新增 1 本 · 更新 1 本 · 移除 2 本';
    expect(find.textContaining(counts), findsOneWidget);
    final openDetails =
        tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed;
    await tester.tap(find.text('同步详情'));
    await tester.pumpAndSettle();
    final details = find.text('书架变更 · $counts');
    expect(details, findsOneWidget);
    expect(find.text('新增 · 新增书'), findsNothing);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('新增 · 新增书'), findsOneWidget);
    expect(find.text('更新 · 新书名'), findsOneWidget);
    expect(find.text('移除 · 移除书'), findsOneWidget);
    expect(find.text('移除 · untitled'), findsOneWidget);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('移除 · 移除书'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    config.revision++;
    openDetails();
    await tester.pumpAndSettle();
    expect(find.byType(SyncPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    openDetails();
    expect(tester.takeException(), isNull);
  });

  testWidgets('不完整书架注明保留本地书籍，仍显示零变更详情', (tester) async {
    final config = _Config();
    addTearDown(config.dispose);
    final result = SyncResult([], 0,
        bookshelf: const BookshelfSyncResult(
          (added: [], updated: [], removed: []),
          complete: false,
        ));
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
      value: config,
      child: MaterialApp(home: SyncPage(initialResult: result)),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保留未返回的本地书籍'), findsOneWidget);
    await tester.tap(find.text('书架变更 · 新增 0 本 · 更新 0 本 · 移除 0 本'));
    await tester.pumpAndSettle();
    expect(find.text('本次没有书架变更'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
