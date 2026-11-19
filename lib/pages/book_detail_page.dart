import 'dart:async';
import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'ai_summary_page.dart';
import '../models/book.dart';
import '../services/database.dart';
import '../services/export_service.dart';
import '../providers/notes_provider.dart';
import '../services/sync_service.dart';
import '../utils/date_format.dart';
import '../widgets/account_session_guard.dart';
import '../widgets/book_cover.dart';

/// 书籍详情页
/// 展示书籍信息、进度、划线和笔记（真实数据）
class BookDetailPage extends StatefulWidget {
  final Book book;
  final DatabaseService? database;
  final Future<SyncService> Function()? syncServiceFactory;

  const BookDetailPage({
    super.key,
    required this.book,
    this.database,
    this.syncServiceFactory,
  });

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  late final DatabaseService _database =
      widget.database ?? DatabaseService.instance;
  List<NoteItem> _allItems = [];
  bool _loading = true;
  int _loadRequest = 0;
  static const _pageSize = 100;
  int _totalCount = 0;
  int _favoriteCount = 0;
  bool _resetRequired = true;
  String? _error;
  final ScrollController _scrollController = ScrollController();
  bool _publishingFavorite = false;
  int _dataVersion = SyncService.changes.dataVersion;
  int _favoriteRevision = 0;
  bool _preparingSummary = false;
  bool _exportingBook = false;
  bool _syncingBook = false;
  bool _groupByChapter = false;
  bool _searching = false;
  String _searchQuery = '';
  Timer? _searchTimer;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _expanded = {};
  final Set<String> _savingFavorites = {};

