import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/main.dart';
import 'package:weread_companion/models/ai_summary.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/models/bookshelf_filter.dart';
import 'package:weread_companion/pages/ai_summary_page.dart';
import 'package:weread_companion/pages/book_detail_page.dart';
import 'package:weread_companion/pages/bookshelf_page.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/pages/notes_page.dart';
import 'package:weread_companion/pages/report_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/providers/theme_controller.dart';
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'package:weread_companion/widgets/settings/ai_settings_section.dart';
import 'support/wait_until.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _FakeAppConfigProvider extends AppConfigProvider {
  _FakeAppConfigProvider({this.local = true}) : super(config: AppConfig());
  final bool local;
  @override
  bool get isLoaded => true;
  @override
  bool get canBrowseLocal => local;
  @override
  bool get isLoggedIn => local;
}

class _StubAI extends AIService {
  _StubAI(
    AppConfig config, {
    this.configured = true,
    this.onTest,
    this.onAnalyze,
    this.onInterpret,
    this.onSummarize,
  }) : super(config: config);

  final bool configured;
  final Future<String> Function()? onTest;
  final Future<String> Function()? onAnalyze;
  final Future<String> Function()? onInterpret;
  final Future<AISummary> Function(
    void Function(String)? onDelta,
    CancelToken? cancelToken,
  )? onSummarize;

  @override
  bool get isConfigured => configured;

  @override
  Future<String> testConnection({CancelToken? cancelToken}) =>
      onTest?.call() ?? Future.value('OK');

  @override
  Future<String> analyzeReading(List<String> bookTitles, int bookmarkCount) =>
      onAnalyze?.call() ?? Future.value('偏好科技与历史');

  @override
  Future<String> interpretQuote(String text, String bookTitle) =>
      onInterpret?.call() ?? Future.value('这句话含义深刻');

  @override
  Future<AISummary> summarizeBook(
    String title,
    String author,
    List<NoteItem> notes, {
    SummaryStyle style = SummaryStyle.standard,
    void Function(String delta)? onDelta,
    CancelToken? cancelToken,
  }) =>
      onSummarize!(onDelta, cancelToken);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory dir;
  late DatabaseService db;
  late PathProviderPlatform originalPaths;
  late _FakeAppConfigProvider config;
  late BookshelfProvider shelf;
  late NotesProvider notes;
  late ThemeController theme;
  bool failShare = false;

