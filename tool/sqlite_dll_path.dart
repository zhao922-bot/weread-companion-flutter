import 'dart:convert';
import 'dart:io';

// Resolve the DLL from the pinned dependency instead of downloading an
// unrelated SQLite build or depending on the developer's absolute cache path.
void main() {
  final configUri =
      Platform.script.resolve('../.dart_tool/package_config.json');
  final config = jsonDecode(File.fromUri(configUri).readAsStringSync()) as Map;
  final package = (config['packages'] as List)
      .cast<Map>()
      .singleWhere((entry) => entry['name'] == 'sqflite_common_ffi');
  final dll = File.fromUri(
      Directory.fromUri(configUri.resolve(package['rootUri'] as String))
          .uri
          .resolve('lib/src/windows/sqlite3.dll'));
  if (!dll.existsSync()) {
    throw StateError('SQLite runtime is missing: ${dll.path}');
  }
  stdout.write(dll.path);
}
