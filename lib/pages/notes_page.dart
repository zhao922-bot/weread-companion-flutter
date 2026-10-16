import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:provider/provider.dart';
import '../providers/notes_provider.dart';
import '../services/export_service.dart';
import '../services/database.dart';
import '../services/sync_service.dart';
import '../models/ai_summary.dart';
import '../widgets/account_session_guard.dart';
import 'ai_summary_page.dart';

class NotesPage extends StatefulWidget {
  final SummaryReference? reference;
  final DatabaseService? database;
  final bool isActive;
  const NotesPage(
      {super.key, this.reference, this.database, this.isActive = true});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final _filters = ReadingFilter.values;
  bool _preparingSummary = false;
  bool _exporting = false;
  Future<Map<String, dynamic>?>? _target;
  NotesProvider? _provider;
  DatabaseService? _referenceDatabase;

  @override
  void initState() {
    super.initState();
    final ref = widget.reference;
    if (ref != null) {
      final db =
          _referenceDatabase = widget.database ?? DatabaseService.instance;
      if (db.isActive) {
        _target = db.getReadingItem(ref.noteId, ref.source.name, ref.bookId);
      }
      SyncService.changes.addListener(_reloadReference);
      return;
    }
    _scrollController.addListener(() {
      if (widget.isActive && _scrollController.position.extentAfter < 600) {
        final provider = context.read<NotesProvider>();
        if (provider.error == null) provider.loadMore();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _provider = context.read<NotesProvider>();
      _provider!.setActive(widget.isActive);
    });
  }

  @override
  void didUpdateWidget(covariant NotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reference != null || oldWidget.isActive == widget.isActive) {
      return;
    }
    if (!widget.isActive) {
      _provider?.setActive(false);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _provider?.setActive(widget.isActive);
      });
    }
  }

  @override
  void dispose() {
    _provider?.setActive(false);
    SyncService.changes.removeListener(_reloadReference);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _reloadReference() {
    final ref = widget.reference;
    final event = SyncService.changes;
    final db = event.value;
    if (!mounted ||
        ref == null ||
        db?.isActive != true ||
        !identical(db, _referenceDatabase)) {
      return;
    }
    if (event.kind == SyncChangeKind.bookshelf ||
        (event.bookIds.isNotEmpty && !event.bookIds.contains(ref.bookId)) ||
        (event.sources.isNotEmpty &&
            !event.sources.contains(ref.source.name)) ||
        (event.itemIds.isNotEmpty &&
            !event.itemIds.contains('${ref.source.name}:${ref.noteId}'))) {
      return;
    }
    _loadReference();
  }

  void _loadReference() {
    final ref = widget.reference!;
    final db = _referenceDatabase!;
    if (!mounted || !db.isActive) return;
    final target = db.getReadingItem(ref.noteId, ref.source.name, ref.bookId);
    setState(() {
      _target = target;
    });
  }

  /// AI 摘要
  Future<void> _aiSummarize() async {
    if (!mounted || _preparingSummary) return;
    setState(() => _preparingSummary = true);
    DatabaseService? owner;
    try {
      final db = owner = DatabaseService.instance;
      final provider = context.read<NotesProvider>();
      final notes = await provider.getSummaryNotes();
      if (!mounted || !db.isActive) return;
      final bookTitles = notes
          .map((n) => n.bookTitle)
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList();
      final title = bookTitles.length == 1 ? bookTitles.first : '多本书籍合集';
      await generateSummary(context, title, '', notes, database: db);
    } catch (e) {
      if (mounted && owner?.isActive == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('摘要准备失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _preparingSummary = false);
    }
  }

  /// 导出笔记
  Future<void> _exportNotes(BuildContext context) async {
    if (!mounted || _exporting) return;
    setState(() => _exporting = true);
    DatabaseService? owner;
    try {
      owner = DatabaseService.instance;
      await ExportService.exportAndShare();
      if (context.mounted && owner.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('笔记已导出并分享'), backgroundColor: ReadAmberPalette.of(context).action),
        );
      }
    } catch (e) {
      if (context.mounted && owner?.isActive == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: ReadAmberColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reference != null) {
      return AccountSessionGuard(
          database: _referenceDatabase!, child: _buildReferencePage());
    }
    return Scaffold(
      backgroundColor: ReadAmberPalette.of(context).canvas,
      appBar: AppBar(
        title: const Text('笔记'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: ReadAmberPalette.of(context).canvas,
        foregroundColor: ReadAmberPalette.of(context).ink,
        actions: [
          // AI 摘要
          IconButton(
            icon: const Icon(Icons.auto_awesome_rounded),
            tooltip: 'AI 摘要',
            onPressed: _preparingSummary ? null : _aiSummarize,
          ),
          IconButton(
              icon: const Icon(Icons.history),
              tooltip: '历史摘要',
              onPressed: () {
                final db = DatabaseService.instance;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AISummaryHistoryPage(database: db)));
              }),
          // 导出
          IconButton(
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: '导出笔记',
            onPressed: _exporting ? null : () => _exportNotes(context),
          ),
        ],
      ),
      body: ReadAmberContent(maxWidth: 960, child: Consumer<NotesProvider>(
        builder: (context, provider, _) {
          // 搜索和筛选由数据库执行，列表只展示 provider 已加载的页。
          final filteredNotes = provider.notes;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 搜索栏 + 筛选按钮 + 计数（合并为一个白色容器，消除缝隙）
              Container(
                color: ReadAmberPalette.of(context).surface,
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
                          hintStyle: TextStyle(color: ReadAmberPalette.of(context).muted),
                          prefixIcon:
                              Icon(Icons.search, color: ReadAmberPalette.of(context).muted),
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
                          fillColor: ReadAmberPalette.of(context).surfaceMuted,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 0),
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
                      child: Wrap(
                        runSpacing: 8,
                        children: _filters.map((filter) {
                          final isSelected = provider.filter == filter;
                          final color = filter == ReadingFilter.favorites
                              ? ReadAmberPalette.of(context).amberText
                              : ReadAmberPalette.of(context).inkSoft;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () {
                                provider.setFilter(filter);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? color
                                      : ReadAmberPalette.of(context).surfaceMuted,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  filter.label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    color: isSelected
                                        ? ReadAmberPalette.of(context).surface
                                        : ReadAmberPalette.of(context).inkSoft,
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
                            style: TextStyle(
                                fontSize: 12, color: ReadAmberPalette.of(context).muted),
                          ),
                          if (provider.isLoading) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.5),
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
      )),
    );
  }

  Widget _buildReferencePage() => Scaffold(
        appBar: AppBar(title: const Text('原笔记')),
        body: FutureBuilder<Map<String, dynamic>?>(
            future: _target,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('原笔记加载失败'),
                  TextButton(
                      onPressed: _loadReference, child: const Text('重试')),
                ]));
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final row = snapshot.data;
              if (row == null) {
                return const Center(child: Text('原笔记已不存在；可在摘要历史中核对引用 ID'));
              }
              final note = NoteItem(
                  id: row['id'],
                  bookId: row['book_id'],
                  bookTitle: row['book_title'],
                  content: row['content'],
                  chapterTitle: row['chapter_title'],
                  createdAt: row['created_at'],
                  isFav: row['is_fav'] == 1,
                  source: NoteSource.values.byName(row['source']));
              return ListView(padding: const EdgeInsets.all(16), children: [
                Text('笔记 ID：${note.id}'),
                _NoteCard(
                    key: ValueKey('${note.source.name}:${note.id}'),
                    note: note,
                    initiallyExpanded: true,
                    onFavoriteToggle: () async {
                      final db = _referenceDatabase!;
                      if (!mounted || !db.isActive) return;
                      if (note.source == NoteSource.bookmark) {
                        await db.toggleBookmarkFavorite(note.id, !note.isFav);
                      } else {
                        await db.toggleFavorite(note.id, !note.isFav);
                      }
                      if (!mounted || !db.isActive) return;
                      SyncService.changes.publish(db,
                          favoritesOnly: true,
                          bookIds: {note.bookId},
                          itemIds: {'${note.source.name}:${note.id}'},
                          sources: {note.source.name});
                    }),
              ]);
            }),
      );

  Widget _buildScrollableState(NotesProvider provider, List<Widget> children) =>
      LayoutBuilder(
          builder: (context, constraints) => RefreshIndicator(
                onRefresh: provider.loadNotes,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: children,
                        ),
                      ),
                    )
                  ],
                ),
              ));

  Widget _buildBody(BuildContext context, NotesProvider provider,
      List<NoteItem> filteredNotes) {
    // 加载中（首次）
    if (provider.isLoading && provider.notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在加载笔记...', style: TextStyle(color: ReadAmberPalette.of(context).muted)),
          ],
        ),
      );
    }

    // 错误状态
    if (provider.error != null && provider.notes.isEmpty) {
      return _buildScrollableState(provider, [
        Icon(Icons.error_outline, size: 64, color: ReadAmberPalette.of(context).error),
        const SizedBox(height: 16),
        Text('加载失败', style: TextStyle(fontSize: 16, color: ReadAmberPalette.of(context).muted)),
        const SizedBox(height: 8),
        Text(provider.error!,
            style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted)),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () => provider.loadNotes(),
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ]);
    }

    // 空状态
    if (filteredNotes.isEmpty) {
      return _buildScrollableState(provider, [
        Icon(Icons.note_alt_outlined, size: 64, color: ReadAmberPalette.of(context).outline),
        const SizedBox(height: 16),
        Text(
          provider.totalCount == 0 ? '暂无笔记，请先同步书架' : '没有匹配的笔记',
          style: TextStyle(fontSize: 16, color: ReadAmberPalette.of(context).muted),
        ),
        if (provider.notes.isEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '下拉刷新重新加载',
            style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
          ),
        ],
      ]);
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
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: filteredNotes.length +
            (provider.hasMore || provider.error != null ? 1 : 0),
        findChildIndexCallback: (key) => childIndices[key],
        itemBuilder: (context, index) {
          if (index == filteredNotes.length) {
            if (provider.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            return TextButton(
                onPressed: provider.loadMore,
                child: Text(provider.error == null
                    ? '加载更多'
                    : '加载失败，点击重试: ${provider.error}'));
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
    if (!mounted || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onFavoriteToggle();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('收藏保存失败: $e')));
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
    final accentColor =
        isHighlight ? ReadAmberPalette.of(context).amberText : ReadAmberPalette.of(context).inkSoft;
    // Inspect only the preview boundary, preserving emoji/combining sequences
    // without scanning the rest of a potentially very long note.
    final preview = note.content.characters.take(81).toList(growable: false);
    final hasMore = preview.length > 80;
    final displayContent = _isExpanded || !hasMore
        ? note.content
        : '${preview.take(80).join()}...';

    return GestureDetector(
      onTap: () {
        setState(() {
          _isExpanded = !_isExpanded;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: ReadAmberPalette.of(context).surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: ReadAmberColors.ink.withValues(alpha: 0.05),
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
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
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
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: ReadAmberPalette.of(context).ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: _saving ? null : _toggleFavorite,
                        child: Icon(
                          note.isFav
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 22,
                          color: note.isFav
                              ? ReadAmberPalette.of(context).amberText
                              : ReadAmberPalette.of(context).outline,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 章节
                  if (note.chapterTitle.isNotEmpty)
                    Text(
                      note.chapterTitle,
                      style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
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
                        style: TextStyle(
                            fontSize: 14, height: 1.6, color: ReadAmberPalette.of(context).inkSoft),
                      ),
                    )
                  else
                    Text(
                      displayContent,
                      style: TextStyle(
                          fontSize: 14, height: 1.6, color: ReadAmberPalette.of(context).inkSoft),
                    ),
                  // 展开/收起
                  if (hasMore) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: ReadAmberPalette.of(context).muted,
                        ),
                        Text(
                          _isExpanded ? '收起' : '展开全部',
                          style:
                              TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  // 时间
                  Row(
                    children: [
                      Icon(Icons.access_time_rounded,
                          size: 14, color: ReadAmberPalette.of(context).muted),
                      const SizedBox(width: 4),
                      Flexible(
                          child: Text(
                        _formatTimestamp(note.createdAt),
                        style: TextStyle(fontSize: 11, color: ReadAmberPalette.of(context).muted),
                      )),
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
