import 'book.dart';

enum BookshelfFilter {
  all,
  finished,
  reading,
  unread;

  String get label => switch (this) {
    all => '全部',
    finished => '读完',
    reading => '在读中',
    unread => '未读',
  };

  bool matches(Book book) => switch (this) {
    all => true,
    finished => book.isFinished,
    reading => book.isReading,
    unread => book.isUnread,
  };
}

enum BookshelfSort {
  recent,
  progressDesc,
  progressAsc,
  title;

  String get label => switch (this) {
    recent => '最近更新',
    progressDesc => '进度从高到低',
    progressAsc => '进度从低到高',
    title => '书名排序',
  };

  int compare(Book a, Book b) => switch (this) {
    recent => b.updatedAt.compareTo(a.updatedAt),
    progressDesc => b.progress.compareTo(a.progress),
    progressAsc => a.progress.compareTo(b.progress),
    title => a.title.compareTo(b.title),
  };
}
