import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/pages/sync_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _SyncConfig extends AppConfigProvider {
  _SyncConfig() : super(config: AppConfig(cookie: 'wr_vid=123; wr_skey=test'));
  bool verified = true;
  @override
  bool get isLoggedIn => verified;
  @override
  bool get canBrowseLocal => true;
  @override
  String? get loginError => '验证失败，请重试';
  @override
  Future<bool> verifyForSync() async => verified;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-uncovered-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
  });
  tearDown(() async {
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  testWidgets('报告展示最近六个月含零月份，排除窗口外和未来数据，支持查询失败重试', (tester) async {
    final now = DateTime.now();
    final dates = [
      DateTime(now.year, now.month, 1),
      DateTime(now.year, now.month, 1),
      DateTime(now.year, now.month - 2, 1),
      DateTime(now.year, now.month - 6, 1),
      now.add(const Duration(days: 1))
    ];
    await tester.runAsync(() => db.insertNotes([
          for (var i = 0; i < dates.length; i++)
            {
              'note_id': 'n$i',
              'book_id': 'b',
              'content': '笔记',
              'created_at': dates[i].millisecondsSinceEpoch ~/ 1000,
            }
        ]));
    probe.afterRead = (sql) {
      if (sql.contains("strftime('%Y-%m'")) {
        probe.afterRead = null;
        throw StateError('report read failed');
      }
    };
    await tester.pumpWidget(const MaterialApp(home: ReportPage()));
    await pumpUntil(
        tester, () => find.textContaining('报告加载失败').evaluate().isNotEmpty);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await pumpUntil(tester, () => find.byType(BarChart).evaluate().isNotEmpty);
    await tester.ensureVisible(find.byType(BarChart));
    await tester.pumpAndSettle();
    final data = tester.widget<BarChart>(find.byType(BarChart)).data;
    expect(data.barGroups.map((bar) => bar.barRods.single.toY),
        [0, 0, 0, 1, 0, 2]);
    expect(data.maxY, greaterThan(2));
    final last = data.barGroups.last;
    final tooltip = data.barTouchData.touchTooltipData
        .getTooltipItem(last, 5, last.barRods.single, 0);
    expect(tooltip!.text, '${now.year}年${now.month}月\n2 条');
    expect(find.textContaining('报告加载失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('书架查询失败保留旧列表，重新加载恢复且结束loading', () async {
    await db.insertBook({'book_id': 'b', 'title': '已有书籍', 'updated_at': 1});
    final shelf = BookshelfProvider();
    addTearDown(shelf.dispose);
    await shelf.loadBooks();
    probe.afterRead = (sql) {
      if (sql == 'books') throw StateError('read failed');
    };
    await shelf.loadBooks();
    expect(shelf.books.single.title, '已有书籍');
    expect(shelf.error, contains('read failed'));
    expect(shelf.isLoading, isFalse);
    probe.afterRead = null;
    await shelf.loadBooks();
    expect(shelf.error, isNull);
    expect(shelf.isLoading, isFalse);
  });

  testWidgets('同步失败清单只重试所选书籍，成功后更新统计且旧日志不可再次点击', (tester) async {
    final config = _SyncConfig();
    addTearDown(config.dispose);
    final requests = <RequestOptions>[];
    await WeReadApi.init(
        config: config.config,
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((request) {
            requests.add(request);
            return jsonResponse(request.path == '/book/bookmarklist'
                ? {
                    'updated': [
                      {'bookmarkId': 'm', 'markText': '划线'}
                    ]
                  }
                : {
                    'reviews': [
                      {'reviewId': 'n', 'content': '笔记'}
                    ]
                  });
          }));
    final result = SyncResult([
      BookSyncResult(Book(bookId: 'failed', title: '失败书'), 0, 0, ['上次失败']),
      BookSyncResult(Book(bookId: 'ok', title: '成功书'), 2, 3, []),
    ], 2);
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
        value: config,
        child: MaterialApp(home: SyncPage(initialResult: result))));
    await tester.pumpAndSettle();
    expect(find.textContaining('成功 1 本 / 失败 1 本'), findsOneWidget);
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    await pumpUntil(tester,
        () => find.textContaining('成功 2 本 / 失败 0 本').evaluate().isNotEmpty);
    expect(requests, hasLength(2));
    expect(
        requests
            .every((request) => request.queryParameters['bookId'] == 'failed'),
        isTrue);
    expect(find.textContaining('3 条划线，4 条笔记'), findsOneWidget);
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('同步验证失败不发起请求，恢复验证后可以重新同步', (tester) async {
    final config = _SyncConfig()..verified = false;
    addTearDown(config.dispose);
    var requests = 0;
    await WeReadApi.init(
        config: config.config,
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((_) {
            requests++;
            return jsonResponse({'books': []});
          }));
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
        value: config, child: const MaterialApp(home: SyncPage())));
    await tester.tap(find.text('需要联网 · 验证并同步'));
    await tester.pumpAndSettle();
    expect(find.text('验证失败，请重试'), findsOneWidget);
    expect(requests, 0);
    config.verified = true;
    config.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('重新同步'));
    await tester.pump();
    await pumpUntil(
        tester, () => find.textContaining('同步结束').evaluate().isNotEmpty);
    expect(requests, 1);
    expect(find.text('取消同步'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('书架同步入口失败后可重试，成功结果等待列表刷新完成', () async {
    final config = _SyncConfig();
    addTearDown(config.dispose);
    final shelf = BookshelfProvider();
    addTearDown(shelf.dispose);
    var failShelf = true;
    await WeReadApi.init(
        config: config.config,
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((request) {
            if (request.path == '/shelf/sync') {
              if (failShelf) return jsonResponse({'errcode': 123});
              return jsonResponse({
                'books': [
                  {'bookId': 'b', 'title': '新书'}
                ]
              });
            }
            return jsonResponse(request.path == '/book/bookmarklist'
                ? {'updated': []}
                : {'reviews': []});
          }));
    await expectLater(
        shelf.syncFromServer(config: config.config), throwsStateError);
    expect(shelf.error, isNotNull);
    expect(shelf.isLoading, isFalse);
    failShelf = false;
    expect(
        await shelf.syncFromServer(config: config.config), contains('成功 1 本'));
    expect(shelf.books.single.title, '新书');
    expect(shelf.lastSyncResult!.failureCount, 0);
    expect(shelf.error, isNull);
    expect(shelf.isLoading, isFalse);
  });
}
