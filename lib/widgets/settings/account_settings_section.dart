import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:provider/provider.dart';
import '../../pages/cookie_login_page.dart';
import '../../providers/app_config_provider.dart';
import 'settings_section.dart';

class AccountSettingsSection extends StatelessWidget {
  const AccountSettingsSection({super.key});

  Future<void> _continueCleanup(BuildContext context, AppConfigProvider config) async {
    try {
      await config.logout();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地数据清理完成')),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(config.loginError ?? '清理失败，请重试')),
      );
    }
  }

  Future<void> _logout(BuildContext context, AppConfigProvider config) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认退出'),
        content: const Text('退出登录后将清除所有本地数据，确定要退出吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: ReadAmberPalette.of(context).error),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    try {
      await config.logout();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已退出登录')),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('退出登录失败，部分本地数据可能未清除，请重试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfigProvider>();
    final enabled = config.isLoaded && !config.isBusy;
    void login() => Navigator.push(context,
      MaterialPageRoute(builder: (_) => const CookieLoginPage()));
    return SettingsSection(title: '账号', children: [
      if (config.cleanupPending)
        ListTile(
          leading: Icon(Icons.delete_outline, color: ReadAmberPalette.of(context).error),
          title: const Text('清理未完成'),
          subtitle: Text(config.loginError ?? '请继续清除本地数据'),
          trailing: TextButton(
            onPressed: config.isBusy ? null : () => _continueCleanup(context, config),
            child: const Text('继续清理'),
          ),
        )
      else if (config.hasSavedCredentials || config.canBrowseLocal)
        ListTile(
          leading: CircleAvatar(
            backgroundColor: ReadAmberPalette.of(context).action,
            child: Icon(Icons.person, color: ReadAmberPalette.of(context).surface, size: 20),
          ),
          title: Text(config.userName.isEmpty ? '微信读书账号' : config.userName),
          subtitle: Text(config.loginStatusText),
          onTap: enabled ? login : null,
          trailing: TextButton(
            // 加载失败时仍允许退出可信本地账号。
            onPressed: config.isBusy ? null : () => _logout(context, config),
            style: TextButton.styleFrom(foregroundColor: ReadAmberPalette.of(context).error),
            child: const Text('退出登录'),
          ),
        )
      else
        ListTile(
          leading: Icon(Icons.cookie_outlined, color: ReadAmberPalette.of(context).ink),
          title: const Text('导入 Cookie'),
          subtitle: const Text('导入后即可同步微信读书数据'),
          trailing: ElevatedButton(
            onPressed: enabled ? login : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: ReadAmberPalette.of(context).action, foregroundColor: ReadAmberPalette.of(context).onAction,
            ),
            child: const Text('登录'),
          ),
        ),
    ]);
  }
}
