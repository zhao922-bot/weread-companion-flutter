import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'config.dart';
import 'credentials.dart';
import 'database.dart';
import '../models/book.dart';
import '../models/bookmark.dart';

class LoginExpiredException implements Exception {
  const LoginExpiredException();

  @override
  String toString() => '登录凭据已失效，请重新登录';
}

class WeReadApi {
  late Dio _dio;
  final AppConfig config;
  final DatabaseService? _database;
  DatabaseService get db => _database ?? (throw StateError('登录验证不能访问阅读数据'));
  bool _cancelled = false;
  Future<void>? _refreshing;
  String? authenticatedAccountId;
  static final Set<WeReadApi> _sessions = {};

  static WeReadApi? _instance;
  static WeReadApi get instance => _instance!;

  static void reset() {
    _instance = null;
    for (final session in _sessions.toList()) {
      session.dispose();
    }
  }

  void dispose() {
    _cancelled = true;
    _dio.close(force: true);
    _sessions.remove(this);
  }

  factory WeReadApi.forLogin({required AppConfig config, Dio? dio}) =>
      WeReadApi._(config: config, dio: dio);

  static Future<WeReadApi> init({required AppConfig config, required DatabaseService db}) async {
    if (_instance == null) {
      _instance = WeReadApi._(config: config, db: db);
    }
    return _instance!;
  }

