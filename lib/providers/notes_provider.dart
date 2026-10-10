import 'package:flutter/foundation.dart';
import '../services/database.dart';
import '../services/sync_service.dart';

/// 笔记数据源标记
enum NoteSource { bookmark, note }

/// 包装统一的笔记条目
class NoteItem {
  final String id;
  final String bookId;
  final String bookTitle;
  final String content;
  final String chapterTitle;
  final int createdAt;
  bool isFav;
  final NoteSource source;

  NoteItem({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.content,
    required this.chapterTitle,
    required this.createdAt,
    required this.isFav,
    required this.source,
  });
}

class NotesProvider extends ChangeNotifier {
  NotesProvider() {
    SyncService.changes.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    if (SyncService.changes.value?.isActive == true) _refresh = loadNotes();
  }
  Future<void>? _refresh;

  @override
  void dispose() {
    SyncService.changes.removeListener(_onSyncChanged);
    _request++;
    super.dispose();
  }
  List<NoteItem> _notes = [];
  int _request = 0;
  int _matchedCount = 0;
  Map<String, dynamic> _stats = {};
  static const pageSize = 100;
  String _searchQuery = '';
  String _filter = '全部划线'; // 全部划线/全部笔记/收藏
  bool _loading = false;
  String? _error;
  int _sessionRevision = -1;

  void resetSession(int revision) {
    if (_sessionRevision == revision) return;
    _sessionRevision = revision;
    _request++;
    _notes = [];
    _matchedCount = 0;
    _stats = {};
    _searchQuery = '';
    _filter = '全部划线';
    _loading = false;
    _error = null;
    notifyListeners();
  }

  List<NoteItem> get notes => _notes;
  bool get isLoading => _loading;
  String? get error => _error;
  String get filter => _filter;
  int get totalCount => bookmarkCount + noteCount;
  int get matchedCount => _matchedCount;
  bool get hasMore => _notes.length < _matchedCount;

  NoteItem _fromRow(Map<String, dynamic> m) => NoteItem(
    id: m['id'] ?? '',
    bookId: m['book_id'] ?? '',
    bookTitle: m['book_title'] ?? '',
    content: m['content'] ?? '',
    chapterTitle: m['chapter_title'] ?? '',
    createdAt: m['created_at'] ?? 0,
    isFav: (m['is_fav'] ?? 0) == 1,
    source: m['source'] == 'bookmark' ? NoteSource.bookmark : NoteSource.note,
  );

  /// 批量操作读取全部匹配项，不受列表已加载页数影响。
  Future<List<NoteItem>> getAllMatchingNotes() async {
    final db = DatabaseService.instance;
    final query = _searchQuery;
    final filter = _filter;
    final items = <NoteItem>[];
    while (true) {
      final rows = await db.getReadingItems(offset: items.length,
          limit: pageSize, query: query, filter: filter);
      if (!db.isActive) throw StateError('账号会话已结束');
      if (rows.isEmpty) return items;
      items.addAll(rows.map(_fromRow));
    }
  }

  /// 搜索和筛选在全库执行，只加载当前批次。
  Future<void> loadNotes() => _loadPage(reset: true);

  Future<void> loadMore() async {
    if (_loading || !hasMore) return;
    await _loadPage(reset: false);
  }

  Future<void> _loadPage({required bool reset}) async {
    final request = ++_request;
    if (reset) _notes = [];
    final offset = _notes.length;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final db = DatabaseService.instance;
      final query = _searchQuery;
      final filter = _filter;
      final count = await db.countReadingItems(query: query, filter: filter);
      final stats = await db.getReadingStats();
      if (request != _request || !db.isActive) return;
      final raw = await db.getReadingItems(offset: offset,
          limit: pageSize, query: query, filter: filter);
      if (request != _request || !db.isActive) return;
      final items = raw.map(_fromRow).toList();
      _notes = [..._notes, ...items];
      _matchedCount = count;
      _stats = stats;
    } catch (e) {
      if (request != _request) return;
      _error = e.toString();
    } finally {
      if (request == _request) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void setSearch(String query) {
    _searchQuery = query;
    loadNotes();
  }

  void setFilter(String filter) {
    _filter = filter;
    loadNotes();
  }

  Future<void> toggleFavorite(NoteItem note) async {
    final revision = _sessionRevision;
    final db = DatabaseService.instance;
    if (note.source == NoteSource.bookmark) {
      await db.toggleBookmarkFavorite(note.id, !note.isFav);
    } else {
      await db.toggleFavorite(note.id, !note.isFav);
    }

    if (revision != _sessionRevision || !db.isActive) return;
    // 统一事件同时刷新详情、收藏列表、卡片和统计；保留可等待的完成语义。
    SyncService.changes.publish(db);
    await _refresh;
  }
  int get favCount => (_stats['favoriteBookmarks'] as int? ?? 0) +
      (_stats['favoriteNotes'] as int? ?? 0);
  int get bookmarkCount => _stats['totalBookmarks'] as int? ?? 0;
  int get noteCount => _stats['totalNotes'] as int? ?? 0;
}
