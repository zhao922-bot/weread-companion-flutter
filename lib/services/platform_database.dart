import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Desktop SQLite runs in its own isolate and stores data outside the install
/// directory, so updates and read-only installation paths do not affect it.
Future<void> initializePlatformDatabase() async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final support = await getApplicationSupportDirectory();
  await databaseFactory.setDatabasesPath(p.join(support.path, 'databases'));
}
