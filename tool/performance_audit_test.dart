// Run separately: flutter test tool/performance_audit_test.dart --reporter expanded
// This is a reproducible host benchmark, not a device/frame-rate benchmark.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/note_item.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure real SQLite queries and streamed exports at three sizes',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi; // Production Windows isolate path.
    final directory = await Directory.systemTemp.createTemp('readamber-perf-');
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final samples = <Map<String, Object>>[];
    var count = 0;
    Future<void> measure(String name, Future<void> Function() action,
        {int repeats = 5}) async {
      final elapsed = <double>[];
      final rssStart = ProcessInfo.currentRss;
      var rssPeak = rssStart;
      final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final rss = ProcessInfo.currentRss;
        if (rss > rssPeak) rssPeak = rss;
      });
      try {
        for (var i = 0; i < repeats; i++) {
          final watch = Stopwatch()..start();
          await action();
          elapsed.add(watch.elapsedMicroseconds / 1000);
        }
      } finally {
        timer.cancel();
      }
      elapsed.sort();
      final result = <String, Object>{
        'rows': count,
        'operation': name,
        'samples': repeats,
        'medianMs': elapsed[elapsed.length ~/ 2],
        'maxMs': elapsed.last,
        'rssStartBytes': rssStart,
        'sampledPeakRssBytes': rssPeak,
      };
      samples.add(result);
      // ignore: avoid_print
      print(jsonEncode(result));
    }

    try {
      await databaseFactory.setDatabasesPath(directory.path);
      await DatabaseService.selectAccount('999999');
      final db = DatabaseService.instance;
      await db.insertBooks(List.generate(
          200,
          (i) => {
                'book_id': 'b$i',
                'title': '审查书籍$i',
                'progress': i % 101,
                'updated_at': 1780000000
              }));
      for (final size in [2000, 20000, 50000]) {
        final seedWatch = Stopwatch()..start();
        while (count < size) {
          await db.insertNotes(List.generate(500, (offset) {
            final id = count + offset;
            return {
              'note_id': 'n$id',
              'book_id': 'b${id % 200}',
              'book_title': '审查书籍${id % 200}',
              'chapter_title': '第${id % 20}章',
              'content': '${id % 1000 == 0 ? "琥珀记忆" : "阅读思考"}'
                  '${List.filled(12, "这是用于性能审查的中文笔记。保留内容以验证搜索和导出。").join()} [$id]',
              'created_at': 1780000000 + id,
              'is_fav': id % 10 == 0 ? 1 : 0,
            };
          }));
          count += 500;
        }
        samples.add({
          'rows': count,
          'operation': 'seed-increment',
          'ms': seedWatch.elapsedMilliseconds
        });
        expect(await db.countReadingItems(), size);
        await measure('first-100', () async {
          expect((await db.getReadingItems()).length, 100);
        });
        final lastPage =
            await db.getReadingItems(offset: size - 200, limit: 100);
        final row = lastPage.last;
        final cursor = NoteItem(
          id: row['id'] as String,
          bookId: row['book_id'] as String,
          bookTitle: row['book_title'] as String,
          content: row['content'] as String,
          chapterTitle: row['chapter_title'] as String,
          createdAt: row['created_at'] as int,
          isFav: row['is_fav'] == 1,
          source: NoteSource.values.byName(row['source'] as String),
        );
        await measure('last-100-keyset', () async {
          final page = await db.getReadingItems(after: cursor);
          expect(page.length, 100);
          expect(page.last['id'], 'n0');
        });
        for (final query in ['琥珀记忆', '琥珀']) {
          await measure('search-$query', () async {
            expect(await db.countReadingItems(query: query), size ~/ 1000);
            expect(
                (await db.getReadingItems(query: query)).length, size ~/ 1000);
          });
        }
        await measure('report', () async {
          expect((await db.getReportStats())['totalNotes'], size);
        });
        await measure('markdown-export', () async {
          final exporting = Stopwatch()..start();
          final file = File(await ExportService.exportToMarkdown());
          samples.add({
            'rows': count,
            'operation': 'export-only',
            'ms': exporting.elapsedMilliseconds
          });
          final lines = await file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .where((line) => line.startsWith('- 💭 '))
              .length;
          expect(lines, size);
          samples.add({
            'rows': count,
            'operation': 'export-size',
            'bytes': await file.length()
          });
          await file.delete();
        }, repeats: 1);
      }
      final output = File('build/audit-performance.json');
      await output.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'platform': Platform.operatingSystem,
        'runtime': Platform.version,
        'mode':
            'Flutter test JIT; SQLite FFI isolate; synthetic Chinese notes; warm process',
        'memory':
            '20ms sampled process RSS, includes Flutter test/VM and all isolates, not Dart heap or exact peak',
        'samples': samples,
      }));
    } finally {
      await DatabaseService.endSession();
      PathProviderPlatform.instance = originalPaths;
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
