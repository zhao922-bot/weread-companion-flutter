import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/main.dart';
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'sync_database_regression_test.dart' show FaultFactory, LegacyDatabase;
import 'support/wait_until.dart';

class _LocalConfig extends AppConfigProvider {
  _LocalConfig() : super(config: AppConfig());
  int revision = 1;
  @override
  bool get canBrowseLocal => true;
  @override
  int get sessionRevision => revision;
  void changeSession() { revision++; notifyListeners(); }
}

class _CountingFactory extends FaultFactory {
  _CountingFactory(super.delegate);
  final reads = <String>[];
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async =>
      _CountingDatabase(await super.openDatabase(path, options: options), reads);
}

class _CountingDatabase extends LegacyDatabase {
  final List<String> reads;
  _CountingDatabase(Database db, this.reads) : super(db, '3.40.0');
  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values, nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) {
    reads.add(sql);
    return delegate.rawQuery(sql, arguments);
  }
  @override
  Future<List<Map<String, Object?>>> query(String table, {bool? distinct,
    List<String>? columns, String? where, List<Object?>? whereArgs,
    String? groupBy, String? having, String? orderBy, int? limit, int? offset}) {
    reads.add(table);
    return super.query(table, distinct: distinct, columns: columns, where: where,
      whereArgs: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy,
      limit: limit, offset: offset);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late _CountingFactory factory;
  setUpAll(() {
    sqfliteFfiInit();
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lazy-tabs-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    factory = _CountingFactory(databaseFactoryFfiNoIsolate);
    databaseFactory = factory;
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.insertBook({'book_id': 'b', 'title': '书', 'updated_at': 1});
    await db.insertBookmark({'bookmark_id': 'bm', 'book_id': 'b', 'mark_text': '引文', 'created_at': 1});
    await db.insertNote({'note_id': 'n', 'book_id': 'b', 'content': '笔记', 'created_at': 1});
    factory.reads.clear();
  });
  tearDown(() async {
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  testWidgets('首次访问才挂载，保留页面状态，隐藏变化合并为进入时刷新，会话切换重新惰性挂载', (tester) async {
    final config = _LocalConfig();
    final shelf = BookshelfProvider(isActive: false);
    final notes = NotesProvider(isActive: false);
    addTearDown(config.dispose);
    addTearDown(shelf.dispose);
    addTearDown(notes.dispose);
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AppConfigProvider>.value(value: config),
      ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
      ChangeNotifierProvider<NotesProvider>.value(value: notes),
    ], child: const MaterialApp(home: MainScreen())));
    await pumpUntil(tester, () => shelf.totalCount == 1 && !shelf.isLoading);
    expect(factory.reads, ['books']);
    for (final type in [NotesPage, CardsPage, ReportPage]) {
      expect(find.byType(type, skipOffstage: false), findsNothing);
    }
    Future<void> visit(int index) async {
      await tester.tap(find.byType(NavigationDestination).at(index));
      await tester.pump();
    }
    await visit(1);
    await pumpUntil(tester, () => notes.matchedCount == 2 && !notes.isLoading);
    final notesState = tester.state(find.byType(NotesPage));
    await tester.enterText(find.byType(TextField), '笔记');
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntil(tester, () => notes.matchedCount == 1 && !notes.isLoading);
    await visit(2);
    await pumpUntil(tester, () => find.text('引文').evaluate().isNotEmpty);
    final cardsState = tester.state(find.byType(CardsPage));
    await visit(3);
    await pumpUntil(tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    final reportState = tester.state(find.byType(ReportPage));
    await visit(0);
    final shelfState = tester.state(find.byType(BookshelfPage));
    factory.reads.clear();
    await tester.runAsync(() async {
      await db.insertNote({'note_id': 'new', 'book_id': 'b', 'content': '新笔记', 'created_at': 2});
      for (var i = 0; i < 3; i++) { SyncService.changes.publish(db); }
      await waitUntil(() => !shelf.isLoading);
    });
    await tester.pumpAndSettle();
    expect(factory.reads.every((sql) => sql == 'books'), isTrue);
    expect(notes.matchedCount, 1);
    factory.reads.clear();
    await visit(1);
    await pumpUntil(tester, () => notes.matchedCount == 2 && !notes.isLoading);
    expect(tester.state(find.byType(NotesPage)), same(notesState));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '笔记');
    expect(factory.reads.where((sql) => sql.contains('AS reading_items') && sql.contains('LIMIT')), hasLength(1));
    await visit(2);
    await pumpUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(tester.state(find.byType(CardsPage)), same(cardsState));
    await visit(3);
    await pumpUntil(tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(tester.state(find.byType(ReportPage)), same(reportState));
    await visit(0);
    expect(tester.state(find.byType(BookshelfPage)), same(shelfState));
    config.changeSession();
    await tester.pumpAndSettle();
    expect(find.byType(NotesPage, skipOffstage: false), findsNothing);
    expect(find.byType(CardsPage, skipOffstage: false), findsNothing);
    expect(find.byType(ReportPage, skipOffstage: false), findsNothing);
    expect(tester.state(find.byType(BookshelfPage)), isNot(same(shelfState)));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test('未激活provider收到事件和显式加载均不查库，激活才刷新', () async {
    final shelf = BookshelfProvider(isActive: false);
    final notes = NotesProvider(isActive: false);
    addTearDown(shelf.dispose);
    addTearDown(notes.dispose);
    SyncService.changes.publish(db);
    await shelf.loadBooks();
    await notes.loadNotes();
    expect(factory.reads, isEmpty);
    await shelf.setActive(true);
    await notes.setActive(true);
    expect(shelf.totalCount, 1);
    expect(notes.matchedCount, 2);
  });

  testWidgets('封面按实际布局乘DPR解码，3/4列切换及DPR变化更新缓存尺寸', (tester) async {
    final config = _LocalConfig();
    final shelf = BookshelfProvider();
    addTearDown(config.dispose);
    addTearDown(shelf.dispose);
    await tester.runAsync(() => db.insertBook({
      'book_id': 'b', 'title': '书', 'cover': 'https://example.com/cover.jpg', 'updated_at': 1,
    }));
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1200, 1800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AppConfigProvider>.value(value: config),
      ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
    ], child: const MaterialApp(home: BookshelfPage())));
    await pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    ResizeImage checkDimensions(double dpr) {
      final finder = find.byType(Image);
      final image = tester.widget<Image>(finder);
      final provider = image.image as ResizeImage;
      final size = tester.getSize(finder);
      expect(provider.width, (size.width * dpr).ceil());
      expect(provider.height, (size.height * dpr).ceil());
      expect((provider.imageProvider as NetworkImage).url, 'https://example.com/cover.jpg');
      return provider;
    }
    final three = checkDimensions(3);
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) =>
      widget is CheckedPopupMenuItem<int> && widget.value == 4));
    await tester.pumpAndSettle();
    final four = checkDimensions(3);
    expect(four.width, lessThan(three.width!));
    expect(four.height, lessThan(three.height!));
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pumpAndSettle();
    final lowerDpr = checkDimensions(2);
    expect(lowerDpr.width, lessThan(four.width!));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
