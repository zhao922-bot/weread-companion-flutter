import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'database.dart';

String _formatBatch(Map<String, dynamic> input) {
  final out = StringBuffer();
  String? chapter = input['chapter'] as String?;
  for (final row in input['rows'] as List<Map<String, dynamic>>) {
    final ch = row['chapter_title'] as String? ?? '';
    if (ch.isNotEmpty && ch != chapter) {
      chapter = ch;
      out.write('\n**$ch**\n\n');
    }
    out.write('- ${row['source'] == 'bookmark' ? '📝' : '💭'} ${row['content'] ?? ''}\n');
  }
  return jsonEncode({'text': out.toString(), 'chapter': chapter});
}

class ExportService {
  static Future<void> clearLocalExports() async {
    for (final directory in [await getApplicationDocumentsDirectory(), await getTemporaryDirectory()]) {
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (entry is Directory && name.startsWith('.weread-export-')) {
          await entry.delete(recursive: true);
          continue;
        }
        if (entry is File && (RegExp(r'^微信读书笔记_(?:[0-9]+|[0-9]{8}_[0-9]{6}_[a-f0-9]{32})\.md$').hasMatch(name) ||
            RegExp(r'^weread_card_[0-9]+(?:_[0-9]+)?\.png$').hasMatch(name))) {
          await entry.delete();
        }
      }
    }
  }

  static Future<String> exportToMarkdown({String? bookId}) async {
    final db = DatabaseService.instance;
    final connection = await db.database;
    Directory? staging;
    try {
      // Capture only database data under the lock. Formatting and I/O use this
      // in-memory snapshot after the transaction has released the connection.
      final snapshot = await connection.transaction((txn) async {
        // Preserve book order: newest bookmark first, then note-only books.
        final books = await txn.rawQuery('''
      SELECT book_id, MIN(priority) AS priority,
        COALESCE(MAX(CASE WHEN priority = 0 THEN created_at END), MAX(created_at)) AS newest FROM (
        SELECT book_id, created_at, 0 AS priority FROM bookmarks
        UNION ALL SELECT book_id, created_at, 1 AS priority FROM notes)
      ${bookId == null ? '' : 'WHERE book_id = ?'}
      GROUP BY book_id ORDER BY priority, newest DESC, book_id DESC
        ''', [if (bookId != null) bookId]);
        if (books.isEmpty) throw Exception('暂无数据可导出');
        final result = <(Object?, List<Map<String, dynamic>>)>[];
        for (final book in books) {
          if (!db.isActive) throw StateError('账号会话已结束');
          final id = book['book_id'];
          final title = await txn.rawQuery('''
          SELECT book_title FROM (
            SELECT book_title, created_at, bookmark_id AS id, 0 AS priority FROM bookmarks WHERE book_id = ?
            UNION ALL SELECT book_title, created_at, note_id AS id, 1 AS priority FROM notes WHERE book_id = ?)
          ORDER BY priority, created_at DESC, id DESC LIMIT 1
            ''', [id, id]);
          final rows = await txn.rawQuery('''
            SELECT * FROM (
              SELECT bookmark_id AS id, mark_text AS content, chapter_title, created_at, 'bookmark' AS source FROM bookmarks WHERE book_id = ?
              UNION ALL SELECT note_id AS id, content, chapter_title, created_at, 'note' AS source FROM notes WHERE book_id = ?)
            ORDER BY created_at ASC, source ASC, id DESC
          ''', [id, id]);
          result.add((title.first['book_title'], rows));
        }
        return result;
      });
      if (!db.isActive) throw StateError('账号会话已结束');
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final dir = await getApplicationDocumentsDirectory();
      if (!db.isActive) throw StateError('账号会话已结束');
      final random = Random.secure();
      final taskId = List.generate(16, (_) => random.nextInt(256)
          .toRadixString(16).padLeft(2, '0')).join();
      final file = File('${dir.path}/微信读书笔记_${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}_$taskId.md');
      staging = await dir.createTemp('.weread-export-');
      final pending = File('${staging.path}/notes.md');
      final sink = pending.openWrite(encoding: utf8);
      try {
        sink.write('# 📚 微信读书笔记\n\n导出时间: ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}\n');
        for (final (title, items) in snapshot) {
          sink.write('\n\n## 📖 $title\n\n');
          String? chapter;
          for (var offset = 0; offset < items.length; offset += 500) {
            if (!db.isActive) throw StateError('账号会话已结束');
            final rows = items.sublist(offset, min(offset + 500, items.length));
            final formatted = jsonDecode(await compute(_formatBatch, {'rows': rows, 'chapter': chapter})) as Map<String, dynamic>;
            sink.write(formatted['text']);
            chapter = formatted['chapter'] as String?;
            await sink.flush();
          }
        }
        await sink.flush();
        if (!db.isActive) throw StateError('账号会话已结束');
      } finally {
        await sink.close();
      }
      if (!db.isActive) throw StateError('账号会话已结束');
      // Both files are on the same filesystem: publish only the complete file.
      await pending.rename(file.path);
      return file.path;
    } finally {
      if (staging != null && await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static Future<void> exportAndShare({String? bookId}) async {
    final path = await exportToMarkdown(bookId: bookId);
    await Share.shareXFiles([XFile(path)], text: '微信读书笔记导出');
  }
}
