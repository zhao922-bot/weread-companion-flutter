import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/providers/bookshelf_provider.dart';
import 'package:weread_companion/providers/notes_provider.dart';
import 'package:weread_companion/services/ai_service.dart';
import 'package:weread_companion/services/api.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/qr_login_service.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse, initial;
import 'support/observed_database.dart';
import 'support/wait_until.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _OpeningFactory extends ObservedFactory {
  _OpeningFactory(super.delegate, super.probe);
  Future<void> Function()? beforeOpen;
  Future<void> Function()? afterOpen;
  final connections = <Database>[];
  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    await beforeOpen?.call();
    final db = await super.openDatabase(path, options: options);
    connections.add(db);
    await afterOpen?.call();
    return db;
  }
}

class _StageConfig extends AppConfig {
  _StageConfig({super.cookie, super.credentials});
  Future<void> Function()? onTrustedLoad;
  Future<void> Function()? onLoad;
  Future<void> Function()? onTrust;
  Future<void> Function()? onClear;
  Future<void> Function()? onPersist;
  Future<void> Function()? onSave;
  @override
  Future<void> save() async {
    await super.save();
    await onSave?.call();
  }

  @override
  Future<void> loadTrustedAccount() async {
    await super.loadTrustedAccount();
    await onTrustedLoad?.call();
  }

  @override
  Future<void> load() async {
    await super.load();
    await onLoad?.call();
  }

  @override
  Future<void> trustAccount(String id) async {
    await super.trustAccount(id);
    await onTrust?.call();
  }

  @override
  Future<void> clear() async {
    await onClear?.call();
    await super.clear();
  }

  @override
  Future<void> persistCredentials(Credentials next) async {
    await onPersist?.call();
    await super.persistCredentials(next);
  }
}

