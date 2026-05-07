import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/bookmark.dart';
import '../services/database.dart';

class CardsPage extends StatefulWidget {
  const CardsPage({super.key});

  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  int _currentPage = 1;
  int _selectedIndex = 0;
  final int _itemsPerPage = 100;
  bool _loading = true;
  String? _error;

  List<Bookmark> _allBookmarks = [];

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await DatabaseService.instance.getAllBookmarks();
      setState(() {
        _allBookmarks = raw.map((m) => Bookmark.fromJson(m)).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Bookmark> get _filteredBookmarks {
    if (_searchQuery.isEmpty) return _allBookmarks;
    final q = _searchQuery.toLowerCase();
    return _allBookmarks.where((b) =>
      b.markText.toLowerCase().contains(q) ||
      b.bookTitle.toLowerCase().contains(q)
    ).toList();
  }

  List<Bookmark> get _pagedBookmarks {
    final filtered = _filteredBookmarks;
    final totalPages = (filtered.length / _itemsPerPage).ceil();
    final safeCurrentPage = _currentPage.clamp(1, totalPages > 0 ? totalPages : 1);
    final start = (safeCurrentPage - 1) * _itemsPerPage;
    final end = (start + _itemsPerPage).clamp(0, filtered.length);
    if (start >= filtered.length) return [];
    return filtered.sublist(start, end);
  }

  int get _totalPages {
    final total = _filteredBookmarks.length;
    return (total / _itemsPerPage).ceil().clamp(1, 9999);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectQuote(int index) {
    final maxIndex = _pagedBookmarks.length - 1;
    setState(() {
      _selectedIndex = index.clamp(0, maxIndex < 0 ? 0 : maxIndex);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pagedBookmarks = _pagedBookmarks;
    final hasSelected = _selectedIndex < pagedBookmarks.length;
    final selectedBookmark = hasSelected ? pagedBookmarks[_selectedIndex] : null;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 600;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('书签卡片'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 搜索栏 + 分页导航（合并为一个白色容器，消除缝隙）
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
                      hintText: '搜索引文或书名...',
                      hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                      prefixIcon: Icon(Icons.search, color: Colors.grey[400], size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                  _currentPage = 1;
                                  _selectedIndex = 0;
                                });
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
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 14),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                        _currentPage = 1;
                        _selectedIndex = 0;
                      });
                    },
                  ),
                ),
                // 分页导航
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          '共 ${_filteredBookmarks.length} 条',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _currentPage > 1
                            ? () {
                                setState(() {
                                  _currentPage--;
                                  _selectedIndex = 0;
                                });
                              }
                            : null,
                        icon: const Icon(Icons.chevron_left_rounded),
                        iconSize: 22,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        color: _currentPage > 1 ? const Color(0xFF2196F3) : Colors.grey[300],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2196F3).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '$_currentPage/$_totalPages',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2196F3),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _currentPage < _totalPages
                            ? () {
                                setState(() {
                                  _currentPage++;
                                  _selectedIndex = 0;
                                });
                              }
                            : null,
                        icon: const Icon(Icons.chevron_right_rounded),
                        iconSize: 22,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        color: _currentPage < _totalPages
                            ? const Color(0xFF2196F3)
                            : Colors.grey[300],
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => _showJumpToPageDialog(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '跳页',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 主内容
          Expanded(
            child: _buildContent(pagedBookmarks, selectedBookmark, isWide),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(List<Bookmark> pagedBookmarks, Bookmark? selectedBookmark, bool isWide) {
    // 加载中
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在加载引文...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // 错误
    if (_error != null) {
      return RefreshIndicator(
        onRefresh: _loadBookmarks,
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
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _loadBookmarks,
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
    if (pagedBookmarks.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadBookmarks,
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.format_quote_rounded, size: 64, color: Colors.grey[300]),
                    const SizedBox(height: 16),
                    Text(
                      _allBookmarks.isEmpty ? '暂无引文，请先同步书架' : '没有匹配的引文',
                      style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                    ),
                    if (_allBookmarks.isEmpty) ...[
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

    // 正常内容
    return isWide
        ? _buildWideLayout(pagedBookmarks, selectedBookmark)
        : _buildNarrowLayout(pagedBookmarks);
  }

  Widget _buildWideLayout(List<Bookmark> pagedBookmarks, Bookmark? selectedBookmark) {
    return Row(
      children: [
        Expanded(
          flex: 1,
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: Colors.grey[200]!, width: 1)),
            ),
            child: _buildQuoteList(pagedBookmarks),
          ),
        ),
        Expanded(
          flex: 1,
          child: selectedBookmark != null
              ? _CardPreview(bookmark: selectedBookmark)
              : Center(
                  child: Text('选择一条引文', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout(List<Bookmark> pagedBookmarks) {
    return _buildQuoteList(pagedBookmarks, enableTapPreview: true);
  }

  Widget _buildQuoteList(List<Bookmark> pagedBookmarks, {bool enableTapPreview = false}) {
    return RefreshIndicator(
      onRefresh: _loadBookmarks,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: pagedBookmarks.length,
        itemBuilder: (context, index) {
          final bookmark = pagedBookmarks[index];
          final isSelected = index == _selectedIndex;
          final accentColor = _getAccentColor(index);

          return GestureDetector(
            onTap: () {
              _selectQuote(index);
              if (enableTapPreview) {
                _showCardPreviewDialog(context, bookmark);
              }
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFE3F2FD) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? const Color(0xFF2196F3) : Colors.grey[200]!,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 3,
                        height: 14,
                        decoration: BoxDecoration(
                          color: accentColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${bookmark.bookTitle}${bookmark.chapterTitle.isNotEmpty ? ' · ${bookmark.chapterTitle}' : ''}',
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    bookmark.markText,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: isSelected ? const Color(0xFF1565C0) : Colors.grey[800],
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showCardPreviewDialog(BuildContext context, Bookmark bookmark) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: _CardPreview(bookmark: bookmark),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showJumpToPageDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('跳转到页面'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '输入页码 (1-$_totalPages)',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final page = int.tryParse(controller.text);
                if (page != null && page >= 1 && page <= _totalPages) {
                  setState(() {
                    _currentPage = page;
                    _selectedIndex = 0;
                  });
                  Navigator.pop(context);
                }
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Color _getAccentColor(int index) {
    const colors = [
      Color(0xFFFF6B6B),
      Color(0xFF4ECDC4),
      Color(0xFF45B7D1),
      Color(0xFFFFA07A),
      Color(0xFF98D8C8),
      Color(0xFFF7DC6F),
      Color(0xFFBB8FCE),
      Color(0xFF85C1E9),
    ];
    return colors[index % colors.length];
  }
}

/// 卡片预览组件（支持调节文字大小 + 导出图片）
class _CardPreview extends StatefulWidget {
  final Bookmark bookmark;

  const _CardPreview({required this.bookmark});

  @override
  State<_CardPreview> createState() => _CardPreviewState();
}

class _CardPreviewState extends State<_CardPreview> {
  final GlobalKey _cardKey = GlobalKey();
  double _fontSize = 18.0;
  bool _exporting = false;

  /// 将卡片渲染为图片并分享
  Future<void> _exportAsImage() async {
    setState(() => _exporting = true);
    try {
      final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

      // 4x 像素密度，保证高清输出
      final image = await boundary.toImage(pixelRatio: 4.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final pngBytes = byteData.buffer.asUint8List();
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/weread_card_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes);

      await Share.shareXFiles(
        [XFile(file.path)],
        text: '「${widget.bookmark.markText}」—— ${widget.bookmark.bookTitle}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const accentColor = Color(0xFF4A7CF7);

    return Column(
      children: [
        // 卡片内容（RepaintBoundary 包裹，用于截图）
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: RepaintBoundary(
              key: _cardKey,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0x0D4A7CF7), // accentColor 0.05
                      Color(0x054A7CF7), // accentColor 0.02
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.15),
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.format_quote_rounded,
                      size: 32,
                      color: Color(0x4D4A7CF7), // accentColor 0.3
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.bookmark.markText,
                      style: TextStyle(
                        fontSize: _fontSize,
                        height: 1.8,
                        color: const Color(0xFF1A1A1A),
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Container(width: 40, height: 1, color: Colors.grey[300]),
                    const SizedBox(height: 12),
                    Text(
                      '—— ${widget.bookmark.bookTitle}',
                      style: TextStyle(
                        fontSize: _fontSize * 0.78,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (widget.bookmark.chapterTitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.bookmark.chapterTitle,
                        style: TextStyle(fontSize: _fontSize * 0.67, color: Colors.grey[400]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        // 底部控制栏：字号调节 + 导出按钮
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey[200]!, width: 0.5)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              // 字号标签
              Icon(Icons.format_size_rounded, size: 18, color: Colors.grey[500]),
              // 字号滑块
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: accentColor,
                    thumbColor: accentColor,
                    overlayColor: accentColor.withValues(alpha: 0.1),
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: _fontSize,
                    min: 12,
                    max: 28,
                    divisions: 16,
                    label: _fontSize.toInt().toString(),
                    onChanged: (v) => setState(() => _fontSize = v),
                  ),
                ),
              ),
              Text(
                '${_fontSize.toInt()}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              // 导出按钮
              SizedBox(
                height: 34,
                child: ElevatedButton.icon(
                  onPressed: _exporting ? null : _exportAsImage,
                  icon: _exporting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.ios_share_rounded, size: 16),
                  label: Text(_exporting ? '导出中...' : '导出图片', style: const TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
