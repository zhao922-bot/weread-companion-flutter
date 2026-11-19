import 'package:flutter/material.dart';
import '../theme/readamber_theme.dart';

/// 阅珀品牌化筛选胶囊，提供点击水波纹、桌面端 Hover 态和语义标签。
class ReadAmberChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? selectedColor;
  final Color? selectedTextColor;
  final IconData? icon;

  const ReadAmberChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor,
    this.selectedTextColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    final bg = selected
        ? (selectedColor ?? palette.amber)
        : palette.surfaceMuted;
    final fg = selected
        ? (selectedTextColor ?? ReadAmberColors.ink)
        : palette.inkSoft;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
