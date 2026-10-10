import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:weread_companion/models/bookshelf_filter.dart';
import 'package:weread_companion/models/note_item.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart' show NotesProvider;
import 'package:weread_companion/services/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tekartik.sqflite');

  setUpAll(() {
    databaseFactory = databaseFactorySqflitePlugin;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getDatabasesPath') return '/tmp/opencode';
      if (call.method == 'deleteDatabase') return null;
      throw UnsupportedError(call.method);
    });
  });

  tearDown(() async {
    await DatabaseService.endSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('账号切换使旧数据库会话失效，退出后禁止访问', () async {
    expect(() => DatabaseService.instance, throwsStateError);
    await DatabaseService.selectAccount('123');
    final first = DatabaseService.instance;
    await DatabaseService.selectAccount('456');
    final second = DatabaseService.instance;
    expect(first.accountId, '123');
    expect(second.accountId, '456');
    expect(identical(first, second), isFalse);
    await expectLater(first.database, throwsStateError);
    await DatabaseService.clearLocalData();
    expect(() => DatabaseService.instance, throwsStateError);
    await expectLater(second.database, throwsStateError);
  });

  test('拒绝无效账号和路径穿越', () async {
    for (final id in ['', '0', '../123', '123/456']) {
      await expectLater(DatabaseService.selectAccount(id), throwsArgumentError);
    }
    expect(() => DatabaseService.instance, throwsStateError);
  });

  test('退出时重置搜索、筛选和加载状态', () {
    final books = BookshelfProvider();
    final notes = NotesProvider();
    books.resetSession(1);
    notes.resetSession(1);
    books.setFilter(BookshelfFilter.finished);
    books.setSearch('旧账号');
    notes.setFilter(ReadingFilter.favorites);
    notes.setSearch('旧账号');
    books.resetSession(2);
    notes.resetSession(2);
    expect(books.filter, BookshelfFilter.all);
    expect(books.searchQuery, isEmpty);
    expect(notes.filter, ReadingFilter.all);
    expect(books.books, isEmpty);
    expect(notes.notes, isEmpty);
    expect(books.isLoading, isFalse);
    expect(notes.isLoading, isFalse);
    books.dispose();
    notes.dispose();
  });
}
