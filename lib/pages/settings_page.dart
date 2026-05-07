import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_config_provider.dart';
import 'cookie_login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _apiKey = '';
  String _baseUrl = 'https://api.deepseek.com';
  String _modelName = 'deepseek-chat';
  bool _obscureApiKey = true;

  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _modelNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAiConfig();
  }

  void _loadAiConfig() {
    final appConfig = context.read<AppConfigProvider>();
    _apiKey = appConfig.config.apiKey;
    _baseUrl = appConfig.config.baseUrl.isNotEmpty
        ? appConfig.config.baseUrl
        : 'https://api.deepseek.com';
    _modelName = appConfig.config.modelName.isNotEmpty
        ? appConfig.config.modelName
        : 'deepseek-chat';
    _apiKeyController.text = _apiKey;
    _baseUrlController.text = _baseUrl;
    _modelNameController.text = _modelName;
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  void _applyPreset(String name, String baseUrl, String model) {
    setState(() {
      _baseUrl = baseUrl;
      _modelName = model;
      _baseUrlController.text = baseUrl;
      _modelNameController.text = model;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已应用 $name 预设配置'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 跳转到 Cookie 导入页面
  Future<void> _startWeChatLogin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const CookieLoginPage(),
      ),
    );
    // 返回后刷新状态
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppConfigProvider>(
      builder: (context, appConfig, _) {
        return Scaffold(
          backgroundColor: const Color(0xFFF5F5F5),
          appBar: AppBar(
            title: const Text('设置'),
            centerTitle: true,
            elevation: 0,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              // Account Section
              _SectionHeader(title: '账号'),
              _SettingsCard(
                children: [
                  if (appConfig.isLoggedIn) ...[
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF07C160),
                        child: const Icon(Icons.person, color: Colors.white, size: 20),
                      ),
                      title: Text(
                        appConfig.userName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: const Text(
                        '已登录',
                        style: TextStyle(fontSize: 13),
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('确认退出'),
                              content: const Text('退出登录后将清除所有本地数据，确定要退出吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.red,
                                  ),
                                  child: const Text('退出'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true && mounted) {
                            await appConfig.logout();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已退出登录'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            }
                          }
                        },
                        child: const Text(
                          '退出登录',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  ] else ...[
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF07C160).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.cookie_outlined,
                          color: Color(0xFF07C160),
                          size: 24,
                        ),
                      ),
                      title: const Text(
                        '导入 Cookie',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: const Text(
                        '导入后即可同步微信读书数据',
                        style: TextStyle(fontSize: 12),
                      ),
                      trailing: ElevatedButton(
                        onPressed: _startWeChatLogin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF07C160),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        ),
                        child: const Text('登录'),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 24),

              // AI Config Section
              _SectionHeader(title: 'AI 配置'),
              _SettingsCard(
                children: [
                  // Preset buttons
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '快速预设',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[500],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _PresetButton(
                              label: 'DeepSeek',
                              color: const Color(0xFF4D6BFE),
                              onTap: () => _applyPreset(
                                'DeepSeek',
                                'https://api.deepseek.com',
                                'deepseek-chat',
                              ),
                            ),
                            _PresetButton(
                              label: 'Qwen',
                              color: const Color(0xFF6C3BF5),
                              onTap: () => _applyPreset(
                                '通义千问',
                                'https://dashscope.aliyuncs.com/compatible-mode/v1',
                                'qwen3.6-plus',
                              ),
                            ),
                            _PresetButton(
                              label: 'MiniMax',
                              color: const Color(0xFF00B4D8),
                              onTap: () => _applyPreset(
                                'MiniMax',
                                'https://api.minimax.chat/v1',
                                'MiniMax-M2.7',
                              ),
                            ),
                            _PresetButton(
                              label: 'Moonshot',
                              color: const Color(0xFF1A1A2E),
                              onTap: () => _applyPreset(
                                'Moonshot',
                                'https://api.moonshot.cn/v1',
                                'kimi-k2.5',
                              ),
                            ),
                            _PresetButton(
                              label: 'SiliconFlow',
                              color: const Color(0xFFFF6B35),
                              onTap: () => _applyPreset(
                                'SiliconFlow',
                                'https://api.siliconflow.cn/v1',
                                'deepseek-ai/DeepSeek-V4-Flash',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // API Key
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Text(
                      'API Key',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _apiKeyController,
                      obscureText: _obscureApiKey,
                      decoration: InputDecoration(
                        hintText: '输入 API Key',
                        hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                        filled: true,
                        fillColor: const Color(0xFFF8F8F8),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureApiKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                          onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                      onChanged: (value) => _apiKey = value,
                    ),
                  ),
                  // Base URL
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Base URL',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _baseUrlController,
                      decoration: InputDecoration(
                        hintText: '输入 Base URL',
                        hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                        filled: true,
                        fillColor: const Color(0xFFF8F8F8),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                      onChanged: (value) => _baseUrl = value,
                    ),
                  ),
                  // Model Name
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      '模型名称',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: TextField(
                      controller: _modelNameController,
                      decoration: InputDecoration(
                        hintText: '输入模型名称',
                        hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                        filled: true,
                        fillColor: const Color(0xFFF8F8F8),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                      onChanged: (value) => _modelName = value,
                    ),
                  ),
                  // Save button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          await appConfig.updateAiConfig(
                            apiKey: _apiKey,
                            baseUrl: _baseUrl,
                            modelName: _modelName,
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('AI 配置已保存'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2196F3),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text(
                          '保存配置',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Help Section
              _SectionHeader(title: '使用帮助'),
              _SettingsCard(
                children: [
                  _helpItem(Icons.cookie_outlined, '导入 Cookie', '在电脑浏览器登录 weread.qq.com 后，F12 → Console 执行 copy(document.cookie)，粘贴到 App'),
                  const Divider(height: 1, indent: 52),
                  _helpItem(Icons.sync_rounded, '同步书架', '导入 Cookie 后，在书架页下拉刷新即可同步所有书籍、划线和笔记'),
                  const Divider(height: 1, indent: 52),
                  _helpItem(Icons.auto_awesome_rounded, 'AI 摘要', '在设置中配置 AI API Key 后，笔记页右上角可使用 AI 摘要功能'),
                  const Divider(height: 1, indent: 52),
                  _helpItem(Icons.ios_share_rounded, '导出笔记', '笔记页右上角可导出所有笔记为 Markdown 文件并通过系统分享'),
                ],
              ),

              const SizedBox(height: 24),

              // About Section
              _SectionHeader(title: '关于'),
              _SettingsCard(
                children: [
                  ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2196F3).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.auto_stories_rounded,
                        color: Color(0xFF2196F3),
                        size: 24,
                      ),
                    ),
                    title: const Text(
                      '微信读书伴侣',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'WeRead Companion',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2196F3).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'v2.1.0',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2196F3),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 70),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded, size: 22),
                    title: const Text('检查更新', style: TextStyle(fontSize: 14)),
                    trailing: Icon(Icons.chevron_right_rounded, color: Colors.grey[400]),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('当前已是最新版本 v2.1.0'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey[500],
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(children: children),
      ),
    );
  }
}

class _PresetButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _PresetButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _helpItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;

  const _helpItem(this.icon, this.title, this.desc);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF4A7CF7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
