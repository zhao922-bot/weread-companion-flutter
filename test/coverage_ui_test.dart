import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/models/bookmark.dart';
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/main.dart' as application;
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/pages/ai_summary_page.dart';
import 'package:weread_companion/pages/cookie_login_page.dart';
import 'package:weread_companion/pages/sync_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'package:weread_companion/widgets/settings/account_settings_section.dart';
import 'package:weread_companion/widgets/settings/ai_settings_section.dart';
import 'package:weread_companion/widgets/settings/about_settings_section.dart';
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Config extends AppConfigProvider {
  _Config() : super(config: AppConfig());
  bool loggedIn = true;
  bool pendingCleanup = false;
  bool saved = true;
  String? message;
  int logouts = 0;
  Future<void> Function()? onLogout;
  Future<bool> Function()? onVerify;
  Future<void> Function()? onSave;
  @override
  Future<void> updateAiConfig(
          {String? apiKey, String? baseUrl, String? modelName}) async =>
      await onSave?.call();
  @override
  bool get isLoaded => true;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  bool get canBrowseLocal => saved;
  @override
  bool get hasSavedCredentials => saved;
  @override
  bool get cleanupPending => pendingCleanup;
  @override
  String? get loginError => message;
  @override
  Future<bool> verifyForSync() async => await onVerify?.call() ?? loggedIn;
  @override
  Future<void> logout() async {
    logouts++;
    await onLogout?.call();
  }
}

class _Shelf extends BookshelfProvider {
  String? problem;
  bool loading = false;
  List<Book> items = [];
  Future<String> Function()? onSync;
  @override
  String? get error => problem;
  @override
  bool get isLoading => loading;
  @override
  List<Book> get books => items;
  @override
  Future<void> setActive(bool active) async {}
  @override
  Future<String> syncFromServer({AppConfig? config}) async =>
      await onSync?.call() ?? '同步完成';
}

class _SummaryService extends AIService {
  _SummaryService(AppConfig config, this.summary) : super(config: config);
  final AISummary summary;
  @override
  bool get isConfigured => true;
  @override
  Future<AISummary> summarizeBook(
          String title, String author, List<NoteItem> notes) async =>
      summary;
}

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences(this.release) : super.empty();
  final Future<void> release;
  @override
  Future<Map<String, Object>> getAll() async {
    await release;
    return {'flutter.bookshelf_columns': 4};
  }
}

