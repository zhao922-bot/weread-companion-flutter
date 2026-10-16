import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/export_service.dart';
import 'package:weread_companion/services/export_snapshot.dart';
import 'support/observed_database.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

final class _FileFaults extends IOOverrides {
  final nativeZone = Zone.current;
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      nativeZone
          .run(() => FileSystemEntity.type(path, followLinks: followLinks));
  Future<void> Function(String path)? beforeRename;
  Future<void> Function(String path)? afterRename;
  Future<void> Function(String path)? beforeFileDelete;
  Future<void> Function(String path)? beforeDirectoryDelete;
  Future<void> Function()? afterWriterClose;
  Future<void> Function()? beforeFlush;
  Future<void> Function(String prefix)? afterCreateTemp;
  final publications = <String>[];
  @override
  File createFile(String path) => path.endsWith('.md')
      ? _FaultFile(super.createFile(path), this)
      : super.createFile(path);
  @override
  Directory createDirectory(String path) =>
      _FaultDirectory(super.createDirectory(path), this);
}

class _FaultFile implements File {
  _FaultFile(this.delegate, this.faults);
  final File delegate;
  final _FileFaults faults;
  @override
  String get path => delegate.path;
  @override
  IOSink openWrite(
          {FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _FaultSink(delegate.openWrite(mode: mode, encoding: encoding), faults);
  @override
  Future<File> rename(String target) async {
    await faults.beforeRename?.call(target);
    final result = await delegate.rename(target);
    faults.publications.add(target);
    await faults.afterRename?.call(target);
    return result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await faults.beforeFileDelete?.call(path);
    return delegate.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultDirectory implements Directory {
  _FaultDirectory(this.delegate, this.faults);
  final Directory delegate;
  final _FileFaults faults;
  @override
  String get path => delegate.path;
  @override
  Directory get absolute => faults.createDirectory(p.absolute(path));
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<Directory> createTemp([String? prefix]) async {
    final result =
        await faults.nativeZone.run(() => delegate.createTemp(prefix));
    await faults.afterCreateTemp?.call(prefix ?? '');
    return _FaultDirectory(result, faults);
  }

  @override
  Stream<FileSystemEntity> list(
          {bool recursive = false, bool followLinks = true}) =>
      delegate
          .list(recursive: recursive, followLinks: followLinks)
          .map((entry) => entry is _FaultDirectory || entry is _FaultFile
              ? entry
              : entry is Directory
                  ? _FaultDirectory(entry, faults)
                  : entry is File
                      ? _FaultFile(entry, faults)
                      : entry);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await faults.beforeDirectoryDelete?.call(path);
    return delegate.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultSink implements IOSink {
  _FaultSink(this.delegate, this.faults);
  final IOSink delegate;
  final _FileFaults faults;
  @override
  void write(Object? object) => delegate.write(object);
  @override
  Future<void> flush() async {
    await faults.beforeFlush?.call();
    await delegate.flush();
  }

  @override
  Future<void> get done => delegate.done;
  @override
  Future<void> close() async {
    await delegate.close();
    await faults.afterWriterClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory directory;
  late DatabaseService db;
  late PathProviderPlatform originalPaths;
  late _FileFaults faults;
  var shares = 0;
  Future<void> seed() => db.insertNote({
        'note_id': 'n',
        'book_id': 'b',
        'book_title': '测试书',
        'content': '完整导出内容',
        'created_at': 1
      });
  Future<List<FileSystemEntity>> outputs() =>
      directory.list().where((e) => e.path.endsWith('.md')).toList();
  Future<void> noStaging() async => expect(
      await directory
          .list()
          .where((e) => p.basename(e.path).startsWith('.weread-export-'))
          .toList(),
      isEmpty);
  Future<T> run<T>(Future<T> Function() body) =>
      IOOverrides.runWithIOOverrides(body, faults);
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('weread-publication-');
    await databaseFactory.setDatabasesPath(directory.path);
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await seed();
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    faults = _FileFaults();
    shares = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      shares++;
      return null;
    });
  });
  tearDown(() async {
    await DatabaseService.endSession();
    await ExportService.clearLocalExports();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final filtered in [false, true]) {
    test('${filtered ? '指定书籍无记录' : '数据库为空'}时不导出或分享，恢复数据后可重试', () async {
      if (!filtered) await (await db.database).delete('notes');
      await expectLater(
          run(() => ExportService.exportAndShare(
              bookId: filtered ? 'missing' : null)),
          throwsA(predicate((e) => e.toString().contains('暂无数据可导出'))));
      expect(shares, 0);
      expect(await outputs(), isEmpty);
      await noStaging();
      expect(
          (await (await db.database).rawQuery('PRAGMA database_list'))
              .where((r) => r['name'] == 'weread_export_snapshot'),
          isEmpty);
      if (!filtered) await seed();
      final file = await run(() => ExportService.exportToMarkdown(bookId: 'b'));
      expect(await File(file).readAsString(), contains('完整导出内容'));
      await noStaging();
    });
  }

  for (final phase in ['rename', 'cleanup']) {
    test('$phase 失败不遗留本次发布文件，并保留之前成功的导出', () async {
      final previous = await ExportService.exportToMarkdown();
      if (phase == 'rename') {
        faults.afterRename =
            (_) async => throw const FileSystemException('publication failed');
      } else {
        faults.beforeDirectoryDelete = (path) async {
          if (p.basename(path).startsWith('.weread-export-snapshot-')) {
            throw FileSystemException('cleanup failed', path);
          }
        };
      }
      await expectLater(run(ExportService.exportToMarkdown),
          throwsA(isA<FileSystemException>()));
      expect((await outputs()).map((f) => p.normalize(f.path)),
          [p.normalize(previous)]);
      faults.afterRename = null;
      faults.beforeDirectoryDelete = null;
      await run(ExportService.clearLocalExports);
      final retried = await run(ExportService.exportToMarkdown);
      expect(await File(retried).readAsString(), contains('完整导出内容'));
      expect(await outputs(), hasLength(1));
      await noStaging();
    });
  }

  for (final share in [false, true]) {
    for (final phase in ['rename_before', 'rename_after', 'cleanup']) {
      test('$phase 期间取消（分享=$share）不返回成功、不分享旧内容并删除发布文件', () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        Future<void> hold(String _) async {
          entered.complete();
          await release.future;
        }

        if (phase == 'rename_before') faults.beforeRename = hold;
        if (phase == 'rename_after') faults.afterRename = hold;
        if (phase == 'cleanup') {
          faults.beforeDirectoryDelete = (path) async {
            if (p.basename(path).startsWith('.weread-export-snapshot-')) {
              await hold(path);
            }
          };
        }
        final failed = expectLater(
            run(() => share
                ? ExportService.exportAndShare()
                : ExportService.exportToMarkdown()),
            throwsStateError);
        await entered.future;
        await DatabaseService.endSession();
        release.complete();
        await failed;
        expect(await outputs(), isEmpty);
        expect(shares, 0);
        await noStaging();
      });
    }
  }

  for (final phase in ['flush', 'close']) {
    test('$phase 失败后不发布文件，立即重试可恢复', () async {
      Future<void> fail() async => throw FileSystemException('$phase failed');
      if (phase == 'flush') faults.beforeFlush = fail;
      if (phase == 'close') faults.afterWriterClose = fail;
      await expectLater(run(ExportService.exportToMarkdown),
          throwsA(isA<FileSystemException>()));
      expect(faults.publications, isEmpty);
      expect(await outputs(), isEmpty);
      faults.beforeFlush = null;
      faults.afterWriterClose = null;
      expect(await File(await run(ExportService.exportToMarkdown)).exists(),
          isTrue);
      await noStaging();
    });
  }

  test('写入和关闭同时失败保留写入错误', () async {
    faults.beforeFlush =
        () async => throw const FileSystemException('primary write failure');
    faults.afterWriterClose =
        () async => throw const FileSystemException('secondary close failure');
    await expectLater(
        run(ExportService.exportToMarkdown),
        throwsA(
            predicate((e) => e.toString().contains('primary write failure'))));
    expect(await outputs(), isEmpty);
    await noStaging();
  });

  test('空快照和临时目录删除同时失败保留无数据提示，之后清理可恢复', () async {
    await (await db.database).delete('notes');
    faults.beforeDirectoryDelete =
        (_) async => throw const FileSystemException('cleanup failure');
    await expectLater(run(ExportService.exportToMarkdown),
        throwsA(predicate((e) => e.toString().contains('暂无数据可导出'))));
    expect(await outputs(), isEmpty);
    faults.beforeDirectoryDelete = null;
    await run(ExportService.clearLocalExports);
    await noStaging();
    await seed();
    expect(
        await File(await run(ExportService.exportToMarkdown)).exists(), isTrue);
  });

  for (final phase in ['rename', 'cleanup']) {
    test('$phase 期间退出并发清理，任务结束和重试均不遗留文件', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      Future<void> hold(String _) async {
        entered.complete();
        await release.future;
      }

      if (phase == 'rename') faults.afterRename = hold;
      if (phase == 'cleanup') {
        faults.beforeDirectoryDelete = (path) async {
          if (p.basename(path).startsWith('.weread-export-snapshot-')) {
            await hold(path);
          }
        };
      }
      final failed =
          expectLater(run(ExportService.exportAndShare), throwsStateError);
      await entered.future;
      await DatabaseService.endSession();
      faults.afterRename = null;
      faults.beforeDirectoryDelete = null;
      await run(ExportService.clearLocalExports);
      release.complete();
      await failed;
      expect(shares, 0);
      expect(await outputs(), isEmpty);
      await noStaging();
      await DatabaseService.selectAccount('123');
      await run(ExportService.exportAndShare);
      expect(shares, 1);
      expect(await outputs(), hasLength(1));
      await noStaging();
    });
  }

  test('发布和清理同时失败保留发布错误，随后清理和重试可恢复', () async {
    faults.beforeRename =
        (_) async => throw const FileSystemException('primary rename error');
    faults.beforeDirectoryDelete =
        (_) async => throw const FileSystemException('secondary cleanup error');
    await expectLater(
        run(ExportService.exportToMarkdown),
        throwsA(
            predicate((e) => e.toString().contains('primary rename error'))));
    faults.beforeRename = null;
    faults.beforeDirectoryDelete = null;
    await run(ExportService.clearLocalExports);
    await noStaging();
    expect(
        await File(await run(ExportService.exportToMarkdown)).exists(), isTrue);
  });

  test('文件已发布后取消且删除失败，恢复后清理仍能删除遗留文件', () async {
    faults.afterRename = (_) => DatabaseService.endSession();
    faults.beforeFileDelete =
        (path) async => throw FileSystemException('delete blocked', path);
    await expectLater(run(ExportService.exportToMarkdown), throwsStateError);
    expect(await outputs(), hasLength(1));
    faults.beforeFileDelete = null;
    await run(ExportService.clearLocalExports);
    expect(await outputs(), isEmpty);
    await noStaging();
  });

  test('关闭写入流期间取消不尝试发布文件', () async {
    faults.afterWriterClose = DatabaseService.endSession;
    await expectLater(run(ExportService.exportToMarkdown), throwsStateError);
    expect(faults.publications, isEmpty);
    expect(await outputs(), isEmpty);
    await noStaging();
  });

  for (final phase in ['暂存目录创建后', '批次刷新后', '最终刷新后']) {
    test('$phase账号退出，关闭文件并清理快照且可重新导出', () async {
      if (phase == '暂存目录创建后') {
        faults.afterCreateTemp = (prefix) async {
          if (prefix == '.weread-export-') await DatabaseService.endSession();
        };
      } else {
        var flushes = 0;
        faults.beforeFlush = () async {
          flushes++;
          if (flushes == (phase == '批次刷新后' ? 1 : 2)) {
            await DatabaseService.endSession();
          }
        };
      }
      await expectLater(run(ExportService.exportAndShare), throwsStateError);
      expect(shares, 0);
      expect(faults.publications, isEmpty);
      expect(await outputs(), isEmpty);
      await noStaging();
      faults.afterCreateTemp = null;
      faults.beforeFlush = null;
      db = await DatabaseService.selectAccount('123');
      await run(ExportService.exportAndShare);
      expect(shares, 1);
    });
  }

  for (final phase in ['快照事务', '分离快照']) {
    test('$phase期间账号结束，快照不返回成功并释放附加数据库', () async {
      await DatabaseService.endSession();
      final probe = DatabaseProbe();
      databaseFactory = ObservedFactory(databaseFactoryFfiNoIsolate, probe);
      addTearDown(() => databaseFactory = databaseFactoryFfiNoIsolate);
      db = await DatabaseService.selectAccount('123');
      await db.database;
      Future<void>? closing;
      void cancelAt(String sql) {
        if (sql.contains(phase == '快照事务'
            ? 'CREATE TABLE weread_export_snapshot.entries'
            : 'DETACH DATABASE')) {
          closing ??= DatabaseService.endSession();
        }
      }

      if (phase == '快照事务') {
        probe.afterExecute = cancelAt;
      } else {
        probe.beforeExecute = cancelAt;
      }
      await expectLater(
          ExportSnapshot.capture(db, '${directory.path}/interrupted.db'),
          throwsStateError);
      await closing;
      expect(closing, isNotNull);
      probe.beforeExecute = null;
      probe.afterExecute = null;
      db = await DatabaseService.selectAccount('123');
      expect(await db.getAllNotes(), hasLength(1));
      final snapshot =
          await ExportSnapshot.capture(db, '${directory.path}/retried.db');
      expect((await snapshot.readPage()).single['content'], '完整导出内容');
      await snapshot.close();
      expect(
          (await (await db.database).rawQuery('PRAGMA database_list'))
              .where((r) => r['name'] == 'weread_export_snapshot'),
          isEmpty);
    });
  }
}