  setUp(() async {
    sqfliteFfiInit();
    failShare = false;
    dir = await Directory.systemTemp.createTemp('readamber-v3-ui-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(dir.path);
    databaseFactory = databaseFactoryFfiNoIsolate;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, (_) async {
      if (failShare) throw PlatformException(code: 'share_failed');
      return 'ok';
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    await DatabaseService.selectAccount('8001');
    db = DatabaseService.instance;
    await db.database;
    config = _FakeAppConfigProvider();
    shelf = BookshelfProvider();
    notes = NotesProvider();
    theme = ThemeController();
  });

  tearDown(() async {
    config.dispose();
    shelf.dispose();
    notes.dispose();
    theme.dispose();
    await DatabaseService.endSession();
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(share, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await dir.delete(recursive: true);
  });

  Widget wrap(Widget home, {AppConfigProvider? cfg}) => MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<AppConfigProvider>.value(value: cfg ?? config),
          ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
          ChangeNotifierProvider<NotesProvider>.value(value: notes),
        ],
        child: MaterialApp(home: home),
      );

  Future<void> clearSnackBars(WidgetTester tester) async {
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
        .clearSnackBars();
    await tester.pump();
  }

  testWidgets('MainScreen 未登录点击前往登录跳转设置，宽屏显示 NavigationRail', (tester) async {
    final guest = _FakeAppConfigProvider(local: false);
    addTearDown(guest.dispose);
    await tester.pumpWidget(wrap(const MainScreen(), cfg: guest));
    await tester.pumpAndSettle();
    expect(find.text('前往登录'), findsOneWidget);
    await tester.tap(find.text('前往登录'));
    await tester.pumpAndSettle();
    expect(find.text('数据与备份'), findsOneWidget);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('BookshelfPage 排序菜单切换正常', (tester) async {
    await tester.runAsync(() => db.insertBooks([
          {'book_id': '1', 'title': '乙书', 'progress': 30, 'updated_at': 10},
          {'book_id': '2', 'title': '甲书', 'progress': 90, 'updated_at': 20},
        ]));
    await tester.pumpWidget(wrap(const BookshelfPage()));
    await pumpUntil(tester, () => find.text('甲书').evaluate().isNotEmpty);
    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书名排序'));
    await tester.pumpAndSettle();
    expect(shelf.sort, BookshelfSort.title);
  });

  testWidgets('BookDetailPage 书内搜索、章节分组、单书导出与单书同步', (tester) async {
    final book = Book(bookId: 'b1', title: '测试书', author: '作者', progress: 60);
    await tester.runAsync(() async {
      await db.insertBook(book.toJson());
      await db.insertBookmark({
        'bookmark_id': 'bm1',
        'book_id': 'b1',
        'book_title': '测试书',
        'mark_text': '苹果内容',
        'chapter_title': '第一章',
        'created_at': 100,
      });
      await db.insertNote({
        'note_id': 'n1',
        'book_id': 'b1',
        'book_title': '测试书',
        'content': '香蕉笔记',
        'chapter_title': '第二章',
        'created_at': 200,
      });
    });

    int syncMode = 0; // 0 ok, 1 partial, 2 throw
    SyncService makeSync() => SyncService(
          loadBooks: () async => [book],
          loadBookmarks: (_) async => 2,
          loadNotes: (_) async {
            if (syncMode == 1) throw StateError('笔记失败');
            return 1;
          },
          isCancelled: () => false,
          onChanged: () {},
        );

    await tester.pumpWidget(wrap(BookDetailPage(
      book: book,
      database: db,
      syncServiceFactory: () async {
        if (syncMode == 2) throw StateError('连接失败');
        return makeSync();
      },
    )));
    await pumpUntil(tester, () => find.text('2条').evaluate().isNotEmpty);

    // 章节分组切换
    await tester.scrollUntilVisible(find.byTooltip('按章节分组显示'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byTooltip('按章节分组显示'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭章节分组'), findsOneWidget);

    // 书内搜索：输入无匹配 -> 清除 -> 关闭
    await tester.tap(find.byTooltip('搜索本书'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在关键词');
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntil(tester, () => find.text('没有匹配的书内记录').evaluate().isNotEmpty);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntil(tester, () => find.text('2条').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), '香蕉');
    await tester.tap(find.byTooltip('关闭书内搜索'));
    await tester.pump(const Duration(milliseconds: 350));

    // 单书导出成功 & 失败
    await clearSnackBars(tester);
    await tester.tap(find.byTooltip('导出本书 Markdown'));
    await pumpUntil(
        tester, () => find.text('本书 Markdown 已导出').evaluate().isNotEmpty);
    expect(find.text('本书 Markdown 已导出'), findsOneWidget);

    await clearSnackBars(tester);
    failShare = true;
    await tester.tap(find.byTooltip('导出本书 Markdown'));
    await pumpUntil(
        tester, () => find.textContaining('导出失败').evaluate().isNotEmpty);
    expect(find.textContaining('导出失败'), findsOneWidget);

    // 单书同步：成功、部分失败、抛错
    await clearSnackBars(tester);
    await tester.tap(find.byTooltip('同步本书'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已同步 2 条划线'), findsOneWidget);

    await clearSnackBars(tester);
    syncMode = 1;
    await tester.tap(find.byTooltip('同步本书'));
    await tester.pumpAndSettle();
    expect(find.textContaining('单书同步部分失败'), findsOneWidget);

    await clearSnackBars(tester);
    syncMode = 2;
    await tester.tap(find.byTooltip('同步本书'));
    await tester.pumpAndSettle();
    expect(find.textContaining('单书同步失败'), findsOneWidget);

    // 默认 syncServiceFactory（未登录直接走 SyncService.connect()）
    await tester.pumpWidget(wrap(BookDetailPage(book: book, database: db)));
    await pumpUntil(tester, () => find.text('2条').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('同步本书'));
    await tester.pumpAndSettle();
    expect(find.textContaining('单书同步失败'), findsOneWidget);
  });

  testWidgets('NotesPage 每日回顾、按书筛选、复制、AI解读与查看本书', (tester) async {
    int aiMode = 0; // 0 unconfigured, 1 ok, 2 error
    await tester.pumpWidget(wrap(NotesPage(
      aiServiceFactory: (c) => _StubAI(
        c,
        configured: aiMode != 0,
        onInterpret: () async {
          if (aiMode == 2) throw StateError('boom');
          return '深刻解读内容';
        },
      ),
    )));
    await pumpUntil(tester, () => find.text('暂无笔记，请先同步书架').evaluate().isNotEmpty);

    // 每日回顾空状态
    await tester.tap(find.byTooltip('每日回顾'));
    await tester.pumpAndSettle();
    expect(find.text('暂无可回顾的划线与笔记'), findsOneWidget);
    Navigator.of(tester.element(find.text('每日回顾'))).pop();
    await tester.pumpAndSettle();

    // 插入书籍与笔记
    await tester.runAsync(() async {
      await db.insertBook({'book_id': 'b1', 'title': '测试书', 'updated_at': 10});
      await db.insertBookmark({
        'bookmark_id': 'bm1',
        'book_id': 'b1',
        'book_title': '测试书',
        'mark_text': '经典划线内容',
        'chapter_title': '第一章',
        'created_at': 100,
      });
      await db.insertNote({
        'note_id': 'n2',
        'book_id': 'b2',
        'book_title': '无书架书',
        'content': '孤立笔记',
        'chapter_title': '',
        'created_at': 200,
      });
    });
    await tester.runAsync(notes.loadNotes);
    await tester.pumpAndSettle();

    // 每日回顾有数据 + 换一批
    await tester.tap(find.byTooltip('每日回顾'));
    await tester.pumpAndSettle();
    expect(find.text('换一批'), findsOneWidget);
    await tester.tap(find.text('换一批'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('每日回顾'))).pop();
    await tester.pumpAndSettle();

    // 按书筛选：取消关闭 -> 选定书 -> 选回全部
    await tester.tap(find.text('按书筛选'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('按书籍筛选'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('按书筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试书').last);
    await tester.pumpAndSettle();
    expect(notes.selectedBookId, 'b1');
    await tester.tap(find.text('测试书').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部书籍'));
    await tester.pumpAndSettle();
    expect(notes.selectedBookId, isNull);

    // 复制原文
    await clearSnackBars(tester);
    await tester.tap(find.byTooltip('复制原文').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已复制到剪贴板'), findsOneWidget);

    // AI 解读：未配置 / 成功 / 失败
    await clearSnackBars(tester);
    await tester.tap(find.byTooltip('AI 解读').first);
    await tester.pumpAndSettle();
    expect(find.text('请先在设置中配置 AI API'), findsOneWidget);

    await clearSnackBars(tester);
    aiMode = 1;
    await tester.tap(find.byTooltip('AI 解读').first);
    await tester.pumpAndSettle();
    expect(find.text('深刻解读内容'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await clearSnackBars(tester);
    aiMode = 2;
    await tester.tap(find.byTooltip('AI 解读').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('AI 解读失败'), findsOneWidget);

    // 查看本书（包含无 books 记录的回退与有 books 记录）
    await tester.tap(find.byTooltip('查看本书').first);
    await tester.pumpAndSettle();
    expect(find.byType(BookDetailPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(BookDetailPage))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('查看本书').last);
    await tester.pumpAndSettle();
    expect(find.byType(BookDetailPage), findsOneWidget);
  });

  testWidgets('CardsPage 模板切换、排版开关与 AI 金句解读', (tester) async {
    await tester.runAsync(() => db.insertBookmark({
          'bookmark_id': 'bm1',
          'book_id': 'b1',
          'book_title': '测试书',
          'mark_text': '山高水长',
          'chapter_title': '序章',
          'created_at': 100,
        }));
    int aiMode = 0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap(CardsPage(
      aiServiceFactory: (c) => _StubAI(
        c,
        configured: aiMode != 0,
        onInterpret: () async {
          if (aiMode == 2) throw StateError('fail');
          return '金句意境悠远';
        },
      ),
    )));
    await pumpUntil(tester, () => find.text('墨青').evaluate().isNotEmpty);

    await tester.tap(find.text('墨青'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('极简'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('纸白'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('切换左对齐'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换居中对齐'), findsOneWidget);

    await tester.tap(find.byTooltip('隐藏章节'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('显示章节'), findsOneWidget);

    await tester.tap(find.byTooltip('隐藏水印'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('显示水印'), findsOneWidget);

    // AI 金句解读：未配置 / 成功 / 失败
    await clearSnackBars(tester);
    await tester.tap(find.byTooltip('AI 金句解读'));
    await tester.pumpAndSettle();
    expect(find.text('请先在设置中配置 AI API'), findsOneWidget);

    await clearSnackBars(tester);
    aiMode = 1;
    await tester.tap(find.byTooltip('AI 金句解读'));
    await tester.pumpAndSettle();
    expect(find.text('金句意境悠远'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await clearSnackBars(tester);
    aiMode = 2;
    await tester.tap(find.byTooltip('AI 金句解读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AI 解读失败'), findsOneWidget);

    // 默认 aiServiceFactory（未配置 AppConfig 走默认 AIService）
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(wrap(const CardsPage()));
    await pumpUntil(tester, () => find.byTooltip('AI 金句解读').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('AI 金句解读'));
    await tester.pumpAndSettle();
    expect(find.text('请先在设置中配置 AI API'), findsOneWidget);
  });

  testWidgets('AISummaryPage Markdown 渲染、风格选择与流式取消', (tester) async {
    final summary = AISummary(
      createdAt: 1700000000000,
      title: '测试书',
      text: '# 一级标题\n\n## 二级标题\n### 三级标题\n> 引用一段话\n正文含 **加粗** 与 [R1] 及 [R9]',
      references: [
        SummaryReference(
          label: 'R1',
          bookId: 'b1',
          bookTitle: '测试书',
          chapterTitle: '第一章',
          noteId: 'bm1',
          source: NoteSource.bookmark,
          content: '原文',
        ),
      ],
    );

    await tester.pumpWidget(wrap(AISummaryPage(summary: summary, database: db)));
    await tester.pumpAndSettle();
    expect(find.text('[R1]'), findsOneWidget);
    await tester.tap(find.byTooltip('复制摘要'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已复制摘要'), findsOneWidget);

    // pickSummaryStyle + streaming preview + manual cancel
    SummaryStyle? chosen;
    final completer = Completer<AISummary>();
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Scaffold(
        body: Column(
          children: [
            ElevatedButton(
              onPressed: () async => chosen = await pickSummaryStyle(ctx),
              child: const Text('选风格'),
            ),
            ElevatedButton(
              onPressed: () => generateSummary(
                ctx,
                '书',
                '作者',
                [
                  NoteItem(
                    id: '1',
                    bookId: 'b1',
                    bookTitle: '书',
                    content: '内容',
                    chapterTitle: '',
                    createdAt: 1,
                    isFav: false,
                    source: NoteSource.bookmark,
                  )
                ],
                database: db,
                stream: true,
                serviceFactory: (c) => _StubAI(
                  c,
                  onSummarize: (onDelta, cancelToken) {
                    onDelta?.call('流式片段...');
                    cancelToken?.whenCancel.then((_) {
                      if (!completer.isCompleted) {
                        completer.completeError(const AICancelledException());
                      }
                    });
                    return completer.future;
                  },
                ),
              ),
              child: const Text('流式生成'),
            ),
          ],
        ),
      ),
    )));
    await tester.tap(find.text('选风格'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核心论点'));
    await tester.pumpAndSettle();
    expect(chosen, SummaryStyle.keyPoints);

    await tester.tap(find.text('流式生成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('流式片段...'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AI 摘要生成或保存失败'), findsOneWidget);

    // 历史摘要分页加载更多（> 50 条）
    await tester.runAsync(() async {
      for (var i = 0; i < 51; i++) {
        await db.saveSummary(AISummary(
          createdAt: 1700000000000 + i,
          title: '历史书$i',
          text: '摘要$i',
          references: [],
        ));
      }
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(wrap(AISummaryHistoryPage(database: db)));
    await pumpUntil(tester, () => find.text('历史书50').evaluate().isNotEmpty);
    await tester.scrollUntilVisible(find.text('加载更多'), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('加载更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await pumpUntil(tester, () => find.text('历史书0').evaluate().isNotEmpty);
    expect(find.text('历史书0'), findsOneWidget);
  });

  testWidgets('ReportPage 响应式统计卡片、空饼图与 AI 阅读洞察', (tester) async {
    int aiMode = 0; // 0 unconfigured, 1 ok, 2 error
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap(ReportPage(
      aiServiceFactory: (c) => _StubAI(
        c,
        configured: aiMode != 0,
        onAnalyze: () async {
          if (aiMode == 2) throw StateError('analyze fail');
          return '你偏爱人文与技术书籍';
        },
      ),
    )));
    await pumpUntil(tester, () => find.text('暂无书籍进度数据').evaluate().isNotEmpty);

    // 未配置
    await clearSnackBars(tester);
    await tester.scrollUntilVisible(find.text('生成洞察'), 200);
    await tester.tap(find.text('生成洞察'));
    await tester.pumpAndSettle();
    expect(find.text('请先在设置中配置 AI API'), findsOneWidget);

    // 已配置但无书
    await clearSnackBars(tester);
    aiMode = 1;
    await tester.tap(find.text('生成洞察'));
    await tester.pumpAndSettle();
    expect(find.text('暂无书籍可供分析'), findsOneWidget);

    // 有书 -> 成功 -> 失败
    await clearSnackBars(tester);
    await tester.runAsync(
        () => db.insertBook({'book_id': 'b1', 'title': '人类简史', 'updated_at': 10}));
    await tester.tap(find.text('生成洞察'));
    await tester.pumpAndSettle();
    expect(find.text('你偏爱人文与技术书籍'), findsOneWidget);

    await clearSnackBars(tester);
    aiMode = 2;
    await tester.tap(find.text('重新分析'));
    await tester.pumpAndSettle();
    expect(find.textContaining('阅读洞察生成失败'), findsOneWidget);
  });

  testWidgets('AiSettingsSection 测试连接与 BackupSettingsSection 备份恢复', (tester) async {
    int testMode = 0; // 0 ok, 1 fail
    await tester.pumpWidget(wrap(Scaffold(
      body: ListView(
        children: [
          AiSettingsSection(
            aiServiceFactory: (c) => _StubAI(
              c,
              onTest: () async {
                if (testMode == 1) throw StateError('bad key');
                return 'OK';
              },
            ),
          ),
        ],
      ),
    )));
    await tester.pumpAndSettle();

    // 展开 AI 配置
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    // 缺少 Key/URL
    await clearSnackBars(tester);
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请先填写 API Key 和有效的 HTTPS 服务地址'), findsOneWidget);

    // 填写后测试成功
    await clearSnackBars(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'sk-123');
    await tester.enterText(fields.at(1), 'https://api.deepseek.com');
    await tester.enterText(fields.at(2), 'deepseek-chat');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('AI 服务连接成功'), findsOneWidget);

    // 测试失败
    await clearSnackBars(tester);
    testMode = 1;
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接测试失败'), findsOneWidget);

    // 默认 aiServiceFactory 走真实 AIService 构造（无效域名失败）
    await tester.pumpWidget(wrap(const Scaffold(
      body: SingleChildScrollView(child: AiSettingsSection()),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    final f2 = find.byType(TextField);
    await tester.enterText(f2.at(0), 'sk-123');
    await tester.enterText(f2.at(1), 'https://127.0.0.1:1');
    await tester.enterText(f2.at(2), 'model');
    await tester.tap(find.text('测试连接'));
    await pumpUntil(
      tester,
      () => find.textContaining('连接测试失败').evaluate().isNotEmpty,
    );
  });
}
