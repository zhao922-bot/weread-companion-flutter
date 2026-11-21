import 'dart:convert';

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
  final List<String> tags;

  NoteItem({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.content,
    required this.chapterTitle,
    required this.createdAt,
    required this.isFav,
    required this.source,
    this.tags = const [],
  });

  factory NoteItem.fromRow(Map<String, dynamic> row,
      {String fallbackBookTitle = ''}) {
    final rawTitle = row['book_title'] as String? ?? '';
    final tags = row['tags'] as String?;
    return NoteItem(
      id: row['id'] as String? ?? '',
      bookId: row['book_id'] as String? ?? '',
      bookTitle: rawTitle.isNotEmpty ? rawTitle : fallbackBookTitle,
      content: row['content'] as String? ?? '',
      chapterTitle: row['chapter_title'] as String? ?? '',
      createdAt: row['created_at'] as int? ?? 0,
      isFav: (row['is_fav'] ?? 0) == 1,
      source: NoteSource.values.byName(row['source'] as String),
      tags:
          tags == null ? const [] : List<String>.unmodifiable(jsonDecode(tags)),
    );
  }
}
