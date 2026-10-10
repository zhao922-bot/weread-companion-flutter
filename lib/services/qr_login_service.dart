import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

enum QrLoginStatus { waiting, scanned, confirmed }

class QrLoginException implements Exception {
  final String message;
  final bool expired;

  const QrLoginException(this.message, {this.expired = false});

  @override
  String toString() => message;
}

class QrLoginRequest {
  final String uuid;

  const QrLoginRequest(this.uuid);

  String get confirmUrl =>
      'https://open.weixin.qq.com/connect/confirm?uuid=${Uri.encodeComponent(uuid)}';
}

class QrLoginCredentials {
  final String vid;
  final String accessToken;
  final String refreshToken;
  final String deviceId;

  const QrLoginCredentials({
    required this.vid,
    required this.accessToken,
    required this.refreshToken,
    required this.deviceId,
  });

  // 复用 AppConfig 的 weread_cookie 安全存储槽及退出清理机制，
  // 不另存一份可能在切换账号或退出后残留的 token。
  String get cookie => 'wr_vid=$vid; wr_skey=$accessToken; '
      'wr_refreshToken=$refreshToken; wr_deviceId=$deviceId';
}

/// 微信 SDK 扫码登录。所有请求和等待均可由调用方的 CancelToken 中止。
class QrLoginService {
  static const _versionHeaders = {
    'baseapi': '30',
    'appver': '2.1.2.10245900',
    'basever': '2.1.2.10245900',
    'osver': '11',
    'channelId': '900',
    'User-Agent': 'WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 '
        '(Linux; U; Android 11; BOOX Build/onyx)',
  };
  final Dio _dio;
  final Random _random = Random.secure();

