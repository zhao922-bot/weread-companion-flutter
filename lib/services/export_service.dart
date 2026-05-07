import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'database.dart';

/// 笔记导出服务
class ExportService {
  /// 导出笔记为 Markdown 格式
  /// 返回文件路径
  static Future<String> exportToMarkdown({String? bookId}) async {
    final db = DatabaseService.instance;

    // 获取所有划线和笔记
    var bookmarks = await db.getAllBookmarks(limit: 9999);
    var notes = await db.getAllNotes(limit: 9999);

    // 按书过滤
    if (bookId != null) {
      bookmarks = bookmarks.where((b) => b['book_id'] == bookId).toList();
      notes = notes.where((n) => n['book_id'] == bookId).toList();
    }

    if (bookmarks.isEmpty && notes.isEmpty) {
      throw Exception('暂无数据可导出');
    }

    // 按 bookId 分组
    final booksMap = <String, Map<String, dynamic>>{};

    for (final bm in bookmarks) {
      final bid = bm['book_id'] ?? '';
      if (bid.isEmpty) continue;
      booksMap.putIfAbsent(bid, () => {
        'title': bm['book_title'] ?? '未知',
        'items': <Map<String, dynamic>>[],
      });
      (booksMap[bid]!['items'] as List).add({
        ...bm,
        '_type': 'bookmark',
      });
    }

    for (final nt in notes) {
      final bid = nt['book_id'] ?? '';
      if (bid.isEmpty) continue;
      booksMap.putIfAbsent(bid, () => {
        'title': nt['book_title'] ?? '未知',
        'items': <Map<String, dynamic>>[],
      });
      (booksMap[bid]!['items'] as List).add({
        ...nt,
        '_type': 'note',
      });
    }

    // 生成 Markdown
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final lines = <String>[
      '# 📚 微信读书笔记\n',
      '导出时间: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}\n',
    ];

    for (final entry in booksMap.entries) {
      final info = entry.value;
      lines.add('\n## 📖 ${info['title']}\n');

      // 同书内按时间正序排列（划线和笔记统一排序）
      final items = info['items'] as List<Map<String, dynamic>>;
      items.sort((a, b) {
        final ta = a['created_at'] ?? 0;
        final tb = b['created_at'] ?? 0;
        return ta.compareTo(tb);
      });

      // 按章节分组输出
      String? currentChapter;
      for (final item in items) {
        final type = item['_type'];
        final ch = item['chapter_title'] ?? '';

        // 章节标题
        if (ch.isNotEmpty && ch != currentChapter) {
          currentChapter = ch;
          lines.add('\n**$ch**\n');
        }

        if (type == 'bookmark') {
          lines.add('- 📝 ${item['mark_text'] ?? ''}');
        } else {
          lines.add('- 💭 ${item['content'] ?? ''}');
        }
      }
      lines.add('');
    }

    // 保存文件
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/微信读书笔记_$dateStr.md');
    await file.writeAsString(lines.join('\n'), encoding: utf8);

    return file.path;
  }

  /// 导出并通过系统分享
  static Future<void> exportAndShare({String? bookId}) async {
    final filePath = await exportToMarkdown(bookId: bookId);
    await Share.shareXFiles(
      [XFile(filePath)],
      text: '微信读书笔记导出',
    );
  }
}
