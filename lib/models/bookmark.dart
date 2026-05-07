class Bookmark {
  final String bookmarkId;
  final String bookId;
  final String bookTitle;
  final String bookAuthor;
  final String markText;
  final String chapterTitle;
  final int createdAt;
  final bool isFav;

  Bookmark({
    required this.bookmarkId,
    required this.bookId,
    this.bookTitle = '',
    this.bookAuthor = '',
    this.markText = '',
    this.chapterTitle = '',
    int? createdAt,
    this.isFav = false,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    return Bookmark(
      bookmarkId: (json['bookmarkId'] ?? json['bookmark_id'] ?? '').toString(),
      bookId: (json['bookId'] ?? json['book_id'] ?? '').toString(),
      bookTitle: json['bookTitle'] ?? json['book_title'] ?? '',
      bookAuthor: json['bookAuthor'] ?? json['book_author'] ?? '',
      markText: json['markText'] ?? json['mark_text'] ?? '',
      chapterTitle: json['chapterTitle'] ?? json['chapter_title'] ?? '',
      createdAt: json['created_at'] ?? json['createTime'] ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      isFav: (json['is_fav'] ?? 0) == 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookmark_id': bookmarkId,
        'book_id': bookId,
        'book_title': bookTitle,
        'book_author': bookAuthor,
        'mark_text': markText,
        'chapter_title': chapterTitle,
        'created_at': createdAt,
        'is_fav': isFav ? 1 : 0,
      };

  @override
  String toString() =>
      'Bookmark($bookmarkId: ${markText.length > 30 ? markText.substring(0, 30) : markText}...)';
}
