import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';

class AppUpdate {
  final String version;
  final String notes;
  final Uri releasePage;
  final ({Uri uri, String label})? download;

  const AppUpdate({
    required this.version,
    required this.notes,
    required this.releasePage,
    required this.download,
  });
}

class ReleaseUpdateService {
  static const _repository = 'zhao922-bot/weread-companion-flutter';
  static final _versionPrefix = RegExp(r'^[vV]');
  final Dio _dio;

  ReleaseUpdateService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  void dispose() => _dio.close(force: true);

  // Release availability uses SemVer precedence, which ignores build metadata.
  Version _version(String value) {
    final version = Version.parse(value.replaceFirst(_versionPrefix, ''));
    return Version.parse(version.toString().split('+').first);
  }

  Future<AppUpdate?> check(
    String installedVersion,
    TargetPlatform platform, {
    required CancelToken cancelToken,
  }) async {
    final installed = _version(installedVersion);
    final response = await _dio.get<Object?>(
      'https://api.github.com/repos/$_repository/releases/latest',
      options: Options(headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      }),
      cancelToken: cancelToken,
    );
    final data = response.data;
    if (data is! Map<String, dynamic> || data['tag_name'] is! String) {
      throw const FormatException('GitHub release is missing a version tag');
    }
    final tag = data['tag_name'] as String;
    final latest = _version(tag);
    if (latest <= installed) return null;

    final notes = data['body'];
    return AppUpdate(
      version: 'v$latest',
      notes: notes is String ? notes.trim() : '',
      releasePage: Uri.https('github.com', '/$_repository/releases/tag/$tag'),
      download: _download(data['assets'], platform, tag, latest),
    );
  }

  ({Uri uri, String label})? _download(
    Object? assets,
    TargetPlatform platform,
    String tag,
    Version version,
  ) {
    final file = switch (platform) {
      TargetPlatform.android => ('android.apk', '下载 Android APK'),
      TargetPlatform.windows => ('windows-x64-setup.exe', '下载 Windows 安装包'),
      _ => null,
    };
    if (file == null || assets is! List) return null;

    final name = 'readamber-v$version-${file.$1}';
    final uri =
        Uri.https('github.com', '/$_repository/releases/download/$tag/$name');
    for (final asset in assets.whereType<Map>()) {
      if (asset['name'] == name &&
          asset['browser_download_url'] == uri.toString()) {
        return (uri: uri, label: file.$2);
      }
    }
    return null;
  }
}