// Model an external transport that finishes despite cancellation, so the
// service's own cancellation boundary is checked independently of Dio's.
class _LateResponseDio implements Dio {
  @override
  Future<Response<T>> post<T>(String path,
      {Object? data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      ProgressCallback? onSendProgress,
      ProgressCallback? onReceiveProgress}) async {
    AIService.cancelAll();
    return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'choices': [
            {
              'message': {'content': '迟到响应'}
            }
          ],
        } as T);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseService db;
  late DatabaseProbe probe;
  late PathProviderPlatform originalPaths;
  final secrets = <String, String>{};
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() async {
    sqfliteFfiInit();
    directory =
        await Directory.systemTemp.createTemp('weread-services-coverage-');
    await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
    probe = DatabaseProbe();
    databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    secrets.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return secrets[key];
      if (call.method == 'write') secrets[key] = args['value'] as String;
      if (call.method == 'delete') secrets.remove(key);
      return null;
    });
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
  });
  tearDown(() async {
    probe.afterRead = null;
    probe.beforeCommit = null;
    WeReadApi.reset();
    await DatabaseService.endSession();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
  });

  test('会话守卫拒绝关闭和切换后的数据库，当前账号仍可用', () async {
    db.requireActive();
    await db.close();
    expect(db.requireActive, throwsStateError);
    final next = await DatabaseService.selectAccount('456');
    expect(db.requireActive, throwsStateError);
    next.requireActive();
    await DatabaseService.endSession();
    expect(next.requireActive, throwsStateError);
  });

  test('数据库直接关闭后 AI 立即取消且不发送请求', () async {
    await db.close();
    final service = AIService(config: AppConfig());
    await expectLater(service.summarizeBook('书', '作者', []),
        throwsA(isA<AICancelledException>()));
  });
  WeReadApi api(Object data, {int status = 200, AppConfig? config}) =>
      WeReadApi.forLogin(
          config: config ?? AppConfig(cookie: 'wr_vid=123'),
          dio: Dio()
            ..httpClientAdapter =
                AuthAdapter((_) => jsonResponse(data, status)));
  Map<String, dynamic> bookmark(String id,
          {String book = 'b', bool favorite = false}) =>
      {
        'bookmark_id': id,
        'book_id': book,
        'book_title': '测试书',
        'mark_text': '含100%_\\的引文',
        'created_at': 1,
        'is_fav': favorite ? 1 : 0,
      };

  test('数据库单项兼容入口保留收藏并正确按书籍与转义文本筛选', () async {
    await db
        .insertOrUpdateBook({'book_id': 'b', 'title': '旧书', 'updated_at': 1});
    await db.updateBook({'book_id': 'b', 'title': '新书'});
    expect((await db.getBook('b'))!['title'], '新书');
    await db.insertBookmark(bookmark('one', favorite: true));
    await db.insertBookmark(bookmark('two', book: 'other'));
    await db.insertBookmarkPreserveFav(
        {...bookmark('one'), 'mark_text': '更新100%_\\'});
    expect((await db.getBookmarksByBook('b')).single['is_fav'], 1);
    expect(await db.searchBookmarks('100%_\\', limit: 1), hasLength(1));
    expect(await db.searchBookmarks('不存在'), isEmpty);
    await db.insertNotes([
      {
        'note_id': 'n1',
        'book_id': 'b',
        'content': '收藏',
        'is_fav': 1,
        'created_at': 2
      },
      {'note_id': 'n2', 'book_id': 'other', 'content': '未收藏', 'created_at': 1},
    ]);
    expect((await db.getAllNotes(bookId: 'b')).single['note_id'], 'n1');
    expect((await db.getFavoriteNotes()).single['note_id'], 'n1');
    expect(await db.getAllFavorites(), hasLength(2));
    expect(await db.getReportStats(), contains('monthly'));
  });

  test('版本1数据库升级补收藏与章节表，不丢失旧划线', () async {
    final legacy = await openDatabase(
        '${directory.path}/weread_companion_account_123.db',
        version: 1, onCreate: (connection, _) async {
      await connection
          .execute('CREATE TABLE books (book_id TEXT PRIMARY KEY, title TEXT)');
      await connection.execute(
          'CREATE TABLE bookmarks (bookmark_id TEXT PRIMARY KEY, book_id TEXT, '
          'book_title TEXT, mark_text TEXT, chapter_title TEXT, created_at INTEGER)');
      await connection.insert('bookmarks', {
        'bookmark_id': 'old',
        'book_id': 'b',
        'mark_text': '旧划线',
        'created_at': 1
      });
    });
    await legacy.close();
    final rows = await db.getBookmarksByBook('b');
    expect(rows.single['mark_text'], '旧划线');
    expect(rows.single['is_fav'], 0);
    expect(await (await db.database).query('chapters'), isEmpty);
  });

  test('已取消账号选择不替换当前账号', () async {
    await expectLater(
        DatabaseService.selectAccount('456', isCancelled: () => true),
        throwsStateError);
    expect(DatabaseService.instance, same(db));
  });

  test('清空Cookie会删除旧安全存储，非法可信账号拒绝写入', () async {
    final config = AppConfig(cookie: 'wr_vid=123', apiKey: 'key');
    await config.save();
    config.cookie = '';
    await config.save();
    expect(secrets['weread_cookie'], isNull);
    for (final id in ['0', '', '../other', 'abc']) {
      await expectLater(config.trustAccount(id), throwsArgumentError);
    }
    expect(config.toJson(), containsPair('apiKey', 'key'));
  });

  test('已提交AI配置含不安全URL时恢复为不可用配置', () async {
    secrets['weread_ai_config'] = jsonEncode({
      'apiKey': 'key',
      'baseUrl': 'http://insecure.test',
      'modelName': 'model'
    });
    final config = AppConfig();
    await config.load();
    expect(config.baseUrl, isEmpty);
    expect(AIService(config: config).isConfigured, isFalse);
  });

  for (final input in ['[1]', 'weread.qq.com\ttoo\tfew']) {
    test('拒绝结构非法的Cookie输入 $input', () {
      expect(() => WeReadApi.normalizeCookie(input), throwsFormatException);
    });
  }
  for (final domain in ['.qq.com', 'qq.com']) {
    test('Netscape格式兼容父域 $domain', () {
      expect(
          WeReadApi.normalizeCookie('$domain\tTRUE\t/\tTRUE\t0\twr_vid\t123'),
          'wr_vid=123');
    });
  }
  for (final status in [401, 403]) {
    test(
        'Cookie验证HTTP$status返回未登录',
        () async =>
            expect(await api({}, status: status).checkLogin(), isFalse));
  }
  test('书架HTTP401提示重新导入Cookie', () async {
    await expectLater(api({}, status: 401).fetchBookshelf(),
        throwsA(predicate((e) => e.toString().contains('Cookie 已过期'))));
  });
  test('同步顶层不是对象拒绝处理', () async {
    await expectLater(api([]).fetchBookshelf(), throwsFormatException);
  });
  test('书架无效进度与空书籍ID不污染有效书籍', () async {
    final books = await api({
      'books': [
        {'bookId': '', 'title': '无效'},
        {'bookId': 'b', 'title': '有效'}
      ],
      'bookProgress': [
        null,
        {'bookId': '', 'progress': 90},
        {'bookId': 'b', 'progress': 50}
      ]
    }).fetchBookshelf();
    expect(books.single.title, '有效');
    expect(books.single.progress, 50);
  });
  test('章节不是对象时增量拒绝推进游标', () async {
    var delta = false;
    await expectLater(
        api({
          'chapters': [null],
          'updated': [],
          'synckey': '2'
        }).fetchBookmarks('b', '书', onDelta: (_, __) => delta = true),
        throwsFormatException);
    expect(delta, isFalse);
  });
  for (final deleted in [null, {}, 'bad']) {
    test('删除列表类型错误 $deleted 不提交增量', () async {
      await expectLater(
          api({'reviews': [], 'deleted': deleted}).fetchNotes('b', '书'),
          throwsFormatException);
    });
  }
  for (final data in [
    [],
    {'books': 'bad'},
    {'books': [], 'errcode': 9}
  ]) {
    test('移动端验证畸形响应 $data 不接受为登录成功', () async {
      await expectLater(
          api(data, config: AppConfig(credentials: initial)).checkLogin(),
          throwsStateError);
    });
  }
  for (final data in [
    [],
    {'errcode': 9},
    {'accessToken': 42}
  ]) {
    test('刷新接口无效响应 $data 保留原凭据', () async {
      final config = AppConfig(credentials: initial);
      final client = WeReadApi.forLogin(
          config: config,
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((request) => jsonResponse(
                request.path == '/login' ? data : {'errcode': -2012})));
      await expectLater(client.checkLogin(), throwsA(anything));
      expect(config.credentials, same(initial));
    });
  }
  test('当前同步入口使用初始化的会话，失效数据库拒绝初始化', () async {
    final client = await WeReadApi.init(
        config: AppConfig(cookie: 'wr_vid=123'),
        db: db,
        dio: Dio()
          ..httpClientAdapter =
              AuthAdapter((_) => jsonResponse({'books': []})));
    expect(WeReadApi.instance, same(client));
    expect((await SyncService.current().syncAll()).failureCount, 0);
    await DatabaseService.endSession();
    await expectLater(
        WeReadApi.init(config: AppConfig(), db: db), throwsStateError);
  });

  for (final name in ['Alice%20Chen', '%GG', '%FF']) {
    test('Cookie昵称 $name 可解码或安全回退', () async {
      final config = AppConfig(cookie: 'wr_vid=123; wr_name=$name');
      await config.save();
      final provider = AppConfigProvider(
          config: config,
          loginApi: (config) => api({'vid': 123}, config: config));
      addTearDown(provider.dispose);
      await provider.init();
      expect(provider.userName, name == 'Alice%20Chen' ? 'Alice Chen' : '微信用户');
      expect(provider.cookie, contains('wr_vid=123'));
      expect(provider.loginStatusText, '验证成功');
    });
  }
  test('Provider已释放的读取入口不通知，重复筛选不额外查询', () async {
    final shelf = BookshelfProvider();
    shelf.resetSession(1);
    shelf.resetSession(1);
    shelf.dispose();
    await shelf.setActive(true);
    await shelf.loadBooks();
    final notes = NotesProvider();
    notes.resetSession(1);
    notes.resetSession(1);
    notes.setSearch('');
    notes.setFilter(ReadingFilter.all);
    notes.dispose();
    await notes.setActive(true);
    await notes.loadNotes();
    expect(probe.reads, isEmpty);
  });
  test('统计刷新失败反馈错误，下一次通知恢复', () async {
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await notes.loadNotes();
    probe.afterRead = (sql) {
      if (sql.contains('COUNT')) throw StateError('统计失败');
    };
    SyncService.changes.publish(db, kind: SyncChangeKind.bookshelf);
    await waitUntil(() => notes.error != null);
    expect(notes.error, contains('统计失败'));
    probe.afterRead = null;
    await notes.loadNotes();
    expect(notes.error, isNull);
  });
  test('局部收藏读取失败反馈，后续完整刷新恢复', () async {
    await db.insertBookmark(bookmark('one'));
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await notes.loadNotes();
    probe.afterRead = (sql) {
      if (sql.contains('WHERE id = ?')) throw StateError('收藏读取失败');
    };
    SyncService.changes.publish(db,
        favoritesOnly: true, itemIds: {'bookmark:one'}, sources: {'bookmark'});
    await waitUntil(() => notes.error != null);
    expect(notes.error, contains('收藏读取失败'));
    probe.afterRead = null;
    await notes.loadNotes();
    expect(notes.error, isNull);
  });
  test('收藏写入期间重复操作仅写一次，划线收藏持久化', () async {
    await db.insertBookmark(bookmark('one'));
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await notes.loadNotes();
    final entered = Completer<void>();
    final release = Completer<void>();
    var writes = 0;
    probe.afterUpdate = (_) async {
      writes++;
      entered.complete();
      await release.future;
    };
    final item = notes.notes.single;
    final first = notes.toggleFavorite(item);
    await entered.future;
    await notes.toggleFavorite(item);
    release.complete();
    await first;
    expect(writes, 1);
    expect(item.isFav, isTrue);
    expect((await db.getBookmarksByBook('b')).single['is_fav'], 1);
  });
  test('批量读取期间销毁Provider拒绝返回过期数据', () async {
    final notes = NotesProvider();
    final entered = Completer<void>();
    final release = Completer<void>();
    probe.afterRead = (sql) async {
      if (sql.contains('UNION ALL')) {
        entered.complete();
        await release.future;
      }
    };
    final result = notes.getAllMatchingNotes();
    final assertion = expectLater(result, throwsStateError);
    await entered.future;
    notes.dispose();
    release.complete();
    await assertion;
  });

  test('扫码错误保留服务端诊断信息', () {
    expect(const QrLoginException('二维码过期', expired: true).toString(), '二维码过期');
  });

  for (final outcome in ['写入失败', '提交后退出', '提交后退出并失败']) {
    test('摘要保存$outcome返回正确错误且不报告成功', () async {
      await db.database;
      final service = AIService(
          config: AppConfig(apiKey: 'test'),
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((_) => jsonResponse({
                  'choices': [
                    {
                      'message': {'content': '完整摘要'}
                    }
                  ],
                })));
      final note = NoteItem(
          id: 'n',
          bookId: 'b',
          bookTitle: '书',
          content: '原文',
          chapterTitle: '',
          createdAt: 1,
          isFav: false,
          source: NoteSource.note);
      if (outcome == '写入失败') {
        probe.beforeCommit = () => throw StateError('磁盘写入失败');
      } else {
        probe.afterCommit = () async {
          await DatabaseService.endSession();
          if (outcome.endsWith('并失败')) throw StateError('迟到写入错误');
        };
      }
      await expectLater(
          service.summarizeBook('书', '', [note]),
          throwsA(outcome == '写入失败'
              ? isA<AIServiceException>()
                  .having((e) => e.message, '原因', 'AI 摘要保存失败')
              : isA<AICancelledException>()));
      if (outcome == '写入失败') expect(await db.getSummaries(), isEmpty);
    });
  }

  test('同步入口拒绝尚未完成的退出清理', () async {
    final config = AppConfig(cookie: 'wr_vid=123')..logoutPending = true;
    await expectLater(SyncService.connect(config: config), throwsStateError);
  });

  test('Provider拒绝缺失账号和不合法移动凭据，AI地址校验不写入', () async {
    final config = AppConfig(cookie: 'wr_skey=test');
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    expect(await provider.verifyForSync(), isFalse);
    expect(provider.loginError, contains('wr_vid'));
    expect(provider.loginStatusText, '凭据失效 · 请重新登录');
    await expectLater(
        provider.loginWithCookie('wr_skey=test'), throwsFormatException);
    await expectLater(
        provider.loginWithCredentials(const Credentials(
          vid: '0',
          accessToken: 'a',
          refreshToken: 'r',
          deviceId: 'd',
        )),
        throwsFormatException);
    await config.save();
    await provider.init();
    await expectLater(provider.updateAiConfig(baseUrl: 'http://insecure.test'),
        throwsFormatException);
    config.credentialsInvalid.value = true;
    config.credentialsInvalid.value = false;
    expect(provider.loginStatusText, '凭据失效 · 请重新登录');
  });

  test('未验证保存状态与已释放入口可安全读取', () async {
    final config = AppConfig(cookie: 'wr_vid=123');
    final provider = AppConfigProvider(
        config: config,
        loginApi: (config) => api({}, status: 500, config: config));
    expect(await provider.verifyForSync(), isFalse);
    expect(provider.loginStatusText, '已保存凭据');
    provider.dispose();
    await provider.init();
    expect(await provider.verifyForSync(), isFalse);
  });

  test('请求队列中凭据降级后阻止请求到达服务端', () async {
    final config = AppConfig(credentials: initial);
    var calls = 0;
    final client = WeReadApi.forLogin(
        config: config,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((_) {
            calls++;
            return jsonResponse({'books': []});
          }));
    config.credentialRevalidation.value = '需要重新验证';
    await expectLater(
        client.fetchBookshelf(),
        throwsA(isA<DioException>().having(
            (e) => e.error, '保存错误', isA<CredentialPersistenceException>())));
    expect(calls, 0);
  });

  test('HTTP401触发刷新后普通异常也保留原始原因', () async {
    final config = AppConfig(credentials: initial);
    final client = WeReadApi.forLogin(
        config: config,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((request) =>
              request.path == '/login'
                  ? jsonResponse({'errcode': 7})
                  : jsonResponse({}, 401)));
    await expectLater(
        client.checkLogin(),
        throwsA(isA<DioException>()
            .having((e) => e.error.toString(), '刷新原因', contains('刷新服务暂时不可用'))));
  });

  test('相同数据版本的收藏广播仍重载当前列表', () async {
    await db.insertBookmark(bookmark('one'));
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await notes.loadNotes();
    final reads = probe.reads.length;
    SyncService.changes.publish(db, favoritesOnly: true);
    await waitUntil(() => !notes.isLoading && probe.reads.length > reads);
    expect(notes.notes.single.id, 'one');
  });

  test('首屏读取期间本地收藏更新，过期列表重新读取而不覆盖新收藏', () async {
    await db.insertBookmark(bookmark('one'));
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await notes.loadNotes();
    final item = notes.notes.single;
    final entered = Completer<void>();
    final release = Completer<void>();
    var gated = false;
    probe.afterRead = (sql) async {
      if (!gated && sql.contains('AS reading_items')) {
        gated = true;
        entered.complete();
        await release.future;
      }
    };
    final reload = notes.loadNotes();
    await entered.future;
    await notes.toggleFavorite(item);
    release.complete();
    await reload;
    expect(notes.notes.single.isFav, isTrue);
    expect(notes.favCount, 1);
  });

  for (final fail in [false, true]) {
    test('数据库打开${fail ? '失败' : '成功'}与关闭并发时不泄漏连接', () async {
      final factory = _OpeningFactory(databaseFactoryFfiNoIsolate, probe);
      databaseFactory = factory;
      final entered = Completer<void>();
      final release = Completer<void>();
      Future<void> wait() async {
        entered.complete();
        await release.future;
      }

      if (fail) {
        factory.beforeOpen = () async {
          await wait();
          throw StateError('打开失败');
        };
      } else {
        factory.afterOpen = wait;
      }
      final opened = db.database;
      final assertion = expectLater(opened, throwsStateError);
      await entered.future;
      final closing = db.close();
      release.complete();
      await assertion;
      await closing;
      expect(factory.connections.every((connection) => !connection.isOpen),
          isTrue);
    });
  }

  test('AI传输忽略取消并返回成功时服务仍拒绝迟到内容', () async {
    final service =
        AIService(config: AppConfig(apiKey: 'key'), dio: _LateResponseDio());
    await expectLater(
        service.analyzeReading(['书'], 1), throwsA(isA<AICancelledException>()));
  });

  test('已经排队但尚未进入鉴权拦截器的请求在关闭后取消', () async {
    final dio = Dio();
    final entered = Completer<void>();
    final release = Completer<void>();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      entered.complete();
      await release.future;
      handler.next(request);
    }));
    var networkCalls = 0;
    dio.httpClientAdapter = AuthAdapter((_) {
      networkCalls++;
      return jsonResponse({'books': []});
    });
    final client =
        WeReadApi.forLogin(config: AppConfig(cookie: 'wr_vid=123'), dio: dio);
    final pending = client.fetchBookshelf();
    final assertion = expectLater(
        pending,
        throwsA(isA<DioException>()
            .having((e) => e.type, '取消', DioExceptionType.cancel)));
    await entered.future;
    client.dispose();
    release.complete();
    await assertion;
    expect(networkCalls, 0);
  });

  test('鉴权失败响应返回时凭据已降级，不再刷新或重放请求', () async {
    final config = AppConfig(credentials: initial);
    var calls = 0;
    final client = WeReadApi.forLogin(
        config: config,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((_) {
            calls++;
            config.credentialRevalidation.value = '保存失败';
            return jsonResponse({'errcode': -2012});
          }));
    await expectLater(
        client.fetchBookshelf(),
        throwsA(isA<DioException>().having(
            (e) => e.error, '原因', isA<CredentialPersistenceException>())));
    expect(calls, 1);
  });

  test('默认登录客户端网络失败保留可重试的保存状态', () async {
    // Flutter's test HTTP client returns 400; no external service is contacted.
    final provider = AppConfigProvider(config: AppConfig(cookie: 'wr_vid=123'));
    addTearDown(provider.dispose);
    expect(await provider.verifyForSync(), isFalse);
    expect(provider.loginStatus, LoginStatus.saved);
    expect(provider.loginError, contains('重试'));
  });

  test('退出清理失败展示待清理状态，恢复存储后可完成退出', () async {
    final config = _StageConfig()
      ..onClear = () async => throw StateError('存储故障');
    final provider = AppConfigProvider(config: config);
    addTearDown(provider.dispose);
    await expectLater(provider.logout(), throwsStateError);
    expect(provider.loginStatusText, '清理未完成');
    expect(provider.cleanupPending, isTrue);
    config.onClear = null;
    await provider.logout();
    expect(provider.loginStatusText, '未登录');
    expect(provider.cleanupPending, isFalse);
  });

  for (final stage in ['可信账号读取', '配置读取', '本地就绪通知']) {
    test('初始化在$stage期间销毁，阻止后续验证与通知', () async {
      final config = _StageConfig();
      if (stage == '本地就绪通知') await config.trustAccount('123');
      var requests = 0;
      final provider = AppConfigProvider(
          config: config,
          loginApi: (config) {
            requests++;
            return api({'vid': 123}, config: config);
          });
      if (stage == '可信账号读取') {
        config.onTrustedLoad = () async => provider.dispose();
      }
      if (stage == '配置读取') config.onLoad = () async => provider.dispose();
      if (stage == '本地就绪通知') {
        provider.addListener(() {
          if (provider.canBrowseLocal) scheduleMicrotask(provider.dispose);
        });
      }
      await provider.init();
      expect(requests, 0);
      expect(provider.isBusy, isFalse);
      expect(provider.isLoading, isFalse);
      expect(await provider.verifyForSync(), isFalse);
    });
  }

  test('配置对象销毁后登录与退出入口拒绝操作，不创建网络客户端', () async {
    var requests = 0;
    final provider = AppConfigProvider(
        config: AppConfig(cookie: 'wr_vid=123'),
        loginApi: (config) {
          requests++;
          return api({'vid': 123}, config: config);
        });
    provider.dispose();
    expect(await provider.verifyForSync(), isFalse);
    await expectLater(provider.loginWithCookie('wr_vid=123'), throwsStateError);
    expect(requests, 0);
    await expectLater(provider.logout(), throwsStateError);
  });

  test('验证期间明确凭据失效与网络错误同时返回，保留重新登录提示', () async {
    final config = AppConfig(cookie: 'wr_vid=123');
    final provider = AppConfigProvider(
        config: config,
        loginApi: (config) => WeReadApi.forLogin(
              config: config,
              dio: Dio()
                ..httpClientAdapter = AuthAdapter((_) {
                  config.credentialsInvalid.value = true;
                  return jsonResponse({}, 500);
                }),
            ));
    addTearDown(provider.dispose);
    expect(await provider.verifyForSync(), isFalse);
    expect(provider.loginStatus, LoginStatus.invalid);
    expect(provider.loginError, const LoginExpiredException().toString());
  });

  test('可信账号写入完成时数据库会话已关闭，验证不能发布成功', () async {
    final config = _StageConfig(cookie: 'wr_vid=123');
    config.onTrust = DatabaseService.endSession;
    final provider = AppConfigProvider(
        config: config,
        loginApi: (config) => api({'vid': 123}, config: config));
    addTearDown(provider.dispose);
    expect(await provider.verifyForSync(), isFalse);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.canBrowseLocal, isFalse);
    config.onTrust = null;
    expect(await provider.verifyForSync(), isTrue);
  });

  test('刷新令牌持久化重试退避期间退出，停止下一次写入', () async {
    final config = _StageConfig(credentials: initial);
    var writes = 0;
    late WeReadApi client;
    config.onPersist = () async {
      writes++;
      // Cancellation happens after the catch schedules its 50 ms retry.
      Timer(const Duration(milliseconds: 5), client.dispose);
      throw StateError('保存失败');
    };
    client = WeReadApi.forLogin(
        config: config,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((request) => jsonResponse(
              request.path == '/login'
                  ? {'accessToken': 'new-token'}
                  : {'errcode': -2012})));
    await expectLater(client.checkLogin(), throwsA(isA<DioException>()));
    expect(writes, 1);
    expect(config.credentials, same(initial));
    expect(config.pendingCredentials, isNull);
  });

  for (final phase in ['轮询开始前', '状态回调后']) {
    test('扫码$phase取消，不再发起轮询或等待', () async {
      var requests = 0;
      final service = QrLoginService(
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((_) {
              requests++;
              return jsonResponse({'wx_errcode': 408});
            }));
      addTearDown(service.dispose);
      final token = CancelToken();
      if (phase == '轮询开始前') token.cancel('关闭页面');
      await expectLater(
          service.pollForCode('uuid',
              cancelToken: token, onStatus: (_) => token.cancel('关闭页面')),
          throwsA(isA<DioException>()
              .having((e) => e.type, '取消', DioExceptionType.cancel)));
      expect(requests, phase == '轮询开始前' ? 0 : 1);
    });
  }

  for (final favorites in [false, true]) {
    test('收藏提交通知中隐藏，${favorites ? '收藏列表' : '全部列表'}停止附加刷新', () async {
      await db.insertBookmark(bookmark('one'));
      final notes = NotesProvider();
      await notes.loadNotes();
      final item = notes.notes.single;
      if (favorites) {
        notes.setFilter(ReadingFilter.favorites);
        await waitUntil(() => !notes.isLoading);
      }
      var changed = false;
      notes.addListener(() {
        if (item.isFav && !changed) {
          changed = true;
          notes.setActive(false);
        }
      });
      final reads = probe.reads.length;
      await notes.toggleFavorite(item);
      expect(changed, isTrue);
      expect(probe.reads.length, reads);
      expect((await db.getBookmarksByBook('b')).single['is_fav'], 1);
      await notes.setActive(true);
      expect(notes.notes.single.isFav, isTrue);
      expect(notes.favCount, 1);
      notes.dispose();
    });
  }

  test('收藏写入结束时 Provider 已销毁，不发布状态和跨页通知', () async {
    await db.insertBookmark(bookmark('one'));
    final notes = NotesProvider();
    await notes.loadNotes();
    final item = notes.notes.single;
    probe.afterUpdate = (_) => notes.dispose();
    var events = 0;
    void onChange() => events++;
    SyncService.changes.addListener(onChange);
    addTearDown(() => SyncService.changes.removeListener(onChange));
    await notes.toggleFavorite(item);
    expect(item.isFav, isFalse);
    expect(events, 0);
    expect((await db.getBookmarksByBook('b')).single['is_fav'], 1);
  });

  for (final phase in ['进度读取后', '索引事务开始后']) {
    test('搜索索引恢复$phase结束会话，取消回填且下次打开能续建', () async {
      await db.insertBookmark(bookmark('one'));
      final connection = await db.database;
      await connection
          .execute('CREATE TABLE search_index_backfill (pending INTEGER)');
      await connection.execute('DELETE FROM item_trigrams');
      await DatabaseService.endSession();
      db = await DatabaseService.selectAccount('123');
      Future<void>? closing;
      if (phase == '进度读取后') {
        probe.afterRead = (sql) {
          if (sql == 'search_index_progress' && closing == null) {
            closing = DatabaseService.endSession();
          }
        };
      } else {
        probe.onTransactionStart = () {
          closing ??= DatabaseService.endSession();
        };
      }
      await expectLater(db.database, throwsStateError);
      await closing;
      expect(closing, isNotNull);
      probe.afterRead = null;
      probe.onTransactionStart = null;
      db = await DatabaseService.selectAccount('123');
      expect(await db.searchBookmarks('100%_'), hasLength(1));
      final rows = await (await db.database).rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'search_index_backfill'");
      expect(rows, isEmpty);
    });
  }

  test('收藏局部刷新读取统计时切换筛选，丢弃旧统计与收藏快照', () async {
    await db.insertBookmark(bookmark('one'));
    final notes = NotesProvider();
    addTearDown(notes.dispose);
    await notes.loadNotes();
    final entered = Completer<void>();
    final release = Completer<void>();
    probe.afterRead = (sql) async {
      if (sql.contains('AS favoriteBookmarks') && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    SyncService.changes
        .publish(db, favoritesOnly: true, itemIds: {'bookmark:one'});
    await entered.future;
    notes.setFilter(ReadingFilter.notes);
    await waitUntil(() => !notes.isLoading);
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(notes.notes, isEmpty);
    expect(notes.matchedCount, 0);
    expect(notes.filter, ReadingFilter.notes);
  });

  test('书架 Provider 已销毁时同步入口拒绝请求，不通知已释放监听器', () async {
    final shelf = BookshelfProvider()..dispose();
    await expectLater(
        shelf.syncFromServer(config: AppConfig(cookie: 'wr_vid=123')),
        throwsStateError);
  });

  for (final transition in ['切换会话', '销毁']) {
    test('书架同步请求中$transition，迟到结果不能发布到新页面', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final config = AppConfig(cookie: 'wr_vid=123');
      await WeReadApi.init(
          config: config,
          db: db,
          dio: Dio()
            ..httpClientAdapter = AuthAdapter((_) async {
              entered.complete();
              await release.future;
              return jsonResponse({'books': []});
            }));
      final shelf = BookshelfProvider();
      final pending = shelf.syncFromServer(config: config);
      final assertion = expectLater(pending, throwsStateError);
      await entered.future;
      if (transition == '销毁') {
        shelf.dispose();
      } else {
        shelf.resetSession(7);
      }
      release.complete();
      await assertion;
      expect(shelf.lastSyncResult, isNull);
      expect(shelf.books, isEmpty);
      if (transition != '销毁') {
        expect(shelf.error, isNull);
        expect(shelf.isLoading, isFalse);
        shelf.dispose();
      }
    });
  }

  test('已恢复本地账号但联网验证失败，显示离线可浏览状态', () async {
    final config = AppConfig(cookie: 'wr_vid=123');
    await config.save();
    await config.trustAccount('123');
    final provider = AppConfigProvider(
        config: config,
        loginApi: (config) => api({}, status: 500, config: config));
    addTearDown(provider.dispose);
    await provider.init();
    expect(provider.canBrowseLocal, isTrue);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.loginStatusText, '本地数据可浏览 · 需要联网验证后同步');
  });

  test('登录凭据保存完成前配置对象释放，保留保存结果但不启动验证', () async {
    var calls = 0;
    final config = _StageConfig();
    final provider = AppConfigProvider(
        config: config,
        loginApi: (config) {
          calls++;
          return api({'vid': 123}, config: config);
        });
    config.onSave = () async => provider.dispose();
    await provider.loginWithCookie('wr_vid=123');
    expect(calls, 0);
    expect(provider.isBusy, isFalse);
    expect(provider.loginStatus, LoginStatus.saved);
    expect(config.cookie, 'wr_vid=123');
  });

  for (final favorites in [false, true]) {
    test('收藏广播的外部监听器销毁${favorites ? '收藏' : '全部'}列表，停止后续刷新', () async {
      await db.insertBookmark(bookmark('one'));
      final notes = NotesProvider();
      await notes.loadNotes();
      final item = notes.notes.single;
      if (favorites) {
        notes.setFilter(ReadingFilter.favorites);
        await waitUntil(() => !notes.isLoading);
      }
      void retire() => notes.dispose();
      SyncService.changes.addListener(retire);
      addTearDown(() => SyncService.changes.removeListener(retire));
      final reads = probe.reads.length;
      await notes.toggleFavorite(item);
      expect(probe.reads.length, reads);
      expect((await db.getBookmarksByBook('b')).single['is_fav'], 1);
    });
  }

  test('没有账号队列的同步实例取消后单书重试不执行数据请求', () async {
    var requests = 0;
    final service = SyncService(
        loadBooks: () async => [],
        loadBookmarks: (_) async {
          requests++;
          return 0;
        },
        loadNotes: (_) async {
          requests++;
          return 0;
        },
        isCancelled: () => false,
        onChanged: () {});
    service.cancel();
    await expectLater(service.retryBook(Book(bookId: 'b', title: '书')),
        throwsA(isA<SyncCancelledException>()));
    expect(requests, 0);
  });

  test('同步实例取消后兼容的直接书架加载入口不发送请求', () async {
    var requests = 0;
    final client = await WeReadApi.init(
        config: AppConfig(cookie: 'wr_vid=123'),
        db: db,
        dio: Dio()
          ..httpClientAdapter = AuthAdapter((_) {
            requests++;
            return jsonResponse({'books': []});
          }));
    final service = SyncService.forApi(client)..cancel();
    await expectLater(
        service.loadBooks(), throwsA(isA<SyncCancelledException>()));
    expect(requests, 0);
  });
}
