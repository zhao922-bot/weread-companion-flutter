import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/main.dart';
import 'package:weread_companion/pages/cookie_login_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/card_image_renderer.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'support/wait_until.dart';

class _PreviewConfig extends AppConfigProvider {
  _PreviewConfig() : super(config: AppConfig());
  @override
  bool get isLoaded => true;
  @override
  bool get canBrowseLocal => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    sqfliteFfiInit();
    final font = FontLoader('ReadAmberPreview');
    font.addFont(File('assets/fonts/NotoSansSC-VariableFont_wght.ttf')
        .readAsBytes()
        .then((bytes) => ByteData.sublistView(bytes)));
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final mono = FontLoader('monospace');
    mono.addFont(File('assets/fonts/NotoSansSC-VariableFont_wght.ttf')
        .readAsBytes()
        .then((bytes) => ByteData.sublistView(bytes)));
    await mono.load();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: '阅珀 ReadAmber',
        packageName: 'com.example.weread_companion',
        version: '2.9.0',
        buildNumber: '23',
        buildSignature: '');
    directory = await Directory.systemTemp.createTemp('readamber-ui-');
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    final db = DatabaseService.instance;
    const titles = ['时间的纹理', '山间来信', '慢读的日子', '万物有光', '沿途的风景', '纸上的远方'];
    for (var i = 0; i < titles.length; i++) {
      await db.insertBook({
        'book_id': 'b$i',
        'title': titles[i],
        'author': '阅珀示例书架',
        'progress': [42, 100, 86, 0, 62, 12][i],
        'updated_at': 6 - i
      });
      await db.insertBookmark({
        'bookmark_id': 'm$i',
        'book_id': 'b$i',
        'book_title': titles[i],
        'chapter_title': '第一章 · 阅读与生活',
        'mark_text': '把喜欢的句子留在纸上，也把阅读的光留在日常里。',
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - i,
        'is_fav': 1
      });
      await db.insertNote({
        'note_id': 'n$i',
        'book_id': 'b$i',
        'book_title': titles[i],
        'content': '今天重读这一页，发现熟悉的文字里还有新的理解。留一点时间，慢慢想。',
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - i - 100
      });
    }
  });
  tearDown(() async {
    await DatabaseService.endSession();
    await directory.delete(recursive: true);
  });

  test('正文、次要文字、状态与日志颜色达到普通文字 4.5:1 对比度', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05));
    }

    for (final background in [
      ReadAmberColors.paper,
      ReadAmberColors.canvas,
      ReadAmberColors.surface,
      ReadAmberColors.surfaceMuted
    ]) {
      for (final foreground in [
        ReadAmberColors.ink,
        ReadAmberColors.inkSoft,
        ReadAmberColors.muted,
        ReadAmberColors.amberText,
        ReadAmberColors.success,
        ReadAmberColors.error
      ]) {
        expect(contrast(foreground, background), greaterThanOrEqualTo(4.5));
      }
    }
    for (final foreground in [
      ReadAmberColors.paper,
      ReadAmberColors.amber,
      ReadAmberColors.logSuccess,
      ReadAmberColors.logError
    ]) {
      expect(
          contrast(foreground, ReadAmberColors.ink), greaterThanOrEqualTo(4.5));
    }
  });

  for (final view in [
    (name: 'phone', size: const Size(390, 844), scale: 1.0),
    (name: 'desktop', size: const Size(1280, 860), scale: 1.0),
    (name: 'compact', size: const Size(320, 568), scale: 1.5),
  ]) {
    testWidgets('${view.name} 品牌主题下导航、表单、报告与卡片无布局溢出', (tester) async {
      tester.view.physicalSize = view.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final config = _PreviewConfig();
      final shelf = BookshelfProvider(isActive: false);
      final notes = NotesProvider(isActive: false);
      addTearDown(config.dispose);
      addTearDown(shelf.dispose);
      addTearDown(notes.dispose);
      final boundary = GlobalKey();
      Widget app(Widget home) => MultiProvider(
              providers: [
                ChangeNotifierProvider<AppConfigProvider>.value(value: config),
                ChangeNotifierProvider<BookshelfProvider>.value(value: shelf),
                ChangeNotifierProvider<NotesProvider>.value(value: notes),
              ],
              child: RepaintBoundary(
                  key: boundary,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: ReadAmberTheme.light.copyWith(
                        appBarTheme: ReadAmberTheme.light.appBarTheme.copyWith(
                            titleTextStyle: ReadAmberTheme
                                .light.appBarTheme.titleTextStyle!
                                .copyWith(fontFamily: 'ReadAmberPreview')),
                        textTheme: ReadAmberTheme.light.textTheme
                            .apply(fontFamily: 'ReadAmberPreview')),
                    builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                            textScaler: TextScaler.linear(view.scale)),
                        child: child!),
                    home: home,
                  )));
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${view.name} / $name');
        if (const bool.fromEnvironment('READAMBER_CAPTURE')) {
          await tester.runAsync(() async {
            final image = await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            try {
              final bytes =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              final file = File('build/ui-previews/${view.name}-$name.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
      }

      await tester.pumpWidget(app(const MainScreen()));
      await pumpUntil(tester, () => shelf.totalCount == 6 && !shelf.isLoading);
      await capture('bookshelf');
      for (final (index, name) in [
        (1, 'notes'),
        (2, 'cards'),
        (3, 'report'),
        (4, 'settings')
      ]) {
        final nav = find
            .descendant(
                of: find.byType(NavigationBar),
                matching: find.byType(NavigationDestination))
            .at(index);
        await tester.tap(nav);
        await tester.pumpAndSettle();
        // FFI reads run outside the fake widget clock.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await capture(name);
        if (name == 'cards') {
          if (view.size.width < 600) {
            await tester.tap(find.text('把喜欢的句子留在纸上，也把阅读的光留在日常里。').first);
            await capture('card-preview');
          }
          expect(find.text('导出图片'), findsOneWidget);
          await tester.runAsync(() async {
            final render = tester.renderObject<CardRenderBoundary>(
                find.byType(CardRepaintBoundary));
            final image = await render.toImage();
            try {
              final bytes = (await image.toByteData())!.buffer.asUint8List();
              // The center of the top edge is inside the rounded paper card.
              // Its alpha must be opaque when exported onto another background.
              expect(bytes[(2 * image.width + image.width ~/ 2) * 4 + 3], 255);
            } finally {
              image.dispose();
            }
          });
          if (view.size.width < 600) {
            Navigator.of(tester.element(find.byType(Slider))).pop();
            await tester.pumpAndSettle();
          }
        }
      }
      await tester.pumpWidget(app(const CookieLoginPage()));
      await capture('cookie');
      await tester.scrollUntilVisible(find.text('扫码登录'), 160,
          scrollable: find.byType(Scrollable).first);
      await capture('cookie-actions');
      expect(find.text('确认导入并验证'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
