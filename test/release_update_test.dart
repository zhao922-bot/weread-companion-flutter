import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:weread_companion/services/release_update_service.dart';
import 'package:weread_companion/widgets/settings/about_settings_section.dart';

import 'mobile_auth_test.dart' show AuthAdapter, jsonResponse;

const _repo = 'zhao922-bot/weread-companion-flutter';
const _github = 'https://github.com/$_repo/releases';
const _apk = 'readamber-v2.10.1-android.apk';
const _setup = 'readamber-v2.10.1-windows-x64-setup.exe';
const _apkUrl = '$_github/download/v2.10.1/$_apk';
const _setupUrl = '$_github/download/v2.10.1/$_setup';
const _notes = '修复划线同步并改进离线体验。';
const _launcher = MethodChannel('plugins.flutter.io/url_launcher');

Map<String, Object?> _release({
  Object tag = 'v2.10.1',
  Object? notes = _notes,
  Object? assets = const [
    false,
    {'name': 'readamber-v2.10.1-windows-x64.zip'},
    {'name': _apk, 'browser_download_url': 'https://example.org/$_apk'},
    {'name': _apk, 'browser_download_url': _apkUrl},
    {'name': _setup, 'browser_download_url': _setupUrl},
  ],
}) =>
    {'tag_name': tag, 'body': notes, 'assets': assets};

ReleaseUpdateService _service(
    FutureOr<ResponseBody> Function(RequestOptions) respond) {
  final service = ReleaseUpdateService(
      dio: Dio()..httpClientAdapter = AuthAdapter(respond));
  addTearDown(service.dispose);
  return service;
}

Future<AppUpdate?> _check(
  ReleaseUpdateService service, {
  String installed = '2.9.99',
  TargetPlatform platform = TargetPlatform.android,
}) =>
    service.check(installed, platform, cancelToken: CancelToken());

