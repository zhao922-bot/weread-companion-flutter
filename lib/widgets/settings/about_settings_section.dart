import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'settings_section.dart';

class AboutSettingsSection extends StatefulWidget {
  const AboutSettingsSection({super.key});

  @override
  State<AboutSettingsSection> createState() => _AboutSettingsSectionState();
}

class _AboutSettingsSectionState extends State<AboutSettingsSection> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = 'v${info.version}');
    } catch (_) {
      if (mounted) setState(() => _version = '版本读取失败');
    }
  }

  Widget _help(IconData icon, String title, String desc) => ListTile(
    leading: Icon(icon, color: const Color(0xFF4A7CF7)),
    title: Text(title), subtitle: Text(desc),
  );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SettingsSection(title: '使用帮助', children: [
        _help(Icons.cookie_outlined, '导入 Cookie', '在电脑浏览器登录 weread.qq.com 后，F12 → Console 执行 copy(document.cookie)，粘贴到 App'),
        const Divider(height: 1, indent: 52),
        _help(Icons.sync_rounded, '同步书架', '导入 Cookie 后，在书架页下拉刷新即可同步所有书籍、划线和笔记'),
        const Divider(height: 1, indent: 52),
        _help(Icons.auto_awesome_rounded, 'AI 摘要', '在设置中配置 AI API Key 后，笔记页右上角可使用 AI 摘要功能'),
        const Divider(height: 1, indent: 52),
        _help(Icons.ios_share_rounded, '导出笔记', '笔记页右上角可导出所有笔记为 Markdown 文件并通过系统分享'),
      ]),
      const SizedBox(height: 24),
      SettingsSection(title: '关于', children: [
        ListTile(
          leading: const Icon(Icons.auto_stories_rounded, color: Color(0xFF2196F3)),
          title: const Text('微信读书伴侣'),
          subtitle: const Text('WeRead Companion'),
          trailing: Text(_version ?? '读取版本中…'),
        ),
        const Divider(height: 1, indent: 70),
        ListTile(
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('检查更新'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('当前版本：${_version ?? '读取版本中…'}')),
          ),
        ),
      ]),
    ]);
  }
}