class _LateSync extends SyncService {
  _LateSync(this.release)
      : super(
            loadBooks: () async => [],
            loadBookmarks: (_) async => 0,
            loadNotes: (_) async => 0,
            isCancelled: () => false,
            onChanged: () {});
  final Future<void> release;
  bool started = false;
  @override
  Future<SyncResult> syncAll(
      {void Function(int)? onBooks,
      void Function(BookSyncResult, int)? onProgress}) async {
    started = true;
    await release;
    onBooks?.call(1);
    throw StateError('迟到失败');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  late PathProviderPlatform originalPaths;
  late _Config config;
  late _Shelf shelf;
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('weread-ui-coverage-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (_) async => null);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.database;
    config = _Config();
    shelf = _Shelf();
  });
  tearDown(() async {
    config.dispose();
    shelf.dispose();
    probe.afterRead = null;
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
    for (final channel in [secure, share]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  Widget app(Widget page) => MultiProvider(providers: [
        ChangeNotifierProvider<AppConfigProvider>.value(value: config),
        ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
      ], child: MaterialApp(home: page));
  Widget section(Widget child) =>
      app(Scaffold(body: SingleChildScrollView(child: child)));
  Future<void> seedCards(int count) => db.insertBookmarks(List.generate(
      count,
      (i) => {
            'bookmark_id': 'bm$i',
            'book_id': 'b',
            'book_title': '测试书',
            'mark_text': '引文$i',
            'chapter_title': '第一章',
            'created_at': i + 1,
          }));

  for (final page in ['书架', '笔记', '同步']) {
    testWidgets('$page首帧回调前销毁，不读取已失效的 context', (tester) async {
      final notes = NotesProvider();
      addTearDown(notes.dispose);
      final present = ValueNotifier(true);
      addTearDown(present.dispose);
      // Run teardown before the callbacks registered during the first build.
      // Use the binding's real root replacement/build/finalize lifecycle.
      tester.binding.addPostFrameCallback((_) {
        present.value = false;
        tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
        tester.binding.buildOwner!.finalizeTree();
      });
      await tester.pumpWidget(app(ChangeNotifierProvider<NotesProvider>.value(
        value: notes,
        child: ValueListenableBuilder<bool>(
            valueListenable: present,
            builder: (context, exists, _) => !exists
                ? const SizedBox.shrink()
                : switch (page) {
                    '书架' => const BookshelfPage(),
                    '笔记' => const NotesPage(),
                    _ => SyncPage(initialResult: SyncResult([], 0)),
                  }),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(BookshelfPage), findsNothing);
      expect(find.byType(NotesPage), findsNothing);
      expect(find.byType(SyncPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final transition in ['销毁', '退出']) {
    testWidgets('引用加载失败后$transition，旧重试回调不会查询或更新界面', (tester) async {
      await tester.runAsync(() => seedCards(1));
      probe.afterRead = (_) => throw StateError('读取失败');
      await tester.pumpWidget(app(NotesPage(
          database: db,
          reference: SummaryReference(
              noteId: 'bm0',
              bookId: 'b',
              source: NoteSource.bookmark,
              bookTitle: '测试书',
              content: '引文0',
              chapterTitle: '第一章',
              label: 'R1'))));
      await pumpUntil(tester, () => find.text('重试').evaluate().isNotEmpty);
      final retry = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '重试'))
          .onPressed!;
      if (transition == '销毁') {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        await tester.runAsync(DatabaseService.endSession);
      }
      probe.afterRead = null;
      final reads = probe.reads.length;
      retry();
      await tester.pumpAndSettle();
      expect(probe.reads.length, reads);
      expect(tester.takeException(), isNull);
    });
  }

  test('模型缺失时间字段自动补齐，诊断文本按长度截断', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final book = Book.fromJson({'bookId': 7, 'title': '书', 'author': '作者'});
    expect(book.updatedAt, inInclusiveRange(now, now + 1));
    expect(book.toString(), 'Book(7: 书 by 作者)');
    final short = Bookmark(bookmarkId: 's', bookId: 'b', markText: '短句');
    final long = Bookmark.fromJson({'bookmarkId': 'l', 'markText': '长' * 40});
    expect(short.createdAt, inInclusiveRange(now, now + 1));
    expect(long.createdAt, inInclusiveRange(now, now + 1));
    expect(short.toString(), 'Bookmark(s: 短句...)');
    expect(long.toString(), 'Bookmark(l: ${'长' * 30}...)');
  });

  for (final entry in {
    '404': '接口地址有误，请检查网络后重试',
    '401': 'Cookie 已过期，请重新导入',
    '302': 'Cookie 已过期，请重新导入',
    'timeout': '网络连接超时，请检查网络',
    '超时': '网络连接超时，请检查网络',
    'SocketException': '无法连接服务器，请检查网络',
    'Connection': '无法连接服务器，请检查网络',
    'Cookie 导入': '请先在设置中导入 Cookie',
    'errcode': 'Cookie 已失效，请重新导入',
    'unknown': '加载失败，请下拉刷新或检查网络',
  }.entries) {
    testWidgets('书架空列表错误 ${entry.key} 显示可理解的提示且可重试', (tester) async {
      shelf.problem = entry.key;
      shelf.lastSyncResult = SyncResult([], 0);
      await tester.pumpWidget(app(const BookshelfPage()));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      await tester.tap(find.text('同步书架'));
      await tester.pumpAndSettle();
      expect(find.text('同步完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final kind in ['验证失败', '验证异常', '同步异常', '部分失败', '成功']) {
    testWidgets('书架下拉同步处理$kind', (tester) async {
      shelf.items = [Book(bookId: 'b', title: '书架书')];
      if (kind == '验证失败' || kind == '验证异常') {
        config.loggedIn = false;
        if (kind == '验证异常') {
          config.onVerify = () async => throw StateError('验证网络错误');
        }
      }
      if (kind == '同步异常') shelf.onSync = () async => throw StateError('同步网络错误');
      shelf.lastSyncResult = SyncResult(
          kind == '部分失败'
              ? [
                  BookSyncResult(shelf.items.single, 0, 0, ['失败'])
                ]
              : [],
          1);
      await tester.pumpWidget(app(const BookshelfPage()));
      await tester.pumpAndSettle();
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      if (kind == '部分失败') {
        await tester.tap(find.text('失败清单'));
        await tester.pumpAndSettle();
        expect(find.byType(SyncPage), findsOneWidget);
      } else if (kind == '验证失败') {
        expect(find.text('本地数据可浏览；同步需要联网验证'), findsOneWidget);
      } else if (kind.endsWith('异常')) {
        expect(find.textContaining('同步失败:'), findsOneWidget);
      } else {
        expect(find.text('同步完成'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('书架空状态下拉同步、同步入口和书籍详情导航', (tester) async {
    shelf.lastSyncResult = SyncResult([], 0);
    await tester.pumpWidget(app(const BookshelfPage()));
    await tester.pumpAndSettle();
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('同步完成'), findsOneWidget);
    await tester.tap(find.byTooltip('同步数据'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    shelf.items = [Book(bookId: 'b', title: '可打开的书')];
    shelf.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.text('可打开的书').first);
    await pumpUntil(
        tester,
        () =>
            find.byType(BookDetailPage).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(find.byType(BookDetailPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('书架加载中显示进度，封面加载占位具备进度提示', (tester) async {
    shelf.loading = true;
    await tester.pumpWidget(app(const BookshelfPage()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    shelf.loading = false;
    shelf.items = [
      Book(bookId: 'b', title: '网络封面', cover: 'https://example.invalid/a.png')
    ];
    shelf.notifyListeners();
    await tester.pump();
    final cover = tester.widget<Image>(find.byType(Image));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => cover.loadingBuilder!(
                context,
                const SizedBox(),
                const ImageChunkEvent(
                    cumulativeBytesLoaded: 1, expectedTotalBytes: 10)))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片加载失败可重试，跳页校验、上一页和清除搜索正常', (tester) async {
    await tester.runAsync(() => seedCards(201));
    probe.afterRead = (sql) {
      if (sql == 'bookmarks') throw StateError('读卡片失败');
    };
    await tester.pumpWidget(app(const CardsPage()));
    await pumpUntil(tester, () => find.text('加载失败').evaluate().isNotEmpty);
    probe.afterRead = null;
    await tester.tap(find.text('重试'));
    await pumpUntil(tester, () => find.text('共 201 条').evaluate().isNotEmpty);
    expect(find.text('第一章'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(20);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
    await tester.tap(find.text('跳页'));
    await tester.pumpAndSettle();
    for (final value in ['abc', '0', '4']) {
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          value);
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
    }
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '2');
    await tester.tap(find.text('确定'));
    await pumpUntil(
        tester,
        () =>
            find.text('2/3').evaluate().isNotEmpty &&
            find.text('导出图片').evaluate().isNotEmpty);
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await pumpUntil(
        tester,
        () =>
            find.text('1/3').evaluate().isNotEmpty &&
            find.text('导出图片').evaluate().isNotEmpty);
    await tester.tap(find.text('跳页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '没有匹配');
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntil(tester, () => find.text('共 0 条').evaluate().isNotEmpty);
    final search = tester.widget<TextField>(find.byType(TextField));
    search.onChanged!('没有匹配');
    await tester.tap(find.byIcon(Icons.clear));
    await pumpUntil(tester, () => find.text('共 201 条').evaluate().isNotEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('笔记搜索清除恢复数据，并能打开摘要历史', (tester) async {
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await tester.runAsync(() => db.insertNote(
        {'note_id': 'n', 'book_id': 'b', 'content': '笔记内容', 'created_at': 1}));
    await tester.runAsync(notes.loadNotes);
    await tester.pumpWidget(ChangeNotifierProvider<NotesProvider>.value(
        value: notes, child: app(const NotesPage())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '无结果');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(notes.loadNotes);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.clear));
    await pumpUntil(
        tester, () => find.textContaining('笔记内容').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('历史摘要'));
    await pumpUntil(
        tester,
        () =>
            find.byType(AISummaryHistoryPage).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(find.byType(AISummaryHistoryPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情分享包含作者和前五条划线，并打开本书摘要历史', (tester) async {
    await tester.runAsync(() => seedCards(6));
    String? shared;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, (call) async {
      shared = (call.arguments as Map)['text'] as String;
      return 'success';
    });
    await tester.pumpWidget(app(BookDetailPage(
        book: Book(
            bookId: 'b',
            title: '测试书',
            author: '测试作者',
            cover: 'https://example.invalid/missing.png'),
        database: db)));
    await pumpUntil(
        tester, () => find.textContaining('引文5').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('分享'));
    await tester.pumpAndSettle();
    expect(shared, contains('测试作者'));
    expect(shared, contains('精彩划线'));
    expect(shared, contains('引文5'));
    expect(shared, isNot(contains('引文0')));
    await tester.tap(find.byTooltip('历史摘要'));
    await pumpUntil(
        tester,
        () =>
            find.byType(AISummaryHistoryPage).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(
        tester
            .widget<AISummaryHistoryPage>(find.byType(AISummaryHistoryPage))
            .bookId,
        'b');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('窄屏横向滚动可使用全部AI预设，密钥显示开关不丢失内容', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(section(const AiSettingsSection()));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    for (final preset in [
      'DeepSeek',
      'Qwen',
      'MiniMax',
      'Moonshot',
      'SiliconFlow'
    ]) {
      final button = find.widgetWithText(OutlinedButton, preset);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.textContaining('$preset ·'), findsOneWidget);
    }
    final keyField = find.widgetWithText(TextField, 'API Key');
    await tester.ensureVisible(keyField);
    await tester.pumpAndSettle();
    await tester.enterText(keyField, 'test-secret');
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pump();
    expect(tester.widget<TextField>(keyField).obscureText, isFalse);
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();
    expect(tester.widget<TextField>(keyField).obscureText, isTrue);
    expect(tester.widget<TextField>(keyField).controller!.text, 'test-secret');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final continueCleanup in [false, true]) {
    for (final failure in [false, true]) {
      testWidgets(
          '${continueCleanup ? '继续清理' : '退出登录'}${failure ? '失败' : '成功'}显示对应反馈',
          (tester) async {
        config.pendingCleanup = continueCleanup;
        if (failure) config.onLogout = () async => throw StateError('无法清理');
        await tester.pumpWidget(section(const AccountSettingsSection()));
        await tester.tap(find.text(continueCleanup ? '继续清理' : '退出登录'));
        await tester.pumpAndSettle();
        if (!continueCleanup) {
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(config.logouts, 0);
          await tester.tap(find.text('退出登录'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('退出'));
          await tester.pumpAndSettle();
        }
        expect(config.logouts, 1);
        expect(
            find.text(failure
                ? (continueCleanup ? '清理失败，请重试' : '退出登录失败，部分本地数据可能未清除，请重试')
                : (continueCleanup ? '本地数据清理完成' : '已退出登录')),
            findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final saved in [false, true]) {
    testWidgets('${saved ? '已有账号' : '未登录'}设置可打开Cookie导入', (tester) async {
      config.saved = saved;
      await tester.pumpWidget(section(const AccountSettingsSection()));
      await tester.tap(find.text(saved ? '微信读书账号' : '登录'));
      await tester.pumpAndSettle();
      expect(find.byType(CookieLoginPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('完整入口恢复可信账号并创建书架和笔记Provider', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'weread_trusted_account_id': '123'});
    await tester.runAsync(() => seedCards(1));
    application.main();
    await tester.pump();
    await pumpUntil(
        tester,
        () =>
            find.byType(BookshelfPage).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(find.text('离线模式：本地数据可浏览 · 同步需要联网验证'), findsOneWidget);
    await tester.tap(find.text('笔记'));
    await pumpUntil(
        tester, () => find.textContaining('引文0').evaluate().isNotEmpty);
    expect(find.byType(NotesPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('摘要成功打开结果，未知引用提示缺失，来源条目打开原笔记', (tester) async {
    final note = NoteItem(
        id: 'n',
        bookId: 'b',
        bookTitle: '原书',
        content: '核对原文',
        chapterTitle: '',
        createdAt: 1,
        isFav: false,
        source: NoteSource.note);
    await tester.runAsync(() => db.insertNote(
        {'note_id': 'n', 'book_id': 'b', 'content': '核对原文', 'created_at': 1}));
    final summary = AISummary(
        createdAt: 1,
        title: '生成结果',
        text: '观点 [R1] 和 [R99]',
        references: [SummaryReference.fromNote(note, 0)]);
    await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () => generateSummary(context, '原书', '', [note],
                    serviceFactory: (config) =>
                        _SummaryService(config, summary)),
                child: const Text('生成'))))));
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();
    expect(find.byType(AISummaryPage), findsOneWidget);
    final rich = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(rich.textSpan!.toPlainText(), contains('[R99]（引用不存在）'));
    await tester.tap(find.byType(ListTile));
    await pumpUntil(tester, () => find.text('核对原文').evaluate().isNotEmpty);
    expect(find.byType(NotesPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final disposed in [false, true]) {
    testWidgets('AI配置加载失败${disposed ? '且页面销毁时忽略错误' : '显示具体失败'}',
        (tester) async {
      final gate = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secure, (_) async {
        await gate.future;
        throw PlatformException(code: 'key-store');
      });
      late BuildContext owner;
      await tester.pumpWidget(app(Builder(builder: (context) {
        owner = context;
        return const Scaffold();
      })));
      final pending = generateSummary(owner, '书', '', []);
      await tester.pump();
      if (disposed) await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pumpAndSettle();
      await pending;
      expect(find.textContaining('AI 配置加载失败'),
          disposed ? findsNothing : findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await generateSummary(owner, '书', '', []);
      expect(tester.takeException(), isNull);
    });
  }

  for (final cleanup in [false, true]) {
    for (final fail in [false, true]) {
      testWidgets(
          '${cleanup ? '继续清理' : '退出登录'}期间销毁页面，迟到${fail ? '失败' : '成功'}不更新UI',
          (tester) async {
        final gate = Completer<void>();
        config.pendingCleanup = cleanup;
        config.onLogout = () async {
          await gate.future;
          if (fail) throw StateError('清理失败');
        };
        await tester
            .pumpWidget(section(AccountSettingsSection(key: UniqueKey())));
        await tester.tap(find.text(cleanup ? '继续清理' : '退出登录'));
        await tester.pumpAndSettle();
        if (!cleanup) {
          await tester.tap(find.text('退出'));
          await tester.pumpAndSettle();
        }
        expect(config.logouts, 1);
        await tester.pumpWidget(const SizedBox());
        gate.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('AI设置保存迟到失败不在销毁后显示反馈', (tester) async {
    final gate = Completer<void>();
    config.onSave = () async {
      await gate.future;
      throw StateError('保存失败');
    };
    await tester.pumpWidget(section(const AiSettingsSection()));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('版本查询失败有反馈，查询中销毁不更新UI', (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    var gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      await gate.future;
      throw PlatformException(code: 'version-error');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(section(const AboutSettingsSection()));
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.text('当前版本：读取版本中…'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('版本读取失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    gate = Completer<void>();
    await tester.pumpWidget(section(const AboutSettingsSection()));
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情手动加载更多及无数据版本变化的刷新保留已加载范围', (tester) async {
    await tester.runAsync(() => seedCards(201));
    await tester.pumpWidget(app(
        BookDetailPage(book: Book(bookId: 'b', title: '测试书'), database: db)));
    await pumpUntil(
        tester, () => find.textContaining('引文200').evaluate().isNotEmpty);
    final listFinder = find.descendant(
        of: find.byType(BookDetailPage), matching: find.byType(ListView));
    final list = tester.widget<ListView>(listFinder);
    final footer = (list.childrenDelegate as SliverChildBuilderDelegate)
        .builder(tester.element(listFinder), 107) as TextButton;
    expect((footer.child as Text).data, '加载更多');
    footer.onPressed!();
    await pumpUntil(
        tester,
        () =>
            (tester.widget<ListView>(listFinder).childrenDelegate
                    as SliverChildBuilderDelegate)
                .childCount ==
            208);
    final before = probe.reads.length;
    SyncService.changes.publish(db, favoritesOnly: true);
    await pumpUntil(
        tester, () => probe.reads.skip(before).any((read) => read.rows == 200));
    expect(
        (tester.widget<ListView>(listFinder).childrenDelegate
                as SliverChildBuilderDelegate)
            .childCount,
        208);
    final reads = probe.reads.where((read) => read.sql != 'books').length;
    SyncService.changes.publish(db, bookIds: {'unrelated'});
    await tester.pumpAndSettle();
    expect(probe.reads.where((read) => read.sql != 'books').length, reads);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情首屏读取时收藏提交会重读快照，旧读取不覆盖新收藏', (tester) async {
    await tester.runAsync(() => seedCards(1));
    await tester.pumpWidget(app(
        BookDetailPage(book: Book(bookId: 'b', title: '测试书'), database: db)));
    await pumpUntil(tester, () => find.byTooltip('收藏笔记').evaluate().isNotEmpty);
    final favorite = tester
        .widget<IconButton>(find.byKey(const ValueKey('favorite-bookmark:bm0')))
        .onPressed!;
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh;
    late Completer<void> entered;
    late Completer<void> release;
    late Future<void> pending;
    await tester.runAsync(() async {
      entered = Completer<void>();
      release = Completer<void>();
      var gated = false;
      probe.afterRead = (sql) async {
        if (!gated && sql.contains('AS reading_items')) {
          gated = true;
          entered.complete();
          await release.future;
        }
      };
      pending = refresh();
      await entered.future;
      var published = false;
      void onChange() => published = true;
      SyncService.changes.addListener(onChange);
      try {
        favorite();
        await waitUntil(() => published);
      } finally {
        SyncService.changes.removeListener(onChange);
      }
      release.complete();
      await pending;
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    favorite();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('笔记首次加载和加载更多时展示等待状态', (tester) async {
    final provider = NotesProvider(isActive: false);
    addTearDown(provider.dispose);
    await tester.runAsync(() => seedCards(101));
    late Completer<void> entered;
    late Completer<void> release;
    late Future<void> loading;
    await tester.runAsync(() async {
      entered = Completer<void>();
      release = Completer<void>();
      probe.afterRead = (sql) async {
        if (sql.contains('COUNT') && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      loading = provider.setActive(true);
      await entered.future;
    });
    await tester.pumpWidget(ChangeNotifierProvider<NotesProvider>.value(
        value: provider, child: app(const NotesPage())));
    await tester.pump();
    expect(find.text('正在加载笔记...'), findsOneWidget);
    await tester.runAsync(() async {
      release.complete();
      await loading;
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      entered = Completer<void>();
      release = Completer<void>();
      probe.afterRead = (sql) async {
        if (sql.contains('AS reading_items')) {
          entered.complete();
          await release.future;
        }
      };
      loading = provider.loadMore();
      await entered.future;
    });
    await tester.pump();
    final listFinder = find.byType(ListView).last;
    final list = tester.widget<ListView>(listFinder);
    final footer = (list.childrenDelegate as SliverChildBuilderDelegate)
        .builder(tester.element(listFinder), 100) as Center;
    expect(footer.child, isA<CircularProgressIndicator>());
    await tester.runAsync(() async {
      release.complete();
      await loading;
    });
    await tester.pumpAndSettle();
    expect(provider.notes, hasLength(101));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Cookie页面销毁后粘贴提交和扫码回调均不访问平台', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(const CookieLoginPage()));
    await tester.pumpAndSettle();
    final actions = [
      tester
          .widget<IconButton>(find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '从剪贴板粘贴'))
          .onPressed!,
      tester
          .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, '确认导入并验证'))
          .onPressed!,
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '扫码登录'))
          .onPressed!,
    ];
    await tester.pumpWidget(const SizedBox());
    for (final action in actions) {
      action();
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final transition in ['隐藏', '销毁']) {
    testWidgets('页码弹窗打开后$transition原页面，确认不能翻页或访问旧State', (tester) async {
      await tester.runAsync(() => seedCards(101));
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(app(ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, value, child) => transition == '销毁' && !value
              ? const Scaffold(body: Text('其他页面'))
              : CardsPage(isActive: value))));
      await pumpUntil(tester, () => find.text('共 101 条').evaluate().isNotEmpty);
      await tester.tap(find.text('跳页'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          '2');
      visible.value = false;
      await tester.pumpAndSettle();
      final reads = probe.reads.length;
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(probe.reads.length, reads);
      if (transition == '隐藏') {
        expect(find.text('1/2', skipOffstage: false), findsOneWidget);
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final operation in [
    '详情列表',
    '详情列表计数',
    '详情收藏刷新',
    '详情收藏计数',
    '详情摘要',
    '历史列表'
  ]) {
    testWidgets('$operation读取已完成但回调未返回时销毁，不继续查询或导航', (tester) async {
      await tester.runAsync(() => seedCards(1));
      final isHistory = operation == '历史列表';
      if (!isHistory) {
        await tester.pumpWidget(app(BookDetailPage(
            book: Book(bookId: 'b', title: '测试书'), database: db)));
        await pumpUntil(
            tester, () => find.byTooltip('收藏笔记').evaluate().isNotEmpty);
      }
      final refresh = isHistory
          ? null
          : tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh;
      final summary = isHistory
          ? null
          : tester
              .widget<IconButton>(find.byWidgetPredicate((widget) =>
                  widget is IconButton && widget.tooltip == 'AI 摘要'))
              .onPressed!;
      late Completer<void> entered;
      late Completer<void> release;
      await tester.runAsync(() async {
        entered = Completer<void>();
        release = Completer<void>();
        probe.afterRead = (sql) async {
          if (!entered.isCompleted &&
              (operation != '详情列表' || sql.contains('AS reading_items')) &&
              (operation != '详情收藏计数' || sql.contains('COUNT'))) {
            entered.complete();
            await release.future;
          }
        };
      });
      if (isHistory) {
        await tester.pumpWidget(app(AISummaryHistoryPage(database: db)));
      } else {
        await tester.runAsync(() async {
          if (operation.startsWith('详情列表')) {
            unawaited(refresh!());
          }
          if (operation == '详情摘要') summary!();
          if (operation.startsWith('详情收藏')) {
            SyncService.changes
                .publish(db, favoritesOnly: true, itemIds: {'bookmark:bm0'});
          }
        });
      }
      await tester.runAsync(() => entered.future);
      await tester.pumpWidget(const SizedBox());
      final reads = probe.reads.length;
      await tester.runAsync(() async {
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(probe.reads.length, reads);
      expect(tester.takeException(), isNull);
      expect(find.byType(AISummaryPage), findsNothing);
    });
  }

  for (final reference in [false, true]) {
    testWidgets('${reference ? '引用笔记' : '详情笔记'}收藏写入后页面销毁，不广播或显示错误',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => seedCards(1));
      await tester.pumpWidget(app(reference
          ? NotesPage(
              database: db,
              reference: SummaryReference(
                  content: '引文0',
                  label: 'N1',
                  source: NoteSource.bookmark,
                  noteId: 'bm0',
                  bookId: 'b',
                  bookTitle: '测试书',
                  chapterTitle: '第一章'))
          : BookDetailPage(
              book: Book(bookId: 'b', title: '测试书'), database: db)));
      final favorite = reference
          ? find.byIcon(Icons.star_border_rounded)
          : find.byTooltip('收藏笔记');
      await pumpUntil(tester, () => favorite.evaluate().isNotEmpty);
      late Completer<void> entered;
      late Completer<void> release;
      await tester.runAsync(() async {
        entered = Completer<void>();
        release = Completer<void>();
        probe.afterUpdate = (_) async {
          entered.complete();
          await release.future;
        };
      });
      var events = 0;
      void onChange() => events++;
      SyncService.changes.addListener(onChange);
      addTearDown(() => SyncService.changes.removeListener(onChange));
      await tester.ensureVisible(favorite);
      await tester.pumpAndSettle();
      await tester.tap(favorite);
      await tester.runAsync(() => entered.future);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect((await db.getBookmarksByBook('b')).single['is_fav'], 1);
      });
      await tester.pumpAndSettle();
      expect(events, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('详情已销毁或会话关闭时旧复制摘要与历史入口停止', (tester) async {
    await tester.runAsync(() => seedCards(1));
    await tester.pumpWidget(app(
        BookDetailPage(book: Book(bookId: 'b', title: '测试书'), database: db)));
    await pumpUntil(tester, () => find.byTooltip('收藏笔记').evaluate().isNotEmpty);
    final actions = ['复制笔记', 'AI 摘要', '历史摘要']
        .map((label) => tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == label))
            .onPressed!)
        .toList();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(DatabaseService.endSession);
    for (final action in actions) {
      action();
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('笔记摘要读取成功返回前销毁，不再打开生成弹窗', (tester) async {
    final provider = NotesProvider();
    addTearDown(provider.dispose);
    await tester.runAsync(() async {
      await seedCards(1);
      await provider.loadNotes();
    });
    await tester.pumpWidget(ChangeNotifierProvider<NotesProvider>.value(
        value: provider, child: app(const NotesPage())));
    await tester.pumpAndSettle();
    late Completer<void> entered;
    late Completer<void> release;
    await tester.runAsync(() async {
      entered = Completer<void>();
      release = Completer<void>();
      probe.afterRead = (_) async {
        entered.complete();
        await release.future;
      };
    });
    await tester.tap(find.byTooltip('AI 摘要'));
    await tester.runAsync(() => entered.future);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片忽略纯笔记事件，搜索期间旧跳页回调不打开弹窗', (tester) async {
    await tester.runAsync(() => seedCards(1));
    await tester.pumpWidget(app(const CardsPage()));
    await pumpUntil(tester, () => find.text('共 1 条').evaluate().isNotEmpty);
    final jump = tester
        .widget<GestureDetector>(find
            .ancestor(
                of: find.text('跳页'), matching: find.byType(GestureDetector))
            .first)
        .onTap!;
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh;
    final reads = probe.reads.where((read) => read.sql != 'books').length;
    SyncService.changes.publish(db, sources: {'note'});
    await tester.pumpAndSettle();
    expect(probe.reads.where((read) => read.sql != 'books').length, reads);
    await tester.enterText(find.byType(TextField), '搜索');
    jump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await refresh();
    expect(tester.takeException(), isNull);
  });

  testWidgets('报表销毁后旧下拉刷新回调不读取数据库', (tester) async {
    await tester.pumpWidget(app(const ReportPage()));
    await pumpUntil(
        tester, () => find.byType(RefreshIndicator).evaluate().isNotEmpty);
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh;
    await tester.pumpWidget(const SizedBox());
    final reads = probe.reads.length;
    await refresh();
    expect(probe.reads.length, reads);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书架密度配置读取完成前页面移除，不访问旧State', (tester) async {
    final gate = Completer<void>();
    SharedPreferencesStorePlatform.instance = _DelayedPreferences(gate.future);
    await tester.pumpWidget(app(const BookshelfPage()));
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步服务取消后仍回传书架与错误，已销毁页面忽略全部回调', (tester) async {
    final gate = Completer<void>();
    final service = _LateSync(gate.future);
    await tester.pumpWidget(app(
        SyncPage(serviceConnector: ({config, isCancelled}) async => service)));
    await tester.tap(find.text('开始同步'));
    await tester.pump();
    expect(service.started, isTrue);
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('迟到失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final operation in ['复制', '收藏失败']) {
    testWidgets('详情$operation返回前销毁页面，不显示提示或报错', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => seedCards(1));
      await tester.pumpWidget(app(
          BookDetailPage(book: Book(bookId: 'b', title: '测试书'), database: db)));
      await pumpUntil(
          tester, () => find.byTooltip('收藏笔记').evaluate().isNotEmpty);
      late Completer<void> entered;
      late Completer<void> release;
      await tester.runAsync(() async {
        entered = Completer<void>();
        release = Completer<void>();
        if (operation == '复制') {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              entered.complete();
              await release.future;
            }
            return null;
          });
        } else {
          probe.afterUpdate = (_) async {
            entered.complete();
            await release.future;
            throw StateError('收藏失败');
          };
        }
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.byTooltip(operation == '复制' ? '复制笔记' : '收藏笔记'));
      await tester.runAsync(() => entered.future);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('重新同步清空失败列表后旧重试点击不崩溃或启动额外任务', (tester) async {
    final failure =
        BookSyncResult(Book(bookId: 'b', title: '失败书'), 0, 0, ['网络失败']);
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final service = _LateSync(gate.future);
    var connections = 0;
    await tester.pumpWidget(app(SyncPage(
        initialResult: SyncResult([failure], 1),
        serviceConnector: ({config, isCancelled}) async {
          connections++;
          return service;
        })));
    await tester.pumpAndSettle();
    final retry = tester
        .widget<GestureDetector>(find
            .ancestor(
                of: find.textContaining('点击重试此书'),
                matching: find.byType(GestureDetector))
            .first)
        .onTap!;
    final start = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '开始同步'))
        .onPressed!;
    start();
    expect(retry, returnsNormally);
    await tester.pump();
    expect(connections, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(retry, returnsNormally);
    await tester.pump();
    expect(connections, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('报表月份图表拒绝范围外索引，合法月份仍显示刻度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => db.insertNote({
          'note_id': 'current',
          'book_id': 'b',
          'content': '本月笔记',
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000
        }));
    await tester.pumpWidget(app(const ReportPage()));
    await pumpUntil(tester, () => find.byType(BarChart).evaluate().isNotEmpty);
    final titles = tester
        .widget<BarChart>(find.byType(BarChart))
        .data
        .titlesData
        .bottomTitles
        .sideTitles;
    final meta = TitleMeta(
        min: 0,
        max: 5,
        parentAxisSize: 600,
        axisPosition: 0,
        appliedInterval: 1,
        sideTitles: titles,
        formattedValue: '',
        axisSide: AxisSide.bottom);
    expect(titles.getTitlesWidget(-1, meta), isA<SizedBox>());
    expect(titles.getTitlesWidget(6, meta), isA<SizedBox>());
    expect(titles.getTitlesWidget(0, meta), isA<SideTitleWidget>());
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in ['开始', '重试', '取消']) {
    testWidgets('同步页销毁后残留的$action回调安全退出', (tester) async {
      final gate = Completer<void>();
      final service = _LateSync(gate.future);
      final failure =
          BookSyncResult(Book(bookId: 'b', title: '失败书'), 0, 0, ['失败']);
      var connections = 0;
      await tester.pumpWidget(app(SyncPage(
          initialResult: action == '重试' ? SyncResult([failure], 1) : null,
          serviceConnector: ({config, isCancelled}) async {
            connections++;
            return service;
          })));
      await tester.pumpAndSettle();
      late VoidCallback callback;
      if (action == '重试') {
        callback = tester
            .widget<GestureDetector>(find
                .ancestor(
                    of: find.textContaining('点击重试此书'),
                    matching: find.byType(GestureDetector))
                .first)
            .onTap!;
      } else if (action == '开始') {
        callback = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始同步'))
            .onPressed!;
      } else {
        await tester.tap(find.text('开始同步'));
        await tester.pump();
        callback = tester
            .widget<OutlinedButton>(find.byType(OutlinedButton))
            .onPressed!;
      }
      await tester.pumpWidget(const SizedBox());
      expect(callback, returnsNormally);
      gate.complete();
      await tester.pumpAndSettle();
      expect(connections, action == '取消' ? 1 : 0);
      expect(tester.takeException(), isNull);
    });
  }
}
