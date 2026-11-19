import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/ai_summary.dart';
import '../providers/notes_provider.dart';
import '../services/ai_service.dart';
import '../services/config.dart';
import '../services/database.dart';
import '../theme/readamber_theme.dart';
import '../utils/date_format.dart';
import '../widgets/account_session_guard.dart';
import 'notes_page.dart';

/// 弹出摘要风格选择（返回 null 表示用户取消）。
Future<SummaryStyle?> pickSummaryStyle(BuildContext context) {
  return showModalBottomSheet<SummaryStyle>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('选择 AI 摘要风格',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          for (final style in SummaryStyle.values)
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text(style.label),
              onTap: () => Navigator.pop(sheetContext, style),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<void> generateSummary(
  BuildContext context,
  String title,
  String author,
  List<NoteItem> notes, {
  DatabaseService? database,
  AIService Function(AppConfig)? serviceFactory,
  SummaryStyle style = SummaryStyle.standard,
  bool stream = false,
}) async {
  final DatabaseService owner;
  try {
    owner = database ?? DatabaseService.instance;
  } on StateError {
    return;
  }
  if (!context.mounted || !owner.isActive) return;
  final config = AppConfig();
  try {
    await config.load();
  } catch (e) {
    if (context.mounted && owner.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI 配置加载失败: $e')));
    }
    return;
  }
  if (!context.mounted || !owner.isActive) return;
  final service = serviceFactory?.call(config) ?? AIService(config: config);
  if (!service.isConfigured || notes.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(notes.isEmpty ? '暂无划线和笔记可摘要' : '请先在设置中配置 AI API')));
    return;
  }
  // 持有具体路由，避免异步完成时误弹出其他页面；支持流式预览与手动取消。
  final navigator = Navigator.of(context, rootNavigator: true);
  final cancelToken = CancelToken();
  final preview = ValueNotifier<String>('');
  final loading = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('AI 正在生成摘要...', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: ValueListenableBuilder<String>(
          valueListenable: preview,
          builder: (_, text, __) => text.isEmpty
              ? const Text('正在整理划线与引文，请稍候…')
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (!cancelToken.isCancelled) cancelToken.cancel('用户手动取消');
            },
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );
  navigator.push(loading);
  AISummary? result;
  Object? error;
  try {
    result = await service.summarizeBook(
      title,
      author,
      notes,
      style: style,
      cancelToken: cancelToken,
      onDelta: stream ? (chunk) => preview.value += chunk : null,
    );
  } catch (e) {
    error = e;
  } finally {
    if (navigator.mounted && loading.isActive) navigator.removeRoute(loading);
    preview.dispose();
  }
  if (!context.mounted || !owner.isActive) return;
  if (result == null || error != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('AI 摘要生成或保存失败: ${error ?? '未返回摘要'}')));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AISummaryPage(summary: result!, database: owner)));
}

class AISummaryPage extends StatefulWidget {
  final AISummary summary;
  final DatabaseService? database;
  const AISummaryPage({super.key, required this.summary, this.database});

  @override
  State<AISummaryPage> createState() => _AISummaryPageState();
}

class _AISummaryPageState extends State<AISummaryPage> {
  late final DatabaseService _database =
      widget.database ?? DatabaseService.instance;
  AISummary get summary => widget.summary;

