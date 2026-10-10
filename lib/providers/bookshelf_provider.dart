import 'package:flutter/foundation.dart';
import '../models/book.dart';
import '../models/bookshelf_filter.dart';
import '../services/database.dart';
import '../services/config.dart';
import '../services/sync_service.dart';

class BookshelfProvider extends ChangeNotifier {
  BookshelfProvider() {
    SyncService.changes.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    final event = SyncService.changes;
    if ((event.kind == SyncChangeKind.all || event.kind == SyncChangeKind.bookshelf) && event.value?.isActive == true) {
      _refresh = loadBooks();
    }
  }
  Future<void>? _refresh;
  bool _disposed = false;
  int _request = 0;

  @override
  void dispose() {
    _disposed = true;
    _request++;
    SyncService.changes.removeListener(_onSyncChanged);
    super.dispose();
  }

  SyncResult? lastSyncResult;
  List<Book> _books = [];
  List<Book> _filtered = [];
  String _searchQuery = '';
  BookshelfFilter _filter = BookshelfFilter.all;
  bool _loading = false;
  String? _error;
  int _sessionRevision = -1;

  void resetSession(int revision) {
    if (_sessionRevision == revision) return;
    _sessionRevision = revision;
    _books = [];
    _filtered = [];
    _searchQuery = '';
    _filter = BookshelfFilter.all;
    _loading = false;
    _error = null;
    lastSyncResult = null;
    notifyListeners();
  }

  List<Book> get books => _filtered;
  bool get isLoading => _loading;
  String? get error => _error;
  BookshelfFilter get filter => _filter;
  String get searchQuery => _searchQuery;
  int get totalCount => _books.length;

  Future<void> loadBooks() async {
    if (_disposed) return;
    final request = ++_request;
    final revision = _sessionRevision;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final db = DatabaseService.instance;
      final raw = await db.getAllBooks();
      if (_disposed || request != _request || !db.isActive || revision != _sessionRevision) return;
      _books = raw.map((m) => Book.fromJson(m)).toList();
      _applyFilter();
    } catch (e) {
      if (_disposed || request != _request || revision != _sessionRevision) return;
      _error = e.toString();
    } finally {
      if (!_disposed && request == _request && revision == _sessionRevision) {
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
      final service = await SyncService.connect(config: config,
          isCancelled: () => _disposed || revision != _sessionRevision);
      final result = await service.syncAll();
      if (revision != _sessionRevision) throw StateError('同步已取消');

      await _refresh;
      if (_disposed || revision != _sessionRevision) throw StateError('同步已取消');

      lastSyncResult = result;
      final msg = result.summary;
      _error = null;
      _loading = false;
      notifyListeners();
      return msg;
    } catch (e) {
      if (_disposed || revision != _sessionRevision) rethrow;
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

  void setFilter(BookshelfFilter filter) {
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

    list = list.where(_filter.matches).toList();

    _filtered = list;
    notifyListeners();
  }

  int get readCount => _books.where((b) => b.isFinished).length;
  int get readingCount => _books.where((b) => b.isReading).length;
  int get unreadCount => _books.where((b) => b.isUnread).length;
}
