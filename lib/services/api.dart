import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'config.dart';
import 'credentials.dart';
import 'database.dart';
import '../models/reading_constants.dart';
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
  bool get syncCancelled => _cancelled;
  Future<void>? _refreshing;
  String? authenticatedAccountId;
  static final Set<WeReadApi> _sessions = {};
  static Map<String, dynamic>? _shelfSnapshot;
  static String? _snapshotCredential;
  static DateTime? _snapshotTime;
  String? get _credentialKey => config.credentials == null ? null :
      sha256.convert(utf8.encode(jsonEncode(config.credentials!.toJson()))).toString();

  static void _clearSnapshot() {
    _shelfSnapshot = null; _snapshotCredential = null; _snapshotTime = null;
  }

  static WeReadApi? _instance;
  static WeReadApi get instance => _instance!;

  static void reset() {
    _clearSnapshot();
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

  static Future<WeReadApi> init({required AppConfig config, required DatabaseService db, Dio? dio}) async {
    _instance ??= WeReadApi._(config: config, db: db, dio: dio);
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
    _clearSnapshot();
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
        _shelfSnapshot = Map<String, dynamic>.from(data);
        _snapshotCredential = _credentialKey;
        _snapshotTime = DateTime.now();
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

  void _checkSyncResponse(dynamic data) {
    if (data is! Map) throw const FormatException('同步接口返回格式无效');
    final code = data['errCode'] ?? data['errcode'];
    if (code != null && code.toString() != '0') {
      throw StateError('同步接口失败 (errcode: $code)');
    }
  }

  List<dynamic> _requiredList(dynamic data, String field) {
    final value = data[field];
    if (value is! List) throw FormatException('同步响应缺少有效的 $field 列表');
    return value;
  }

  int _integer(dynamic value, {int fallback = 0}) {
    if (value == null) return fallback;
    if (value is num && value.isFinite) return value.toInt();
    throw const FormatException('数值字段类型无效');
  }

  String _text(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    throw const FormatException('文本字段类型无效');
  }

  String _id(dynamic value) {
    if (value == null) return '';
    if (value is String || value is int) return value.toString();
    throw const FormatException('ID 字段类型无效');
  }

  void _invalidRow(String kind, Object error) => debugPrint('同步跳过无效$kind：$error');

  /// 书架同步 — GET /web/shelf/sync
  Future<List<Book>> fetchBookshelf() async {
    try {
      final reusable = !_cancelled && _database?.isActive == true &&
          _database?.accountId == config.credentials?.vid &&
          _credentialKey != null && _credentialKey == _snapshotCredential &&
          _snapshotTime != null && DateTime.now().difference(_snapshotTime!) < const Duration(seconds: 30);
      final snapshot = reusable ? _shelfSnapshot : null;
      _clearSnapshot();
      final data = snapshot ?? (await _dio.get('/shelf/sync')).data;

      _checkSyncResponse(data);

      final booksData = _requiredList(data, 'books');
      final progressData = data['bookProgress'] ?? [];

      // 构建 bookId -> progress 的映射
      final progressMap = <String, int>{};
      if (progressData is List) {
        for (final p in progressData) {
          try {
            if (p is! Map) throw const FormatException('阅读进度条目类型无效');
            final bookId = _id(p['bookId']);
            final progress = p['progress'] ?? 0;
            if (bookId.isEmpty) throw const FormatException('阅读进度缺少 bookId');
            progressMap[bookId] = _integer(progress);
          } on FormatException catch (e) {
            _invalidRow('阅读进度', e);
          }
        }
      }

      final books = <Book>[];
      for (final item in booksData) {
        try {
          if (item is! Map) throw const FormatException('书籍条目类型无效');

          final b = item.containsKey('bookId') && item.containsKey('title')
              ? item
              : (item['book'] ?? item);
          if (b is! Map) throw const FormatException('book 字段类型无效');

          final bookId = _id(b['bookId']);
          if (bookId.isEmpty) throw const FormatException('书籍缺少 bookId');

          final progress = progressMap[bookId] ?? (b['progress'] ?? 0);
          final progressInt = _integer(progress);

          // finished 语义修正：API 的 finished=1 表示「在书架上」，不是「读完了」
          // 实际判断是否读完用 progress >= 100
          final book = Book(
            bookId: bookId,
            title: _text(b['title']),
            author: _text(b['author']),
            cover: _text(b['cover']),
            progress: progressInt,
            finished: progressInt >= finishedProgress ? 1 : 0,
            category: _text(b['category']),
            updatedAt: _integer(
              b['updateTime'],
              fallback: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
          );

          books.add(book);
        } on FormatException catch (e) {
          _invalidRow('书籍', e);
        }
      }
      return books;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 302) {
        throw Exception('Cookie 已过期，请重新导入');
      }
      rethrow;
    }
  }

  /// 划线/书签 — GET /web/book/bookmarklist?bookId=xxx
  Future<List<Bookmark>> fetchBookmarks(String bookId, String bookTitle,
      {String synckey = '0', void Function(String?, List<String>)? onDelta}) async {
    try {
      final resp = await _dio.get(
        '/book/bookmarklist',
        queryParameters: {'bookId': bookId, 'synckey': synckey},
      );
      final data = resp.data;
      _checkSyncResponse(data);

      // 构建 chapterUid -> chapterTitle 映射
      final chMap = <int, String>{};
      var invalidRows = false;
      final chapters = data['chapters'] ?? [];
      if (chapters is List) {
        for (final c in chapters) {
          try {
            if (c is! Map) throw const FormatException('章节条目类型无效');
            final uid = _integer(c['chapterUid']);
            final title = _text(c['title']);
            if (uid != 0) chMap[uid] = title;
          } on FormatException catch (e) {
            invalidRows = true;
            _invalidRow('章节', e);
          }
        }
      }

      final updated = _requiredList(data, 'updated');

      final bookmarks = <Bookmark>[];
      for (final item in updated) {
        try {
          if (item is! Map) throw const FormatException('划线条目类型无效');

          final bmId = _id(item['bookmarkId']);
          if (bmId.isEmpty) throw const FormatException('划线缺少 bookmarkId');

          final chapterUid = _integer(item['chapterUid']);
          final chapterTitle = chMap[chapterUid] ?? _text(item['chapterName']);

          final bookmark = Bookmark(
            bookmarkId: bmId,
            bookId: bookId,
            bookTitle: bookTitle,
            markText: _text(item['markText']),
            chapterTitle: chapterTitle,
            createdAt: _integer(
              item['createTime'],
              fallback: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
          );

          bookmarks.add(bookmark);
        } on FormatException catch (e) {
          invalidRows = true;
          _invalidRow('划线', e);
        }
      }
      _checkDeltaRows(data, invalidRows);
      onDelta?.call(data['synckey']?.toString(), _deletedIds(data, 'bookmarkId'));
      return bookmarks;
    } on DioException {
      rethrow;
    }
  }

  /// 笔记/想法 — GET /web/review/list?bookId=xxx&listType=11&mine=1&synckey=0
  Future<List<Map<String, dynamic>>> fetchNotes(
    String bookId,
    String bookTitle,
    {String synckey = '0', void Function(String?, List<String>)? onDelta}
  ) async {
    try {
      final resp = await _dio.get('/review/list', queryParameters: {
        'bookId': bookId,
        'listType': '11',
        'mine': '1',
        'synckey': synckey,
      });
      final data = resp.data;
      _checkSyncResponse(data);
      final reviews = _requiredList(data, 'reviews');

      final notes = <Map<String, dynamic>>[];
      var invalidRows = false;
      for (final item in reviews) {
        try {
          if (item is! Map) throw const FormatException('笔记条目类型无效');

          final rv = item['review'] ?? item;
          if (rv is! Map) throw const FormatException('review 字段类型无效');

          final reviewId = _id(rv['reviewId']);
          if (reviewId.isEmpty) throw const FormatException('笔记缺少 reviewId');

          final note = {
            'note_id': reviewId,
            'book_id': bookId,
            'book_title': bookTitle,
            'content': _text(rv['content']),
            'chapter_title': _text(rv['chapterName']),
            'created_at': _integer(
              rv['createTime'],
              fallback: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
            'is_fav': 0,
          };
          notes.add(note);
        } on FormatException catch (e) {
          invalidRows = true;
          _invalidRow('笔记', e);
        }
      }
      _checkDeltaRows(data, invalidRows);
      onDelta?.call(data['synckey']?.toString(), _deletedIds(data, 'reviewId'));
      return notes;
    } on DioException {
      rethrow;
    }
  }

  void _checkDeltaRows(dynamic data, bool invalidRows) {
    if (invalidRows && data['synckey'] != null) {
      throw const FormatException('增量响应包含无效条目，未提交数据或推进同步游标，请重试');
    }
  }

  List<String> _deletedIds(dynamic data, String field) {
    final deleted = data['deleted'] ?? data['removed'] ?? [];
    if (deleted is! List) throw const FormatException('删除记录格式无效');
    return deleted.map((row) => _id(row is Map ? row[field] : row))
        .where((id) => id.isNotEmpty).toList();
  }
}