void main() {
  test('checks the public endpoint and matches official installers by platform',
      () async {
    final service = _service((request) {
      expect(request.method, 'GET');
      expect(request.uri.toString(),
          'https://api.github.com/repos/$_repo/releases/latest');
      expect(request.headers['Accept'], 'application/vnd.github+json');
      expect(request.headers['Authorization'], isNull);
      return jsonResponse(_release(notes: '\n$_notes\n'));
    });
    final android = (await _check(service))!;
    expect(android.version, 'v2.10.1');
    expect(android.notes, _notes);
    expect(android.releasePage.toString(), '$_github/tag/v2.10.1');
    expect(
        android.download, (uri: Uri.parse(_apkUrl), label: '下载 Android APK'));

    final windows = (await _check(service, platform: TargetPlatform.windows))!;
    expect(
        windows.download, (uri: Uri.parse(_setupUrl), label: '下载 Windows 安装包'));
    expect((await _check(service, platform: TargetPlatform.macOS))!.download,
        isNull);
  });

  test('compares versions numerically and ignores build metadata', () async {
    final service = _service((_) => jsonResponse(_release()));
    expect(await _check(service, installed: '2.10.1+99'), isNull);
    expect(await _check(service, installed: '2.11.0'), isNull);
    expect(
        (await _check(service, installed: '2.10.1-rc.1'))!.version, 'v2.10.1');
  });

  test('keeps the public release page when the installer or notes are absent',
      () async {
    final service =
        _service((_) => jsonResponse(_release(notes: null, assets: null)));
    final update = (await _check(service))!;
    expect(update.releasePage.toString(), '$_github/tag/v2.10.1');
    expect(update.notes, isEmpty);
    expect(update.download, isNull);

    final unavailable = _service((_) => jsonResponse(_release(assets: [
          {'name': _setup, 'browser_download_url': _setupUrl},
          {
            'name': _apk,
            'browser_download_url': '$_github/download/v2.9.99/$_apk'
          },
        ])));
    expect((await _check(unavailable))!.download, isNull);
  });

  test('rejects invalid metadata and propagates request errors for retry',
      () async {
    for (final body in [[], _release(tag: 123), _release(tag: 'nightly')]) {
      final service = _service((_) => jsonResponse(body));
      await expectLater(_check(service), throwsFormatException);
    }
    final rateLimited =
        _service((_) => jsonResponse({'message': 'Rate limit'}, 403));
    await expectLater(_check(rateLimited), throwsA(isA<DioException>()));
  });

  testWidgets('version errors are visible only while the About screen is open',
      (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    final messenger = tester.binding.defaultBinaryMessenger;
    var gate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (_) async {
      await gate.future;
      throw PlatformException(code: 'version-error');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const about = MaterialApp(
      home:
          Scaffold(body: SingleChildScrollView(child: AboutSettingsSection())),
    );
    await tester.pumpWidget(about);
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.text('正在检查更新…'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('无法检查更新，请稍后重试。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('版本读取失败'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    gate = Completer<void>();
    await tester.pumpWidget(about);
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissal while reading the version skips the network request',
      (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    final version = Completer<Map<String, String>>();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) => version.future);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var requests = 0;
    final service = _service((_) {
      requests++;
      return jsonResponse(_release());
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
              child: AboutSettingsSection(updateService: service))),
    ));
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    version.complete({'version': '2.9.99', 'buildNumber': '25'});
    await tester.pumpAndSettle();
    expect(requests, 0);
  });

  Future<void> showAbout(
      WidgetTester tester, ReleaseUpdateService service) async {
    PackageInfo.setMockInitialValues(
      appName: 'ReadAmber',
      packageName: 'weread_companion',
      version: '2.9.99',
      buildNumber: '25',
      buildSignature: '',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
              child: AboutSettingsSection(updateService: service))),
    ));
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
  }

  void mockLauncher(
      WidgetTester tester, Future<Object?> Function(MethodCall) launch) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_launcher, launch);
    addTearDown(() => messenger.setMockMethodCallHandler(_launcher, null));
  }

  testWidgets(
      'retries a failed check and opens the Android installer on demand',
      (tester) async {
    final firstResponse = Completer<ResponseBody>();
    var requests = 0;
    final service = _service((_) async {
      if (requests++ == 0) return firstResponse.future;
      return jsonResponse(_release());
    });
    final launches = <MethodCall>[];
    final firstLaunch = Completer<bool>();
    mockLauncher(tester, (call) {
      launches.add(call);
      return launches.length == 1 ? firstLaunch.future : Future.value(true);
    });
    await showAbout(tester, service);
    expect(find.text('正在检查更新…'), findsOneWidget);
    expect(find.text('下载 Android APK'), findsNothing);

    firstResponse.complete(jsonResponse({'message': 'Unavailable'}, 503));
    await tester.pumpAndSettle();
    expect(find.text('无法检查更新，请稍后重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('发现新版本 v2.10.1'), findsOneWidget);
    expect(find.text(_notes), findsOneWidget);
    expect(launches, isEmpty);

    await tester.tap(find.text('下载 Android APK'));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '下载 Android APK'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '打开发布页面'))
            .onPressed,
        isNull);
    firstLaunch.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('无法打开链接，请重试。'), findsOneWidget);
    await tester.tap(find.text('下载 Android APK'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开链接，请重试。'), findsNothing);
    expect(launches, hasLength(2));
    for (final call in launches) {
      expect(call.method, 'launch');
      expect(call.arguments['url'], _apkUrl);
      expect(call.arguments['useWebView'], isFalse);
    }
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('uses the release page when a matching package is unavailable',
      (tester) async {
    final service =
        _service((_) => jsonResponse(_release(assets: [], notes: ' ')));
    final launched = <String>[];
    final launchResult = Completer<bool>();
    mockLauncher(tester, (call) async {
      launched.add(call.arguments['url'] as String);
      return launchResult.future;
    });
    await showAbout(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('暂无发布说明。'), findsOneWidget);
    expect(find.text('此版本暂无适用于当前平台的安装包。'), findsOneWidget);
    expect(find.text('下载 Windows 安装包'), findsNothing);
    await tester.tap(find.text('打开发布页面'));
    await tester.pump();
    expect(launched, ['$_github/tag/v2.10.1']);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    launchResult.completeError(PlatformException(code: 'launch-failed'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('无法打开链接，请重试。'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('dismissal cancels a pending request and reopening checks again',
      (tester) async {
    final delayedResponse = Completer<ResponseBody>();
    late CancelToken firstRequest;
    var requests = 0;
    final service = _service((request) {
      if (requests++ == 0) {
        firstRequest = request.cancelToken!;
        return delayedResponse.future;
      }
      return jsonResponse(_release(tag: 'v2.9.99'));
    });
    await showAbout(tester, service);
    expect(find.text('正在检查更新…'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(firstRequest.isCancelled, isTrue);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('暂无可用更新。'), findsOneWidget);
    delayedResponse.complete(jsonResponse(_release()));
    await tester.pumpAndSettle();
    expect(find.text('暂无可用更新。'), findsOneWidget);
    expect(find.text('发现新版本 v2.10.1'), findsNothing);
  });
}
