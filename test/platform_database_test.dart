import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/services/platform_database.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => databaseFactory = databaseFactoryFfiNoIsolate);
  test('Android keeps the existing database factory', () async {
    final original = databaseFactory;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await initializePlatformDatabase();
    expect(databaseFactory, same(original));
  });

  test('Windows persists SQLite in application support across connections',
      () async {
    final originalFactory = databaseFactory;
    final originalPaths = PathProviderPlatform.instance;
    final directory = await Directory.systemTemp.createTemp('weread-desktop-');
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      databaseFactory = originalFactory;
      PathProviderPlatform.instance = originalPaths;
      await directory.delete(recursive: true);
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    PathProviderPlatform.instance = _Paths(directory.path);
    await initializePlatformDatabase();
    expect(databaseFactory, same(databaseFactoryFfi));
    final databases = await getDatabasesPath();
    expect(databases, p.join(directory.path, 'databases'));
    final path = p.join(databases, 'persistence.db');
    final first = await openDatabase(path);
    try {
      await first.execute('CREATE TABLE probe (value TEXT)');
      await first.insert('probe', {'value': 'desktop persistence'});
    } finally {
      await first.close();
    }
    await initializePlatformDatabase();
    final second = await openDatabase(path);
    try {
      expect(await second.query('probe'), [
        {'value': 'desktop persistence'}
      ]);
    } finally {
      await second.close();
    }
  });
}
