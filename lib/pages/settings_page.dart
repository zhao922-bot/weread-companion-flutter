import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import '../widgets/settings/account_settings_section.dart';
import '../widgets/settings/ai_settings_section.dart';
import '../widgets/settings/about_settings_section.dart';
import '../widgets/settings/theme_settings_section.dart';

class SettingsPage extends StatelessWidget {
  final bool isActive;

  const SettingsPage({super.key, this.isActive = true});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ReadAmberPalette.of(context).canvas,
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: ReadAmberPalette.of(context).canvas,
        foregroundColor: ReadAmberPalette.of(context).ink,
      ),
      body: ReadAmberContent(maxWidth: 840, child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const AccountSettingsSection(),
          const SizedBox(height: 24),
          const ThemeSettingsSection(),
          const SizedBox(height: 24),
          AiSettingsSection(isActive: isActive),
          const SizedBox(height: 24),
          const AboutSettingsSection(),
        ],
      )),
    );
  }
}
