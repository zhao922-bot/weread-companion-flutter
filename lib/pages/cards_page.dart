import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/bookmark.dart';
import '../services/database.dart';
import '../services/export_service.dart';
import '../services/card_image_renderer.dart';
import '../services/sync_service.dart';

// A bottom sheet can outlive the page that opened it. Share the owner's
// lifetime, and invalidate an in-flight export even when the user returns.
class _CardExportScope {
  bool active = true;
  int revision = 0;

  void setActive(bool value) {
    if (active && !value) revision++;
    active = value;
  }
}

class CardsPage extends StatefulWidget {
  final bool isActive;
  final CardImageRenderer renderer;
  const CardsPage({super.key, this.isActive = true,
    this.renderer = const CardImageRenderer()});

  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  String _searchQuery = '';
  Timer? _searchTimer;
  final TextEditingController _searchController = TextEditingController();
  int _currentPage = 1;
  int _selectedIndex = 0;
  final int _itemsPerPage = 100;
  bool _loading = true;
  String? _error;

  List<Bookmark> _allBookmarks = [];
  int _totalCount = 0;
  int _request = 0;
  String? _loadedQuery;
  int? _loadedPage;
  bool _exporting = false;
  bool _refreshPending = false;
  final _exportScope = _CardExportScope();

  @override
  void didUpdateWidget(covariant CardsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _exportScope.setActive(widget.isActive);
    if (!widget.isActive && oldWidget.isActive &&
        (_loading || _searchTimer?.isActive == true)) {
      _request++;
      _searchTimer?.cancel();
      _refreshPending = true;
      _loading = false;
    }
    if (widget.isActive && !oldWidget.isActive && _refreshPending) _loadBookmarks();
  }

  void _onExportChanged(bool exporting) {
    if (!mounted) return;
    setState(() => _exporting = exporting);
    if (!exporting && _refreshPending) {
      _refreshPending = false;
      _loadBookmarks();
    }
  }

  @override
  void initState() {
    super.initState();
    _exportScope.setActive(widget.isActive);
    SyncService.changes.addListener(_onSyncChanged);
    _loadBookmarks();
  }

  void _onSyncChanged() {
    final event = SyncService.changes;
    if (event.kind == SyncChangeKind.bookshelf || event.favoritesOnly ||
        (event.sources.isNotEmpty && !event.sources.contains('bookmark'))) {
      return;
    }
    if (SyncService.changes.value?.isActive == true) _loadBookmarks();
  }

