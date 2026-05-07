import 'package:flutter/foundation.dart';
import '../services/database.dart';

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
  List<NoteItem> _notes = [];
  List<NoteItem> _filtered = [];
  String _searchQuery = '';
  String _filter = '全部划线'; // 全部划线/全部笔记/收藏
  bool _loading = false;
  String? _error;

  List<NoteItem> get notes => _filtered;
  bool get isLoading => _loading;
  String? get error => _error;
  String get filter => _filter;
  int get totalCount => _notes.length;

  /// 从 bookmarks 表和 notes 表加载全部数据，合并排序
  Future<void> loadNotes() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final items = <NoteItem>[];

      // 从 bookmarks 表加载划线
      final rawBookmarks = await DatabaseService.instance.getAllBookmarks();
      for (final m in rawBookmarks) {
        items.add(NoteItem(
          id: m['bookmark_id'] ?? '',
          bookId: m['book_id'] ?? '',
          bookTitle: m['book_title'] ?? '',
          content: m['mark_text'] ?? '',
          chapterTitle: m['chapter_title'] ?? '',
          createdAt: m['created_at'] ?? 0,
          isFav: (m['is_fav'] ?? 0) == 1,
          source: NoteSource.bookmark,
        ));
      }

      // 从 notes 表加载笔记/想法
      final rawNotes = await DatabaseService.instance.getAllNotes();
      for (final m in rawNotes) {
        items.add(NoteItem(
          id: m['note_id'] ?? '',
          bookId: m['book_id'] ?? '',
          bookTitle: m['book_title'] ?? '',
          content: m['content'] ?? '',
          chapterTitle: m['chapter_title'] ?? '',
          createdAt: m['created_at'] ?? 0,
          isFav: (m['is_fav'] ?? 0) == 1,
          source: NoteSource.note,
        ));
      }

      // 按时间倒序
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      _notes = items;
      _applyFilter();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
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

  Future<void> toggleFavorite(NoteItem note) async {
    if (note.source == NoteSource.bookmark) {
      await DatabaseService.instance.toggleBookmarkFavorite(note.id, !note.isFav);
    } else {
      await DatabaseService.instance.toggleFavorite(note.id, !note.isFav);
    }

    final idx = _notes.indexWhere((n) => n.id == note.id && n.source == note.source);
    if (idx >= 0) {
      _notes[idx].isFav = !_notes[idx].isFav;
    }
    _applyFilter();
  }

  void _applyFilter() {
    var list = List<NoteItem>.from(_notes);

    // 搜索过滤
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((n) =>
        n.content.toLowerCase().contains(q) ||
        n.bookTitle.toLowerCase().contains(q)
      ).toList();
    }

    // 类型过滤：用 source 字段区分（而非长度猜测）
    switch (_filter) {
      case '全部笔记':
        list = list.where((n) => n.source == NoteSource.note).toList();
        break;
      case '收藏':
        list = list.where((n) => n.isFav).toList();
        break;
      // '全部划线' 显示全部（划线 + 笔记）
    }

    _filtered = list;
    notifyListeners();
  }

  int get favCount => _notes.where((n) => n.isFav).length;
  int get bookmarkCount => _notes.where((n) => n.source == NoteSource.bookmark).length;
  int get noteCount => _notes.where((n) => n.source == NoteSource.note).length;
}
