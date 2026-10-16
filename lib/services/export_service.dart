import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'database.dart';
import 'export_snapshot.dart';
import 'export_writer.dart';

String _formatBatch(Map<String, dynamic> input) {
  final out = StringBuffer();
  String? chapter = input['chapter'] as String?;
  int? book = input['book'] as int?;
  for (final row in input['rows'] as List<Map<String, dynamic>>) {
    if (row['book_position'] != book) {
      book = row['book_position'] as int;
      chapter = null;
      out.write('\n\n## 📖 ${row['title']}\n\n');
    }
    final ch = row['chapter_title'] as String? ?? '';
    if (ch.isNotEmpty && ch != chapter) {
      chapter = ch;
      out.write('\n**$ch**\n\n');
    }
    out.write(
        '- ${row['source'] == 'bookmark' ? '📝' : '💭'} ${row['content'] ?? ''}\n');
  }
  return jsonEncode({'text': out.toString(), 'chapter': chapter, 'book': book});
}

class ExportService {
  static final _snapshots = <ExportSnapshot>{};
  static final _writers = <ExportWriter>{};
  static final _failedCardExports = <String>{};

  /// Keep failed deletions reachable so the next export/logout can retry them.
  static Future<void> removeCardExports(Iterable<String> paths) async {
    Object? failure;
    StackTrace? failureStack;
    for (final path in paths.toList()) {
      try {
        await _deleteIfPresent(File(path));
        _failedCardExports.remove(path);
      } catch (error, stack) {
        _failedCardExports.add(path);
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  static Future<void> retryFailedCardExports() =>
      removeCardExports(_failedCardExports.toList());

  static Future<void> _deleteIfPresent(FileSystemEntity entry,
      {bool recursive = false}) async {
    try {
      await entry.delete(recursive: recursive);
    } on FileSystemException {
      // Export completion and logout can clean the same task concurrently.
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        rethrow;
      }
    }
  }

  static Future<void> clearLocalExports() async {
    Object? failure;
    StackTrace? failureStack;
    Future<void> clean(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    // Release failed captures and readers before deleting files on Windows.
    await clean(retryFailedCardExports);
    await clean(ExportSnapshot.releaseAttachments);
    for (final snapshot in _snapshots.toList()) {
      await clean(() async {
        await snapshot.close();
        _snapshots.remove(snapshot);
      });
    }
    for (final writer in _writers.toList()) {
      await clean(writer.close);
    }
    final visited = <String>{};
    for (final locate in [
      getApplicationDocumentsDirectory,
      getTemporaryDirectory
    ]) {
      await clean(() async {
        final directory = await locate();
        if (!visited.add(directory.absolute.path) ||
            !await directory.exists()) {
          return;
        }
        await for (final entry in directory.list(followLinks: false)) {
          final name = p.basename(entry.path);
          if (entry is Directory && name.startsWith('.weread-export-')) {
            await clean(() => _deleteIfPresent(entry, recursive: true));
            continue;
          }
          if (entry is File &&
              (RegExp(r'^微信读书笔记_(?:[0-9]+|[0-9]{8}_[0-9]{6}_[a-f0-9]{32})\.md$')
                      .hasMatch(name) ||
                  RegExp(r'^weread_card_[0-9]+(?:(?:_[a-f0-9]{32})?_[0-9]+)?\.png$')
                      .hasMatch(name))) {
            await clean(() => _deleteIfPresent(entry));
          }
        }
      });
    }
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  static Future<String> exportToMarkdown({String? bookId}) async {
    final db = DatabaseService.instance;
    Directory? staging;
    Directory? snapshotDirectory;
    ExportSnapshot? snapshot;
    File? output;
    Object? failure;
    StackTrace? failureStack;
    void recordFailure(Object error, StackTrace stack) {
      failure ??= error;
      failureStack ??= stack;
    }

    Future<void> clean(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        recordFailure(error, stack);
      }
    }

    try {
      final temporary = await getTemporaryDirectory();
      db.requireActive();
      snapshotDirectory =
          await temporary.createTemp('.weread-export-snapshot-');
      snapshot = await ExportSnapshot.capture(
          db, p.join(snapshotDirectory.path, 'snapshot.db'),
          bookId: bookId);
      _snapshots.add(snapshot);
      db.requireActive();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final dir = await getApplicationDocumentsDirectory();
      db.requireActive();
      final random = Random.secure();
      final taskId = List.generate(
              16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      final file = output = File(
          '${dir.path}/微信读书笔记_${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}_$taskId.md');
      staging = await dir.createTemp('.weread-export-');
      db.requireActive();
      final pending = File('${staging.path}/notes.md');
      final sink = ExportWriter(pending.openWrite(encoding: utf8));
      _writers.add(sink);
      try {
        sink.write(
            '# 📚 微信读书笔记\n\n导出时间: ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}\n');
        String? chapter;
        int? book;
        var after = 0;
        while (true) {
          db.requireActive();
          final rows = await snapshot.readPage(after: after);
          db.requireActive();
          if (rows.isEmpty) break;
          final formatted = jsonDecode(await compute(_formatBatch, {
            'rows': rows,
            'chapter': chapter,
            'book': book
          })) as Map<String, dynamic>;
          db.requireActive();
          sink.write(formatted['text']);
          chapter = formatted['chapter'] as String?;
          book = formatted['book'] as int?;
          after = rows.last['position'] as int;
          await sink.flush();
        }
        await sink.flush();
        db.requireActive();
      } catch (error, stack) {
        recordFailure(error, stack);
      } finally {
        await clean(sink.close);
        _writers.remove(sink);
      }
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      db.requireActive();
      // Both files are on the same filesystem: publish only the complete file.
      await pending.rename(file.path);
      db.requireActive();
    } catch (error, stack) {
      recordFailure(error, stack);
    }
    // Cleanup can fail or yield to logout. Do not publish a success until all
    // resources are released and the owning session has been checked again.
    await clean(() async {
      await snapshot?.close();
      _snapshots.remove(snapshot);
    });
    if (staging != null) {
      await clean(() => _deleteIfPresent(staging!, recursive: true));
    }
    if (snapshotDirectory != null) {
      await clean(() => _deleteIfPresent(snapshotDirectory!, recursive: true));
    }
    if (!db.isActive) {
      recordFailure(StateError('账号会话已结束'), StackTrace.current);
    }
    if (failure != null) {
      // A rename may have completed before reporting an error. Roll back only
      // this task's unique output; cleanup failures must not hide its cause.
      if (output != null) await clean(() => _deleteIfPresent(output!));
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    return output!.path;
  }

  static Future<void> exportAndShare({String? bookId}) async {
    final db = DatabaseService.instance;
    final path = await exportToMarkdown(bookId: bookId);
    db.requireActive();
    await Share.shareXFiles([XFile(path)], text: '微信读书笔记导出');
  }
}