  QrLoginService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: false,
            ));

  void dispose() => _dio.close(force: true);

  Map<String, dynamic> _object(dynamic data) {
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        throw const QrLoginException('登录服务返回了无效数据，请重试');
      }
    }
    if (data is! Map) {
      throw const QrLoginException('登录服务返回了无效数据，请重试');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<QrLoginRequest> requestQr({required CancelToken cancelToken}) async {
    final ticketResponse = await _dio.get<dynamic>(
      'https://i.weread.qq.com/wxticket',
      queryParameters: {'nonceStr': 'weread'},
      options: Options(headers: _versionHeaders),
      cancelToken: cancelToken,
    );
    final ticket = _object(ticketResponse.data);
    final signature = ticket['signature'];
    final timestamp = ticket['timeStamp'];
    if (signature is! String ||
        signature.isEmpty ||
        (timestamp is! num && timestamp is! String)) {
      throw const QrLoginException('获取微信登录 ticket 失败，请重试');
    }
    final response = await _dio.get<dynamic>(
      'https://open.weixin.qq.com/connect/sdk/qrconnect',
      queryParameters: {
        'appid': 'wxab9b71ad2b90ff34',
        'noncestr': 'weread',
        'timestamp': timestamp.toString(),
        'scope': 'snsapi_userinfo,snsapi_timeline,snsapi_friend',
        'signature': signature,
      },
      options: Options(headers: {'User-Agent': _versionHeaders['User-Agent']}),
      cancelToken: cancelToken,
    );
    final qr = _object(response.data);
    final uuid = qr['uuid'];
    if (qr['errcode'] != 0 || uuid is! String || uuid.isEmpty) {
      throw const QrLoginException('获取二维码失败，请重试');
    }
    return QrLoginRequest(uuid);
  }

  Future<void> _delay(Duration duration, CancelToken token) async {
    if (token.isCancelled) throw token.cancelError!;
    final completer = Completer<void>();
    final timer = Timer(duration, completer.complete);
    try {
      await Future.any<void>([
        completer.future,
        token.whenCancel.then<void>((error) => throw error),
      ]);
    } finally {
      timer.cancel();
    }
  }

  Future<String> pollForCode(
    String uuid, {
    required CancelToken cancelToken,
    void Function(QrLoginStatus)? onStatus,
  }) async {
    final elapsed = Stopwatch()..start();
    const deadline = Duration(minutes: 5);
    int? last;
    bool scanned = false;
    while (true) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final remaining = deadline - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw const QrLoginException('二维码已过期，请重新扫码', expired: true);
      }
      final timeout = remaining < const Duration(seconds: 65)
          ? remaining
          : const Duration(seconds: 65);
      // 独立计时器保证连接和接收阶段合计不超过单次/总时限。
      final requestToken = CancelToken();
      final timer = Timer(timeout, () => requestToken.cancel('poll timeout'));
      unawaited(cancelToken.whenCancel.then((error) {
        if (!requestToken.isCancelled) requestToken.cancel(error);
      }));
      Map<String, dynamic> result;
      try {
        final response = await _dio.get<dynamic>(
          'https://long.open.weixin.qq.com/connect/l/qrconnect',
          queryParameters: {
            'f': 'json',
            'uuid': uuid,
            if (last != null) 'last': last,
          },
          options: Options(
            headers: {'User-Agent': 'Mozilla/5.0'},
            receiveTimeout: timeout,
          ),
          cancelToken: requestToken,
        );
        result = _object(response.data);
      } on DioException catch (e) {
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        if (e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.connectionTimeout ||
            (e.type == DioExceptionType.cancel &&
                requestToken.cancelError?.error == 'poll timeout')) {
          continue;
        }
        rethrow;
      } finally {
        timer.cancel();
      }
      final code = int.tryParse('${result['wx_errcode']}');
      switch (code) {
        case 405:
          final wxCode = result['wx_code'];
          if (wxCode is! String || wxCode.isEmpty) {
            throw const QrLoginException('微信确认未返回授权码，请重试');
          }
          onStatus?.call(QrLoginStatus.confirmed);
          return wxCode;
        case 404:
          scanned = true;
          onStatus?.call(QrLoginStatus.scanned);
          break;
        case 408:
          if (!scanned) onStatus?.call(QrLoginStatus.waiting);
          break;
        case 402:
          throw const QrLoginException('二维码已过期，请重新扫码', expired: true);
        case 403:
          throw const QrLoginException('已拒绝登录，请重新扫码');
        default:
          throw const QrLoginException('微信返回了未知登录状态，请重试');
      }
      last = code;
      final delay = deadline - elapsed.elapsed;
      if (delay > Duration.zero) {
        await _delay(
            delay < const Duration(seconds: 1)
                ? delay
                : const Duration(seconds: 1),
            cancelToken);
      }
    }
  }

  String _digits(int length) =>
      List.generate(length, (_) => _random.nextInt(10)).join();

  Future<QrLoginCredentials> exchange(
    String wxCode, {
    required CancelToken cancelToken,
  }) async {
    var identity = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      identity = (identity << 8) | BigInt.from(_random.nextInt(256));
    }
    final suffix = identity.toUnsigned(63).toString().padLeft(19, '0');
    final deviceId = 'eink334691225$suffix';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = _random.nextInt(1000);
    final response = await _dio.post<dynamic>(
      'https://i.weread.qq.com/login',
      options: Options(
        headers: _versionHeaders,
        contentType: 'application/json; charset=UTF-8',
      ),
      data: {
        'appFirstInstall': 1,
        'code': wxCode,
        'deviceId': deviceId,
        'deviceName': 'BOOX',
        'installId': 'eink31${_digits(26)}',
        'isAutoLogout': 0,
        'isFromQrcode': 1,
        'random': random,
        'signature': sha256
            .convert(utf8.encode('$timestamp$deviceId$random'))
            .toString(),
        'timestamp': timestamp,
        'trackId': '',
        'deviceType': 3,
      },
      cancelToken: cancelToken,
    );
    final result = _object(response.data);
    final vid = result['vid']?.toString() ?? '';
    final accessToken = result['accessToken'];
    final refreshToken = result['refreshToken'];
    bool validToken(dynamic token) =>
        token is String &&
        token.isNotEmpty &&
        !RegExp(r'[;\s\x00-\x1f\x7f]').hasMatch(token);
    if (!RegExp(r'^[0-9]+$').hasMatch(vid) ||
        vid == '0' ||
        !validToken(accessToken) ||
        !validToken(refreshToken)) {
      throw const QrLoginException('换取登录凭据失败，请重新扫码');
    }
    return QrLoginCredentials(
      vid: vid,
      accessToken: accessToken as String,
      refreshToken: refreshToken as String,
      deviceId: deviceId,
    );
  }

  Future<QrLoginCredentials> login({
    required CancelToken cancelToken,
    required void Function(QrLoginRequest) onQr,
    void Function(QrLoginStatus)? onStatus,
  }) async {
    final qr = await requestQr(cancelToken: cancelToken);
    onQr(qr);
    final code = await pollForCode(qr.uuid,
        cancelToken: cancelToken, onStatus: onStatus);
    return exchange(code, cancelToken: cancelToken);
  }
}
