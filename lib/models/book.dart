class Book {
  final String bookId;
  final String title;
  final String author;
  final String cover;
  final int progress;
  final int finished;
  bool get isFinished => finished != 0;
  final String category;
  final int updatedAt;

  Book({
    required this.bookId,
    required this.title,
    this.author = '',
    this.cover = '',
    this.progress = 0,
    this.finished = 0,
    this.category = '',
    int? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  factory Book.fromJson(Map<String, dynamic> json) {
    final bookJson = json['book'] ?? json;
    return Book(
      bookId: (bookJson['bookId'] ?? bookJson['book_id'] ?? '').toString(),
      title: bookJson['title'] ?? '',
      author: bookJson['author'] ?? '',
      cover: bookJson['cover'] ?? '',
      progress: bookJson['progress'] ?? 0,
      finished: bookJson['finished'] ?? 0,
      category: bookJson['category'] ?? '',
      updatedAt: bookJson['updated_at'] ?? bookJson['updateTime'] ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'title': title,
        'author': author,
        'cover': cover,
        'progress': progress,
        'finished': finished,
        'category': category,
        'updated_at': updatedAt,
      };

  @override
  String toString() => 'Book($bookId: $title by $author)';
}
