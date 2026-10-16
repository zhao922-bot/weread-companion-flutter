import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/bookshelf_provider.dart';
import 'providers/notes_provider.dart';
import 'providers/app_config_provider.dart';
import 'services/config.dart';
import 'services/platform_database.dart';
import 'pages/bookshelf_page.dart';
import 'pages/notes_page.dart';
import 'pages/cards_page.dart';
import 'pages/report_page.dart';
import 'pages/settings_page.dart';
import 'theme/readamber_theme.dart';

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
      child: MaterialApp(
        title: '阅珀 ReadAmber',
        debugShowCheckedModeBanner: false,
        theme: ReadAmberTheme.light,
        themeMode: ThemeMode.light,
        home: const MainScreen(),
      ),
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
      2 => CardsPage(isActive: active),
      3 => ReportPage(isActive: active),
      _ => SettingsPage(isActive: active),
    };
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfigProvider>();
    if (_sessionRevision != config.sessionRevision || _canBrowseLocal != config.canBrowseLocal) {
      _sessionRevision = config.sessionRevision;
      _canBrowseLocal = config.canBrowseLocal;
      _visited..clear()..add(_currentIndex);
    }
    return Scaffold(
      body: Column(
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
                for (var i = 0; i < 5; i++)
                  if (!_visited.contains(i))
                    const SizedBox.shrink()
                  else if (i == 4 || config.canBrowseLocal)
                    _page(i)
                  else
                    const Center(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image(
                              image: AssetImage('assets/branding/readamber-v1/readamber-icon-128.png'),
                              width: 80, height: 80, semanticLabel: '阅珀应用图标',
                            ),
                            SizedBox(height: 24),
                            Text('阅珀 ReadAmber', textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600,
                                color: ReadAmberColors.ink)),
                            SizedBox(height: 10),
                            Text('让读过的，留下来。',
                              style: TextStyle(fontSize: 16, color: ReadAmberColors.amberText)),
                            SizedBox(height: 32),
                            Text('请先在设置中验证登录', textAlign: TextAlign.center,
                              style: TextStyle(color: ReadAmberColors.muted)),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
            _visited.add(index);
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.book_outlined),
            selectedIcon: Icon(Icons.book),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.note_outlined),
            selectedIcon: Icon(Icons.note),
            label: '笔记',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: '卡片',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: '报告',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
