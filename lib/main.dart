import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/bookshelf_provider.dart';
import 'providers/notes_provider.dart';
import 'providers/app_config_provider.dart';
import 'services/config.dart';
import 'services/platform_database.dart';
import 'pages/bookshelf_page.dart';
import 'pages/notes_page.dart';
import 'pages/report_page.dart';
import 'pages/settings_page.dart';
import 'theme/readamber_theme.dart';
import 'providers/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializePlatformDatabase();
  runApp(const ReadAmberApp());
}

class ReadAmberApp extends StatelessWidget {
  const ReadAmberApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appConfig = AppConfig();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController()..load()),
        ChangeNotifierProvider(
          create: (_) => AppConfigProvider(config: appConfig)..init(),
        ),
        ChangeNotifierProxyProvider<AppConfigProvider, BookshelfProvider>(
          create: (_) => BookshelfProvider(isActive: false),
          update: (_, config, provider) => provider!
            ..resetSession(config.sessionRevision),
        ),
        ChangeNotifierProxyProvider<AppConfigProvider, NotesProvider>(
          create: (_) => NotesProvider(isActive: false),
          update: (_, config, provider) => provider!
            ..resetSession(config.sessionRevision),
        ),
      ],
      child: Consumer<ThemeController>(builder: (_, appearance, __) => MaterialApp(
        title: '阅珀 ReadAmber',
        debugShowCheckedModeBanner: false,
        theme: ReadAmberTheme.lightFor(fontFamily: appearance.fontFamily),
        darkTheme: ReadAmberTheme.darkFor(fontFamily: appearance.fontFamily),
        themeMode: appearance.mode,
        builder: (context, child) => DefaultTextStyle.merge(
          style: TextStyle(
            fontFamily: appearance.fontFamily,
            fontFamilyFallback: ReadAmberTheme.defaultFontFallback,
          ),
          child: child!,
        ),
        home: const MainScreen(),
      )),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final Set<int> _visited = {0};
  int? _sessionRevision;
  bool? _canBrowseLocal;

  Widget _page(int index) {
    final active = index == _currentIndex;
    return switch (index) {
      0 => BookshelfPage(isActive: active),
      1 => NotesPage(isActive: active),
      2 => ReportPage(isActive: active),
      _ => SettingsPage(isActive: active),
    };
  }

  void _selectTab(int index) {
    setState(() {
      _currentIndex = index;
      _visited.add(index);
    });
  }

  static const _destinations = [
    (Icons.book_outlined, Icons.book, '书架'),
    (Icons.note_outlined, Icons.note, '笔记'),
    (Icons.bar_chart_outlined, Icons.bar_chart, '报告'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfigProvider>();
    if (_sessionRevision != config.sessionRevision || _canBrowseLocal != config.canBrowseLocal) {
      _sessionRevision = config.sessionRevision;
      _canBrowseLocal = config.canBrowseLocal;
      _visited..clear()..add(_currentIndex);
    }
    final isWide = MediaQuery.sizeOf(context).width >= 840;
    final bodyContent = Column(
      children: [
        if (config.needsOnlineSync)
          const SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text('离线模式：本地数据可浏览 · 同步需要联网验证'),
            ),
          ),
        Expanded(
          child: IndexedStack(
            key: ValueKey('${config.sessionRevision}:${config.canBrowseLocal}'),
            index: _currentIndex,
            children: [
              for (var i = 0; i < 4; i++)
                if (!_visited.contains(i))
                  const SizedBox.shrink()
                else if (i == 3 || config.canBrowseLocal)
                  _page(i)
                else
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Image(
                            image: AssetImage('assets/branding/readamber-v1/readamber-icon-128.png'),
                            width: 80, height: 80, semanticLabel: '阅珀应用图标',
                          ),
                          const SizedBox(height: 24),
                          Text('阅珀 ReadAmber', textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600,
                              color: ReadAmberPalette.of(context).ink)),
                          const SizedBox(height: 10),
                          Text('让读过的，留下来。',
                            style: TextStyle(fontSize: 16, color: ReadAmberPalette.of(context).amberText)),
                          const SizedBox(height: 24),
                          Text('请先在设置中验证登录', textAlign: TextAlign.center,
                            style: TextStyle(color: ReadAmberPalette.of(context).muted)),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: () => _selectTab(3),
                            icon: const Icon(Icons.login_rounded, size: 18),
                            label: const Text('前往登录'),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      body: isWide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: _selectTab,
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Image(
                      image: AssetImage(
                          'assets/branding/readamber-v1/readamber-icon-128.png'),
                      width: 32,
                      height: 32,
                      semanticLabel: '阅珀应用图标',
                    ),
                  ),
                  destinations: [
                    for (final d in _destinations)
                      NavigationRailDestination(
                        icon: Icon(d.$1),
                        selectedIcon: Icon(d.$2),
                        label: Text(d.$3),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: bodyContent),
              ],
            )
          : bodyContent,
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _selectTab,
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: d.$3,
                  ),
              ],
            ),
    );
  }
}
