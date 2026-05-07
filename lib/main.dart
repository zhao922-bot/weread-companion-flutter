import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/bookshelf_provider.dart';
import 'providers/notes_provider.dart';
import 'providers/app_config_provider.dart';
import 'services/config.dart';
import 'pages/bookshelf_page.dart';
import 'pages/notes_page.dart';
import 'pages/cards_page.dart';
import 'pages/report_page.dart';
import 'pages/settings_page.dart';

void main() {
  runApp(const WeReadCompanionApp());
}

class WeReadCompanionApp extends StatelessWidget {
  const WeReadCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appConfig = AppConfig();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AppConfigProvider(config: appConfig)..init(),
        ),
        ChangeNotifierProvider(create: (_) => BookshelfProvider()),
        ChangeNotifierProvider(create: (_) => NotesProvider()),
      ],
      child: MaterialApp(
        title: '微信读书伴侣',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
                    colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4A7CF7),
            primary: const Color(0xFF4A7CF7),
            surface: const Color(0xFFF7F8FC),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF7F8FC),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            foregroundColor: Color(0xFF1A1A1A),
            elevation: 0,
            scrolledUnderElevation: 0.5,
            centerTitle: true,
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: Colors.white,
            indicatorColor: const Color(0xFF4A7CF7).withValues(alpha: 0.12),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            height: 64,
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
                    colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4A7CF7),
            primary: const Color(0xFF4A7CF7),
            brightness: Brightness.dark,
          ),
        ),
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

  final List<Widget> _pages = const [
    BookshelfPage(),
    NotesPage(),
    CardsPage(),
    ReportPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
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
            icon: Icon(Icons.card_giftcard_outlined),
            selectedIcon: Icon(Icons.card_giftcard),
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
