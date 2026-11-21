import 'package:flutter/material.dart';
import '../services/database.dart';
import 'account_session_guard.dart';

class ReadingTagPicker extends StatefulWidget {
  const ReadingTagPicker({super.key, required this.database, this.selectedTag});

  final DatabaseService database;
  final String? selectedTag;

  @override
  State<ReadingTagPicker> createState() => _ReadingTagPickerState();
}

class _ReadingTagPickerState extends State<ReadingTagPicker> {
  late Future<List<String>> _tags = widget.database.getReadingTags();

  @override
  Widget build(BuildContext context) => AccountSessionGuard(
        database: widget.database,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('按标签筛选',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.all_inbox_outlined),
                title: const Text('全部标签'),
                selected: widget.selectedTag == null,
                onTap: () => Navigator.pop(context, (tag: null as String?)),
              ),
              Flexible(
                child: FutureBuilder<List<String>>(
                  future: _tags,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      );
                    }
                    if (snapshot.hasError) {
                      return TextButton(
                        onPressed: () => setState(() {
                          _tags = widget.database.getReadingTags();
                        }),
                        child: const Text('标签加载失败，点击重试'),
                      );
                    }
                    final tags = snapshot.data!;
                    if (tags.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂无标签'),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: tags.length,
                      itemBuilder: (context, index) {
                        final tag = tags[index];
                        return ListTile(
                          leading: const Icon(Icons.label_outline),
                          title: Text(tag),
                          selected: widget.selectedTag == tag,
                          onTap: () => Navigator.pop(context, (tag: tag)),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
}

class ReadingTagsEditor extends StatefulWidget {
  const ReadingTagsEditor({
    super.key,
    required this.database,
    required this.tags,
    required this.onSave,
  });

  final DatabaseService database;
  final List<String> tags;
  final Future<void> Function(Set<String>) onSave;

  @override
  State<ReadingTagsEditor> createState() => _ReadingTagsEditorState();
}

class _ReadingTagsEditorState extends State<ReadingTagsEditor> {
  late final Set<String> _tags = widget.tags.toSet();
  final TextEditingController _input = TextEditingController();
  bool _saving = false;
  Object? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _addTag() {
    final tag = _input.text.trim();
    if (tag.isEmpty) return;
    setState(() => _tags.add(tag));
    _input.clear();
  }

  Future<void> _save() async {
    if (_saving) return;
    _addTag();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_tags);
      if (mounted && widget.database.isActive) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AccountSessionGuard(
        database: widget.database,
        child: AlertDialog(
          title: const Text('编辑标签'),
          scrollable: true,
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in _tags)
                      InputChip(
                        label: Text(tag,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        deleteButtonTooltipMessage: '移除 $tag',
                        onDeleted: _saving
                            ? null
                            : () => setState(() => _tags.remove(tag)),
                      ),
                  ],
                ),
                TextField(
                  controller: _input,
                  enabled: !_saving,
                  onSubmitted: (_) => _addTag(),
                  decoration: InputDecoration(
                    labelText: '新标签',
                    suffixIcon: IconButton(
                      tooltip: '添加标签',
                      onPressed: _saving ? null : _addTag,
                      icon: const Icon(Icons.add),
                    ),
                    errorText: _error == null ? null : '保存标签失败：$_error',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
          ],
        ),
      );
}
