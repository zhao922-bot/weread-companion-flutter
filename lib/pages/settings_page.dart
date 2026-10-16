import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import '../widgets/settings/account_settings_section.dart';
import '../widgets/settings/ai_settings_section.dart';
import '../widgets/settings/about_settings_section.dart';

class SettingsPage extends StatelessWidget {
  final bool isActive;

  const SettingsPage({super.key, this.isActive = true});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ReadAmberColors.canvas,
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: ReadAmberColors.canvas,
        foregroundColor: ReadAmberColors.ink,
      ),
      body: ReadAmberContent(maxWidth: 840, child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const AccountSettingsSection(),
          const SizedBox(height: 24),
          AiSettingsSection(isActive: isActive),
          const SizedBox(height: 24),
          const AboutSettingsSection(),
        ],
      )),
    );
  }
}
