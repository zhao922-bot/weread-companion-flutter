import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'config.dart';
import 'database.dart';
import '../models/book.dart';
import '../models/bookmark.dart';

class WeReadApi {
  late Dio _dio;
  final AppConfig config;
  final DatabaseService db;

  static WeReadApi? _instance;
  static WeReadApi get instance => _instance!;

  static Future<WeReadApi> init({required AppConfig config, required DatabaseService db}) async {
    if (_instance == null) {
      _instance = WeReadApi._(config: config, db: db);
    }
    return _instance!;
  }

  WeReadApi._({required this.config, required this.db}) {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://weread.qq.com/web',
      headers: {
        'Host': 'weread.qq.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
      followRedirects: true,
      maxRedirects: 5,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (config.cookie.isNotEmpty) {
          options.headers['Cookie'] = config.cookie;
        }
        handler.next(options);
      },
      onError: (error, handler) {
        handler.next(error);
      },
    ));
  }

  void updateCookie(String cookie) {
    config.cookie = normalizeCookie(cookie);
  }

  /// Cookie 格式兼容：支持 JSON 数组、Netscape/TSV、普通字符串
  static String normalizeCookie(String raw) {
    raw = raw.trim();

    // JSON 数组格式（Cookie-Editor 导出）
    if (raw.startsWith('[')) {
      try {
        final cookies = jsonDecode(raw);
        if (cookies is List && cookies.isNotEmpty && cookies[0] is Map && cookies[0].containsKey('name')) {
          final parts = cookies.map((c) => '${c['name']}=${c['value'] ?? ''}').join('; ');
          return parts;
        }
      } catch (_) {}
    }

    // JSON 对象格式
    if (raw.startsWith('{')) {
      try {
        final obj = jsonDecode(raw);
        if (obj is Map) {
          final parts = obj.entries.map((e) => '${e.key}=${e.value}').join('; ');
          return parts;
        }
      } catch (_) {}
    }

    return raw;
  }

  /// 检查登录状态
  Future<bool> checkLogin() async {
    try {
      final resp = await _dio.get('/user?userVid=0');
      final data = resp.data;
      if (data is Map && data.containsKey('vid') && data['vid'] != 0) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 书架同步 — GET /web/shelf/sync
  Future<List<Book>> fetchBookshelf() async {
    try {
      final resp = await _dio.get('/shelf/sync');
      final data = resp.data;

      if (data is Map && data.containsKey('errcode')) {
        throw Exception('Cookie 已过期或无效 (errcode: ${data['errcode']})');
      }

      final booksData = data['books'] ?? [];
      final progressData = data['bookProgress'] ?? [];

      if (booksData is! List) return [];

      // 构建 bookId -> progress 的映射
      final progressMap = <String, int>{};
      if (progressData is List) {
        for (final p in progressData) {
          if (p is Map) {
            final bookId = (p['bookId'] ?? '').toString();
            final progress = p['progress'] ?? 0;
            if (bookId.isNotEmpty) {
              progressMap[bookId] = progress is int ? progress : (progress as num).toInt();
            }
          }
        }
      }

      final books = <Book>[];
      for (final item in booksData) {
        if (item is! Map) continue;

        final b = item.containsKey('bookId') && item.containsKey('title')
            ? item as Map<String, dynamic>
            : (item['book'] ?? item) as Map<String, dynamic>;

        final bookId = (b['bookId'] ?? '').toString();
        if (bookId.isEmpty) continue;

        final progress = progressMap[bookId] ?? (b['progress'] ?? 0);
        final progressInt = progress is int ? progress : (progress as num).toInt();

        // finished 语义修正：API 的 finished=1 表示「在书架上」，不是「读完了」
        // 实际判断是否读完用 progress >= 85
        final book = Book(
          bookId: bookId,
          title: b['title'] ?? '',
          author: b['author'] ?? '',
          cover: b['cover'] ?? '',
          progress: progressInt,
          finished: progressInt >= 85 ? 1 : 0,
          category: b['category'] ?? '',
          updatedAt: b['updateTime'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );

        books.add(book);
        await db.insertOrUpdateBook(book.toJson());
      }
      return books;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 302) {
        throw Exception('Cookie 已过期，请重新导入');
      }
      throw Exception('获取书架失败: ${e.message}');
    }
  }

  /// 划线/书签 — GET /web/book/bookmarklist?bookId=xxx
  Future<List<Bookmark>> fetchBookmarks(String bookId, String bookTitle) async {
    try {
      final resp = await _dio.get('/book/bookmarklist', queryParameters: {'bookId': bookId});
      final data = resp.data;

      // 构建 chapterUid -> chapterTitle 映射
      final chMap = <int, String>{};
      final chapters = data['chapters'] ?? [];
      if (chapters is List) {
        for (final c in chapters) {
          if (c is Map) {
            final uid = c['chapterUid'] ?? 0;
            final title = c['title'] ?? '';
            if (uid != 0) chMap[uid as int] = title.toString();
          }
        }
      }

      final updated = data['updated'] ?? [];
      if (updated is! List) return [];

      final bookmarks = <Bookmark>[];
      for (final item in updated) {
        if (item is! Map) continue;

        final bmId = (item['bookmarkId'] ?? '').toString();
        if (bmId.isEmpty) continue;

        final chapterUid = item['chapterUid'] ?? 0;
        final chapterTitle = chMap[chapterUid as int] ?? item['chapterName'] ?? '';

        final bookmark = Bookmark(
          bookmarkId: bmId,
          bookId: bookId,
          bookTitle: bookTitle,
          markText: item['markText'] ?? '',
          chapterTitle: chapterTitle,
          createdAt: item['createTime'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );

        bookmarks.add(bookmark);
        // 使用 insertOrUpdate 但保留已有的 is_fav 状态
        await db.insertBookmarkPreserveFav(bookmark.toJson());
      }
      return bookmarks;
    } on DioException catch (e) {
      throw Exception('获取划线失败: ${e.message}');
    }
  }

  /// 笔记/想法 — GET /web/review/list?bookId=xxx&listType=11&mine=1&synckey=0
  Future<List<Map<String, dynamic>>> fetchNotes(String bookId, String bookTitle) async {
    try {
      final resp = await _dio.get('/review/list', queryParameters: {
        'bookId': bookId,
        'listType': '11',
        'mine': '1',
        'synckey': '0',
      });
      final data = resp.data;
      final reviews = data['reviews'] ?? [];
      if (reviews is! List) return [];

      final notes = <Map<String, dynamic>>[];
      for (final item in reviews) {
        if (item is! Map) continue;

        final rv = item['review'] ?? item;
        if (rv is! Map) continue;

        final reviewId = (rv['reviewId'] ?? '').toString();
        if (reviewId.isEmpty) continue;

        final note = {
          'note_id': reviewId,
          'book_id': bookId,
          'book_title': bookTitle,
          'content': rv['content'] ?? '',
          'chapter_title': rv['chapterName'] ?? '',
          'created_at': rv['createTime'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'is_fav': 0,
        };
        notes.add(note);
        // 保留已有的 is_fav 状态
        await db.insertNotePreserveFav(note);
      }
      return notes;
    } on DioException catch (e) {
      throw Exception('获取笔记失败: ${e.message}');
    }
  }

  /// 全量同步
  Future<Map<String, int>> syncAll() async {
    final books = await fetchBookshelf();
    int totalBookmarks = 0;
    int totalNotes = 0;

    for (int i = 0; i < books.length; i++) {
      final book = books[i];

      try {
        final bm = await fetchBookmarks(book.bookId, book.title);
        totalBookmarks += bm.length;
      } catch (_) {}

      try {
        final nt = await fetchNotes(book.bookId, book.title);
        totalNotes += nt.length;
      } catch (_) {}

      // 请求间隔，避免被限流（与桌面端一致）
      if (i < books.length - 1) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    return {
      'books': books.length,
      'bookmarks': totalBookmarks,
      'notes': totalNotes,
    };
  }
}
