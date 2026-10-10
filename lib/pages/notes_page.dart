import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/notes_provider.dart';
import '../services/export_service.dart';
import '../services/database.dart';
import '../services/sync_service.dart';
import '../models/ai_summary.dart';
import 'ai_summary_page.dart';


class NotesPage extends StatefulWidget {
  final SummaryReference? reference;
  const NotesPage({super.key, this.reference});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final _filters = ReadingFilter.values;
  bool _preparingSummary = false;
  Future<Map<String, dynamic>?>? _target;

  @override
  void initState() {
    super.initState();
    final ref = widget.reference;
    _target = ref == null ? null : DatabaseService.instance.getReadingItem(
        ref.noteId, ref.source.name, ref.bookId);
    if (ref != null) {
      SyncService.changes.addListener(_reloadReference);
      return;
    }
    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 600) {
        context.read<NotesProvider>().loadMore();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<NotesProvider>().loadNotes();
    });
  }

  @override
  void dispose() {
    SyncService.changes.removeListener(_reloadReference);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _reloadReference() {
    final ref = widget.reference;
    final db = SyncService.changes.value;
    if (!mounted || ref == null || db?.isActive != true) return;
    setState(() => _target = db!.getReadingItem(ref.noteId, ref.source.name, ref.bookId));
  }

  /// AI 摘要
  Future<void> _aiSummarize() async {
    if (_preparingSummary) return;
    setState(() => _preparingSummary = true);
    try {
      final provider = context.read<NotesProvider>();
      final notes = await provider.getAllMatchingNotes();
      if (!mounted) return;
      final bookTitles = notes.map((n) => n.bookTitle).where((t) => t.isNotEmpty).toSet().toList();
      final title = bookTitles.length == 1 ? bookTitles.first : '多本书籍合集';
      await generateSummary(context, title, '', notes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('摘要准备失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _preparingSummary = false);
    }
  }

  /// 导出笔记
  Future<void> _exportNotes(BuildContext context) async {
    try {
      await ExportService.exportAndShare();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('笔记已导出并分享'), backgroundColor: Color(0xFF07C160)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reference != null) return _buildReferencePage();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('笔记'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        actions: [
          // AI 摘要
          IconButton(
            icon: const Icon(Icons.auto_awesome_rounded),
            tooltip: 'AI 摘要',
            onPressed: _preparingSummary ? null : _aiSummarize,
          ),
          IconButton(icon: const Icon(Icons.history), tooltip: '历史摘要',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const AISummaryHistoryPage()))),
          // 导出
          IconButton(
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: '导出笔记',
            onPressed: () => _exportNotes(context),
          ),
        ],
      ),
      body: Consumer<NotesProvider>(
        builder: (context, provider, _) {
          // 搜索和筛选由数据库执行，列表只展示 provider 已加载的页。
          final filteredNotes = provider.notes;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 搜索栏 + 筛选按钮 + 计数（合并为一个白色容器，消除缝隙）
              Container(
                color: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 搜索栏
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '搜索笔记内容或书名...',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    setState(() {
                                      _searchController.clear();
                                      _searchQuery = '';
                                    });
                                    provider.setSearch('');
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: const Color(0xFFF0F0F0),
                          contentPadding: const EdgeInsets.symmetric(vertical: 0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                          provider.setSearch(value);
                        },
                      ),
                    ),
                    // 过滤按钮
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Row(
                        children: _filters.map((filter) {
                           final isSelected = provider.filter == filter;
                           final color = filter == ReadingFilter.favorites
                              ? const Color(0xFFFFB74D)
                              : const Color(0xFF2196F3);
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () {
                                 provider.setFilter(filter);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSelected ? color : const Color(0xFFF0F0F0),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                   filter.label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                    color: isSelected ? Colors.white : Colors.grey[700],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    // 计数
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            '共 ${provider.matchedCount} 条',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                          if (provider.isLoading) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 列表
              Expanded(
                child: _buildBody(context, provider, filteredNotes),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReferencePage() => Scaffold(
    appBar: AppBar(title: const Text('原笔记')),
    body: FutureBuilder<Map<String, dynamic>?>(future: _target, builder: (context, snapshot) {
      if (snapshot.hasError) return const Center(child: Text('原笔记加载失败'));
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final row = snapshot.data;
      if (row == null) return const Center(child: Text('原笔记已不存在；可在摘要历史中核对引用 ID'));
      final note = NoteItem(id: row['id'], bookId: row['book_id'],
        bookTitle: row['book_title'], content: row['content'],
        chapterTitle: row['chapter_title'], createdAt: row['created_at'],
        isFav: row['is_fav'] == 1,
        source: NoteSource.values.byName(row['source']));
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text('笔记 ID：${note.id}'),
        _NoteCard(key: ValueKey('${note.source.name}:${note.id}'),
          note: note, initiallyExpanded: true, onFavoriteToggle: () async {
          final db = DatabaseService.instance;
          if (note.source == NoteSource.bookmark) {
            await db.toggleBookmarkFavorite(note.id, !note.isFav);
          } else {
            await db.toggleFavorite(note.id, !note.isFav);
          }
          if (!mounted || !db.isActive) return;
          SyncService.changes.publish(db, favoritesOnly: true, bookIds: {note.bookId},
            itemIds: {'${note.source.name}:${note.id}'}, sources: {note.source.name});
        }),
      ]);
    }),
  );

  Widget _buildBody(BuildContext context, NotesProvider provider, List<NoteItem> filteredNotes) {
    // 加载中（首次）
    if (provider.isLoading && provider.notes.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在加载笔记...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // 错误状态
    if (provider.error != null && provider.notes.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => provider.loadNotes(),
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 64, color: Colors.red[200]),
                    const SizedBox(height: 16),
                    Text('加载失败', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                    const SizedBox(height: 8),
                    Text(provider.error!, style: TextStyle(fontSize: 12, color: Colors.grey[400])),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => provider.loadNotes(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 空状态
    if (filteredNotes.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => provider.loadNotes(),
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.note_alt_outlined, size: 64, color: Colors.grey[300]),
                    const SizedBox(height: 16),
                    Text(
                       provider.totalCount == 0 ? '暂无笔记，请先同步书架' : '没有匹配的笔记',
                      style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                    ),
                    if (provider.notes.isEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '下拉刷新重新加载',
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 正常列表
    final childIndices = <Key, int>{
      for (var i = 0; i < filteredNotes.length; i++)
        ValueKey('${filteredNotes[i].source.name}:${filteredNotes[i].id}'): i,
    };
    return RefreshIndicator(
      onRefresh: () => provider.loadNotes(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: filteredNotes.length + (provider.hasMore || provider.error != null ? 1 : 0),
        findChildIndexCallback: (key) => childIndices[key],
        itemBuilder: (context, index) {
          if (index == filteredNotes.length) {
            if (provider.isLoading) return const Center(child: CircularProgressIndicator());
            return TextButton(onPressed: provider.loadMore,
              child: Text(provider.error == null ? '加载更多' : '加载失败，点击重试: ${provider.error}'));
          }
          final note = filteredNotes[index];
          return _NoteCard(
            key: ValueKey('${note.source.name}:${note.id}'),
            note: note,
            onFavoriteToggle: () => provider.toggleFavorite(note),
          );
        },
      ),
    );
  }
}

class _NoteCard extends StatefulWidget {
  final bool initiallyExpanded;
  final NoteItem note;
  final Future<void> Function() onFavoriteToggle;

  const _NoteCard({
    super.key,
    this.initiallyExpanded = false,
    required this.note,
    required this.onFavoriteToggle,
  });

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  late bool _isExpanded = widget.initiallyExpanded;
  bool _saving = false;

  Future<void> _toggleFavorite() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onFavoriteToggle();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收藏保存失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    // 使用数据来源区分划线和笔记，与文本长度无关。
    final isHighlight = note.source == NoteSource.bookmark;
    final accentColor = isHighlight
        ? const Color(0xFFFF6B6B)
        : const Color(0xFF4ECDC4);
    final displayContent = _isExpanded
        ? note.content
        : (note.content.length > 80
            ? '${note.content.substring(0, 80)}...'
            : note.content);

    return GestureDetector(
      onTap: () {
        setState(() {
          _isExpanded = !_isExpanded;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 类型指示条
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 头部
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isHighlight ? '划线' : '笔记',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: accentColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          note.bookTitle,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                         onTap: _saving ? null : _toggleFavorite,
                        child: Icon(
                          note.isFav ? Icons.star_rounded : Icons.star_border_rounded,
                          size: 22,
                          color: note.isFav
                              ? const Color(0xFFFFB74D)
                              : Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 章节
                  if (note.chapterTitle.isNotEmpty)
                    Text(
                      note.chapterTitle,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  const SizedBox(height: 10),
                  // 内容
                  if (isHighlight)
                    Container(
                      padding: const EdgeInsets.only(left: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: accentColor.withValues(alpha: 0.6),
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(
                        displayContent,
                        style: TextStyle(fontSize: 14, height: 1.6, color: Colors.grey[800]),
                      ),
                    )
                  else
                    Text(
                      displayContent,
                      style: TextStyle(fontSize: 14, height: 1.6, color: Colors.grey[800]),
                    ),
                  // 展开/收起
                  if (note.content.length > 80) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: Colors.grey[400],
                        ),
                        Text(
                          _isExpanded ? '收起' : '展开全部',
                          style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  // 时间
                  Row(
                    children: [
                      Icon(Icons.access_time_rounded, size: 14, color: Colors.grey[400]),
                      const SizedBox(width: 4),
                      Text(
                        _formatTimestamp(note.createdAt),
                        style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
