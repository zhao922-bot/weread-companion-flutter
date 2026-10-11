import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
      await for (final entry in directory.list()) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && (RegExp(r'^微信读书笔记_[0-9]+\.md$').hasMatch(name) ||
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
      // All paginated reads share one snapshot; sync writes wait for it.
      final paths = await connection.transaction((txn) async {
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
        final now = DateTime.now();
        String two(int n) => n.toString().padLeft(2, '0');
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/微信读书笔记_${now.year}${two(now.month)}${two(now.day)}.md');
        staging = await dir.createTemp('.weread-export-');
        final pending = File('${staging!.path}/notes.md');
        final sink = pending.openWrite(encoding: utf8);
        try {
          sink.write('# 📚 微信读书笔记\n\n导出时间: ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}\n');
          for (final book in books) {
            final id = book['book_id'];
            final title = await txn.rawQuery('''
          SELECT book_title FROM (
            SELECT book_title, created_at, bookmark_id AS id, 0 AS priority FROM bookmarks WHERE book_id = ?
            UNION ALL SELECT book_title, created_at, note_id AS id, 1 AS priority FROM notes WHERE book_id = ?)
          ORDER BY priority, created_at DESC, id DESC LIMIT 1
            ''', [id, id]);
            sink.write('\n\n## 📖 ${title.first['book_title']}\n\n');
            String? chapter;
            Map<String, dynamic>? after;
            while (true) {
              if (!db.isActive) throw StateError('账号会话已结束');
              final rows = await txn.rawQuery('''
            SELECT * FROM (
              SELECT bookmark_id AS id, mark_text AS content, chapter_title, created_at, 'bookmark' AS source FROM bookmarks WHERE book_id = ?
              UNION ALL SELECT note_id AS id, content, chapter_title, created_at, 'note' AS source FROM notes WHERE book_id = ?)
            ${after == null ? '' : 'WHERE created_at > ? OR (created_at = ? AND (source > ? OR (source = ? AND id < ?)))'}
            ORDER BY created_at ASC, source ASC, id DESC LIMIT 500
              ''', [id, id, if (after != null) ...[after['created_at'], after['created_at'], after['source'], after['source'], after['id']]]);
              if (rows.isEmpty) break;
              final formatted = jsonDecode(await compute(_formatBatch, {'rows': rows, 'chapter': chapter})) as Map<String, dynamic>;
              sink.write(formatted['text']);
              chapter = formatted['chapter'] as String?;
              after = rows.last;
              await sink.flush();
            }
          }
          await sink.flush();
          if (!db.isActive) throw StateError('账号会话已结束');
        } finally {
          await sink.close();
        }
        return (pending, file);
      });
      if (!db.isActive) throw StateError('账号会话已结束');
      // Both files are on the same filesystem: publish only the complete file.
      await paths.$1.rename(paths.$2.path);
      return paths.$2.path;
    } finally {
      if (staging != null && await staging!.exists()) await staging!.delete(recursive: true);
    }
  }

  static Future<void> exportAndShare({String? bookId}) async {
    final path = await exportToMarkdown(bookId: bookId);
    await Share.shareXFiles([XFile(path)], text: '微信读书笔记导出');
  }
}
