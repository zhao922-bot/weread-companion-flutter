import 'package:flutter/foundation.dart';
import '../models/book.dart';
import '../services/database.dart';
import '../services/api.dart';
import '../services/config.dart';

class BookshelfProvider extends ChangeNotifier {
  List<Book> _books = [];
  List<Book> _filtered = [];
  String _searchQuery = '';
  String _filter = '全部'; // 全部/读完/在读中/未读
  bool _loading = false;
  String? _error;

  List<Book> get books => _filtered;
  bool get isLoading => _loading;
  String? get error => _error;
  String get filter => _filter;
  int get totalCount => _books.length;

  Future<void> loadBooks() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final raw = await DatabaseService.instance.getAllBooks();
      _books = raw.map((m) => Book.fromJson(m)).toList();
      _applyFilter();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 从服务器同步数据
  /// [config] 可选，传入主 AppConfig 实例以保持一致性
  /// 返回同步结果信息，供 UI 显示
  Future<String> syncFromServer({AppConfig? config}) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // 使用传入的 config 或从存储加载
      final appConfig = config ?? AppConfig();
      if (config == null) await appConfig.load();

      if (appConfig.cookie.isEmpty) {
        throw Exception('请先导入 Cookie 再同步');
      }

      // 初始化 API（如果尚未初始化）
      try {
        WeReadApi.instance;
      } catch (_) {
        await WeReadApi.init(config: appConfig, db: DatabaseService.instance);
      }

      // 更新 Cookie
      WeReadApi.instance.updateCookie(appConfig.cookie);

      // 执行同步
      final result = await WeReadApi.instance.syncAll();

      // 重新加载本地数据
      final raw = await DatabaseService.instance.getAllBooks();
      _books = raw.map((m) => Book.fromJson(m)).toList();
      _applyFilter();

      final msg = '同步完成：${result['books']} 本书，${result['bookmarks']} 条划线，${result['notes']} 条笔记';
      _error = null;
      _loading = false;
      notifyListeners();
      return msg;
    } catch (e) {
      _error = e.toString();
      _loading = false;
      notifyListeners();
      rethrow;
    }
  }

  void setSearch(String query) {
    _searchQuery = query;
    _applyFilter();
  }

  void setFilter(String filter) {
    _filter = filter;
    _applyFilter();
  }

  void _applyFilter() {
    var list = List<Book>.from(_books);

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((b) =>
        b.title.toLowerCase().contains(q) ||
        b.author.toLowerCase().contains(q)
      ).toList();
    }

    switch (_filter) {
      case '读完':
        list = list.where((b) => b.isFinished || b.progress >= 85).toList();
        break;
      case '在读中':
        list = list.where((b) => !b.isFinished && b.progress >= 5 && b.progress < 85).toList();
        break;
      case '未读':
        list = list.where((b) => b.progress < 5 && !b.isFinished).toList();
        break;
    }

    _filtered = list;
    notifyListeners();
  }

  int get readCount => _books.where((b) => b.isFinished || b.progress >= 85).length;
  int get readingCount => _books.where((b) => !b.isFinished && b.progress >= 5 && b.progress < 85).length;
  int get unreadCount => _books.where((b) => b.progress < 5 && !b.isFinished).length;
}
