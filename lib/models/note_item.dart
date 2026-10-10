/// 笔记数据源标记。
enum NoteSource { bookmark, note }

/// 阅读条目筛选，label 同时用于界面展示和数据库查询。
enum ReadingFilter {
  all,
  notes,
  favorites;

  String get label => switch (this) {
    all => '全部划线',
    notes => '全部笔记',
    favorites => '收藏',
  };
}

/// 包装统一的笔记条目。
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
