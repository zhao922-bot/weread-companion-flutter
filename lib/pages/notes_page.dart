import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/notes_provider.dart';
import '../providers/app_config_provider.dart';
import '../services/ai_service.dart';
import '../services/export_service.dart';
import '../services/config.dart';


class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String _searchQuery = '';
  String _selectedFilter = '全部划线';
  final TextEditingController _searchController = TextEditingController();

  final List<String> _filters = ['全部划线', '全部笔记', '收藏'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotesProvider>().loadNotes();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// AI 摘要
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

    final provider = context.read<NotesProvider>();
    final notes = provider.notes;
    if (notes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无笔记可摘要'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    // 显示加载对话框
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
    final highlights = notes.map((n) => n.content).where((c) => c.isNotEmpty).toList();
    final bookTitles = notes.map((n) => n.bookTitle).where((t) => t.isNotEmpty).toSet().toList();

    // 多本书时使用通用标题，避免拼接书名导致 AI 困惑
    final title = bookTitles.length == 1 ? bookTitles.first : '多本书籍合集（${bookTitles.length}本）';
    final result = await ai.summarizeBook(
      title,
      bookTitles.length == 1 ? '' : bookTitles.join('、'),
      highlights,
    );

    if (mounted) Navigator.pop(context); // 关闭加载对话框

    if (result != null && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('AI 摘要'),
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
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI 摘要生成失败，请检查 API 配置'), backgroundColor: Colors.red),
      );
    }
  }

  /// 导出笔记
  Future<void> _exportNotes(BuildContext context) async {
    try {
      await ExportService.exportAndShare();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('笔记已导出并分享'), backgroundColor: Color(0xFF07C160)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: () => _aiSummarize(context),
          ),
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
          // 同步搜索和过滤到 provider
          final filteredNotes = _applyLocalFilter(provider.notes);

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
                          final isSelected = _selectedFilter == filter;
                          final color = filter == '收藏'
                              ? const Color(0xFFFFB74D)
                              : const Color(0xFF2196F3);
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () {
                                setState(() => _selectedFilter = filter);
                                provider.setFilter(filter);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSelected ? color : const Color(0xFFF0F0F0),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  filter,
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
                            '共 ${filteredNotes.length} 条',
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

  List<NoteItem> _applyLocalFilter(List<NoteItem> notes) {
    // Provider 已经处理了搜索和过滤，这里直接返回
    return notes;
  }

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
                      provider.notes.isEmpty ? '暂无笔记，请先同步书架' : '没有匹配的笔记',
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
    return RefreshIndicator(
      onRefresh: () => provider.loadNotes(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: filteredNotes.length,
        itemBuilder: (context, index) {
          final note = filteredNotes[index];
          return _NoteCard(
            note: note,
            onFavoriteToggle: () => provider.toggleFavorite(note),
          );
        },
      ),
    );
  }
}

class _NoteCard extends StatefulWidget {
  final NoteItem note;
  final VoidCallback onFavoriteToggle;

  const _NoteCard({
    required this.note,
    required this.onFavoriteToggle,
  });

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    // 内容较长视为笔记，较短视为划线
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
                        onTap: widget.onFavoriteToggle,
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
