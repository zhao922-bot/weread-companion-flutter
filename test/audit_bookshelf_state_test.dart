import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/services/config.dart';

class _Config extends AppConfigProvider {
  _Config() : super(config: AppConfig());
  @override
  bool get isLoggedIn => true;
}

class _Shelf extends BookshelfProvider {
  List<Book> items = [];
  int syncs = 0;
  @override
  List<Book> get books => items;
  @override
  Future<void> setActive(bool active) async {}
  @override
  Future<String> syncFromServer({AppConfig? config}) async {
    syncs++;
    return '同步完成';
  }
}

class _Store extends InMemorySharedPreferencesStore {
  _Store(super.data) : super.withData();
  bool readError = false;
  bool writeError = false;
  bool writeOk = true;
  int writes = 0;
  Completer<void>? reading;
  Completer<void>? writing;
  @override
  Future<Map<String, Object>> getAll() async {
    await reading?.future;
    if (readError) throw StateError('read failed');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes++;
    await writing?.future;
    if (writeError) throw StateError('write failed');
    if (!writeOk) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  late _Store store;
  late _Shelf shelf;
  late _Config config;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _Store({});
    SharedPreferencesStorePlatform.instance = store;
    shelf = _Shelf();
    config = _Config();
  });
  tearDown(() {
    shelf.dispose();
    config.dispose();
  });
  Widget app() => MultiProvider(
        providers: [
          ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
          ChangeNotifierProvider<AppConfigProvider>.value(value: config),
        ],
        child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: const BookshelfPage()),
      );
  Future<void> selectFour(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(CheckedPopupMenuItem<int>, '4 列 · 更紧凑'));
    await tester.pumpAndSettle();
  }

  testWidgets('密度读取失败后保留默认布局，用户可重新选择并保存', (tester) async {
    store.readError = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('显示密度：当前 3 列'), findsOneWidget);
    expect(
        tester
            .widget<PopupMenuButton<int>>(find.byType(PopupMenuButton<int>))
            .enabled,
        isTrue);
    store.readError = false;
    await selectFour(tester);
    expect(find.byTooltip('显示密度：当前 4 列'), findsOneWidget);
    expect((await store.getAll())['flutter.bookshelf_columns'], 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧密度值类型损坏时回退默认布局并可覆盖保存', (tester) async {
    store = _Store({'flutter.bookshelf_columns': 'four'});
    SharedPreferencesStorePlatform.instance = store;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('显示密度：当前 3 列'), findsOneWidget);
    await selectFour(tester);
    expect((await store.getAll())['flutter.bookshelf_columns'], 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final throws in [false, true]) {
    testWidgets('密度保存${throws ? "抛错" : "返回false"}不误报成功，重建和重试保持一致',
        (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      store.writeOk = false;
      store.writeError = throws;
      await selectFour(tester);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('显示密度：当前 3 列'), findsOneWidget);
      expect(find.text('显示密度保存失败，请重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byTooltip('显示密度：当前 3 列'), findsOneWidget);
      store.writeOk = true;
      store.writeError = false;
      await selectFour(tester);
      expect(find.byTooltip('显示密度：当前 4 列'), findsOneWidget);
      expect((await store.getAll())['flutter.bookshelf_columns'], 4);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final failure in [false, true]) {
    testWidgets('密度保存中禁用重复选择，销毁后${failure ? "失败" : "完成"}无迟到界面更新',
        (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      store.writing = Completer<void>();
      store.writeError = failure;
      await selectFour(tester);
      final menu = tester
          .widget<PopupMenuButton<int>>(find.byType(PopupMenuButton<int>));
      expect(menu.enabled, isFalse);
      menu.onSelected!(
          3); // A callback already queued before the selector disabled.
      await tester.pump();
      expect(store.writes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      store.writing!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      menu.onSelected!(3); // A stale callback cannot write after disposal.
      await tester.pump();
      expect(store.writes, 1);
      expect((await store.getAll())['flutter.bookshelf_columns'],
          failure ? isNull : 4);
    });
  }

  testWidgets('保存等待打开偏好存储时销毁页面，不再发起写入', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final select = tester
        .widget<PopupMenuButton<int>>(find.byType(PopupMenuButton<int>))
        .onSelected!;
    // Reopen the platform store and hold its response at the await boundary.
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = store;
    store.reading = Completer<void>();
    select(4);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    store.reading!.complete();
    await tester.pumpAndSettle();
    expect(store.writes, 0);
    expect((await store.getAll())['flutter.bookshelf_columns'], isNull);
    expect(tester.takeException(), isNull);
  });

  for (final count in [0, 1]) {
    testWidgets('$count 本书不足一屏时仍能通过下拉手势同步', (tester) async {
      shelf.items =
          List.generate(count, (i) => Book(bookId: '$i', title: '书籍 $i'));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final list = count == 0 ? find.byType(ListView) : find.byType(GridView);
      await tester.drag(list, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(shelf.syncs, 1);
      expect(find.text('同步完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
