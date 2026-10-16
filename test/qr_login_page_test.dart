import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:weread_companion/pages/qr_login_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/services/qr_login_service.dart';

const _credentials = Credentials(
    vid: '123',
    accessToken: 'access',
    refreshToken: 'refresh',
    deviceId: 'device');

class _Attempt {
  _Attempt(this.token, this.onQr, this.onStatus);
  final CancelToken token;
  final void Function(QrLoginRequest) onQr;
  final void Function(QrLoginStatus)? onStatus;
  final result = Completer<Credentials>();
}

class _QrService extends QrLoginService {
  final attempts = <_Attempt>[];
  int disposals = 0;
  @override
  Future<Credentials> login(
      {required CancelToken cancelToken,
      required void Function(QrLoginRequest) onQr,
      void Function(QrLoginStatus)? onStatus}) {
    final attempt = _Attempt(cancelToken, onQr, onStatus);
    attempts.add(attempt);
    // Deliberately allow late completion to exercise the page's stale guards.
    return attempt.result.future;
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

class _Config extends AppConfigProvider {
  _Config() : super(config: AppConfig());
  bool busy = false;
  bool verified = true;
  String? verificationError;
  Object? saveError;
  Completer<void>? saveGate;
  final saved = <Credentials>[];
  @override
  bool get isBusy => busy;
  @override
  bool get isLoggedIn => verified;
  @override
  String? get loginError => verificationError;
  @override
  Future<void> loginWithCredentials(Credentials credentials) async {
    saved.add(credentials);
    busy = true;
    notifyListeners();
    try {
      await saveGate?.future;
      if (saveError != null) throw saveError!;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

void main() {
  late _QrService service;
  late _Config config;
  late GlobalKey<NavigatorState> navigator;
  bool? result;

  setUp(() {
    service = _QrService();
    config = _Config();
    navigator = GlobalKey<NavigatorState>();
    result = null;
  });
  tearDown(() => config.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
      value: config,
      child: MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () async {
                        result = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                                builder: (_) => QrLoginPage(
                                    serviceFactory: () => service)));
                      },
                      child: const Text('打开扫码'),
                    )),
          )),
    ));
    await tester.tap(find.text('打开扫码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.attempts, hasLength(1));
  }

  testWidgets('获取二维码、扫码、确认、保存与验证成功后返回true', (tester) async {
    await open(tester);
    expect(find.text('正在获取二维码…'), findsOneWidget);
    final attempt = service.attempts.single;
    attempt.onQr(const QrLoginRequest('uuid'));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    attempt.onStatus!(QrLoginStatus.waiting);
    await tester.pump();
    expect(find.text('待扫码：请使用微信扫描二维码'), findsOneWidget);
    attempt.onStatus!(QrLoginStatus.scanned);
    await tester.pump();
    expect(find.text('已扫码：请在微信中确认登录'), findsOneWidget);
    attempt.onStatus!(QrLoginStatus.confirmed);
    await tester.pump();
    expect(find.text('已确认：正在获取登录凭据…'), findsOneWidget);
    config.saveGate = Completer<void>();
    attempt.result.complete(_credentials);
    await tester.pump();
    expect(config.saved, [_credentials]);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('已确认：正在安全保存凭据并验证账号…'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消登录'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.arrow_back))
            .onPressed,
        isNull);
    await navigator.currentState!.maybePop();
    await tester.pump();
    expect(find.byType(QrLoginPage), findsOneWidget);
    config.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(QrLoginPage), findsNothing);
    expect(service.disposals, 1);
    expect(attempt.token.isCancelled, isTrue);
  });

  testWidgets('过期后重新扫码，旧回调不能覆盖新二维码', (tester) async {
    await open(tester);
    final first = service.attempts.single;
    first.onQr(const QrLoginRequest('old'));
    first.result.completeError(const QrLoginException('二维码已过期', expired: true));
    await tester.pumpAndSettle();
    expect(find.text('过期：二维码已过期'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.text('重试 / 重新扫码'));
    await tester.pump();
    final second = service.attempts.last;
    expect(first.token.isCancelled, isTrue);
    second.onQr(const QrLoginRequest('new'));
    await tester.pump();
    final currentQr = tester.widget<QrImageView>(find.byType(QrImageView));
    first.onQr(const QrLoginRequest('stale'));
    first.onStatus!(QrLoginStatus.confirmed);
    await tester.pump();
    expect(
        tester.widget<QrImageView>(find.byType(QrImageView)), same(currentQr));
    expect(find.text('待扫码：请使用微信扫描二维码'), findsOneWidget);
  });

  for (final failure in ['network', 'cancel', 'refused', 'save']) {
    testWidgets('$failure错误显示可重试提示且不退出页面', (tester) async {
      await open(tester);
      final attempt = service.attempts.single;
      switch (failure) {
        case 'cancel':
          // The service ended unexpectedly; the user's attempt is still active.
          attempt.result.completeError(DioException(
              requestOptions: RequestOptions(), type: DioExceptionType.cancel));
        case 'network':
          attempt.result.completeError(DioException(
              requestOptions: RequestOptions(),
              type: DioExceptionType.connectionError));
        case 'refused':
          attempt.result.completeError(const QrLoginException('已拒绝登录'));
        case 'save':
          config.saveError = StateError('storage failure');
          attempt.result.complete(_credentials);
      }
      await tester.pumpAndSettle();
      expect(
          find.text(switch (failure) {
            'network' || 'cancel' => '失败：网络请求失败，请检查网络后重试',
            'refused' => '失败：已拒绝登录',
            _ => '失败：无法保存或验证登录凭据，请重试',
          }),
          findsOneWidget);
      expect(find.text('重试 / 重新扫码'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(result, isNull);
      config.saveError = null;
      await tester.tap(find.text('重试 / 重新扫码'));
      await tester.pump();
      service.attempts.last.result.complete(_credentials);
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  }

  for (final reason in ['账号不匹配', null]) {
    testWidgets('验证未成功显示${reason ?? '默认状态'}，不误报成功', (tester) async {
      await open(tester);
      config.verified = false;
      config.verificationError = reason;
      service.attempts.single.result.complete(_credentials);
      await tester.pumpAndSettle();
      expect(
          find.text('失败：${reason ?? config.loginStatusText}'), findsOneWidget);
      expect(find.byType(QrLoginPage), findsOneWidget);
      expect(result, isNull);
    });
  }

  for (final method in ['cancel', 'back', 'system']) {
    testWidgets('$method退出立即取消，退出动画中的成功响应不能再保存凭据', (tester) async {
      await open(tester);
      final attempt = service.attempts.single;
      if (method == 'system') {
        await navigator.currentState!.maybePop();
      } else {
        await tester.tap(method == 'cancel'
            ? find.text('取消登录')
            : find.byIcon(Icons.arrow_back));
      }
      // Complete before the route's reverse animation has disposed the state.
      attempt.result.complete(_credentials);
      await tester.pumpAndSettle();
      expect(config.saved, isEmpty);
      expect(attempt.token.isCancelled, isTrue);
      expect(service.disposals, 1);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final saving in [false, true]) {
    testWidgets('页面强制移除后${saving ? '保存失败' : '请求回调'}不会访问已释放页面', (tester) async {
      await open(tester);
      final attempt = service.attempts.single;
      if (saving) {
        config.saveGate = Completer<void>();
        config.saveError = StateError('save failure');
        attempt.result.complete(_credentials);
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox());
      expect(attempt.token.isCancelled, isTrue);
      if (saving) {
        config.saveGate!.complete();
      } else {
        attempt.onQr(const QrLoginRequest('late'));
        attempt.onStatus!(QrLoginStatus.scanned);
        attempt.result
            .completeError(DioException(requestOptions: RequestOptions()));
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(service.disposals, 1);
      expect(config.saved.length, saving ? 1 : 0);
    });
  }

  testWidgets('快速重复点击重试只启动一个扫码请求', (tester) async {
    await open(tester);
    service.attempts.single.result.completeError(const QrLoginException('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试 / 重新扫码'));
    await tester.tap(find.text('重试 / 重新扫码'));
    await tester.pump();
    expect(service.attempts, hasLength(2));
  });

  testWidgets('配置忙碌时禁用重试，恢复后可重新扫码', (tester) async {
    await open(tester);
    service.attempts.single.result.completeError(const QrLoginException('重试'));
    config.busy = true;
    config.notifyListeners();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, '重试 / 重新扫码'))
            .onPressed,
        isNull);
    config.busy = false;
    config.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('重试 / 重新扫码'));
    await tester.pump();
    expect(service.attempts, hasLength(2));
  });

  testWidgets('连续50次相同等待状态不重复构建二维码', (tester) async {
    await open(tester);
    final attempt = service.attempts.single;
    attempt.onQr(const QrLoginRequest('uuid'));
    await tester.pump();
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    for (var i = 0; i < 50; i++) {
      attempt.onStatus!(QrLoginStatus.waiting);
      await tester.pump();
      expect(tester.widget<QrImageView>(find.byType(QrImageView)), same(qr));
    }
  });

  testWidgets('保存验证成功返回前页面被移除，迟到成功不弹提示或导航', (tester) async {
    await open(tester);
    final attempt = service.attempts.single;
    config.saveGate = Completer<void>();
    attempt.result.complete(_credentials);
    await tester.pump();
    expect(config.saved, [_credentials]);
    await tester.pumpWidget(const SizedBox());
    config.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(attempt.token.isCancelled, isTrue);
    expect(service.disposals, 1);
    expect(find.text('扫码登录验证成功'), findsNothing);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
}