  Future<void> _copy() async {
    if (!mounted || !_database.isActive) return;
    try {
      await Clipboard.setData(ClipboardData(
          text:
              '${summary.coverage}\n${summary.text}\n${summary.references.map((r) => '[${r.label}] ${r.bookTitle} · ${r.chapterTitle} · ${r.source.name}:${r.noteId}').join('\n')}'));
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已复制摘要'), duration: Duration(seconds: 1)));
      }
    } catch (_) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  void _openReference(BuildContext context, SummaryReference reference) {
    if (!mounted || !_database.isActive) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NotesPage(reference: reference, database: _database)));
  }

  List<InlineSpan> _buildInlineSpans(BuildContext context, String text) {
    final palette = ReadAmberPalette.of(context);
    final spans = <InlineSpan>[];
    final tokenPattern = RegExp(r'(\*\*[^*]+\*\*|\[R\d+\])');
    var offset = 0;
    for (final match in tokenPattern.allMatches(text)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: TextStyle(fontWeight: FontWeight.w600, color: palette.ink),
        ));
      } else {
        final label = token.substring(1, token.length - 1);
        final refs = summary.references.where((r) => r.label == label);
        spans.add(refs.isEmpty
            ? TextSpan(text: '$token（引用不存在）')
            : WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: TextButton(
                    onPressed: () => _openReference(context, refs.first),
                    style: TextButton.styleFrom(
                      backgroundColor: palette.paper,
                      foregroundColor: palette.amberText,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: Text(
                      token,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ));
      }
      offset = match.end;
    }
    if (offset < text.length) {
      spans.add(TextSpan(text: text.substring(offset)));
    }
    return spans;
  }

  List<Widget> _buildMarkdownBody(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    final widgets = <Widget>[];
    for (final rawLine in summary.text.split('\n')) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
        continue;
      }
      final heading = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: SelectableText.rich(
            TextSpan(children: _buildInlineSpans(context, heading.group(2)!)),
            style: TextStyle(
              fontSize: level == 1 ? 18 : (level == 2 ? 16 : 15),
              fontWeight: FontWeight.w700,
              color: palette.ink,
              height: 1.5,
            ),
          ),
        ));
        continue;
      }
      if (line.startsWith('> ')) {
        widgets.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: palette.amber, width: 3),
            ),
          ),
          child: SelectableText.rich(
            TextSpan(children: _buildInlineSpans(context, line.substring(2))),
            style: TextStyle(fontSize: 14, height: 1.6, color: palette.muted),
          ),
        ));
        continue;
      }
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SelectableText.rich(
          TextSpan(children: _buildInlineSpans(context, line)),
          style: TextStyle(fontSize: 14, height: 1.7, color: palette.inkSoft),
        ),
      ));
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    return AccountSessionGuard(
      database: _database,
      child: Scaffold(
        appBar: AppBar(title: Text('${summary.title} · AI 摘要'), actions: [
          IconButton(
            tooltip: '复制摘要',
            icon: const Icon(Icons.copy),
            onPressed: _copy,
          ),
        ]),
        body: ReadAmberContent(
          maxWidth: 960,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.outline, width: 0.7),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.coverage,
                      key: const ValueKey('summary-coverage'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '生成于 ${ReadAmberDateFormat.formatMillis(summary.createdAt)}',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.outline, width: 0.7),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _buildMarkdownBody(context),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '来源（点击核对原笔记）',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 8),
              ...summary.references.map((r) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(
                          '[${r.label}] ${r.bookTitle} · ${r.chapterTitle.isEmpty ? '未注明章节' : r.chapterTitle}'),
                      subtitle: Text('${r.source.name}:${r.noteId}'),
                      trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                      onTap: () => _openReference(context, r),
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class AISummaryHistoryPage extends StatefulWidget {
  final String? bookId;
  final DatabaseService? database;
  const AISummaryHistoryPage({super.key, this.bookId, this.database});
  @override
  State<AISummaryHistoryPage> createState() => _AISummaryHistoryPageState();
}

class _AISummaryHistoryPageState extends State<AISummaryHistoryPage> {
  late final DatabaseService _database =
      widget.database ?? DatabaseService.instance;
  final _items = <Map<String, dynamic>>[];
  bool _loading = false;
  bool _opening = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted || !_database.isActive || _loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = _database;
      final rows = await db.getSummaryMetadata(
          bookId: widget.bookId,
          before: _items.isEmpty ? null : _items.last['id'] as int);
      if (!mounted || !db.isActive) return;
      setState(() {
        _items.addAll(rows);
        _hasMore = rows.length == 50;
      });
    } catch (e) {
      if (mounted && _database.isActive) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(int id) async {
    if (!mounted || !_database.isActive || _opening) return;
    _opening = true;
    try {
      final db = _database;
      final summary = await db.getSummary(id);
      if (!mounted || !db.isActive) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AISummaryPage(summary: summary, database: db)));
    } catch (e) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('摘要加载失败: $e')));
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => AccountSessionGuard(
        database: _database,
        child: Scaffold(
          appBar: AppBar(title: const Text('历史摘要')),
          body: ReadAmberContent(
            maxWidth: 960,
            child: _items.isEmpty && !_loading && _error == null
                ? const Center(child: Text('暂无历史摘要'))
                : ListView.builder(
                    itemCount: _items.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        if (_loading) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        if (_error != null) {
                          return TextButton(
                              onPressed: _load,
                              child: Text('历史摘要加载失败: $_error · 重试'));
                        }
                        return _hasMore
                            ? TextButton(
                                onPressed: _load, child: const Text('加载更多'))
                            : const SizedBox.shrink();
                      }
                      final row = _items[index];
                      return ListTile(
                        title: Text(row['title'] as String),
                        subtitle: Text(
                            '${row['coverage']}\n${ReadAmberDateFormat.formatMillis(row['created_at'] as int)}'),
                        onTap: () => _open(row['id'] as int),
                      );
                    },
                  ),
          ),
        ),
      );
}
