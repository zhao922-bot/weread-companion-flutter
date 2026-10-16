import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:provider/provider.dart';
import '../../providers/app_config_provider.dart';
import '../../services/config.dart';
import 'settings_section.dart';

class AiSettingsSection extends StatefulWidget {
  final bool isActive;
  const AiSettingsSection({super.key, this.isActive = true});

  @override
  State<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends State<AiSettingsSection> {
  final _apiKey = TextEditingController();
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  AppConfigProvider? _provider;
  bool _applied = false;
  bool _obscure = true;
  int? _revision;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<AppConfigProvider>();
    if (identical(provider, _provider)) return;
    _provider?.removeListener(_onConfigChanged);
    _provider = provider;
    _applied = false;
    _revision = null;
    provider.addListener(_onConfigChanged);
    _syncConfig();
  }

  void _syncConfig() {
    final provider = _provider!;
    if (!provider.isLoaded) {
      _applied = false;
      _apiKey.clear();
      _baseUrl.clear();
      _model.clear();
      return;
    }
    if (_applied && _revision == provider.sessionRevision) return;
    _apiKey.text = provider.config.apiKey;
    _baseUrl.text = provider.config.baseUrl;
    _model.text = provider.config.modelName;
    _revision = provider.sessionRevision;
    _applied = true;
  }

  void _onConfigChanged() {
    // dispose removes this synchronous listener before releasing controllers.
    setState(_syncConfig);
  }

  @override
  void dispose() {
    _provider?.removeListener(_onConfigChanged);
    _apiKey.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  void _feedback(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (!AppConfig.isHttpsUrl(_baseUrl.text.trim())) {
      _feedback('AI 服务地址必须是有效的 HTTPS 地址');
      return;
    }
    try {
      await _provider!.updateAiConfig(
        apiKey: _apiKey.text, baseUrl: _baseUrl.text, modelName: _model.text,
      );
      if (!mounted) return;
      _feedback('AI 配置已保存');
    } catch (_) {
      if (!mounted) return;
      _feedback('AI 配置保存失败，请重试');
    }
  }

  String get _summary {
    final host = Uri.tryParse(_baseUrl.text.trim())?.host.toLowerCase() ?? '';
    final name = switch (host) {
      'api.deepseek.com' => 'DeepSeek',
      'dashscope.aliyuncs.com' => 'Qwen',
      'api.minimax.chat' || 'api.minimax.io' => 'MiniMax',
      'api.moonshot.cn' || 'api.moonshot.ai' => 'Moonshot',
      'api.siliconflow.cn' || 'api.siliconflow.com' => 'SiliconFlow',
      _ => '自定义服务',
    };
    return '$name · ${_model.text.trim().isEmpty ? '未设置模型' : _model.text.trim()}';
  }

  Widget _field(String label, TextEditingController controller, bool enabled,
      {bool secret = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: secret && _obscure,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: ReadAmberColors.surfaceMuted,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          suffixIcon: secret ? IconButton(
            onPressed: enabled ? () => setState(() => _obscure = !_obscure) : null,
            icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
          ) : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfigProvider>();
    if (!config.isLoaded || !_applied) {
      return SettingsSection(title: 'AI 配置', children: [
        ListTile(
          leading: config.configLoadError == null
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
              : const Icon(Icons.error_outline),
          title: Text(config.configLoadError ?? '正在加载配置…'),
          trailing: config.configLoadError != null ? TextButton(
            onPressed: config.isBusy ? null : config.init,
            child: const Text('重试'),
          ) : null,
        ),
      ]);
    }
    final enabled = !config.isBusy;
    const presets = [
      ('DeepSeek', 'https://api.deepseek.com', 'deepseek-chat', ReadAmberColors.ink),
      ('Qwen', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen3.6-plus', ReadAmberColors.ink),
      ('MiniMax', 'https://api.minimax.chat/v1', 'MiniMax-M2.7', ReadAmberColors.ink),
      ('Moonshot', 'https://api.moonshot.cn/v1', 'kimi-k2.5', ReadAmberColors.ink),
      ('SiliconFlow', 'https://api.siliconflow.cn/v1', 'deepseek-ai/DeepSeek-V4-Flash', ReadAmberColors.ink),
    ];
    return SettingsSection(title: 'AI 配置', children: [
      ExpansionTile(
        key: ValueKey(widget.isActive),
        initiallyExpanded: false,
        shape: const Border(), collapsedShape: const Border(),
        title: const Text('AI 配置'), subtitle: Text(_summary),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('快速预设'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final preset in presets)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: preset.$4),
                    onPressed: enabled ? () {
                      setState(() {
                        _baseUrl.text = preset.$2;
                        _model.text = preset.$3;
                      });
                      _feedback('已应用 ${preset.$1} 预设配置');
                    } : null,
                    child: Text(preset.$1),
                  ),
              ]),
            ]),
          ),
          const Divider(height: 1),
          _field('API Key', _apiKey, enabled, secret: true),
          _field('Base URL', _baseUrl, enabled),
          _field('模型名称', _model, enabled),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: enabled ? _save : null,
              child: config.isBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存配置'),
            )),
          ),
        ],
      ),
    ]);
  }
}
