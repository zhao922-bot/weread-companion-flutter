import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weread_companion/services/release_update_service.dart';
import 'package:weread_companion/theme/readamber_theme.dart';

import 'settings_section.dart';

class AboutSettingsSection extends StatefulWidget {
  final ReleaseUpdateService? updateService;

  const AboutSettingsSection({super.key, this.updateService});

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
        leading: Icon(icon, color: ReadAmberPalette.of(context).ink),
        title: Text(title),
        subtitle: Text(desc),
      );

  @override
  Widget build(BuildContext context) {
    final updateService = widget.updateService;
    return Column(children: [
      SettingsSection(title: '使用帮助', children: [
        _help(Icons.cookie_outlined, '导入 Cookie',
            '在电脑浏览器登录 weread.qq.com 后，F12 → Console 执行 copy(document.cookie)，粘贴到 App'),
        const Divider(height: 1, indent: 52),
        _help(Icons.sync_rounded, '同步书架', '导入 Cookie 后，在书架页下拉刷新即可同步所有书籍、划线和笔记'),
        const Divider(height: 1, indent: 52),
        _help(Icons.auto_awesome_rounded, 'AI 摘要',
            '在设置中配置 AI API Key 后，笔记页右上角可使用 AI 摘要功能'),
        const Divider(height: 1, indent: 52),
        _help(Icons.ios_share_rounded, '导出笔记',
            '笔记页右上角可导出所有笔记为 Markdown 文件并通过系统分享'),
      ]),
      const SizedBox(height: 24),
      SettingsSection(title: '关于', children: [
        ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/branding/readamber-v1/readamber-icon-128.png',
              width: 40,
              height: 40,
              semanticLabel: '阅珀应用图标',
            ),
          ),
          title: const Text('阅珀'),
          subtitle: const Text('ReadAmber · 让读过的，留下来。'),
          trailing: Text(_version ?? '读取版本中…'),
        ),
        const Divider(height: 1, indent: 70),
        ListTile(
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('检查更新'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _UpdateDialog(updateService: updateService),
          ),
        ),
      ]),
    ]);
  }
}

class _UpdateDialog extends StatefulWidget {
  final ReleaseUpdateService? updateService;

  const _UpdateDialog({this.updateService});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  late final _service = widget.updateService ?? ReleaseUpdateService();
  late CancelToken _request;
  late Future<AppUpdate?> _pending;
  bool _openingLink = false;
  bool _launchFailed = false;

  @override
  void initState() {
    super.initState();
    _pending = _check();
  }

  @override
  void dispose() {
    _request.cancel();
    if (widget.updateService == null) _service.dispose();
    super.dispose();
  }

  Future<AppUpdate?> _check() async {
    final request = _request = CancelToken();
    final info = await PackageInfo.fromPlatform();
    if (request.isCancelled) return null;
    return _service.check(info.version, defaultTargetPlatform,
        cancelToken: request);
  }

  Future<void> _open(Uri uri) async {
    setState(() {
      _openingLink = true;
      _launchFailed = false;
    });
    bool opened;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _openingLink = false;
      _launchFailed = !opened;
    });
  }

  Widget _content(AsyncSnapshot<AppUpdate?> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(),
          SizedBox(height: 12),
          Text('正在检查更新…'),
        ],
      );
    }
    if (snapshot.hasError) return const Text('无法检查更新，请稍后重试。');
    final update = snapshot.data;
    if (update == null) return const Text('暂无可用更新。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('发现新版本 ${update.version}'),
        const SizedBox(height: 12),
        SelectableText(update.notes.isEmpty ? '暂无发布说明。' : update.notes),
        if (update.download == null) ...[
          const SizedBox(height: 12),
          const Text('此版本暂无适用于当前平台的安装包。'),
        ],
        if (_launchFailed) ...[
          const SizedBox(height: 12),
          const Text('无法打开链接，请重试。'),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppUpdate?>(
        future: _pending,
        builder: (context, snapshot) {
          final checked = snapshot.connectionState == ConnectionState.done;
          final update = checked ? snapshot.data : null;
          return AlertDialog(
            scrollable: true,
            title: const Text('检查更新'),
            content: _content(snapshot),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              if (checked && snapshot.hasError)
                FilledButton(
                  onPressed: () {
                    final pending = _check();
                    setState(() {
                      _pending = pending;
                    });
                  },
                  child: const Text('重试'),
                ),
              if (update != null)
                TextButton(
                  onPressed:
                      _openingLink ? null : () => _open(update.releasePage),
                  child: const Text('打开发布页面'),
                ),
              if (update?.download case final download?)
                FilledButton(
                  onPressed: _openingLink ? null : () => _open(download.uri),
                  child: Text(download.label),
                ),
            ],
          );
        },
      );
}
