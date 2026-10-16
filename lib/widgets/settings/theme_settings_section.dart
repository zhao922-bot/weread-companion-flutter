import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_controller.dart';
import 'settings_section.dart';

class ThemeSettingsSection extends StatelessWidget {
  const ThemeSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return SettingsSection(title: '外观', children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('应用主题'),
          const SizedBox(height: 8),
          DropdownButtonFormField<ThemeMode>(
            key: ValueKey((theme.mode, theme.isBusy, theme.error)),
            initialValue: theme.mode,
            isExpanded: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.palette_outlined),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            items: const [
              DropdownMenuItem(value: ThemeMode.light, child: Text('纸白浅色')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('墨青深色')),
              DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
            ],
            onChanged: theme.isBusy ? null : (mode) => theme.setMode(mode!),
          ),
          if (theme.error != null) ...[
            const SizedBox(height: 8),
            Text(theme.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(onPressed: theme.load, child: const Text('重新读取')),
          ],
        ]),
      ),
    ]);
  }
}
