import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'ai_summary_page.dart';
import '../models/book.dart';
import '../services/database.dart';
import '../providers/notes_provider.dart';
import '../services/sync_service.dart';

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
  int _loadRequest = 0;
  static const _pageSize = 100;
  int _totalCount = 0;
  int _favoriteCount = 0;
  String? _error;
  final ScrollController _scrollController = ScrollController();
  bool _publishingFavorite = false;
  int _dataVersion = SyncService.changes.dataVersion;
  int _favoriteRevision = 0;
  bool _preparingSummary = false;
  final Set<String> _expanded = {};
  final Set<String> _savingFavorites = {};

  @override
  void initState() {
    super.initState();
    SyncService.changes.addListener(_onDataChanged);
    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 600 && !_loading &&
          _allItems.length < _totalCount && _error == null) {
        _loadPage(reset: false);
      }
    });
    _loadBookmarks();
  }

  void _onDataChanged() {
    if (!mounted || SyncService.changes.value?.isActive != true || _publishingFavorite) return;
    final version = SyncService.changes.dataVersion;
    final limit = version == _dataVersion && _allItems.length > _pageSize
        ? _allItems.length : _pageSize;
    _dataVersion = version;
    _loadPage(reset: true, limit: limit);
  }

  @override
  void dispose() {
    SyncService.changes.removeListener(_onDataChanged);
    _loadRequest++;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadBookmarks() => _loadPage(reset: true);

  // 两种来源统一排序后分页；同时间记录用来源和 ID 保证稳定顺序。
  static const _bookItems = '''
    SELECT bookmark_id AS id, book_id, book_title, mark_text AS content,
      chapter_title, created_at, is_fav, 'bookmark' AS source FROM bookmarks
    UNION ALL
    SELECT note_id AS id, book_id, book_title, content,
      chapter_title, created_at, is_fav, 'note' AS source FROM notes
  ''';

  Future<void> _loadPage({required bool reset, int limit = _pageSize}) async {
    if (!mounted) return;
    final request = ++_loadRequest;
    final favoriteRevision = _favoriteRevision;
    final offset = reset ? 0 : _allItems.length;
    setState(() { _loading = true; _error = null; });
    try {
      final db = DatabaseService.instance;
      final connection = await db.database;
      final counts = await connection.rawQuery(
        'SELECT COUNT(*) AS total, COALESCE(SUM(is_fav), 0) AS favorites '
        'FROM ($_bookItems) WHERE book_id = ?', [widget.book.bookId]);
      final rows = await connection.rawQuery(
        'SELECT * FROM ($_bookItems) WHERE book_id = ? '
        'ORDER BY created_at DESC, source DESC, id DESC LIMIT ? OFFSET ?',
        [widget.book.bookId, limit, offset]);
      if (!mounted || request != _loadRequest || !db.isActive) return;
      if (favoriteRevision != _favoriteRevision) {
        await _loadPage(reset: reset, limit: limit);
        return;
      }
      final items = rows.map((m) => NoteItem(
          id: m['id'] as String? ?? '',
          bookId: m['book_id'] as String? ?? '',
          bookTitle: (m['book_title'] as String?)?.isNotEmpty == true
              ? m['book_title'] as String : widget.book.title,
          content: m['content'] as String? ?? '',
          chapterTitle: m['chapter_title'] as String? ?? '',
          createdAt: m['created_at'] as int? ?? 0,
          isFav: (m['is_fav'] ?? 0) == 1,
          source: NoteSource.values.byName(m['source'] as String),
        )).toList();

      setState(() {
        _allItems = reset ? items : [..._allItems, ...items];
        _totalCount = counts.first['total'] as int;
        _favoriteCount = counts.first['favorites'] as int;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  String _itemKey(NoteItem note) => '${note.source.name}:${note.id}';

  Future<void> _copyNote(NoteItem note) async {
    await Clipboard.setData(ClipboardData(text: note.content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)));
  }

  Future<void> _toggleFavorite(NoteItem note) async {
    final key = _itemKey(note);
    if (_savingFavorites.contains(key)) return;
    final favorite = !note.isFav;
    setState(() => _savingFavorites.add(key));
    try {
      final db = DatabaseService.instance;
      if (note.source == NoteSource.bookmark) {
        await db.toggleBookmarkFavorite(note.id, favorite);
      } else {
        await db.toggleFavorite(note.id, favorite);
      }
      if (!mounted || !db.isActive) return;
      setState(() {
        _favoriteRevision++;
        final current = _allItems.where((item) => _itemKey(item) == key);
        final wasFavorite = current.isEmpty ? note.isFav : current.first.isFav;
        note.isFav = favorite;
        for (final item in current) { item.isFav = favorite; }
        if (wasFavorite != favorite) _favoriteCount += favorite ? 1 : -1;
      });
      _publishingFavorite = true;
      try {
        SyncService.changes.publish(db, favoritesOnly: true);
      } finally {
        _publishingFavorite = false;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('收藏保存失败')));
    } finally {
      if (mounted) setState(() => _savingFavorites.remove(key));
    }
  }

  String _getStatusText() {
    return widget.book.readingStatus;
  }

  Future<void> _aiSummarize() async {
    if (_preparingSummary) return;
    setState(() => _preparingSummary = true);
    try {
      // 摘要显式读取该书全部条目，不受详情已加载页数影响。
      final db = DatabaseService.instance;
      final connection = await db.database;
      final rows = await connection.rawQuery(
        'SELECT * FROM ($_bookItems) WHERE book_id = ? '
        'ORDER BY created_at DESC, source DESC, id DESC', [widget.book.bookId]);
      if (!mounted || !db.isActive) return;
      final notes = rows.map((m) => NoteItem(
        id: m['id'] as String, bookId: m['book_id'] as String,
        bookTitle: widget.book.title, content: m['content'] as String? ?? '',
        chapterTitle: m['chapter_title'] as String? ?? '',
        createdAt: m['created_at'] as int? ?? 0, isFav: m['is_fav'] == 1,
        source: NoteSource.values.byName(m['source'] as String))).toList();
      await generateSummary(context, widget.book.title, widget.book.author, notes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('摘要准备失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _preparingSummary = false);
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
            onPressed: _loading || _preparingSummary ? null : _aiSummarize,
          ),
          IconButton(icon: const Icon(Icons.history), tooltip: '历史摘要',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AISummaryHistoryPage(bookId: book.bookId)))),
          IconButton(
            icon: const Icon(Icons.share_rounded),
            tooltip: '分享',
            onPressed: () => _shareBook(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadBookmarks,
        child: ListView.builder(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: 8 + _allItems.length,
          itemBuilder: (context, index) {
            if (index >= 7 && index < 7 + _allItems.length) {
              return _buildNoteItem(_allItems[index - 7]);
            }
            if (index == 7 + _allItems.length) {
              if (_error != null) {
                return Column(children: [
                  Text('加载失败: $_error'),
                  TextButton(onPressed: () => _loadPage(reset: _allItems.isEmpty), child: const Text('重试')),
                ]);
              }
              if (_loading) return const Center(child: CircularProgressIndicator());
              if (_allItems.isEmpty) return const Center(child: Text('暂无划线和笔记'));
              if (_allItems.length < _totalCount) {
                return TextButton(onPressed: () => _loadPage(reset: false), child: const Text('加载更多'));
              }
              return const SizedBox(height: 8);
            }
            return [
              // 书籍头部信息
              _buildBookHeader(context, isNarrow),
              const SizedBox(height: 20),
              // 阅读统计
              _buildStatsSection(context),
              const SizedBox(height: 20),
              // 阅读进度
              _buildProgressSection(context),
              const SizedBox(height: 20),
              // 划线和笔记标题；条目由外层列表按需构建。
              _buildNotesSection(context),
            ][index];
          },
        ),
      ),
    );
  }

  Widget _buildBookHeader(BuildContext context, bool isNarrow) {
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
                color: book.isFinished ? Colors.green : const Color(0xFF2196F3),
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
      case '接近读完':
        color = Colors.orange;
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
          _buildStatItem(Icons.note_rounded, '划线笔记', '$_totalCount条'),
          _buildStatDivider(),
          _buildStatItem(Icons.star_rounded, '收藏', '$_favoriteCount条'),
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
                widget.book.isFinished ? Colors.green : const Color(0xFF2196F3),
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
                widget.book.isFinished ? '🎉 恭喜读完！'
                    : widget.book.isNearlyFinished ? '接近读完' : '继续加油',
                style: TextStyle(
                  fontSize: 13,
                  color: widget.book.isFinished ? Colors.green : Colors.grey[500],
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
                    '$_totalCount 条',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildNoteItem(NoteItem bookmark) {
    final key = _itemKey(bookmark);
    final expanded = _expanded.contains(key);
    final isHighlight = bookmark.source == NoteSource.bookmark;
    final accentColor = isHighlight ? const Color(0xFFFF6B6B) : const Color(0xFF4ECDC4);

    return Padding(
      key: ValueKey(key),
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
              maxLines: expanded ? null : 3,
              overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
          ),
          Row(children: [
            TextButton(
              key: ValueKey('expand-$key'),
              onPressed: () => setState(() {
                if (expanded) { _expanded.remove(key); } else { _expanded.add(key); }
              }),
              child: Text(expanded ? '收起' : '展开全文')),
            const Spacer(),
            IconButton(key: ValueKey('copy-$key'), tooltip: '复制笔记',
              icon: const Icon(Icons.copy, size: 20), onPressed: () => _copyNote(bookmark)),
            IconButton(key: ValueKey('favorite-$key'),
              tooltip: bookmark.isFav ? '取消收藏' : '收藏笔记',
              icon: Icon(bookmark.isFav ? Icons.star_rounded : Icons.star_border_rounded,
                color: bookmark.isFav ? Colors.amber : Colors.grey),
              onPressed: _savingFavorites.contains(key) ? null : () => _toggleFavorite(bookmark)),
          ]),
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
