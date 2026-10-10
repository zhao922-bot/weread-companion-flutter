import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/ai_summary.dart';
import '../providers/notes_provider.dart';
import '../services/ai_service.dart';
import '../services/config.dart';
import '../services/database.dart';
import 'notes_page.dart';

Future<void> generateSummary(BuildContext context, String title, String author,
    List<NoteItem> notes) async {
  final config = AppConfig();
  await config.load();
  if (!context.mounted) return;
  if (!AIService(config: config).isConfigured || notes.isEmpty) {
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
    result = await AIService(config: config).summarizeBook(title, author, notes);
  } catch (e) {
    error = e;
  } finally {
    if (navigator.mounted && loading.isActive) navigator.removeRoute(loading);
  }
  if (!context.mounted) return;
  if (result == null || error != null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI 摘要生成或保存失败，请检查 API 配置')));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AISummaryPage(summary: result!)));
}

class AISummaryPage extends StatelessWidget {
  final AISummary summary;
  const AISummaryPage({super.key, required this.summary});

  void _openReference(BuildContext context, SummaryReference reference) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NotesPage(reference: reference)));
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
    return Scaffold(
      appBar: AppBar(title: Text('${summary.title} · AI 摘要'), actions: [
        IconButton(tooltip: '复制摘要', icon: const Icon(Icons.copy),
          onPressed: () => Clipboard.setData(ClipboardData(
              text: '${summary.coverage}\n${summary.text}\n${summary.references.map((r) => '[${r.label}] ${r.bookTitle} · ${r.chapterTitle} · ${r.source.name}:${r.noteId}').join('\n')}'))),
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
    );
  }
}

class AISummaryHistoryPage extends StatefulWidget {
  final String? bookId;
  const AISummaryHistoryPage({super.key, this.bookId});
  @override
  State<AISummaryHistoryPage> createState() => _AISummaryHistoryPageState();
}

class _AISummaryHistoryPageState extends State<AISummaryHistoryPage> {
  late final Future<List<AISummary>> _history =
      DatabaseService.instance.getSummaries(bookId: widget.bookId);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('历史摘要')),
    body: FutureBuilder<List<AISummary>>(future: _history, builder: (context, snapshot) {
      if (snapshot.hasError) return const Center(child: Text('历史摘要加载失败'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.data!.isEmpty) return const Center(child: Text('暂无历史摘要'));
      return ListView(children: snapshot.data!.map((s) => ListTile(
        title: Text(s.title), subtitle: Text('${s.coverage}\n${DateTime.fromMillisecondsSinceEpoch(s.createdAt).toLocal()}'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AISummaryPage(summary: s))),
      )).toList());
    }),
  );
}
