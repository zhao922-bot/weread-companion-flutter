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
