import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../services/ai_service.dart';
import '../services/config.dart';
import '../models/book.dart';
import '../services/database.dart';
import '../providers/notes_provider.dart';

/// 书籍详情页
/// 展示书籍信息、进度、划线和笔记（真实数据）
class BookDetailPage extends StatefulWidget {
  final Book book;

  const BookDetailPage({super.key, required this.book});

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  List<NoteItem> _allItems = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    setState(() => _loading = true);
    try {
      final items = <NoteItem>[];

      // 加载划线
      final rawBookmarks = await DatabaseService.instance.getBookmarksByBook(widget.book.bookId);
      for (final m in rawBookmarks) {
        items.add(NoteItem(
          id: m['bookmark_id'] ?? '',
          bookId: m['book_id'] ?? '',
          bookTitle: m['book_title'] ?? '',
          content: m['mark_text'] ?? '',
          chapterTitle: m['chapter_title'] ?? '',
          createdAt: m['created_at'] ?? 0,
          isFav: (m['is_fav'] ?? 0) == 1,
          source: NoteSource.bookmark,
        ));
      }

      // 加载笔记
      final rawNotes = await DatabaseService.instance.getNotesByBook(widget.book.bookId);
      for (final m in rawNotes) {
        items.add(NoteItem(
          id: m['note_id'] ?? '',
          bookId: m['book_id'] ?? '',
          bookTitle: m['book_title'] ?? '',
          content: m['content'] ?? '',
          chapterTitle: m['chapter_title'] ?? '',
          createdAt: m['created_at'] ?? 0,
          isFav: (m['is_fav'] ?? 0) == 1,
          source: NoteSource.note,
        ));
      }

      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() {
        _allItems = items;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  String _getStatusText() {
    final book = widget.book;
    if (book.isFinished || book.progress >= 85) return '已读完';
    if (book.progress >= 5) return '在读中';
    return '未读';
  }

  Future<void> _aiSummarize(BuildContext context) async {
    final config = AppConfig();
    await config.load();

    if (config.apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中配置 AI API Key'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    if (_allItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无划线和笔记可摘要'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('AI 正在生成摘要...'),
            ],
          ),
        ),
      );
    }

    final ai = AIService(config: config);
    final highlights = _allItems.map((n) => n.content).where((c) => c.isNotEmpty).toList();
    final result = await ai.summarizeBook(widget.book.title, widget.book.author, highlights);

    if (mounted) Navigator.pop(context);

    if (result != null && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('《${widget.book.title}》AI 摘要'),
          content: SingleChildScrollView(
            child: SelectableText(result, style: const TextStyle(fontSize: 14, height: 1.6)),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
                );
              },
              child: const Text('复制'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI 摘要生成失败'), backgroundColor: Colors.red),
      );
    }
  }

  void _shareBook(BuildContext context) {
    final book = widget.book;
    final highlights = _allItems
        .where((n) => n.source == NoteSource.bookmark)
        .take(5)
        .map((n) => '「${n.content}」')
        .join('\n');

    final text = StringBuffer();
    text.writeln('📖 《${book.title}》');
    if (book.author.isNotEmpty) text.writeln('✍️ ${book.author}');
    text.writeln('📊 阅读进度: ${book.progress}%');
    text.writeln('');

    if (highlights.isNotEmpty) {
      text.writeln('--- 精彩划线 ---');
      text.writeln(highlights);
    }

    text.writeln('');
    text.writeln('—— 来自微信读书伴侣');

    Share.share(text.toString());
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 400;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(book.title, style: const TextStyle(fontSize: 16)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome_rounded),
            tooltip: 'AI 摘要',
            onPressed: () => _aiSummarize(context),
          ),
          IconButton(
            icon: const Icon(Icons.share_rounded),
            tooltip: '分享',
            onPressed: () => _shareBook(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadBookmarks,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 书籍头部信息
            _buildBookHeader(context, isNarrow),
            const SizedBox(height: 20),
            // 阅读统计
            _buildStatsSection(context),
            const SizedBox(height: 20),
            // 阅读进度
            _buildProgressSection(context),
            const SizedBox(height: 20),
            // 划线和笔记
            _buildNotesSection(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBookHeader(BuildContext context, bool isNarrow) {
    final book = widget.book;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: isNarrow
          ? Column(
              children: [
                _buildCoverImage(),
                const SizedBox(height: 16),
                _buildBookInfo(context),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCoverImage(),
                const SizedBox(width: 16),
                Expanded(child: _buildBookInfo(context)),
              ],
            ),
    );
  }

  Widget _buildCoverImage() {
    final book = widget.book;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 100,
        height: 140,
        color: Colors.grey[200],
        child: book.cover.isNotEmpty
            ? Image.network(
                book.cover,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.book, size: 32, color: Colors.grey[400]),
                      const SizedBox(height: 4),
                      Text(
                        book.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
              )
            : Center(
                child: Icon(Icons.book, size: 40, color: Colors.grey[400]),
              ),
      ),
    );
  }

  Widget _buildBookInfo(BuildContext context) {
    final book = widget.book;
    final status = _getStatusText();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          book.title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Text(
          book.author,
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (book.category.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF2196F3).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              book.category,
              style: const TextStyle(fontSize: 11, color: Color(0xFF2196F3)),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            _buildStatusChip(status),
            const SizedBox(width: 8),
            Text(
              '${book.progress}%',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: book.progress >= 85 ? Colors.green : const Color(0xFF2196F3),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusChip(String status) {
    Color color;
    switch (status) {
      case '已读完':
        color = Colors.green;
        break;
      case '在读中':
        color = const Color(0xFF2196F3);
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        status,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color),
      ),
    );
  }

  Widget _buildStatsSection(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(Icons.note_rounded, '划线笔记', '${_allItems.length}条'),
          _buildStatDivider(),
          _buildStatItem(Icons.star_rounded, '收藏', '${_allItems.where((b) => b.isFav).length}条'),
          _buildStatDivider(),
          _buildStatItem(Icons.trending_up_rounded, '进度', '${widget.book.progress}%'),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 22, color: const Color(0xFF2196F3)),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
      ],
    );
  }

  Widget _buildStatDivider() {
    return Container(height: 36, width: 1, color: Colors.grey[200]);
  }

  Widget _buildProgressSection(BuildContext context) {
    final progress = widget.book.progress / 100.0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trending_up_rounded, size: 18, color: Colors.grey[600]),
              const SizedBox(width: 6),
              Text(
                '阅读进度',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.grey[800]),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                progress >= 0.85 ? Colors.green : const Color(0xFF2196F3),
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${widget.book.progress}% 已完成',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
              Text(
                progress >= 0.85 ? '🎉 恭喜读完！' : '继续加油',
                style: TextStyle(
                  fontSize: 13,
                  color: progress >= 0.85 ? Colors.green : Colors.grey[500],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotesSection(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.note_alt_outlined, size: 18, color: Colors.grey[600]),
                const SizedBox(width: 6),
                Text(
                  '划线与笔记',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.grey[800]),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Text(
                    '${_allItems.length} 条',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          if (_loading && _allItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_allItems.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.note_add_outlined, size: 40, color: Colors.grey[300]),
                    const SizedBox(height: 8),
                    Text('暂无划线和笔记', style: TextStyle(color: Colors.grey[400])),
                  ],
                ),
              ),
            )
          else
            ..._allItems.map((bookmark) => _buildNoteItem(bookmark)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildNoteItem(NoteItem bookmark) {
    final isHighlight = bookmark.source == NoteSource.bookmark;
    final accentColor = isHighlight ? const Color(0xFFFF6B6B) : const Color(0xFF4ECDC4);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isHighlight ? '划线' : '笔记',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: accentColor),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bookmark.chapterTitle.isNotEmpty ? bookmark.chapterTitle : '',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatTimestamp(bookmark.createdAt),
                style: TextStyle(fontSize: 11, color: Colors.grey[400]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: accentColor.withValues(alpha: 0.4),
                  width: 3,
                ),
              ),
            ),
            child: Text(
              bookmark.content,
              style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[700]),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Colors.grey[100]),
        ],
      ),
    );
  }

  String _formatTimestamp(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