  Future<void> _loadBookmarks({bool recount = true}) async {
    if (!mounted) return;
    if (_exporting || !widget.isActive) {
      _refreshPending = true;
      return;
    }
    // A sync/refresh during debounce already loads the current query.
    _searchTimer?.cancel();
    _refreshPending = false;
    final request = ++_request;
    final query = _searchQuery;
    final selected = _loadedQuery == query && _loadedPage == _currentPage &&
        _selectedIndex < _allBookmarks.length
        ? _allBookmarks[_selectedIndex] : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = DatabaseService.instance;
      final count = recount ? await db.countBookmarks(query: query) : _totalCount;
      if (!mounted || request != _request || !db.isActive) return;
      // didUpdateWidget invalidates _request when a loading page is hidden.
      final totalPages = (count / _itemsPerPage).ceil();
      final page = _currentPage.clamp(1, totalPages > 0 ? totalPages : 1);
      final raw = await db.getAllBookmarks(query: query,
          offset: (page - 1) * _itemsPerPage, limit: _itemsPerPage);
      if (!mounted || request != _request || !db.isActive) return;
      setState(() {
        _currentPage = page;
        _totalCount = count;
        _allBookmarks = raw.map((m) => Bookmark.fromJson(m)).toList();
        final selectedIndex = selected == null ? -1 : _allBookmarks.indexWhere(
            (item) => item.bookId == selected.bookId && item.bookmarkId == selected.bookmarkId);
        _selectedIndex = selectedIndex < 0 ? 0 : selectedIndex;
        _loadedQuery = query;
        _loadedPage = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Bookmark> get _pagedBookmarks => _allBookmarks;

  bool get _canChangePage => mounted && widget.isActive && !_exporting &&
      !_loading && _error == null &&
      _searchTimer?.isActive != true;

  int get _totalPages {
    final pages = (_totalCount / _itemsPerPage).ceil();
    return pages > 0 ? pages : 1;
  }

  @override
  void dispose() {
    _exportScope.setActive(false);
    _searchTimer?.cancel();
    SyncService.changes.removeListener(_onSyncChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _selectQuote(int index) {
    if (_exporting) return;
    final maxIndex = _pagedBookmarks.length - 1;
    setState(() {
      _selectedIndex = index.clamp(0, maxIndex < 0 ? 0 : maxIndex);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pagedBookmarks = _pagedBookmarks;
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
      body: AbsorbPointer(
        absorbing: _exporting,
        child: Column(
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
                                _searchTimer?.cancel();
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                  _currentPage = 1;
                                  _selectedIndex = 0;
                                });
                                _loadBookmarks();
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
                      if (value == _searchQuery) return;
                      _request++;
                      _searchTimer?.cancel();
                      setState(() {
                        _searchQuery = value;
                        _currentPage = 1;
                        _selectedIndex = 0;
                      });
                      _searchTimer = Timer(const Duration(milliseconds: 300), _loadBookmarks);
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
                          '共 $_totalCount 条',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _canChangePage && _currentPage > 1
                            ? () {
                                setState(() {
                                  _currentPage--;
                                  _selectedIndex = 0;
                                });
                                _loadBookmarks(recount: false);
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
                        onPressed: _canChangePage && _currentPage < _totalPages
                            ? () {
                                setState(() {
                                  _currentPage++;
                                  _selectedIndex = 0;
                                });
                                _loadBookmarks(recount: false);
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
                        onTap: _canChangePage ? () => _showJumpToPageDialog(context) : null,
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
            child: _buildContent(pagedBookmarks, isWide),
          ),
        ],
      )),
    );
  }

  Widget _buildContent(List<Bookmark> pagedBookmarks, bool isWide) {
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
                      _searchQuery.isEmpty ? '暂无引文，请先同步书架' : '没有匹配的引文',
                      style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                    ),
                    if (_searchQuery.isEmpty) ...[
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
        ? _buildWideLayout(pagedBookmarks, pagedBookmarks[_selectedIndex])
        : _buildNarrowLayout(pagedBookmarks);
  }

  Widget _buildWideLayout(List<Bookmark> pagedBookmarks, Bookmark selectedBookmark) {
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
          child: _CardPreview(key: ValueKey((selectedBookmark.bookId, selectedBookmark.bookmarkId)),
                  bookmark: selectedBookmark, scope: _exportScope,
                  renderer: widget.renderer, onExportChanged: _onExportChanged),
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
                    child: _CardPreview(key: ValueKey((bookmark.bookId, bookmark.bookmarkId)),
                      bookmark: bookmark, scope: _exportScope,
                      renderer: widget.renderer, onExportChanged: _onExportChanged),
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
    if (!_canChangePage) return;
    // The dialog can outlive its owning tab. Keep only the input value here;
    // TextFormField owns and disposes its internal controller with the route.
    var input = '';
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('跳转到页面'),
          content: TextFormField(
            initialValue: input,
            onChanged: (value) => input = value,
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
                final page = int.tryParse(input);
                if (_canChangePage && page != null && page >= 1 && page <= _totalPages) {
                  setState(() {
                    _currentPage = page;
                    _selectedIndex = 0;
                  });
                  _loadBookmarks(recount: false);
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
  final _CardExportScope scope;
  final CardImageRenderer renderer;
  final ValueChanged<bool> onExportChanged;

  const _CardPreview({super.key, required this.bookmark, required this.scope,
    required this.renderer, required this.onExportChanged});

  @override
  State<_CardPreview> createState() => _CardPreviewState();
}

class _CardPreviewState extends State<_CardPreview> {
  final GlobalKey _cardKey = GlobalKey();
  double _fontSize = 18.0;
  bool _exporting = false;
  Bookmark? _exportBookmark;
  double? _exportFontSize;
  bool _routeCurrent = true;
  int _routeRevision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeCurrent && !current) _routeRevision++;
    _routeCurrent = current;
  }

  /// 将卡片渲染为图片并分享
  Future<void> _exportAsImage() async {
    if (!mounted || _exporting || !widget.scope.active) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == false) return;
    final scope = widget.scope;
    final revision = scope.revision;
    final routeRevision = _routeRevision;
    DatabaseService db;
    try {
      db = DatabaseService.instance;
    } on StateError {
      return;
    }
    bool isCurrent() => mounted && scope.active && scope.revision == revision &&
        _routeRevision == routeRevision && route?.isCurrent != false && db.isActive;
    final snapshot = Bookmark.fromJson(Map<String, dynamic>.from(widget.bookmark.toJson()));
    final onExportChanged = widget.onExportChanged;
    _exportBookmark = snapshot;
    _exportFontSize = _fontSize;
    setState(() => _exporting = true);
    onExportChanged(true);
    final files = <XFile>[];
    var shared = false;
    Object? failure;
    try {
      final boundary = widget.renderer.findBoundary(_cardKey);
      if (boundary == null) return;

      final size = boundary.size;
      final view = View.of(context);
      final screenSize = view.physicalSize;
      final pixelRatio = view.devicePixelRatio;
      void checkLayout() {
        if (!boundary.attached || boundary.size != size ||
            view.physicalSize != screenSize || view.devicePixelRatio != pixelRatio) {
          throw StateError('布局已变化，请勿在导出时旋转屏幕，请重试');
        }
      }
      await ExportService.retryFailedCardExports();
      if (!isCurrent()) return;
      final tempDir = await getTemporaryDirectory();
      if (!isCurrent()) return;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final random = math.Random.secure();
      final id = List.generate(16, (_) => random.nextInt(256)
          .toRadixString(16).padLeft(2, '0')).join();
      // Render one bounded region at a time, never allocate a full long image.
      const pageHeight = 1600.0;
      for (var top = 0.0; top < size.height; top += pageHeight) {
        if (!isCurrent()) {
          return;
        }
        checkLayout();
        final height = math.min(pageHeight, size.height - top);
        var ratio = math.min(4.0, math.sqrt(8000000 / (size.width * height)));
        // Raster dimensions are rounded up; include that rounding in the budget.
        while ((size.width * ratio).ceil() * (height * ratio).ceil() > 8000000) {
          ratio *= 0.999;
        }
        final image = await widget.renderer.capture(
          boundary, Rect.fromLTWH(0, top, size.width, height), ratio);
        try {
          if (!isCurrent()) return;
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (!isCurrent()) return;
          if (bytes == null) throw StateError('图片编码失败');
          checkLayout();
          final file = File('${tempDir.path}/weread_card_${stamp}_${id}_${files.length + 1}.png');
          files.add(XFile(file.path));
          await file.writeAsBytes(bytes.buffer.asUint8List(
              bytes.offsetInBytes, bytes.lengthInBytes));
        } finally {
          image.dispose();
        }
      }
      if (!isCurrent()) return;
      checkLayout();
      await Share.shareXFiles(
        files,
        text: '「${snapshot.markText}」—— ${snapshot.bookTitle}',
      );
      // The native share cannot be revoked once opened. Keep its files until
      // it completes, then clean them if this page/session was cancelled.
      shared = isCurrent();
    } catch (e) {
      failure = e;
    } finally {
      if (!shared) {
        try {
          await ExportService.removeCardExports(files.map((file) => file.path));
        } catch (e) {
          // Preserve the export error and release both interaction locks even
          // when cleanup fails. The next attempt retries these deletions first.
          failure ??= e;
        }
      }
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportBookmark = null;
          _exportFontSize = null;
        });
      }
      if (mounted && failure != null && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $failure'), backgroundColor: Colors.red),
        );
      }
      onExportChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const accentColor = Color(0xFF4A7CF7);
    final bookmark = _exportBookmark ?? widget.bookmark;
    final fontSize = _exportFontSize ?? _fontSize;

    return Column(
      children: [
        // 卡片内容（RepaintBoundary 包裹，用于截图）
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: CardRepaintBoundary(
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
                      bookmark.markText,
                      style: TextStyle(
                        fontSize: fontSize,
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
                      '—— ${bookmark.bookTitle}',
                      style: TextStyle(
                        fontSize: fontSize * 0.78,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (bookmark.chapterTitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        bookmark.chapterTitle,
                        style: TextStyle(fontSize: fontSize * 0.67, color: Colors.grey[400]),
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
                    onChanged: _exporting ? null : (v) => setState(() => _fontSize = v),
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
