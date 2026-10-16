import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_config_provider.dart';
import 'qr_login_page.dart';
import '../services/qr_login_service.dart';

/// 登录页面 —— Cookie 导入及扫码登录入口
class CookieLoginPage extends StatefulWidget {
  final QrLoginService Function()? qrServiceFactory;
  const CookieLoginPage({super.key, this.qrServiceFactory});

  @override
  State<CookieLoginPage> createState() => _CookieLoginPageState();
}

class _CookieLoginPageState extends State<CookieLoginPage> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _submitting = false;
  int _pasteRequest = 0;

  bool get _isActive => mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    if (_submitting || !_isActive) return;
    final request = ++_pasteRequest;
    final input = _controller.value;
    bool isCurrent() => _isActive && !_submitting && request == _pasteRequest &&
        _controller.value == input;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!isCurrent()) return;
      final text = data?.text?.trim() ?? '';
      if (text.isNotEmpty) {
        _controller.text = text;
      } else {
        _showMsg('剪贴板为空', isError: true);
      }
    } catch (_) {
      if (isCurrent()) _showMsg('读取剪贴板失败，请重试', isError: true);
    }
  }

  Future<void> _copyCommand() async {
    try {
      await Clipboard.setData(const ClipboardData(text: 'copy(document.cookie)'));
      if (!mounted || !_isActive) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('代码已复制'), duration: Duration(seconds: 1)),
      );
    } catch (_) {
      if (mounted) _showMsg('复制失败，请重试', isError: true);
    }
  }

  Future<void> _submit() async {
    if (!_isActive || context.read<AppConfigProvider>().isBusy) return;
    final cookie = _controller.text.trim();

    if (cookie.isEmpty) {
      _showMsg('请输入 Cookie', isError: true);
      return;
    }
    if (_submitting) return;
    _pasteRequest++;
    final appConfig = context.read<AppConfigProvider>();
    setState(() => _submitting = true);
    try {
      await appConfig.loginWithCookie(cookie);
      if (!mounted || !_isActive) return;
      if (appConfig.isLoggedIn) {
        _showMsg('验证成功');
        Navigator.pop(context);
      } else {
        _showMsg(appConfig.loginError ?? appConfig.loginStatusText,
          isError: appConfig.loginStatus == LoginStatus.invalid);
      }
    } on FormatException catch (e) {
      if (mounted) _showMsg(e.message, isError: true);
    } catch (_) {
      if (mounted) _showMsg('导入失败，请重试', isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    if (!_isActive) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? ReadAmberPalette.of(context).error : null),
    );
  }

  Future<void> _openQrLogin() async {
    if (!_isActive || _submitting || context.read<AppConfigProvider>().isBusy) return;
    _pasteRequest++;
    final navigator = Navigator.of(context);
    final success = await navigator.push<bool>(MaterialPageRoute(
      builder: (_) => QrLoginPage(serviceFactory: widget.qrServiceFactory),
    ));
    if (_isActive && success == true) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: _buildForm(context),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Scaffold(
      backgroundColor: ReadAmberPalette.of(context).canvas,
      appBar: AppBar(
        title: const Text('导入 Cookie'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: ReadAmberPalette.of(context).canvas,
        foregroundColor: ReadAmberPalette.of(context).ink,
      ),
      body: ReadAmberContent(maxWidth: 720, child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 16),
          // 图标
          Center(
            child: Column(
              children: [
                Icon(Icons.cookie_outlined, size: 56, color: ReadAmberPalette.of(context).ink),
                SizedBox(height: 12),
                Text(
                  '导入微信读书 Cookie',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 6),
                Text(
                  '支持普通文本和 JSON 格式（Cookie-Editor 导出）',
                  style: TextStyle(fontSize: 14, color: ReadAmberPalette.of(context).muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // 操作步骤
          _buildStepCard(),
          const SizedBox(height: 20),

          // 输入框
          Container(
            decoration: BoxDecoration(
              color: ReadAmberPalette.of(context).surface,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(color: ReadAmberColors.ink.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
              ],
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cookie 内容', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  maxLines: _obscure ? 1 : 6,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_submitting,
                  decoration: InputDecoration(
                    hintText: 'wr_vid=xxx; wr_skey=xxx; ... 或 Cookie-Editor JSON 格式',
                    hintStyle: TextStyle(fontSize: 13, color: ReadAmberPalette.of(context).muted),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: ReadAmberPalette.of(context).surfaceMuted,
                    contentPadding: const EdgeInsets.all(14),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 20),
                          onPressed: () => setState(() => _obscure = !_obscure),
                          tooltip: _obscure ? '显示' : '隐藏',
                        ),
                        IconButton(
                          icon: const Icon(Icons.paste_rounded, size: 20),
                          onPressed: _submitting ? null : _pasteFromClipboard,
                          tooltip: '从剪贴板粘贴',
                        ),
                      ],
                    ),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 提交按钮
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _submitting || context.watch<AppConfigProvider>().isBusy ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: ReadAmberPalette.of(context).action,
                foregroundColor: ReadAmberPalette.of(context).onAction,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(_submitting ? '正在验证…' : '确认导入并验证', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),

          OutlinedButton.icon(
            onPressed: _submitting || context.watch<AppConfigProvider>().isBusy
                ? null
                : _openQrLogin,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('扫码登录'),
          ),
          const SizedBox(height: 12),

          Consumer<AppConfigProvider>(
            builder: (_, config, __) => Center(child: Text(config.loginStatusText)),
          ),

          // 提示
          Center(
            child: Text(
              '导入后请到书架页点击同步按钮获取数据',
              style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
            ),
          ),
        ],
      )),
    );
  }

  Widget _buildStepCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ReadAmberPalette.of(context).paper,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.computer_rounded, size: 18, color: ReadAmberPalette.of(context).ink),
              const SizedBox(width: 6),
              Text(
                '电脑端操作步骤',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ReadAmberPalette.of(context).ink),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _step(1, '打开浏览器', 'Chrome / Edge 访问 weread.qq.com'),
          _step(2, '微信登录', '扫码登录你的微信读书账号'),
          _step(3, '打开开发者工具', '按 F12，切换到 Console（控制台）'),
          _step(4, '复制 Cookie', '输入以下代码并回车：'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _copyCommand,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: ReadAmberColors.ink,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'copy(document.cookie)',
                    style: TextStyle(color: ReadAmberColors.amber, fontSize: 14, fontFamily: 'monospace'),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: ReadAmberColors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('点击复制', style: TextStyle(color: ReadAmberColors.amber, fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          _step(5, '传到手机', '将复制的内容发送到手机（微信/QQ），粘贴到上方输入框'),
        ],
      ),
    );
  }

  Widget _step(int num, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(color: ReadAmberPalette.of(context).ink, shape: BoxShape.circle),
            child: Center(
              child: Text('$num', style: TextStyle(color: ReadAmberPalette.of(context).surface, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  fontSize: 13, color: ReadAmberPalette.of(context).ink, height: 1.4),
                children: [
                  TextSpan(text: title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const TextSpan(text: '  '),
                  TextSpan(text: desc, style: TextStyle(color: ReadAmberPalette.of(context).muted)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
