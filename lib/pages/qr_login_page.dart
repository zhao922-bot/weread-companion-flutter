import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/app_config_provider.dart';
import '../services/qr_login_service.dart';

class QrLoginPage extends StatefulWidget {
  /// Creates a service owned and disposed by this page.
  final QrLoginService Function()? serviceFactory;
  const QrLoginPage({super.key, this.serviceFactory});

  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  late final _service = widget.serviceFactory?.call() ?? QrLoginService();
  CancelToken? _cancelToken;
  String? _confirmUrl;
  String _status = '正在获取二维码…';
  bool _failed = false;
  bool _saving = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startLogin();
    });
  }

  @override
  void dispose() {
    _cancelToken?.cancel('登录页面已关闭');
    _service.dispose();
    super.dispose();
  }

  bool _isCurrent(CancelToken token) =>
      mounted && identical(token, _cancelToken) && !token.isCancelled;

  Future<void> _startLogin() async {
    if (_running) return;
    _running = true;
    final config = context.read<AppConfigProvider>();
    _cancelToken?.cancel('重新扫码');
    final token = CancelToken();
    _cancelToken = token;
    setState(() {
      _confirmUrl = null;
      _status = '正在获取二维码…';
      _failed = false;
    });
    try {
      final credentials = await _service.login(
        cancelToken: token,
        onQr: (qr) {
          if (!_isCurrent(token)) return;
          setState(() {
            _confirmUrl = qr.confirmUrl;
            _status = '待扫码：请使用微信扫描二维码';
          });
        },
        onStatus: (status) {
          if (!_isCurrent(token)) return;
          final next = switch (status) {
            QrLoginStatus.waiting => '待扫码：请使用微信扫描二维码',
            QrLoginStatus.scanned => '已扫码：请在微信中确认登录',
            QrLoginStatus.confirmed => '已确认：正在获取登录凭据…',
          };
          if (_status != next) setState(() => _status = next);
        },
      );
      if (!_isCurrent(token)) return;
      setState(() {
        _saving = true;
        _confirmUrl = null;
        _status = '已确认：正在安全保存凭据并验证账号…';
      });
      await config.loginWithCredentials(credentials);
      if (!mounted || !_isCurrent(token)) return;
      if (!config.isLoggedIn) {
        throw QrLoginException(config.loginError ?? config.loginStatusText);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('扫码登录验证成功')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!_isCurrent(token)) return;
      setState(() {
        _failed = true;
        _confirmUrl = null;
        _status = error is QrLoginException
            ? '${error.expired ? '过期' : '失败'}：${error.message}'
            : error is DioException
                ? '失败：网络请求失败，请检查网络后重试'
                : '失败：无法保存或验证登录凭据，请重试';
      });
    } finally {
      if (mounted && identical(token, _cancelToken)) {
        setState(() {
          _saving = false;
          _running = false;
        });
      }
    }
  }

  void _cancel() {
    _cancelToken?.cancel('用户取消登录');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        // A popped route stays mounted during its reverse animation.
        if (didPop) _cancelToken?.cancel('登录页面已退出');
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(
          title: const Text('微信读书扫码登录'),
          centerTitle: true,
          leading: IconButton(
            onPressed: _saving ? null : _cancel,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.qr_code_scanner,
                    size: 48, color: Color(0xFF07C160)),
                const SizedBox(height: 20),
                if (_confirmUrl != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: QrImageView(
                      data: _confirmUrl!,
                      size: 240,
                      backgroundColor: Colors.white,
                      semanticsLabel: '微信读书登录二维码',
                    ),
                  )
                else if (!_failed)
                  const Padding(
                    padding: EdgeInsets.all(48),
                    child: CircularProgressIndicator(),
                  ),
                const SizedBox(height: 24),
                Text(_status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 16,
                        color: _failed ? Colors.red : Colors.black87)),
                const SizedBox(height: 12),
                const Text('二维码 5 分钟内有效，可使用另一台设备上的微信扫描',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 24),
                if (_failed)
                  ElevatedButton.icon(
                    onPressed:
                        _saving || context.watch<AppConfigProvider>().isBusy
                            ? null
                            : _startLogin,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试 / 重新扫码'),
                  ),
                TextButton(
                  onPressed: _saving ? null : _cancel,
                  child: const Text('取消登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
