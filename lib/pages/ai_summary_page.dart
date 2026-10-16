import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/ai_summary.dart';
import '../providers/notes_provider.dart';
import '../services/ai_service.dart';
import '../services/config.dart';
import '../services/database.dart';
import '../widgets/account_session_guard.dart';
import 'notes_page.dart';

Future<void> generateSummary(BuildContext context, String title, String author,
    List<NoteItem> notes, {DatabaseService? database,
      AIService Function(AppConfig)? serviceFactory}) async {
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        notes.isEmpty ? '暂无划线和笔记可摘要' : '请先在设置中配置 AI API')));
    return;
  }
  // 持有具体路由，避免异步完成时误弹出其他页面。
  final navigator = Navigator.of(context, rootNavigator: true);
  final loading = DialogRoute<void>(context: context, barrierDismissible: false,
    builder: (_) => const PopScope(canPop: false, child: AlertDialog(
      content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20),
        Text('AI 正在生成摘要...')]))));
  navigator.push(loading);
  AISummary? result;
  Object? error;
  try {
    result = await service.summarizeBook(title, author, notes);
  } catch (e) {
    error = e;
  } finally {
    if (navigator.mounted && loading.isActive) navigator.removeRoute(loading);
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
  late final DatabaseService _database = widget.database ?? DatabaseService.instance;
  AISummary get summary => widget.summary;

  Future<void> _copy() async {
    if (!mounted || !_database.isActive) return;
    try {
      await Clipboard.setData(ClipboardData(
        text: '${summary.coverage}\n${summary.text}\n${summary.references.map((r) => '[${r.label}] ${r.bookTitle} · ${r.chapterTitle} · ${r.source.name}:${r.noteId}').join('\n')}'));
    } catch (_) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  void _openReference(BuildContext context, SummaryReference reference) {
    if (!mounted || !_database.isActive) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NotesPage(reference: reference, database: _database)));
  }

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in RegExp(r'\[R\d+\]').allMatches(summary.text)) {
      spans.add(TextSpan(text: summary.text.substring(offset, match.start)));
      final label = match.group(0)!.substring(1, match.group(0)!.length - 1);
      final refs = summary.references.where((r) => r.label == label);
      spans.add(refs.isEmpty
          ? TextSpan(text: '${match.group(0)}（引用不存在）')
          : WidgetSpan(alignment: PlaceholderAlignment.middle, child: TextButton(
              onPressed: () => _openReference(context, refs.first),
              child: Text(match.group(0)!))));
      offset = match.end;
    }
    spans.add(TextSpan(text: summary.text.substring(offset)));
    return AccountSessionGuard(database: _database, child: Scaffold(
      appBar: AppBar(title: Text('${summary.title} · AI 摘要'), actions: [
        IconButton(tooltip: '复制摘要', icon: const Icon(Icons.copy),
          onPressed: _copy),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(summary.coverage, key: const ValueKey('summary-coverage')),
        Text('生成于 ${DateTime.fromMillisecondsSinceEpoch(summary.createdAt).toLocal()}'),
        const SizedBox(height: 16),
        SelectableText.rich(TextSpan(children: spans),
          style: const TextStyle(fontSize: 14, height: 1.6)),
        const Divider(),
        const Text('来源（点击核对原笔记）'),
        ...summary.references.map((r) => ListTile(
          title: Text('[${r.label}] ${r.bookTitle} · ${r.chapterTitle.isEmpty ? '未注明章节' : r.chapterTitle}'),
          subtitle: Text('${r.source.name}:${r.noteId}'),
          onTap: () => _openReference(context, r))),
      ]),
    ));
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
  late final DatabaseService _database = widget.database ?? DatabaseService.instance;
  final _items = <Map<String, dynamic>>[];
  bool _loading = false;
  bool _opening = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (!mounted || !_database.isActive || _loading || !_hasMore) return;
    setState(() { _loading = true; _error = null; });
    try {
      final db = _database;
      final rows = await db.getSummaryMetadata(bookId: widget.bookId,
        before: _items.isEmpty ? null : _items.last['id'] as int);
      if (!mounted || !db.isActive) return;
      setState(() { _items.addAll(rows); _hasMore = rows.length == 50; });
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
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AISummaryPage(summary: summary, database: db)));
    } catch (e) {
      if (mounted && _database.isActive) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('摘要加载失败: $e')));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => AccountSessionGuard(database: _database, child: Scaffold(
    appBar: AppBar(title: const Text('历史摘要')),
    body: _items.isEmpty && !_loading && _error == null
      ? const Center(child: Text('暂无历史摘要'))
      : ListView.builder(itemCount: _items.length + 1, itemBuilder: (context, index) {
        if (index == _items.length) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_error != null) return TextButton(onPressed: _load, child: Text('历史摘要加载失败: $_error · 重试'));
          return _hasMore ? TextButton(onPressed: _load, child: const Text('加载更多')) : const SizedBox.shrink();
        }
        final row = _items[index];
        return ListTile(title: Text(row['title'] as String),
          subtitle: Text('${row['coverage']}\n${DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int).toLocal()}'),
          onTap: () => _open(row['id'] as int));
      }),
  ));
}