  @override
  void initState() {
    super.initState();
    SyncService.changes.addListener(_onDataChanged);
    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 600 &&
          !_loading &&
          _allItems.length < _totalCount &&
          _error == null) {
        _loadPage(reset: false);
      }
    });
    _loadBookmarks();
  }

  void _onDataChanged() {
    if (!mounted ||
        !_database.isActive ||
        !identical(SyncService.changes.value, _database) ||
        _publishingFavorite) {
      return;
    }
    final event = SyncService.changes;
    if (event.kind == SyncChangeKind.bookshelf ||
        (event.bookIds.isNotEmpty &&
            !event.bookIds.contains(widget.book.bookId))) {
      return;
    }
    if (event.favoritesOnly && event.itemIds.isNotEmpty) {
      _refreshFavorites(event.itemIds);
      return;
    }
    final version = SyncService.changes.dataVersion;
    final limit = version == _dataVersion && _allItems.length > _pageSize
        ? _allItems.length
        : _pageSize;
    _dataVersion = version;
    _loadPage(reset: true, limit: limit);
  }

  @override
  void dispose() {
    SyncService.changes.removeListener(_onDataChanged);
    _searchTimer?.cancel();
    _searchController.dispose();
    _loadRequest++;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshFavorites(Set<String> keys) async {
    // Both callers validate the page/session immediately before this call.
    final request = _loadRequest;
    final favoriteRevision = _favoriteRevision;
    try {
      final db = _database;
      final updates = <(NoteItem, bool)>[];
      for (final item
          in _allItems.where((n) => keys.contains(_itemKey(n))).toList()) {
        final row =
            await db.getReadingItem(item.id, item.source.name, item.bookId);
        if (!mounted || !db.isActive || request != _loadRequest) return;
        if (row != null) updates.add((item, row['is_fav'] == 1));
      }
      final count = await db.countReadingItems(
          bookId: widget.book.bookId, filter: ReadingFilter.favorites);
      if (!mounted || !db.isActive || request != _loadRequest) return;
      if (favoriteRevision != _favoriteRevision) {
        await _refreshFavorites(keys);
        return;
      }
      setState(() {
        _favoriteRevision++;
        for (final (item, favorite) in updates) {
          item.isFav = favorite;
        }
        _favoriteCount = count;
      });
    } catch (e) {
      if (mounted &&
          _database.isActive &&
          request == _loadRequest &&
          favoriteRevision == _favoriteRevision) {
        setState(() {
          _resetRequired = true;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _loadBookmarks() => _loadPage(reset: true);

  Future<void> _loadPage({required bool reset, int limit = _pageSize}) async {
    if (!mounted || !_database.isActive) return;
    final reload = reset || _resetRequired;
    if (reload) _resetRequired = true;
    final request = ++_loadRequest;
    final favoriteRevision = _favoriteRevision;
    final query = _searchQuery;
    final after = reload || _allItems.isEmpty ? null : _allItems.last;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = _database;
      var total = _totalCount;
      var favorites = _favoriteCount;
      if (reload) {
        final counts =
            await db.getBookItemCounts(widget.book.bookId, query: query);
        total = counts.total;
        favorites = counts.favorites;
      }
      if (!mounted || request != _loadRequest || !db.isActive) return;
      final rows = await db.getReadingItems(
        bookId: widget.book.bookId,
        query: query,
        limit: limit,
        after: after,
      );
      if (!mounted || request != _loadRequest || !db.isActive) return;
      if (favoriteRevision != _favoriteRevision) {
        await _loadPage(reset: reload, limit: limit);
        return;
      }
      final items = rows
          .map((m) => NoteItem.fromRow(m, fallbackBookTitle: widget.book.title))
          .toList();

      setState(() {
        _allItems = reload ? items : [..._allItems, ...items];
        _totalCount = total;
        _favoriteCount = favorites;
        _resetRequired = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !_database.isActive || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _itemKey(NoteItem note) => '${note.source.name}:${note.id}';

  Future<void> _copyNote(NoteItem note) async {
    if (!mounted || !_database.isActive) return;
    try {
      await Clipboard.setData(ClipboardData(text: note.content));
      if (!mounted || !_database.isActive) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)));
    } catch (_) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  Future<void> _toggleFavorite(NoteItem note) async {
    final key = _itemKey(note);
    if (!mounted || !_database.isActive || _savingFavorites.contains(key)) {
      return;
    }
    final favorite = !note.isFav;
    setState(() => _savingFavorites.add(key));
    try {
      final db = _database;
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
        for (final item in current) {
          item.isFav = favorite;
        }
        if (wasFavorite != favorite) _favoriteCount += favorite ? 1 : -1;
      });
      _publishingFavorite = true;
      try {
        SyncService.changes.publish(db,
            favoritesOnly: true,
            bookIds: {note.bookId},
            itemIds: {_itemKey(note)},
            sources: {note.source.name});
      } finally {
        _publishingFavorite = false;
      }
    } catch (e) {
      if (!mounted || !_database.isActive) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('收藏保存失败')));
    } finally {
      if (mounted) setState(() => _savingFavorites.remove(key));
    }
  }

  String _getStatusText() {
    return widget.book.readingStatus;
  }

  Future<void> _aiSummarize() async {
    if (!mounted || !_database.isActive || _preparingSummary) return;
    setState(() => _preparingSummary = true);
    try {
      // 数据库筛选最新非空条目，最多读取 30 条，不受详情分页影响。
      final db = _database;
      final rows = await db.getSummaryItems(bookId: widget.book.bookId);
      if (!mounted || !db.isActive) return;
      final notes = rows
          .map((m) => NoteItem.fromRow(m, fallbackBookTitle: widget.book.title))
          .toList();
      await generateSummary(
          context, widget.book.title, widget.book.author, notes,
          database: db);
    } catch (e) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('摘要准备失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _preparingSummary = false);
    }
  }

  Future<void> _shareBook(BuildContext context) async {
    if (!mounted || !_database.isActive) return;
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
    text.writeln('—— 来自阅珀 ReadAmber');

    try {
      await Share.share(text.toString());
    } catch (_) {
      if (context.mounted && _database.isActive) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('分享失败，请重试')));
      }
    }
  }

  Future<void> _exportBookMarkdown() async {
    setState(() => _exportingBook = true);
    try {
      await ExportService.exportAndShare(
        bookId: widget.book.bookId,
        obsidianFrontmatter: true,
      );
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本书 Markdown 已导出')),
        );
      }
    } catch (e) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exportingBook = false);
    }
  }

  Future<void> _syncSingleBook() async {
    setState(() => _syncingBook = true);
    try {
      final service = await (widget.syncServiceFactory?.call() ??
          SyncService.connect());
      final result = await service.retryBook(widget.book);
      if (mounted && _database.isActive) {
        final msg = result.succeeded
            ? '已同步 ${result.bookmarks} 条划线、${result.notes} 条笔记'
            : '单书同步部分失败：${result.reason}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted && _database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('单书同步失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncingBook = false);
    }
  }

  void _onSearchChanged(String value) {
    _searchQuery = value;
    _searchTimer?.cancel();
    _searchTimer = Timer(
      const Duration(milliseconds: 300),
      () => _loadPage(reset: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 400;

    return AccountSessionGuard(
      database: _database,
      child: Scaffold(
        backgroundColor: ReadAmberPalette.of(context).canvas,
        appBar: AppBar(
          title: Text(book.title, style: const TextStyle(fontSize: 16)),
          centerTitle: true,
          elevation: 0,
          backgroundColor: ReadAmberPalette.of(context).canvas,
          foregroundColor: ReadAmberPalette.of(context).ink,
          actions: [
            IconButton(
              icon: const Icon(Icons.auto_awesome_rounded),
              tooltip: 'AI 摘要',
              onPressed: _loading || _preparingSummary ? null : _aiSummarize,
            ),
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: '历史摘要',
              onPressed: () {
                if (!_database.isActive) return;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AISummaryHistoryPage(
                        bookId: book.bookId, database: _database)));
              },
            ),
            IconButton(
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: '导出本书 Markdown',
              onPressed: _exportingBook ? null : _exportBookMarkdown,
            ),
            IconButton(
              icon: const Icon(Icons.sync_rounded),
              tooltip: '同步本书',
              onPressed: _syncingBook ? null : _syncSingleBook,
            ),
            IconButton(
              icon: const Icon(Icons.share_rounded),
              tooltip: '分享',
              onPressed: () => _shareBook(context),
            ),
          ],
        ),
        body: ReadAmberContent(
          maxWidth: 960,
          child: RefreshIndicator(
            onRefresh: _loadBookmarks,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildBookHeader(context, isNarrow),
                        const SizedBox(height: 20),
                        _buildStatsSection(context),
                        const SizedBox(height: 20),
                        _buildProgressSection(context),
                        const SizedBox(height: 20),
                        _buildNotesSection(context),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList.builder(
                    itemCount: _allItems.length,
                    itemBuilder: (context, index) => _buildNoteItem(
                      _allItems[index],
                      previousChapter:
                          index > 0 ? _allItems[index - 1].chapterTitle : null,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  sliver: SliverToBoxAdapter(child: _buildFooter()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    if (_error != null) {
      return Column(children: [
        Text('加载失败: $_error'),
        TextButton(
            onPressed: () => _loadPage(reset: _allItems.isEmpty),
            child: const Text('重试')),
      ]);
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_allItems.isEmpty) {
      return Center(
          child: Text(_searchQuery.isEmpty ? '暂无划线和笔记' : '没有匹配的书内记录'));
    }
    if (_allItems.length < _totalCount) {
      return TextButton(
          onPressed: () => _loadPage(reset: false), child: const Text('加载更多'));
    }
    return const SizedBox(height: 8);
  }

  Widget _buildBookHeader(BuildContext context, bool isNarrow) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ReadAmberPalette.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: ReadAmberColors.ink.withValues(alpha: 0.05),
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
    return BookCover(
      bookId: book.bookId,
      title: book.title,
      coverUrl: book.cover,
      width: 100,
      height: 140,
      borderRadius: BorderRadius.circular(8),
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
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: ReadAmberPalette.of(context).ink,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Text(
          book.author,
          style: TextStyle(fontSize: 14, color: ReadAmberPalette.of(context).muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (book.category.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: ReadAmberPalette.of(context).inkSoft.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              book.category,
              style: TextStyle(fontSize: 11, color: ReadAmberPalette.of(context).inkSoft),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildStatusChip(status),
            Text(
              '${book.progress}%',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: book.isFinished ? ReadAmberPalette.of(context).success : ReadAmberPalette.of(context).inkSoft,
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
        color = ReadAmberPalette.of(context).success;
        break;
      case '在读中':
        color = ReadAmberPalette.of(context).inkSoft;
        break;
      case '接近读完':
        color = ReadAmberPalette.of(context).amberText;
        break;
      default:
        color = ReadAmberPalette.of(context).muted;
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
        style:
            TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color),
      ),
    );
  }

  Widget _buildStatsSection(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ReadAmberPalette.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: ReadAmberColors.ink.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Expanded(
              child:
                  _buildStatItem(Icons.note_rounded, '划线笔记', '$_totalCount条')),
          _buildStatDivider(),
          Expanded(
              child:
                  _buildStatItem(Icons.star_rounded, '收藏', '$_favoriteCount条')),
          _buildStatDivider(),
          Expanded(
              child: _buildStatItem(
                  Icons.trending_up_rounded, '进度', '${widget.book.progress}%')),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 22, color: ReadAmberPalette.of(context).inkSoft),
        const SizedBox(height: 6),
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: ReadAmberPalette.of(context).ink),
        ),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: ReadAmberPalette.of(context).muted)),
      ],
    );
  }

  Widget _buildStatDivider() {
    return Container(height: 36, width: 1, color: ReadAmberPalette.of(context).surfaceMuted);
  }

  Widget _buildProgressSection(BuildContext context) {
    final progress = widget.book.progress / 100.0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ReadAmberPalette.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: ReadAmberColors.ink.withValues(alpha: 0.05),
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
              Icon(Icons.trending_up_rounded,
                  size: 18, color: ReadAmberPalette.of(context).muted),
              const SizedBox(width: 6),
              Text(
                '阅读进度',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: ReadAmberPalette.of(context).inkSoft),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: ReadAmberPalette.of(context).surfaceMuted,
              valueColor: AlwaysStoppedAnimation<Color>(
                widget.book.isFinished ? ReadAmberPalette.of(context).success : ReadAmberPalette.of(context).inkSoft,
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                '${widget.book.progress}% 已完成',
                style: TextStyle(fontSize: 13, color: ReadAmberPalette.of(context).muted),
              ),
              Text(
                widget.book.isFinished
                    ? '🎉 恭喜读完！'
                    : widget.book.isNearlyFinished
                        ? '接近读完'
                        : '继续加油',
                style: TextStyle(
                  fontSize: 13,
                  color:
                      widget.book.isFinished ? ReadAmberPalette.of(context).success : ReadAmberPalette.of(context).muted,
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
        color: ReadAmberPalette.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: ReadAmberColors.ink.withValues(alpha: 0.05),
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
                Icon(Icons.note_alt_outlined,
                    size: 18, color: ReadAmberPalette.of(context).muted),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(
                  '划线与笔记',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: ReadAmberPalette.of(context).inkSoft),
                )),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Text(
                    '$_totalCount 条',
                    style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
                  ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _searching ? '关闭书内搜索' : '搜索本书',
                  icon: Icon(
                    _searching ? Icons.search_off_rounded : Icons.search_rounded,
                    size: 18,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() {
                      _searching = !_searching;
                      if (!_searching && _searchQuery.isNotEmpty) {
                        _searchController.clear();
                        _onSearchChanged('');
                      }
                    });
                  },
                ),
                IconButton(
                  tooltip: _groupByChapter ? '关闭章节分组' : '按章节分组显示',
                  icon: Icon(
                    _groupByChapter
                        ? Icons.view_agenda_rounded
                        : Icons.view_stream_outlined,
                    size: 18,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _groupByChapter = !_groupByChapter),
                ),
              ],
            ),
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索本书划线或笔记...',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged('');
                            setState(() {});
                          },
                        )
                      : null,
                ),
              ),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildNoteItem(NoteItem bookmark, {String? previousChapter}) {
    final key = _itemKey(bookmark);
    final expanded = _expanded.contains(key);
    final isHighlight = bookmark.source == NoteSource.bookmark;
    final accentColor =
        isHighlight ? ReadAmberPalette.of(context).amberText : ReadAmberPalette.of(context).inkSoft;
    final showChapterHeader = _groupByChapter &&
        bookmark.chapterTitle.isNotEmpty &&
        bookmark.chapterTitle != previousChapter;

    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showChapterHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                bookmark.chapterTitle,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: ReadAmberPalette.of(context).ink,
                ),
              ),
            ),
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
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: accentColor),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bookmark.chapterTitle.isNotEmpty ? bookmark.chapterTitle : '',
                  style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Flexible(
                  child: Text(
                ReadAmberDateFormat.formatDate(bookmark.createdAt),
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 11, color: ReadAmberPalette.of(context).muted),
              )),
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
              style:
                  TextStyle(fontSize: 13, height: 1.5, color: ReadAmberPalette.of(context).inkSoft),
              maxLines: expanded ? null : 3,
              overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
          ),
          Row(children: [
            TextButton(
                key: ValueKey('expand-$key'),
                onPressed: () => setState(() {
                      if (expanded) {
                        _expanded.remove(key);
                      } else {
                        _expanded.add(key);
                      }
                    }),
                child: Text(expanded ? '收起' : '展开全文')),
            const Spacer(),
            IconButton(
                key: ValueKey('copy-$key'),
                tooltip: '复制笔记',
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () => _copyNote(bookmark)),
            IconButton(
                key: ValueKey('favorite-$key'),
                tooltip: bookmark.isFav ? '取消收藏' : '收藏笔记',
                icon: Icon(
                    bookmark.isFav
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: bookmark.isFav ? ReadAmberPalette.of(context).amberText : ReadAmberPalette.of(context).muted),
                onPressed: _savingFavorites.contains(key)
                    ? null
                    : () => _toggleFavorite(bookmark)),
          ]),
          const SizedBox(height: 12),
          Divider(height: 1, color: ReadAmberPalette.of(context).surfaceMuted),
        ],
      ),
    );
  }
}
