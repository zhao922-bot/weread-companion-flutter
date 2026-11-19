import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/ai_summary.dart';
import '../utils/date_format.dart';
import 'database.dart';
import 'sync_service.dart';

class BackupRestoreResult {
  final int books;
  final int bookmarks;
  final int notes;
  final int summaries;

  const BackupRestoreResult({
    required this.books,
    required this.bookmarks,
    required this.notes,
    required this.summaries,
  });

  String get summary =>
      '已恢复 $books 本书、$bookmarks 条划线、$notes 条笔记、$summaries 条摘要';
}

/// 本地 JSON 完整备份与恢复服务（保留收藏状态与 AI 摘要历史）。
abstract final class BackupService {
  static const int currentVersion = 1;

  static Future<String> buildBackupJson(DatabaseService db) async {
    db.requireActive();
    final books = await db.getAllBooks();
    final bookmarks = await db.getAllBookmarks(limit: 1000000);
    final notes = await db.getAllNotes(limit: 1000000);
    final summaries = await db.getSummaries();
    db.requireActive();
    return jsonEncode({
      'version': currentVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'books': books,
      'bookmarks': bookmarks,
      'notes': notes,
      'summaries': summaries.map((s) => s.toJson()).toList(),
    });
  }

  static Future<String> exportBackupFile({DatabaseService? database}) async {
    final db = database ?? DatabaseService.instance;
    final payload = await buildBackupJson(db);
    final dir = await getApplicationDocumentsDirectory();
    db.requireActive();
    final stamp = ReadAmberDateFormat.formatFileStamp(DateTime.now());
    final file = File('${dir.path}/readamber_backup_$stamp.json');
    await file.writeAsString(payload);
    return file.path;
  }

  static Future<void> exportAndShare({DatabaseService? database}) async {
    final db = database ?? DatabaseService.instance;
    final path = await exportBackupFile(database: db);
    db.requireActive();
    await Share.shareXFiles([XFile(path)], text: '阅珀 ReadAmber 完整数据备份');
  }

  static Future<BackupRestoreResult> restoreFromJson(
    String jsonText, {
    DatabaseService? database,
  }) async {
    final db = database ?? DatabaseService.instance;
    db.requireActive();
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != currentVersion) {
      throw const FormatException('不支持的备份文件格式或版本');
    }
    final books = _castRows(decoded['books']);
    final bookmarks = _castRows(decoded['bookmarks']);
    final notes = _castRows(decoded['notes']);
    final rawSummaries = _castRows(decoded['summaries']);

    if (books.isNotEmpty) await db.insertBooks(books);
    if (bookmarks.isNotEmpty) await db.insertBookmarks(bookmarks);
    if (notes.isNotEmpty) await db.insertNotes(notes);
    for (final raw in rawSummaries) {
      await db.saveSummary(AISummary.fromJson(raw));
    }
    db.requireActive();
    SyncService.changes.publish(db, kind: SyncChangeKind.all);
    return BackupRestoreResult(
      books: books.length,
      bookmarks: bookmarks.length,
      notes: notes.length,
      summaries: rawSummaries.length,
    );
  }

  static List<Map<String, dynamic>> _castRows(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }
}
