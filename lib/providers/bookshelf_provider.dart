import 'package:flutter/foundation.dart';
import '../models/book.dart';
import '../services/database.dart';
import '../services/api.dart';
import '../services/config.dart';
import '../services/sync_service.dart';

class BookshelfProvider extends ChangeNotifier {
  BookshelfProvider() {
    SyncService.changes.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    if (SyncService.changes.value?.isActive == true) loadBooks();
  }

  @override
  void dispose() {
    SyncService.changes.removeListener(_onSyncChanged);
    super.dispose();
  }

  SyncResult? lastSyncResult;
  List<Book> _books = [];
  List<Book> _filtered = [];
  String _searchQuery = '';
  String _filter = '全部'; // 全部/读完/在读中/未读
  bool _loading = false;
  String? _error;
  int _sessionRevision = -1;

  void resetSession(int revision) {
    if (_sessionRevision == revision) return;
    _sessionRevision = revision;
    _books = [];
    _filtered = [];
    _searchQuery = '';
    _filter = '全部';
    _loading = false;
    _error = null;
    lastSyncResult = null;
    notifyListeners();
  }

  List<Book> get books => _filtered;
  bool get isLoading => _loading;
  String? get error => _error;
  String get filter => _filter;
  int get totalCount => _books.length;

  Future<void> loadBooks() async {
    final revision = _sessionRevision;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final raw = await DatabaseService.instance.getAllBooks();
      if (revision != _sessionRevision) return;
      _books = raw.map((m) => Book.fromJson(m)).toList();
      _applyFilter();
    } catch (e) {
      if (revision != _sessionRevision) return;
      _error = e.toString();
    } finally {
      if (revision == _sessionRevision) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 从服务器同步数据
  /// [config] 可选，传入主 AppConfig 实例以保持一致性
  /// 返回同步结果信息，供 UI 显示
  Future<String> syncFromServer({AppConfig? config}) async {
    final revision = _sessionRevision;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // 使用传入的 config 或从存储加载
      final appConfig = config ?? AppConfig();
      if (config == null) await appConfig.load();
      if (revision != _sessionRevision) throw StateError('同步已取消');
      final db = DatabaseService.instance;

      if (!appConfig.isConfigured) {
        throw Exception('请先登录（扫码或导入 Cookie）再同步');
      }

      final api = await WeReadApi.init(config: appConfig, db: db);
      if (revision != _sessionRevision) throw StateError('同步已取消');

      // 更新 Cookie
      api.updateCookie(appConfig.cookie);

      // 执行同步
      final result = await SyncService.forApi(api,
          isCancelled: () => revision != _sessionRevision).syncAll();
      if (revision != _sessionRevision) throw StateError('同步已取消');

      // 重新加载本地数据
      final raw = await db.getAllBooks();
      if (revision != _sessionRevision) throw StateError('同步已取消');
      _books = raw.map((m) => Book.fromJson(m)).toList();
      _applyFilter();

      lastSyncResult = result;
      final msg = result.summary;
      _error = null;
      _loading = false;
      notifyListeners();
      return msg;
    } catch (e) {
      if (revision != _sessionRevision) rethrow;
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
        list = list.where((b) => b.isFinished).toList();
        break;
      case '在读中':
        list = list.where((b) => b.isReading).toList();
        break;
      case '未读':
        list = list.where((b) => b.isUnread).toList();
        break;
    }

    _filtered = list;
    notifyListeners();
  }

  int get readCount => _books.where((b) => b.isFinished).length;
  int get readingCount => _books.where((b) => b.isReading).length;
  int get unreadCount => _books.where((b) => b.isUnread).length;
}
