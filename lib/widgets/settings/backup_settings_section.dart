import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_config_provider.dart';
import '../../services/backup_service.dart';
import '../../services/export_service.dart';
import 'settings_section.dart';

/// 数据导出与本地 JSON 完整备份/恢复分区。
class BackupSettingsSection extends StatefulWidget {
  const BackupSettingsSection({super.key});

  @override
  State<BackupSettingsSection> createState() => _BackupSettingsSectionState();
}

class _BackupSettingsSectionState extends State<BackupSettingsSection> {
  bool _working = false;

  void _feedback(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() task, String successMessage) async {
    setState(() => _working = true);
    try {
      await task();
      if (mounted) _feedback(successMessage);
    } catch (e) {
      if (mounted) _feedback('操作失败: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _showRestoreDialog() async {
    var input = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复 JSON 备份'),
        content: TextFormField(
          minLines: 4,
          maxLines: 8,
          onChanged: (v) => input = v,
          decoration: const InputDecoration(
            hintText: '粘贴备份 JSON 内容…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('开始恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || input.trim().isEmpty || !mounted) return;
    await _run(() async {
      final result = await BackupService.restoreFromJson(input.trim());
      if (mounted) _feedback(result.summary);
    }, '备份恢复完成');
  }

  @override
  Widget build(BuildContext context) {
    final canBrowse = context.watch<AppConfigProvider>().canBrowseLocal;
    final enabled = canBrowse && !_working;
    return SettingsSection(
      title: '数据与备份',
      children: [
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('导出 Obsidian Markdown'),
          subtitle: const Text('包含 YAML Frontmatter 属性头'),
          enabled: enabled,
          onTap: enabled
              ? () => _run(
                    () => ExportService.exportAndShare(
                      obsidianFrontmatter: true,
                    ),
                    '已导出 Obsidian Markdown',
                  )
              : null,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('导出完整备份（JSON）'),
          subtitle: const Text('保留书架、划线、笔记、收藏状态与 AI 摘要历史'),
          enabled: enabled,
          onTap: enabled
              ? () => _run(BackupService.exportAndShare, '已导出完整 JSON 备份')
              : null,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.restore_outlined),
          title: const Text('从 JSON 恢复备份'),
          subtitle: const Text('导入之前导出的阅珀 JSON 备份'),
          enabled: enabled,
          onTap: enabled ? _showRestoreDialog : null,
        ),
      ],
    );
  }
}