  WeReadApi._({required this.config, DatabaseService? db, Dio? dio}) : _database = db {
    _sessions.add(this);
    final options = BaseOptions(
      baseUrl: config.credentials != null
          ? 'https://i.weread.qq.com' : 'https://weread.qq.com/web',
      headers: config.credentials != null ? mobileVersionHeaders : {
        'Host': 'weread.qq.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
      followRedirects: config.credentials == null,
      maxRedirects: 5,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    );
    _dio = dio ?? Dio();
    _dio.options = options;

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_cancelled) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            message: '账号会话已结束',
          ));
          return;
        }
        final credentials = config.credentials;
        if (credentials != null) {
          options.headers.remove('Cookie');
          if (options.extra['tokenMint'] != true) {
            options.headers['vid'] = credentials.vid;
            options.headers['accessToken'] = credentials.accessToken;
          }
        } else if (config.cookie.isNotEmpty) {
          options.headers['Cookie'] = config.cookie;
        }
        handler.next(options);
      },
      onResponse: (response, handler) async {
        if (_shouldRefresh(response)) {
          try {
            handler.resolve(await _retryAuthenticated(response));
          } on DioException catch (error) {
            handler.reject(error);
          } catch (error) {
            handler.reject(DioException(
              requestOptions: response.requestOptions,
              error: error,
            ));
          }
        } else {
          handler.next(response);
        }
      },
      onError: (error, handler) async {
        final response = error.response;
        if (response != null && _shouldRefresh(response)) {
          try {
            handler.resolve(await _retryAuthenticated(response));
          } on DioException catch (failure) {
            handler.next(failure);
          } catch (failure) {
            handler.next(DioException(
              requestOptions: error.requestOptions,
              error: failure,
            ));
          }
        } else {
          handler.next(error);
        }
      },
    ));
  }

  bool _authFailed(Response<dynamic> response) {
    final data = response.data;
    final code = data is Map ? data['errCode'] ?? data['errcode'] : null;
    return response.statusCode == 401 || response.statusCode == 403 ||
        code?.toString() == '-2012';
  }

  bool _shouldRefresh(Response<dynamic> response) =>
      config.credentials != null &&
      response.requestOptions.extra['tokenMint'] != true &&
      response.requestOptions.extra['authRetried'] != true &&
      _authFailed(response);

  Future<Response<dynamic>> _retryAuthenticated(Response<dynamic> response) async {
    final options = response.requestOptions;
    // 迟到的旧 token 响应复用已刷新的凭据，多个并发请求只刷新一次。
    if (options.headers['accessToken'] == config.credentials?.accessToken) {
      await _refreshToken();
    }
    if (_cancelled) throw StateError('账号会话已结束');
    final retried = await _dio.fetch<dynamic>(options.copyWith(
      extra: {...options.extra, 'authRetried': true},
    ));
    if (_authFailed(retried)) {
      // 新 token 仍被拒绝不能证明 refreshToken 失效，保留凭据供再次验证。
      throw StateError('新 token 暂时无法通过验证，请稍后重试');
    }
    return retried;
  }

  Future<void> _refreshToken() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final started = _mintAccessToken();
    _refreshing = started;
    try {
      await started;
    } finally {
      if (identical(_refreshing, started)) _refreshing = null;
    }
  }

  Future<void> _mintAccessToken() async {
    final previous = config.credentials!;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure().nextInt(1000) + 1;
    final response = await _dio.post<dynamic>('/login',
      options: Options(
        extra: {'tokenMint': true},
        contentType: 'application/json; charset=UTF-8',
        validateStatus: (status) => status != null && status < 500,
      ),
      data: {
        'deviceId': previous.deviceId,
        'deviceName': 'BOOX',
        'deviceType': 3,
        'inBackground': 0,
        'kickType': 1,
        'random': random,
        'refCgi': '',
        'refreshToken': previous.refreshToken,
        'signature': sha256.convert(utf8.encode(
            '$timestamp${previous.deviceId}$random')).toString(),
        'timestamp': timestamp,
        'trackId': '',
      },
    );
    final data = response.data;
    if (_authFailed(response)) {
      throw const LoginExpiredException();
    }
    final code = data is Map ? data['errCode'] ?? data['errcode'] : null;
    if (response.statusCode != 200 || data is! Map ||
        (code != null && code.toString() != '0')) {
      throw StateError('刷新服务暂时不可用');
    }
    final next = Credentials.fromJson({
      'vid': data['vid'] ?? previous.vid,
      'accessToken': data['accessToken'],
      'refreshToken': data['refreshToken'] ?? previous.refreshToken,
      'deviceId': previous.deviceId,
    });
    if (next.vid != previous.vid) throw StateError('刷新返回的账号不匹配');
    if (_cancelled || !identical(config.credentials, previous)) {
      throw StateError('账号会话已结束');
    }
    config.credentials = next;
    await config.saveCredentials();
  }

  void updateCookie(String cookie) {
    config.cookie = normalizeCookie(cookie);
  }

  /// Cookie 格式兼容：支持 JSON 数组、Netscape/TSV、普通字符串
  static String normalizeCookie(String raw) {
    raw = raw.trim();
    final cookies = <String, String>{};
    void add(dynamic name, dynamic value) {
      if (name is! String || value is! String ||
          !RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]+$').hasMatch(name) ||
          RegExp(r'[;\r\n\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('Cookie 格式无效');
      }
      cookies[name] = value;
    }

    if (raw.startsWith('[') || raw.startsWith('{')) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) throw const FormatException('Cookie JSON 格式无效');
          final domain = item['domain'];
          if (domain is String && domain.isNotEmpty &&
              domain != 'weread.qq.com' && domain != '.weread.qq.com' &&
              domain != '.qq.com' && domain != 'qq.com') {
            continue;
          }
          add(item['name'], item['value'] ?? '');
        }
      } else if (decoded is Map) {
        for (final entry in decoded.entries) {
          add(entry.key, entry.value);
        }
      } else {
        throw const FormatException('Cookie JSON 格式无效');
      }
    } else if (raw.contains('\t')) {
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        if (line.trim().isEmpty || (line.startsWith('#') && !line.startsWith('#HttpOnly_'))) continue;
        final fields = line.replaceFirst('#HttpOnly_', '').split('\t');
        if (fields.length != 7) throw const FormatException('Cookie TSV 格式无效');
        if (fields[0] == 'weread.qq.com' || fields[0] == '.weread.qq.com' ||
            fields[0] == '.qq.com' || fields[0] == 'qq.com') {
          add(fields[5], fields[6]);
        }
      }
    } else {
      raw = raw.replaceFirst(RegExp(r'^cookie\s*:\s*', caseSensitive: false), '');
      for (final part in raw.split(';')) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        final separator = trimmed.indexOf('=');
        if (separator < 1) throw const FormatException('Cookie 格式无效');
        add(trimmed.substring(0, separator).trim(), trimmed.substring(separator + 1).trim());
      }
    }
    return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 检查登录状态
  Future<bool> checkLogin() async {
    authenticatedAccountId = null;
    try {
      if (config.credentials != null) {
        // 书架同步是需要认证的接口，不用公开用户资料接口验证移动端 token。
        final resp = await _dio.get('/shelf/sync');
        final data = resp.data;
        final code = data is Map ? data['errCode'] ?? data['errcode'] : null;
        if (data is! Map || data['books'] is! List || _authFailed(resp) ||
            (code != null && code.toString() != '0')) {
          throw StateError('暂时无法验证移动端登录');
        }
        authenticatedAccountId = config.credentials!.vid;
        return true;
      }
      final resp = await _dio.get('/user?userVid=0');
      final data = resp.data;
      final id = data is Map ? data['vid']?.toString() : null;
      if (id != null && RegExp(r'^[0-9]+$').hasMatch(id) && id != '0') {
        authenticatedAccountId = id;
        return true;
      }
      return false;
    } on DioException catch (e) {
      if (config.credentials != null) {
        if (e.error is LoginExpiredException) return false;
        rethrow;
      }
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) return false;
      rethrow;
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
      if (_cancelled) throw StateError('同步已取消');
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
