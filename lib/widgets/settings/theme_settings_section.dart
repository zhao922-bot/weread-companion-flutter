import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_controller.dart';
import '../../services/font_service.dart';
import '../../theme/readamber_theme.dart';
import 'settings_section.dart';

class ThemeSettingsSection extends StatelessWidget {
  const ThemeSettingsSection({super.key});

  void _openFontSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _FontManagerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final activeFont = OpenSourceFont.byId(theme.fontId);

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
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.font_download_outlined),
        title: const Text('应用字体（开源可商用）'),
        subtitle: Text(
          activeFont == null ? '当前：系统默认（内置中文优化）' : '当前：${activeFont.name}',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _openFontSheet(context),
      ),
    ]);
  }
}

class _FontManagerSheet extends StatelessWidget {
  const _FontManagerSheet();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final palette = ReadAmberPalette.of(context);
    final downloading = theme.downloadingFontId != null;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.font_download_outlined, color: palette.amberText),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '开源可商用字体库',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '按需下载 · 即时生效',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
            ),
            if (theme.fontError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  theme.fontError!,
                  style: TextStyle(fontSize: 12, color: palette.error),
                ),
              ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: const Text('系统默认'),
                    subtitle: const Text('内置中文回退栈，不占用额外存储空间'),
                    trailing: theme.fontId == null
                        ? Icon(Icons.check_circle_rounded,
                            color: palette.amberText)
                        : null,
                    onTap: downloading ? null : () => theme.setFont(null),
                  ),
                  for (final font in OpenSourceFont.catalog) ...[
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _buildFontTile(theme, font, palette, downloading),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFontTile(
    ThemeController theme,
    OpenSourceFont font,
    ReadAmberPalette palette,
    bool anyDownloading,
  ) {
    final isDownloaded = theme.downloadedFonts.contains(font.id);
    final isSelected = theme.fontId == font.id;
    final isThisDownloading = theme.downloadingFontId == font.id;

    return ListTile(
      title: Text(font.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${font.description} · ${font.sizeHint}'),
          Text(
            font.license,
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
          if (isThisDownloading) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: theme.downloadProgress > 0 ? theme.downloadProgress : null,
            ),
          ],
        ],
      ),
      onTap: isDownloaded && !anyDownloading
          ? () => theme.setFont(font.id)
          : null,
      trailing: isThisDownloading
          ? Text(
              '${(theme.downloadProgress * 100).round()}%',
              style: TextStyle(fontSize: 12, color: palette.amberText),
            )
          : isDownloaded
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isSelected)
                      Icon(Icons.check_circle_rounded,
                          color: palette.amberText),
                    IconButton(
                      tooltip: '删除 ${font.name}',
                      icon: Icon(Icons.delete_outline,
                          size: 20, color: palette.muted),
                      onPressed:
                          anyDownloading ? null : () => theme.deleteFont(font),
                    ),
                  ],
                )
              : OutlinedButton.icon(
                  onPressed: anyDownloading
                      ? null
                      : () => theme.downloadAndApplyFont(font),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('下载'),
                ),
    );
  }
}
