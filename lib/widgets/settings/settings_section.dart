import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';

class SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsSection({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(title, style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: ReadAmberPalette.of(context).muted, letterSpacing: 0.5,
          )),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ReadAmberPalette.of(context).outline, width: 0.7),
            boxShadow: [BoxShadow(
              color: ReadAmberColors.ink.withValues(alpha: 0.04),
              blurRadius: 8, offset: const Offset(0, 2),
            )],
          ),
          child: Material(
            color: ReadAmberPalette.of(context).surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}
