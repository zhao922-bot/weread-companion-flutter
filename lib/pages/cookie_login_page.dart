import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_config_provider.dart';

/// 登录页面 —— 仅支持 Cookie 导入
class CookieLoginPage extends StatefulWidget {
  const CookieLoginPage({super.key});

  @override
  State<CookieLoginPage> createState() => _CookieLoginPageState();
}

class _CookieLoginPageState extends State<CookieLoginPage> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) {
      setState(() => _controller.text = text);
    } else {
      _showMsg('剪贴板为空', isError: true);
    }
  }

  Future<void> _submit() async {
    final cookie = _controller.text.trim();

    if (cookie.isEmpty) {
      _showMsg('请输入 Cookie', isError: true);
      return;
    }
    if (cookie.length < 20) {
      _showMsg('Cookie 内容过短，请检查', isError: true);
      return;
    }

    // 保存
    final appConfig = context.read<AppConfigProvider>();
    await appConfig.loginWithCookie(cookie);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cookie 已保存'), backgroundColor: Color(0xFF07C160)),
      );
      Navigator.pop(context);
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? Colors.red : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('导入 Cookie'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 16),
          // 图标
          const Center(
            child: Column(
              children: [
                Icon(Icons.cookie_outlined, size: 56, color: Color(0xFF4A7CF7)),
                SizedBox(height: 12),
                Text(
                  '导入微信读书 Cookie',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 6),
                Text(
                  '支持普通文本和 JSON 格式（Cookie-Editor 导出）',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
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
                  maxLines: 6,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    hintText: 'wr_vid=xxx; wr_skey=xxx; ... 或 Cookie-Editor JSON 格式',
                    hintStyle: TextStyle(fontSize: 13, color: Colors.grey[400]),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: const Color(0xFFF8F8F8),
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
                          onPressed: _pasteFromClipboard,
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
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF07C160),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('确认导入', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),

          // 提示
          Center(
            child: Text(
              '导入后请到书架页点击同步按钮获取数据',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.computer_rounded, size: 18, color: Colors.blue.shade700),
              const SizedBox(width: 6),
              Text(
                '电脑端操作步骤',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.blue.shade700),
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
            onTap: () {
              Clipboard.setData(const ClipboardData(text: 'copy(document.cookie)'));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('代码已复制'), duration: Duration(seconds: 1)),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Text(
                    'copy(document.cookie)',
                    style: TextStyle(color: Color(0xFF569CD6), fontSize: 14, fontFamily: 'monospace'),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('点击复制', style: TextStyle(color: Colors.blue, fontSize: 11)),
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
            decoration: const BoxDecoration(color: Color(0xFF4A7CF7), shape: BoxShape.circle),
            child: Center(
              child: Text('$num', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.4),
                children: [
                  TextSpan(text: title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const TextSpan(text: '  '),
                  TextSpan(text: desc, style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
