import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:weread_companion/pages/cookie_login_page.dart';
import 'package:weread_companion/providers/app_config_provider.dart';
import 'package:weread_companion/services/config.dart';
import 'package:weread_companion/services/credentials.dart';
import 'package:weread_companion/services/qr_login_service.dart';
import 'package:weread_companion/pages/qr_login_page.dart';

class _PendingQr extends QrLoginService {
  final result = Completer<Credentials>();
  CancelToken? token;
  @override
  Future<Credentials> login(
      {required CancelToken cancelToken,
      required void Function(QrLoginRequest) onQr,
      void Function(QrLoginStatus)? onStatus}) {
    token = cancelToken;
    return result.future;
  }
}

class _CookieConfig extends AppConfigProvider {
  _CookieConfig() : super(config: AppConfig());
  Completer<void>? gate;
  Object? failure;
  bool verified = true;
  String? reason = '账号验证未通过';
  int qrSaved = 0;
  final saved = <String>[];
  @override
  bool get isLoggedIn => verified;
  @override
  String? get loginError => reason;
  @override
  Future<void> loginWithCredentials(Credentials credentials) async {
    qrSaved++;
  }

  @override
  Future<void> loginWithCookie(String cookie) async {
    saved.add(cookie);
    await gate?.future;
    if (failure != null) throw failure!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CookieConfig config;
  late GlobalKey<NavigatorState> navigator;
  late FutureOr<Object?> Function(MethodCall) clipboard;
  late List<_PendingQr> qrServices;
  setUp(() {
    config = _CookieConfig();
    navigator = GlobalKey<NavigatorState>();
    qrServices = [];
    clipboard = (_) => {'text': '  wr_vid=123; wr_skey=pasted  '};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      if (call.method == 'LiveText.isLiveTextInputAvailable') return false;
      if (call.method == 'Clipboard.getData' ||
          call.method == 'Clipboard.setData') {
        return clipboard(call);
      }
      return null;
    });
  });
  tearDown(() {
    config.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider<AppConfigProvider>.value(
      value: config,
      child: MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) =>
                                    CookieLoginPage(qrServiceFactory: () {
                                      final service = _PendingQr();
                                      qrServices.add(service);
                                      return service;
                                    }))),
                        child: const Text('打开导入'),
                      )))),
    ));
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
  }

  Future<void> paste(WidgetTester tester) async {
    await tester.ensureVisible(find.byTooltip('从剪贴板粘贴'));
    await tester.tap(find.byTooltip('从剪贴板粘贴'));
  }

  String input(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<void> scan(WidgetTester tester) async {
    await tester.ensureVisible(find.text('扫码登录'));
    await tester.tap(find.text('扫码登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('空Cookie不提交；未验证且没有具体错误时显示登录状态', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('确认导入并验证'));
    await tester.tap(find.text('确认导入并验证'));
    await tester.pumpAndSettle();
    expect(config.saved, isEmpty);
    expect(find.text('请输入 Cookie'), findsOneWidget);
    config.reason = null;
    config.verified = false;
    await tester.enterText(find.byType(TextField), 'cookie');
    await tester.ensureVisible(find.text('确认导入并验证'));
    await tester.tap(find.text('确认导入并验证'));
    await tester.pumpAndSettle();
    expect(find.byType(CookieLoginPage), findsOneWidget);
    expect(config.saved, ['cookie']);
  });

  testWidgets('扫码取消保留Cookie输入，再次扫码成功关闭两层登录页', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'kept-cookie');
    await scan(tester);
    await tester.tap(find.text('取消登录'));
    await tester.pumpAndSettle();
    expect(input(tester), 'kept-cookie');
    expect(qrServices.first.token!.isCancelled, isTrue);
    await scan(tester);
    qrServices.last.result.complete(const Credentials(
        vid: '123',
        accessToken: 'access',
        refreshToken: 'refresh',
        deviceId: 'device'));
    await tester.pumpAndSettle();
    expect(find.byType(CookieLoginPage), findsNothing);
    expect(find.byType(QrLoginPage), findsNothing);
    expect(config.qrSaved, 1);
    expect(find.text('打开导入'), findsOneWidget);
  });

  testWidgets('快速连点扫码入口只打开一个扫码页面', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('扫码登录'));
    await tester.tap(find.text('扫码登录'));
    await tester.tap(find.text('扫码登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QrLoginPage, skipOffstage: false), findsOneWidget);
    expect(qrServices, hasLength(1));
  });

  testWidgets('进入扫码后返回的旧粘贴不修改Cookie表单', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'original');
    final response = Completer<Object?>();
    clipboard = (_) => response.future;
    await paste(tester);
    await scan(tester);
    response.complete({'text': 'stale'});
    await tester.pump();
    await tester.tap(find.text('取消登录'));
    await tester.pumpAndSettle();
    expect(input(tester), 'original');
  });

  for (final failed in [false, true]) {
    testWidgets('复制命令在退出动画中${failed ? '失败' : '成功'}不向上一页显示过期提示', (tester) async {
      await open(tester);
      final response = Completer<Object?>();
      clipboard = (_) => response.future;
      await tester.tap(find.text('点击复制'));
      await navigator.currentState!.maybePop();
      if (failed) {
        response.completeError(PlatformException(code: 'denied'));
      } else {
        response.complete(null);
      }
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('快速连点导入只提交一次凭据', (tester) async {
    await open(tester);
    config.gate = Completer<void>();
    await tester.enterText(find.byType(TextField), 'cookie');
    await tester.ensureVisible(find.text('确认导入并验证'));
    await tester.tap(find.text('确认导入并验证'));
    await tester.tap(find.text('确认导入并验证'));
    await tester.pump();
    expect(config.saved, ['cookie']);
    config.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('打开导入'), findsOneWidget);
  });

  for (final failed in [false, true]) {
    testWidgets('强制移除导入路由时，迟到的保存${failed ? '异常' : '成功'}不影响上一页', (tester) async {
      await open(tester);
      config.gate = Completer<void>();
      config.failure = failed ? StateError('late failure') : null;
      await tester.enterText(find.byType(TextField), 'cookie');
      await tester.ensureVisible(find.text('确认导入并验证'));
      await tester.tap(find.text('确认导入并验证'));
      await tester.pump();
      navigator.currentState!.pop();
      config.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.text('打开导入'), findsOneWidget);
    });
  }

  testWidgets('粘贴裁剪空白，空剪贴板不清除现有输入', (tester) async {
    await open(tester);
    await paste(tester);
    await tester.pumpAndSettle();
    expect(input(tester), 'wr_vid=123; wr_skey=pasted');
    clipboard = (_) => null;
    await paste(tester);
    await tester.pumpAndSettle();
    expect(input(tester), 'wr_vid=123; wr_skey=pasted');
    expect(find.text('剪贴板为空'), findsOneWidget);
  });

  testWidgets('读取剪贴板失败显示错误并可重试，不产生未处理异常', (tester) async {
    await open(tester);
    clipboard = (_) => throw PlatformException(code: 'clipboard_denied');
    await paste(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('读取剪贴板失败，请重试'), findsOneWidget);
    clipboard = (_) => {'text': 'new-cookie'};
    await paste(tester);
    await tester.pumpAndSettle();
    expect(input(tester), 'new-cookie');
  });

  testWidgets('粘贴等待期间用户手动输入，迟到结果不能覆盖输入', (tester) async {
    await open(tester);
    final response = Completer<Object?>();
    clipboard = (_) => response.future;
    await paste(tester);
    await tester.enterText(find.byType(TextField), 'manually-entered');
    response.complete({'text': 'old-clipboard'});
    await tester.pumpAndSettle();
    expect(input(tester), 'manually-entered');
  });

  testWidgets('两次粘贴逆序完成，仅保留最后一次结果', (tester) async {
    await open(tester);
    final first = Completer<Object?>();
    final second = Completer<Object?>();
    var calls = 0;
    clipboard = (_) => ++calls == 1 ? first.future : second.future;
    await paste(tester);
    await paste(tester);
    second.complete({'text': 'new'});
    await tester.pump();
    first.complete({'text': 'old'});
    await tester.pumpAndSettle();
    expect(input(tester), 'new');
  });

  testWidgets('保存期间迟到粘贴不改动正在验证的内容，系统返回等待保存完成', (tester) async {
    await open(tester);
    await tester.enterText(
        find.byType(TextField), 'wr_vid=123; wr_skey=submitted');
    final response = Completer<Object?>();
    clipboard = (_) => response.future;
    await paste(tester);
    config.gate = Completer<void>();
    await tester.ensureVisible(find.text('确认导入并验证'));
    await tester.tap(find.text('确认导入并验证'));
    await tester.pump();
    response.complete({'text': 'different-account'});
    await tester.pump();
    expect(input(tester), 'wr_vid=123; wr_skey=submitted');
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(CookieLoginPage), findsOneWidget);
    config.gate!.complete();
    await tester.pumpAndSettle();
    expect(config.saved, ['wr_vid=123; wr_skey=submitted']);
    expect(find.byType(CookieLoginPage), findsNothing);
  });

  testWidgets('复制命令失败不误报成功，重试写入成功后提示已复制', (tester) async {
    await open(tester);
    clipboard = (_) => throw PlatformException(code: 'clipboard_denied');
    await tester.tap(find.text('点击复制'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('代码已复制'), findsNothing);
    expect(find.text('复制失败，请重试'), findsOneWidget);
    MethodCall? copied;
    clipboard = (call) {
      copied = call;
      return null;
    };
    await tester.tap(find.text('点击复制'));
    await tester.pumpAndSettle();
    expect(copied!.method, 'Clipboard.setData');
    expect(copied!.arguments['text'], 'copy(document.cookie)');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('代码已复制'), findsOneWidget);
  });

  testWidgets('提交失败后才返回的旧粘贴不改动保留的输入', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'submitted-cookie');
    final response = Completer<Object?>();
    clipboard = (_) => response.future;
    await paste(tester);
    config.failure = StateError('save failed');
    await tester.ensureVisible(find.text('确认导入并验证'));
    await tester.tap(find.text('确认导入并验证'));
    await tester.pumpAndSettle();
    response.complete({'text': 'stale-cookie'});
    await tester.pumpAndSettle();
    expect(input(tester), 'submitted-cookie');
  });

  for (final error in ['format', 'save', 'verification']) {
    testWidgets('$error导入失败保留输入并恢复按钮', (tester) async {
      await open(tester);
      config.failure = switch (error) {
        'format' => const FormatException('Cookie 格式不正确'),
        'save' => StateError('failed'),
        _ => null,
      };
      config.verified = false;
      await tester.enterText(find.byType(TextField), 'invalid-cookie');
      await tester.ensureVisible(find.text('确认导入并验证'));
      await tester.tap(find.text('确认导入并验证'));
      await tester.pumpAndSettle();
      expect(input(tester), 'invalid-cookie');
      expect(
          find.text(switch (error) {
            'format' => 'Cookie 格式不正确',
            'save' => '导入失败，请重试',
            _ => '账号验证未通过'
          }),
          findsOneWidget);
      expect(
          tester
              .widget<ElevatedButton>(
                  find.widgetWithText(ElevatedButton, '确认导入并验证'))
              .onPressed,
          isNotNull);
    });
  }

  testWidgets('粘贴期间退出页面，迟到结果不访问已释放输入框', (tester) async {
    await open(tester);
    final response = Completer<Object?>();
    clipboard = (_) => response.future;
    await paste(tester);
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    response.complete({'text': 'late'});
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
