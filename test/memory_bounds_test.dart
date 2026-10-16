import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';
import 'support/observed_database.dart';

class _Paths extends PathProviderPlatform {
  final String path;
  Future<void> Function()? onDocuments;
  _Paths(this.path);
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    await onDocuments?.call();
    return path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  late PathProviderPlatform originalPaths;
  late _Paths paths;
  setUpAll(() {
    sqfliteFfiInit();
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('weread-memory-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = paths = _Paths(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    await DatabaseService.endSession();
    PathProviderPlatform.instance = originalPaths;
    databaseFactory = databaseFactoryFfiNoIsolate;
    await directory.delete(recursive: true);
  });

  Future<void> seed(int count, {bool manyBooks = false}) async {
    final batch = (await db.database).batch();
    for (var i = 0; i < count; i++) {
      final bookmark = i.isEven;
      batch.insert(bookmark ? 'bookmarks' : 'notes', {
        bookmark ? 'bookmark_id' : 'note_id':
            'id${i.toString().padLeft(5, '0')}',
        'book_id': manyBooks && i >= 3000 ? 'b$i' : 'b',
        'book_title': manyBooks && i >= 3000 ? '书籍$i' : '测试书籍',
        bookmark ? 'mark_text' : 'content': '正文$i',
        'chapter_title': '共同章节',
        'created_at': 1,
        'is_fav': 1,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> expectNoStaging() async {
    expect(
        await directory
            .list()
            .where((entry) => entry.path.contains('.weread-export-'))
            .toList(),
        isEmpty);
  }

  test('5505条跨2506本书导出每次读取不超过500行，跨页章节和顺序完整', () async {
    await seed(5505, manyBooks: true);
    probe.reads.clear();
    final path = await ExportService.exportToMarkdown();
    expect(probe.reads, isNotEmpty);
    expect(probe.reads.map((read) => read.rows),
        everyElement(lessThanOrEqualTo(500)));
    final text = await File(path).readAsString();
    final lines =
        RegExp(r'^- [📝💭]+ 正文([0-9]+)$', multiLine: true, unicode: true)
            .allMatches(text)
            .map((m) => int.parse(m[1]!))
            .toList();
    expect(lines, hasLength(5505));
    expect(lines.toSet(), hasLength(5505));
    expect(
        RegExp(r'^## 📖 ', multiLine: true).allMatches(text), hasLength(2506));
    expect(RegExp(r'^\*\*共同章节\*\*$', multiLine: true).allMatches(text),
        hasLength(2506));
    final sameBook = lines.where((i) => i < 3000).toList();
    expect(sameBook, [
      for (var i = 2998; i >= 0; i -= 2) i,
      for (var i = 2999; i >= 1; i -= 2) i,
    ]);
    await expectNoStaging();
  });

  test('快照生成失败回滚并解除ATTACH，清理暂存文件且可再次导出', () async {
    await seed(5);
    probe.beforeExecute = (sql) {
      if (sql.contains('CREATE TABLE weread_export_snapshot.entries')) {
        throw StateError('模拟快照磁盘写入失败');
      }
    };
    await expectLater(ExportService.exportToMarkdown(), throwsStateError);
    await expectNoStaging();
    probe.beforeExecute = null;
    final attached = await (await db.database).rawQuery('PRAGMA database_list');
    expect(attached.where((row) => row['name'] == 'weread_export_snapshot'),
        isEmpty);
    expect(await db.countReadingItems(), 5);
    expect(await File(await ExportService.exportToMarkdown()).exists(), isTrue);
  });

  test('12次并发导出只占用一个附加数据库，文件互不覆盖且无暂存残留', () async {
    await seed(10);
    var attached = 0;
    var maximum = 0;
    probe.beforeExecute = (sql) {
      if (sql.startsWith('ATTACH')) {
        attached++;
        if (attached > maximum) maximum = attached;
      } else if (sql.startsWith('DETACH')) {
        attached--;
      }
    };
    final files = await Future.wait(
        List.generate(12, (_) => ExportService.exportToMarkdown()));
    expect(maximum, 1);
    expect(attached, 0);
    expect(files.toSet(), hasLength(12));
    for (final path in files) {
      expect(
          RegExp(r'^- ', multiLine: true)
              .allMatches(await File(path).readAsString()),
          hasLength(10));
    }
    await expectNoStaging();
  });

  test('快照已生成但文件写入前退出，清理后不会发布旧账号内容', () async {
    await seed(5);
    final reached = Completer<void>();
    final release = Completer<void>();
    paths.onDocuments = () async {
      paths.onDocuments = null;
      reached.complete();
      await release.future;
    };
    final failed =
        expectLater(ExportService.exportToMarkdown(), throwsStateError);
    try {
      await reached.future.timeout(const Duration(seconds: 5));
      await DatabaseService.endSession();
      await ExportService.clearLocalExports();
      await expectNoStaging();
    } finally {
      release.complete();
    }
    await failed;
    expect(
        await directory
            .list()
            .where((entry) => entry.path.endsWith('.md'))
            .toList(),
        isEmpty);
  });

  test('导出快照读取中退出能关闭文件句柄并清理，禁止继续写入和发布', () async {
    await seed(1005);
    final reached = Completer<void>();
    final release = Completer<void>();
    probe.afterRead = (sql) async {
      if (sql.contains('FROM entries AS e')) {
        probe.afterRead = null;
        reached.complete();
        await release.future;
      }
    };
    final failed =
        expectLater(ExportService.exportToMarkdown(), throwsStateError);
    try {
      await reached.future.timeout(const Duration(seconds: 5));
      await DatabaseService.endSession();
      await ExportService.clearLocalExports();
      await expectNoStaging();
    } finally {
      release.complete();
    }
    await failed;
    expect(
        await directory
            .list()
            .where((entry) => entry.path.endsWith('.md'))
            .toList(),
        isEmpty);
  });

  test('同时清理已完成导出和暂存目录时，重复删除不应报错', () async {
    await seed(1);
    await ExportService.exportToMarkdown();
    final staging = await directory.createTemp('.weread-export-');
    await File('${staging.path}/notes.md').writeAsString('未完成内容');
    await Future.wait(
        [ExportService.clearLocalExports(), ExportService.clearLocalExports()]);
    await expectNoStaging();
    expect(
        await directory
            .list()
            .where((entry) => entry.path.endsWith('.md'))
            .toList(),
        isEmpty);
  });

  test('旧库回填每批最多100行，失败保留进度并从已提交批次之后续跑', () async {
    await seed(605);
    final connection = await db.database;
    await connection
        .execute('CREATE TABLE search_index_backfill (pending INTEGER)');
    await connection.execute('''
      CREATE TRIGGER fail_backfill BEFORE INSERT ON item_trigrams
      WHEN new.id = 'id00200' AND new.source = 'bookmark'
      BEGIN SELECT RAISE(ABORT, '模拟回填中断'); END
    ''');
    await DatabaseService.endSession();
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await expectLater(db.database, throwsA(isA<DatabaseException>()));
    final repair = await databaseFactoryFfiNoIsolate
        .openDatabase('${directory.path}/weread_companion_account_123.db');
    final progress = await repair.query('search_index_progress');
    expect(progress.single['source'], 'bookmarks');
    expect(progress.single['last_id'], 'id00198');
    expect(
        (await repair.rawQuery(
                'SELECT COUNT(DISTINCT id) AS total FROM item_trigrams'))
            .single['total'],
        100);
    await repair.execute('DROP TRIGGER fail_backfill');
    // A retry must not rewrite the first committed batch.
    await repair.execute('''
      CREATE TRIGGER reject_replay BEFORE INSERT ON bookmarks
      WHEN new.bookmark_id <= 'id00198'
      BEGIN SELECT RAISE(ABORT, '不应重放已提交批次'); END
    ''');
    await repair.close();
    probe.reads.clear();
    await db.database;
    final migrationReads = probe.reads
        .where((read) => read.sql == 'bookmarks' || read.sql == 'notes');
    expect(migrationReads, isNotEmpty);
    expect(migrationReads.map((read) => read.rows),
        everyElement(lessThanOrEqualTo(100)));
    expect(await db.countReadingItems(query: '共同章节'), 605);
    expect((await db.getReadingStats())['favoriteBookmarks'], 303);
    expect((await db.getReadingStats())['favoriteNotes'], 302);
    expect(
        await (await db.database).rawQuery(
            "SELECT name FROM sqlite_master WHERE name IN ('search_index_backfill', 'search_index_progress')"),
        isEmpty);
  });
}
