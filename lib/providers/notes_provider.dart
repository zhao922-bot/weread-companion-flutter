import 'package:flutter/foundation.dart';
import 'dart:async';
import '../services/database.dart';
import '../services/sync_service.dart';
import '../models/note_item.dart';
export '../models/note_item.dart';

class NotesProvider extends ChangeNotifier {
  NotesProvider({bool isActive = true}) : _active = isActive {
    SyncService.changes.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    if (SyncService.changes.value?.isActive != true || _publishingFavorite) return;
    if (!_active) {
      _refreshPending = true;
      _statsDirty = true;
      return;
    }
    final event = SyncService.changes;
    if (event.kind == SyncChangeKind.bookshelf ||
        (_filter == ReadingFilter.notes && event.sources.isNotEmpty && !event.sources.contains('note'))) {
      _dataVersion = event.dataVersion;
      _refreshStats();
      return;
    }
    if (event.favoritesOnly && event.itemIds.isNotEmpty) {
      _refreshFavorites(event.itemIds);
      return;
    }
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
  bool _active;
  bool _refreshPending = true;
  int _backgroundReads = 0;

  Future<void> setActive(bool active) async {
    if (_disposed) return;
    _active = active;
    if (!active && (_loading || _searchTimer?.isActive == true || _backgroundReads > 0)) {
      _refreshPending = true;
      _statsDirty = true;
      _searchTimer?.cancel();
      // Invalidate results without notifying from a page's build/dispose.
      _request++;
      _statsRequest++;
      _loading = false;
    }
    if (active && _refreshPending) {
      _dataVersion = SyncService.changes.dataVersion;
      await loadNotes();
    }
  }
  int _statsRequest = 0;

  Future<void> _refreshStats() async {
    if (_disposed) return;
    if (!_active) { _refreshPending = true; _statsDirty = true; return; }
    final request = ++_statsRequest;
    final revision = _sessionRevision;
    final pageRequest = _request;
    _statsDirty = true;
    _backgroundReads++;
    try {
      final db = DatabaseService.instance;
      final stats = await db.getReadingStats();
      if (_disposed || !db.isActive || revision != _sessionRevision || request != _statsRequest || pageRequest != _request) return;
      _stats = stats;
      _statsDirty = false;
      notifyListeners();
    } catch (e) {
      if (!_disposed && revision == _sessionRevision && request == _statsRequest && pageRequest == _request) {
        _error = e.toString();
        notifyListeners();
      }
    } finally {
      _backgroundReads--;
    }
  }

  Future<void> _refreshFavorites(Set<String> keys) async {
    if (_disposed) return;
    if (!_active) { _refreshPending = true; _statsDirty = true; return; }
    if (_filter == ReadingFilter.favorites) {
      _favoriteRevision++;
      _statsDirty = true;
      await _loadPage(reset: true, preserve: true,
        limit: _notes.length < pageSize ? pageSize : _notes.length);
      return;
    }
    final revision = _sessionRevision;
    final request = _request;
    final favoriteRevision = _favoriteRevision;
    bool isCurrent() => !_disposed && _active && revision == _sessionRevision && request == _request;
    _backgroundReads++;
    try {
      final db = DatabaseService.instance;
      final updates = <(NoteItem, bool)>[];
      for (final item in _notes.where((n) => keys.contains('${n.source.name}:${n.id}')).toList()) {
        final row = await db.getReadingItem(item.id, item.source.name, item.bookId);
        if (!isCurrent() || !db.isActive) return;
        if (row != null) updates.add((item, row['is_fav'] == 1));
      }
      final statsRequest = ++_statsRequest;
      final stats = await db.getReadingStats();
      if (_disposed || !db.isActive || revision != _sessionRevision || request != _request) return;
      // Another refresh or a local toggle may have committed while these reads
      // were in flight. Read again instead of publishing its stale snapshot.
      if (favoriteRevision != _favoriteRevision) {
        await _refreshFavorites(keys);
        return;
      }
      _favoriteRevision++;
      for (final (item, favorite) in updates) {
        item.isFav = favorite;
      }
      if (statsRequest == _statsRequest) {
        _stats = stats;
        _statsDirty = false;
      }
      notifyListeners();
    } catch (e) {
      if (isCurrent() && favoriteRevision == _favoriteRevision) {
        _error = e.toString(); notifyListeners();
      }
    } finally {
      _backgroundReads--;
    }
  }
  bool _publishingFavorite = false;
  final Set<String> _savingFavorites = {};
  int _favoriteRevision = 0;
  bool _disposed = false;
  Timer? _searchTimer;
  bool _statsDirty = true;

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    SyncService.changes.removeListener(_onSyncChanged);
    _request++;
    super.dispose();
  }
  List<NoteItem> _notes = [];
  int _request = 0;
  int _matchedCount = 0;
  bool _resetRequired = true;
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
    _refreshPending = true;
    _statsRequest++;
    _searchTimer?.cancel();
    _statsDirty = true;
    _request++;
    _notes = [];
    _matchedCount = 0;
    _resetRequired = true;
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
      final rows = await db.getReadingItems(after: items.isEmpty ? null : items.last,
          limit: pageSize, query: query, filter: filter);
      if (!db.isActive || revision != _sessionRevision || _disposed) {
        throw StateError('账号会话已结束');
      }
      if (rows.isEmpty) return items;
      items.addAll(rows.map(_fromRow));
    }
  }

  /// 摘要只读取数据库最终入选的最多 30 条。
  Future<List<NoteItem>> getSummaryNotes() async {
    final db = DatabaseService.instance;
    final revision = _sessionRevision;
    final rows = await db.getSummaryItems(query: _searchQuery, filter: _filter);
    if (!db.isActive || revision != _sessionRevision || _disposed) {
      throw StateError('账号会话已结束');
    }
    return rows.map(_fromRow).toList();
  }

  /// 搜索和筛选在全库执行，只加载当前批次。
  Future<void> loadNotes() {
    _searchTimer?.cancel();
    _statsDirty = true;
    return _loadPage(reset: true);
  }

  Future<void> loadMore() async {
    // The visible list still belongs to the previous query during debounce.
    if (_loading || _searchTimer?.isActive == true || !hasMore) return;
    await _loadPage(reset: _resetRequired);
  }

  Future<void> _loadPage({required bool reset, bool preserve = false, int limit = pageSize}) async {
    if (_disposed) return;
    if (reset) _resetRequired = true;
    if (!_active) { _refreshPending = true; return; }
    _refreshPending = false;
    final request = ++_request;
    final favoriteRevision = _favoriteRevision;
    if (reset && !preserve) _notes = [];
    final after = reset || _notes.isEmpty ? null : _notes.last;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final db = DatabaseService.instance;
      final query = _searchQuery;
      final filter = _filter;
      // Data/filter changes reset the list. Continuations can reuse its count.
      final count = reset
          ? await db.countReadingItems(query: query, filter: filter)
          : _matchedCount;
      if (request != _request || !db.isActive) return;
      // Deactivation invalidates _request and marks the refresh pending.
      final statsRequest = _statsDirty ? ++_statsRequest : _statsRequest;
      final stats = _statsDirty ? await db.getReadingStats() : _stats;
      if (request != _request || !db.isActive) return;
      final raw = await db.getReadingItems(after: after,
          limit: limit, query: query, filter: filter);
      if (request != _request || !db.isActive) return;
      if (favoriteRevision != _favoriteRevision) {
        await _loadPage(reset: reset, preserve: true, limit: limit);
        return;
      }
      final items = raw.map(_fromRow).toList();
      _notes = reset ? items : [..._notes, ...items];
      _matchedCount = count;
      _resetRequired = false;
      if (statsRequest == _statsRequest) {
        _stats = stats;
        _statsDirty = false;
      }
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
    if (query == _searchQuery) return;
    _searchQuery = query;
    _request++;
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 300), () => _loadPage(reset: true));
  }

  void setFilter(ReadingFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    _searchTimer?.cancel();
    _loadPage(reset: true);
  }

  Future<void> toggleFavorite(NoteItem note) async {
    if (_disposed) return;
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
      _statsRequest++;
      _statsDirty = true;
      note.isFav = favorite;
      for (final item in _notes) {
        if (item.id == note.id && item.source == note.source) item.isFav = favorite;
      }
      if (_filter == ReadingFilter.favorites && !favorite &&
          _notes.any((item) => item.id == note.id && item.source == note.source)) {
        _notes.removeWhere((item) => item.id == note.id && item.source == note.source);
        _matchedCount--;
      }
      notifyListeners();
      // 本列表直接更新；其他详情接收收藏事件，报告的数据版本不变。
      _publishingFavorite = true;
      try {
        SyncService.changes.publish(db, favoritesOnly: true, bookIds: {note.bookId},
          itemIds: {key}, sources: {note.source.name});
      } finally {
        _publishingFavorite = false;
      }
      if (_filter == ReadingFilter.favorites) {
        await _refreshFavorites({key});
      } else {
        // A concurrent stats refresh may already include this write. Adding a
        // local delta again would double-count it; read the committed totals.
        await _refreshStats();
      }
    } finally {
      _savingFavorites.remove(key);
    }
  }
  int get favCount => (_stats['favoriteBookmarks'] as int? ?? 0) +
      (_stats['favoriteNotes'] as int? ?? 0);
  int get bookmarkCount => _stats['totalBookmarks'] as int? ?? 0;
  int get noteCount => _stats['totalNotes'] as int? ?? 0;
  int get bookCount => _stats['totalBooks'] as int? ?? 0;
}
