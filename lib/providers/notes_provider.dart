import 'package:flutter/foundation.dart';
import '../services/database.dart';
import '../services/sync_service.dart';
import '../models/note_item.dart';
export '../models/note_item.dart';

class NotesProvider extends ChangeNotifier {
  NotesProvider() {
    SyncService.changes.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    if (SyncService.changes.value?.isActive != true || _publishingFavorite) return;
    final version = SyncService.changes.dataVersion;
    if (version != _dataVersion) {
      _dataVersion = version;
      loadNotes();
    } else {
      _loadPage(reset: true, preserve: true,
        limit: _notes.length < pageSize ? pageSize : _notes.length);
    }
  }
  int _dataVersion = SyncService.changes.dataVersion;
  bool _publishingFavorite = false;
  final Set<String> _savingFavorites = {};
  int _favoriteRevision = 0;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
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
  ReadingFilter _filter = ReadingFilter.all;
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
    _filter = ReadingFilter.all;
    _dataVersion = SyncService.changes.dataVersion;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  List<NoteItem> get notes => _notes;
  bool get isLoading => _loading;
  String? get error => _error;
  ReadingFilter get filter => _filter;
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
    final revision = _sessionRevision;
    final query = _searchQuery;
    final filter = _filter;
    final items = <NoteItem>[];
    while (true) {
      final rows = await db.getReadingItems(offset: items.length,
          limit: pageSize, query: query, filter: filter);
      if (!db.isActive || revision != _sessionRevision || _disposed) {
        throw StateError('账号会话已结束');
      }
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

  Future<void> _loadPage({required bool reset, bool preserve = false, int limit = pageSize}) async {
    final request = ++_request;
    final favoriteRevision = _favoriteRevision;
    if (reset && !preserve) _notes = [];
    final offset = reset ? 0 : _notes.length;
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
          limit: limit, query: query, filter: filter);
      if (request != _request || !db.isActive) return;
      if (favoriteRevision != _favoriteRevision) {
        await _loadPage(reset: reset, preserve: true, limit: limit);
        return;
      }
      final items = raw.map(_fromRow).toList();
      _notes = reset ? items : [..._notes, ...items];
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

  void setFilter(ReadingFilter filter) {
    _filter = filter;
    loadNotes();
  }

  Future<void> toggleFavorite(NoteItem note) async {
    final key = '${note.source.name}:${note.id}';
    if (!_savingFavorites.add(key)) return;
    final revision = _sessionRevision;
    final favorite = !note.isFav;
    try {
      final db = DatabaseService.instance;
      if (note.source == NoteSource.bookmark) {
        await db.toggleBookmarkFavorite(note.id, favorite);
      } else {
        await db.toggleFavorite(note.id, favorite);
      }

      if (revision != _sessionRevision || !db.isActive || _disposed) return;
      _favoriteRevision++;
      note.isFav = favorite;
      for (final item in _notes) {
        if (item.id == note.id && item.source == note.source) item.isFav = favorite;
      }
      final stat = note.source == NoteSource.bookmark ? 'favoriteBookmarks' : 'favoriteNotes';
      _stats[stat] = (_stats[stat] as int? ?? 0) + (favorite ? 1 : -1);
      if (_filter == ReadingFilter.favorites && !favorite &&
          _notes.any((item) => item.id == note.id && item.source == note.source)) {
        _notes.removeWhere((item) => item.id == note.id && item.source == note.source);
        _matchedCount--;
      }
      notifyListeners();
      // 本列表直接更新；其他详情接收收藏事件，报告的数据版本不变。
      _publishingFavorite = true;
      try {
        SyncService.changes.publish(db, favoritesOnly: true);
      } finally {
        _publishingFavorite = false;
      }
    } finally {
      _savingFavorites.remove(key);
    }
  }
  int get favCount => (_stats['favoriteBookmarks'] as int? ?? 0) +
      (_stats['favoriteNotes'] as int? ?? 0);
  int get bookmarkCount => _stats['totalBookmarks'] as int? ?? 0;
  int get noteCount => _stats['totalNotes'] as int? ?? 0;
}
