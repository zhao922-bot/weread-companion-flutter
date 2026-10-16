import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/pages/sync_page.dart';
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;
import 'support/wait_until.dart';

class _SessionConfig extends AppConfigProvider {
  _SessionConfig()
      : super(config: AppConfig(cookie: 'wr_vid=123; wr_skey=test'));
  bool verified = true;
  int revision = 1;
  Completer<bool>? verification;
  @override
  bool get isLoggedIn => verified;
  @override
  bool get canBrowseLocal => true;
  @override
  int get sessionRevision => revision;
  @override
  String? get loginError => '旧验证错误';
  @override
  Future<bool> verifyForSync() async =>
      verification == null ? verified : await verification!.future;
  void switchSession() {
    revision++;
    notifyListeners();
  }
}

class _CountingBookshelf extends BookshelfProvider {
  int syncs = 0;
  @override
  Future<void> setActive(bool active) async {}
  @override
  Future<String> syncFromServer({AppConfig? config}) async {
    syncs++;
    return '同步完成';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late _SessionConfig config;
  late List<RequestOptions> requests;
  late FutureOr<ResponseBody> Function(RequestOptions) respond;
  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('weread-sync-exceptions-');
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
    config = _SessionConfig();
    requests = [];
    respond = (_) => jsonResponse({'books': []});
    await WeReadApi.init(
        config: config.config,
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((request) {
            requests.add(request);
            return respond(request);
          }));
  });
  tearDown(() async {
    config.dispose();
    WeReadApi.reset();
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });
  Future<void> show(WidgetTester tester,
      {SyncResult? result,
      Future<SyncService> Function(
              {AppConfig? config, bool Function()? isCancelled})
          serviceConnector = SyncService.connect}) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
        value: config,
        child: MaterialApp(
            home: SyncPage(
                initialResult: result, serviceConnector: serviceConnector))));
    await tester.pump();
  }

  SyncResult failedResult() => SyncResult([
        BookSyncResult(Book(bookId: 'b', title: '失败书'), 0, 0, ['上次失败'])
      ], 1);

  for (final valid in [true, false]) {
    testWidgets('书架入口验证${valid ? '成功' : '失败'}返回前切换账号，不启动旧同步或显示旧错误',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      config.verified = false;
      config.verification = Completer<bool>();
      final shelf = _CountingBookshelf();
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<AppConfigProvider>.value(value: config),
        ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
      ], child: const MaterialApp(home: BookshelfPage())));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步书架'));
      await tester.pump();
      config.switchSession();
      config.verification!.complete(valid);
      await tester.pumpAndSettle();
      expect(shelf.syncs, 0);
      expect(find.text('旧验证错误'), findsNothing);
      expect(find.text('同步完成'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      shelf.dispose();
    });
  }

  for (final interruption in ['取消', '退出', '切换账号']) {
    testWidgets('服务刚连接但尚未交付页面时$interruption，迟到服务被取消且不启动请求', (tester) async {
      final connecting = Completer<SyncService>();
      var calls = 0;
      var connections = 0;
      final service = SyncService(
          loadBooks: () async {
            calls++;
            return [];
          },
          loadBookmarks: (_) async => 0,
          loadNotes: (_) async => 0,
          // Deliberately independent of the page predicate: the owner must cancel it.
          isCancelled: () => false,
          onChanged: () {});
      await show(tester, serviceConnector: ({config, isCancelled}) {
        connections++;
        return connecting.future;
      });
      await tester.tap(find.text('开始同步'));
      await tester.pump();
      expect(connections, 1);
      if (interruption == '取消') {
        await tester.tap(find.text('取消同步'));
      } else if (interruption == '退出') {
        await tester.pumpWidget(const SizedBox());
      } else {
        config.switchSession();
      }
      await tester.pump();
      connecting.complete(service);
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(requests, isEmpty);
      expect((await service.syncAll()).cancelled, isTrue);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
      if (interruption == '取消') {
        expect(find.textContaining('同步已取消'), findsWidgets);
      } else if (interruption == '切换账号') {
        expect(find.text('账号已切换，请重新同步'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('取消连接后立即重试，旧连接返回不结束新操作或覆盖结果', (tester) async {
    final oldConnection = Completer<SyncService>();
    final newConnection = Completer<SyncService>();
    var connections = 0;
    var oldCalls = 0;
    var newCalls = 0;
    final oldService = SyncService(
        loadBooks: () async {
          oldCalls++;
          return [];
        },
        loadBookmarks: (_) async => 0,
        loadNotes: (_) async => 0,
        isCancelled: () => false,
        onChanged: () {});
    final newService = SyncService(
        loadBooks: () async {
          newCalls++;
          return [];
        },
        loadBookmarks: (_) async => 0,
        loadNotes: (_) async => 0,
        isCancelled: () => false,
        onChanged: () {});
    await show(tester,
        serviceConnector: ({config, isCancelled}) =>
            ++connections == 1 ? oldConnection.future : newConnection.future);
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await tester.tap(find.text('取消同步'));
    await tester.pump();
    await tester.tap(find.text('重新同步'));
    await tester.pump();
    oldConnection.complete(oldService);
    await tester.pump();
    expect(find.text('取消同步'), findsOneWidget);
    expect(oldCalls, 0);
    expect(newCalls, 0);
    newConnection.complete(newService);
    await tester.pumpAndSettle();
    expect(newCalls, 1);
    expect(find.text('取消同步'), findsNothing);
    expect(find.textContaining('同步结束：成功 0 本'), findsOneWidget);
    expect((await oldService.syncAll()).cancelled, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单书重试验证抛错后恢复按钮，下一次重试仍可成功', (tester) async {
    config.verified = false;
    config.verification = Completer<bool>();
    await show(tester, result: failedResult());
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    config.verification!
        .completeError(StateError('verification storage failed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('verification storage failed'), findsOneWidget);
    expect(find.text('取消同步'), findsNothing);
    expect(requests, isEmpty);
    config.verified = true;
    respond = (r) => jsonResponse(
        r.path == '/book/bookmarklist' ? {'updated': []} : {'reviews': []});
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    await pumpUntil(tester,
        () => find.textContaining('成功 1 本 / 失败 0 本').evaluate().isNotEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('账号切换后旧单书进度不能重新填回日志', (tester) async {
    final response = Completer<void>();
    respond = (r) async {
      if (r.path == '/shelf/sync') {
        return jsonResponse({
          'books': [
            {'bookId': 'old', 'title': '旧账号书籍'}
          ]
        });
      }
      await response.future;
      return jsonResponse(
          r.path == '/book/bookmarklist' ? {'updated': []} : {'reviews': []});
    };
    await show(tester);
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await pumpUntil(tester, () => requests.length == 3);
    config.switchSession();
    await tester.pump();
    response.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.textContaining('旧账号书籍'), findsNothing);
    expect(find.text('取消同步'), findsNothing);
    expect(find.textContaining('账号已切换'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('系统返回立即取消同步，退出动画中书架响应不再启动逐书请求', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final response = Completer<ResponseBody>();
    respond = (_) => response.future;
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
        value: config,
        child: MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
                body: TextButton(
                    onPressed: () => navigator.currentState!.push(
                        MaterialPageRoute<void>(
                            builder: (_) => const SyncPage())),
                    child: const Text('打开同步'))))));
    await tester.tap(find.text('打开同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await pumpUntil(tester, () => requests.isNotEmpty);
    await navigator.currentState!.maybePop();
    response.complete(jsonResponse({
      'books': [
        {'bookId': 'b', 'title': '迟到的书'}
      ]
    }));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(requests.map((r) => r.path), ['/shelf/sync']);
    expect(find.byType(SyncPage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('快速连点开始只运行一次同步', (tester) async {
    await show(tester);
    await tester.tap(find.text('开始同步'));
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await pumpUntil(
        tester, () => find.textContaining('同步结束').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单书重试响应晚于账号切换，不恢复旧失败清单或触发空结果异常', (tester) async {
    final response = Completer<void>();
    respond = (r) async {
      await response.future;
      return jsonResponse(
          r.path == '/book/bookmarklist' ? {'updated': []} : {'reviews': []});
    };
    await show(tester, result: failedResult());
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    await pumpUntil(tester, () => requests.length == 2);
    config.switchSession();
    await tester.pump();
    response.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.textContaining('失败书'), findsNothing);
    expect(find.textContaining('账号已切换'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单书重试验证晚于账号切换抛错，不显示过期错误', (tester) async {
    config.verified = false;
    config.verification = Completer<bool>();
    await show(tester, result: failedResult());
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    config.switchSession();
    await tester.pump();
    config.verification!
        .completeError(StateError('stale verification failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('stale verification failure'), findsNothing);
    expect(find.textContaining('账号已切换'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final success in [false, true]) {
    testWidgets('验证期间取消立即结束等待，迟到的$success验证结果不修改取消状态', (tester) async {
      config.verified = false;
      config.verification = Completer<bool>();
      await show(tester);
      await tester.tap(find.text('需要联网 · 验证并同步'));
      await tester.pump();
      await tester.tap(find.text('取消同步'));
      await tester.pump();
      expect(find.text('取消同步'), findsNothing);
      expect(find.textContaining('同步已取消'), findsOneWidget);
      config.verification!.complete(success);
      await tester.pumpAndSettle();
      expect(find.textContaining('旧验证错误'), findsNothing);
      expect(requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('账号切换后旧请求失败不污染当前页面，且停止旧同步状态', (tester) async {
    final response = Completer<ResponseBody>();
    respond = (_) => response.future;
    await show(tester);
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await pumpUntil(tester, () => requests.isNotEmpty);
    config.switchSession();
    await tester.pump();
    final wasSyncing = find.text('取消同步').evaluate().isNotEmpty;
    response.complete(jsonResponse({'errcode': 987654}));
    await tester.pumpAndSettle();
    expect(wasSyncing, isFalse);
    expect(find.textContaining('987654'), findsNothing);
    expect(find.textContaining('账号已切换'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧失败清单在API未初始化时仍可查看，不抛出空断言', (tester) async {
    WeReadApi.reset();
    config.verified = false;
    await show(tester, result: failedResult());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('点击重试此书'), findsOneWidget);
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pumpAndSettle();
    expect(find.textContaining('旧验证错误'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单书重试前重新验证，验证失败不能发送旧凭据请求', (tester) async {
    config.verified = false;
    await show(tester, result: failedResult());
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    await pumpUntil(tester, () => find.text('取消同步').evaluate().isEmpty);
    expect(requests, isEmpty);
    expect(find.textContaining('旧验证错误'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('书架接口失败后显示错误，可重新同步并接收单书进度', (tester) async {
    respond = (_) => jsonResponse({'errcode': 123});
    await show(tester);
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await pumpUntil(
        tester, () => find.textContaining('同步失败').evaluate().isNotEmpty);
    respond = (request) => jsonResponse(switch (request.path) {
          '/shelf/sync' => {
              'books': [
                {'bookId': 'b', 'title': '恢复后的书'}
              ]
            },
          '/book/bookmarklist' => {'updated': []},
          _ => {'reviews': []},
        });
    await tester.tap(find.text('重新同步'));
    await tester.pump();
    await pumpUntil(tester,
        () => find.textContaining('成功 1 本 / 失败 0 本').evaluate().isNotEmpty);
    expect(find.textContaining('恢复后的书'), findsOneWidget);
    expect(find.textContaining('同步失败'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单书部分成功后重试不重拉成功来源，统计保留已提交数量', (tester) async {
    var failNotes = true;
    respond = (request) => jsonResponse(switch (request.path) {
          '/shelf/sync' => {
              'books': [
                {'bookId': 'b', 'title': '部分失败书'}
              ]
            },
          '/book/bookmarklist' => {
              'updated': request.queryParameters['synckey'] == '0'
                  ? [
                      {'bookmarkId': 'm', 'markText': '已保存划线'}
                    ]
                  : [],
              'synckey': 'done'
            },
          _ => failNotes
              ? {'errcode': 123}
              : {
                  'reviews': [
                    {'reviewId': 'n', 'content': '恢复笔记'}
                  ]
                },
        });
    await show(tester);
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    await pumpUntil(
        tester, () => find.textContaining('点击重试此书').evaluate().isNotEmpty);
    expect(await tester.runAsync(() => db.countBookmarks()), 1);
    requests.clear();
    failNotes = false;
    await tester.tap(find.textContaining('点击重试此书'));
    await tester.pump();
    await pumpUntil(tester,
        () => find.textContaining('成功 1 本 / 失败 0 本').evaluate().isNotEmpty);
    expect(requests.map((r) => r.path), ['/review/list']);
    expect(find.textContaining('1 条划线，1 条笔记'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
