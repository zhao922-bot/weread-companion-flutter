import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/bookmark.dart';
import '../services/ai_service.dart';
import '../services/config.dart';
import '../services/database.dart';
import '../services/export_service.dart';
import '../services/card_image_renderer.dart';
import '../services/sync_service.dart';
import '../widgets/account_session_guard.dart';

/// 金句卡片配色模板。
enum CardTemplate {
  paper,
  ink,
  minimal;

  String get label => switch (this) {
    paper => '纸白',
    ink => '墨青',
    minimal => '极简',
  };
}

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

typedef _CardBookTitleChange = ({String bookId, String? title});

// A quick card can change the title of a wide preview kept alive offstage.
final _cardBookTitleChanges = Expando<StreamController<_CardBookTitleChange>>();

void _noopExport(bool _) {}

/// 打开单条引文的金句卡片预览与导出弹窗。
Future<void> showQuoteCardSheet(
  BuildContext context,
  Bookmark bookmark, {
  CardImageRenderer renderer = const CardImageRenderer(),
  AIService Function(AppConfig)? aiServiceFactory,
}) async {
  final DatabaseService database;
  try {
    database = DatabaseService.instance;
  } on StateError {
    return;
  }
  final scope = _CardExportScope();
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuoteCardSheet(
        bookmark: bookmark,
        database: database,
        scope: scope,
        renderer: renderer,
        aiServiceFactory: aiServiceFactory,
      ),
    );
  } finally {
    scope.setActive(false);
  }
}

class CardsPage extends StatefulWidget {
  final bool isActive;
  final bool embedded;
  final CardImageRenderer renderer;
  final AIService Function(AppConfig)? aiServiceFactory;
  const CardsPage({
    super.key,
    this.isActive = true,
    this.embedded = false,
    this.renderer = const CardImageRenderer(),
    this.aiServiceFactory,
  });

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
  late DatabaseService _bookmarkDatabase;

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
        _bookmarkDatabase = db;
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
    final body = AbsorbPointer(
      absorbing: _exporting,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 搜索栏 + 分页导航（合并为一个白色容器，消除缝隙）
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
                      hintText: '搜索引文或书名...',
                      hintStyle: TextStyle(color: ReadAmberPalette.of(context).muted, fontSize: 14),
                      prefixIcon: Icon(Icons.search, color: ReadAmberPalette.of(context).muted, size: 20),
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
                      fillColor: ReadAmberPalette.of(context).surfaceMuted,
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
                          style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
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
                        color: _currentPage > 1 ? ReadAmberPalette.of(context).inkSoft : ReadAmberPalette.of(context).outline,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: ReadAmberPalette.of(context).inkSoft.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '$_currentPage/$_totalPages',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: ReadAmberPalette.of(context).inkSoft,
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
                            ? ReadAmberPalette.of(context).inkSoft
                            : ReadAmberPalette.of(context).outline,
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: _canChangePage ? () => _showJumpToPageDialog(context) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: ReadAmberPalette.of(context).outline),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '跳页',
                            style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
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
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: ReadAmberPalette.of(context).canvas,
      appBar: AppBar(
        title: const Text('书签卡片'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: ReadAmberPalette.of(context).canvas,
        foregroundColor: ReadAmberPalette.of(context).ink,
      ),
      body: body,
    );
  }

  Widget _buildContent(List<Bookmark> pagedBookmarks, bool isWide) {
    // 加载中
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在加载引文...', style: TextStyle(color: ReadAmberPalette.of(context).muted)),
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
                    Icon(Icons.error_outline, size: 64, color: ReadAmberPalette.of(context).error),
                    const SizedBox(height: 16),
                    Text('加载失败', style: TextStyle(fontSize: 16, color: ReadAmberPalette.of(context).muted)),
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
                    Icon(Icons.format_quote_rounded, size: 64, color: ReadAmberPalette.of(context).outline),
                    const SizedBox(height: 16),
                    Text(
                      _searchQuery.isEmpty ? '暂无引文，请先同步书架' : '没有匹配的引文',
                      style: TextStyle(fontSize: 16, color: ReadAmberPalette.of(context).muted),
                    ),
                    if (_searchQuery.isEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '下拉刷新重新加载',
                        style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted),
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
          flex: 2,
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: ReadAmberPalette.of(context).surfaceMuted, width: 1)),
            ),
            child: _buildQuoteList(pagedBookmarks),
          ),
        ),
        Expanded(
          key: ObjectKey(_bookmarkDatabase),
          flex: 3,
          child: _CardPreview(
              key: ValueKey((selectedBookmark.bookId, selectedBookmark.bookmarkId)),
              bookmark: selectedBookmark,
              database: _bookmarkDatabase,
              scope: _exportScope,
              renderer: widget.renderer,
              aiServiceFactory: widget.aiServiceFactory,
              onExportChanged: _onExportChanged),
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
                color: isSelected ? ReadAmberPalette.of(context).paper : ReadAmberPalette.of(context).surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? ReadAmberPalette.of(context).inkSoft : ReadAmberPalette.of(context).surfaceMuted,
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
                          style: TextStyle(fontSize: 11, color: ReadAmberPalette.of(context).muted),
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
                      color: isSelected ? ReadAmberPalette.of(context).ink : ReadAmberPalette.of(context).inkSoft,
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
    final database = _bookmarkDatabase;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuoteCardSheet(
        bookmark: bookmark,
        database: database,
        scope: _exportScope,
        renderer: widget.renderer,
        aiServiceFactory: widget.aiServiceFactory,
        onExportChanged: _onExportChanged,
      ),
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
    final colors = [
      ReadAmberPalette.of(context).amberText,
      ReadAmberPalette.of(context).inkSoft,
      ReadAmberPalette.of(context).success,
      ReadAmberPalette.of(context).amberText,
      ReadAmberPalette.of(context).inkSoft,
      ReadAmberPalette.of(context).amberText,
      ReadAmberPalette.of(context).success,
      ReadAmberPalette.of(context).inkSoft,
    ];
    return colors[index % colors.length];
  }
}

/// 卡片预览组件（支持调节文字大小 + 导出图片）
class _CardPreview extends StatefulWidget {
  final Bookmark bookmark;
  final DatabaseService database;
  final _CardExportScope scope;
  final CardImageRenderer renderer;
  final ValueChanged<bool> onExportChanged;
  final ScrollController? scrollController;
  final AIService Function(AppConfig)? aiServiceFactory;

  const _CardPreview({
    super.key,
    required this.bookmark,
    required this.database,
    required this.scope,
    required this.renderer,
    required this.onExportChanged,
    this.scrollController,
    this.aiServiceFactory,
  });

  @override
  State<_CardPreview> createState() => _CardPreviewState();
}

class _CardPreviewState extends State<_CardPreview> {
  final GlobalKey _cardKey = GlobalKey();
  double _fontSize = 18.0;
  CardTemplate _template = CardTemplate.paper;
  bool _centerAlign = true;
  bool _showChapter = true;
  bool _showWatermark = true;
  bool _exporting = false;
  bool _interpreting = false;
  Bookmark? _exportBookmark;
  double? _exportFontSize;
  String? _customBookTitle;
  bool _titleBusy = true;
  bool _titleChanged = false;
  late final _titleChanges = _cardBookTitleChanges[widget.database] ??=
      StreamController<_CardBookTitleChange>.broadcast(sync: true);
  late final StreamSubscription<_CardBookTitleChange> _titleSubscription;
  bool _routeCurrent = true;
  int _routeRevision = 0;

  String get _effectiveBookTitle =>
      _customBookTitle ?? widget.bookmark.bookTitle;

  bool get _canUseBookTitle => !_exporting && !_titleBusy;

  @override
  void initState() {
    super.initState();
    _titleSubscription = _titleChanges.stream.listen(_onBookTitleChanged);
    unawaited(_loadBookTitle());
  }

  @override
  void dispose() {
    unawaited(_titleSubscription.cancel());
    super.dispose();
  }

  Future<void> _loadBookTitle() async {
    final database = widget.database;
    try {
      final title = await database.getCardBookTitle(widget.bookmark.bookId);
      database.requireActive();
      // A commit may have arrived while this lookup was in flight.
      if (!_titleChanged) _customBookTitle = title;
    } catch (_) {
      if (mounted && database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('卡片书名加载失败，请重新打开卡片重试'),
        ));
      }
    } finally {
      if (mounted) setState(() => _titleBusy = false);
    }
  }

  void _onBookTitleChanged(_CardBookTitleChange change) {
    if (change.bookId != widget.bookmark.bookId) return;
    setState(() {
      _titleChanged = true;
      _customBookTitle = change.title;
    });
  }

  Future<void> _editBookTitle() async {
    final database = widget.database;
    final bookId = widget.bookmark.bookId;
    var input = _effectiveBookTitle;
    final edited = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑卡片书名'),
        content: TextFormField(
          initialValue: input,
          onChanged: (value) => input = value,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入想要展示的书籍名称',
            helperText: '同一本书的金句卡片共用此书名',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (edited == null || !mounted || !widget.scope.active || !database.isActive) {
      return;
    }
    final title = edited.isEmpty || edited == widget.bookmark.bookTitle
        ? null
        : edited;
    setState(() => _titleBusy = true);
    try {
      await database.setCardBookTitle(bookId, title);
      database.requireActive();
      _titleChanges.add((bookId: bookId, title: title));
    } catch (_) {
      if (mounted && database.isActive) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('卡片书名保存失败，请重试'),
        ));
      }
    } finally {
      if (mounted) setState(() => _titleBusy = false);
    }
  }

  Future<void> _interpretQuote() async {
    setState(() => _interpreting = true);
    try {
      final config = AppConfig();
      await config.load();
      final service = widget.aiServiceFactory?.call(config) ??
          AIService(config: config);
      if (!service.isConfigured) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('请先在设置中配置 AI API')));
        }
        return;
      }
      final result = await service.interpretQuote(
        widget.bookmark.markText,
        _effectiveBookTitle,
      );
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('AI 金句解读'),
            content: SingleChildScrollView(child: Text(result)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('AI 解读失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _interpreting = false);
    }
  }

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
    final db = widget.database;
    if (!db.isActive) return;
    bool isCurrent() => mounted && scope.active && scope.revision == revision &&
        _routeRevision == routeRevision && route?.isCurrent != false && db.isActive;
    final snapshot = Bookmark.fromJson({
      ...widget.bookmark.toJson(),
      'book_title': _effectiveBookTitle,
    });
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
          SnackBar(content: Text('导出失败: $failure'), backgroundColor: ReadAmberColors.error),
        );
      }
      onExportChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookmark = _exportBookmark ?? widget.bookmark;
    final bookTitle = _exportBookmark?.bookTitle ?? _effectiveBookTitle;
    final fontSize = _exportFontSize ?? _fontSize;
    final palette = ReadAmberPalette.of(context);
    final isInk = _template == CardTemplate.ink;
    final isMinimal = _template == CardTemplate.minimal;
    final textColor = isInk ? ReadAmberColors.paper : ReadAmberColors.ink;
    final subColor = isInk ? ReadAmberColors.outline : ReadAmberColors.muted;
    final cardDecoration = switch (_template) {
      CardTemplate.paper => BoxDecoration(
          color: ReadAmberColors.surface,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [ReadAmberColors.paper, ReadAmberColors.surface],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: ReadAmberColors.ink.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
      CardTemplate.ink => BoxDecoration(
          color: ReadAmberColors.ink,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [ReadAmberColors.ink, ReadAmberColors.inkSoft],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: ReadAmberColors.amber.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
      CardTemplate.minimal => BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ReadAmberColors.outline, width: 1),
        ),
    };

    return Column(
      children: [
        // 卡片内容（RepaintBoundary 包裹，用于截图）
        Expanded(
          child: SingleChildScrollView(
            controller: widget.scrollController,
            padding: const EdgeInsets.all(24),
            child: CardRepaintBoundary(
              key: _cardKey,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: cardDecoration,
                child: Column(
                  crossAxisAlignment: _centerAlign
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.format_quote_rounded,
                      size: 32,
                      color: isMinimal
                          ? ReadAmberColors.inkSoft
                          : ReadAmberColors.amber,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      bookmark.markText,
                      style: TextStyle(
                        fontSize: fontSize,
                        height: 1.8,
                        color: textColor,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign:
                          _centerAlign ? TextAlign.center : TextAlign.start,
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: 40,
                      height: 1,
                      color: isInk
                          ? ReadAmberColors.amber.withValues(alpha: 0.5)
                          : ReadAmberColors.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '—— $bookTitle',
                      style: TextStyle(
                        fontSize: fontSize * 0.78,
                        color: subColor,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (_showChapter && bookmark.chapterTitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        bookmark.chapterTitle,
                        style: TextStyle(
                            fontSize: fontSize * 0.67, color: subColor),
                      ),
                    ],
                    if (_showWatermark) ...[
                      const SizedBox(height: 16),
                      Text(
                        '阅珀 ReadAmber',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.2,
                          color: subColor.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        // 模板与排版工具条
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border(
                top: BorderSide(color: palette.surfaceMuted, width: 0.5)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final tpl in CardTemplate.values)
                ChoiceChip(
                  label: Text(tpl.label, style: const TextStyle(fontSize: 12)),
                  selected: _template == tpl,
                  visualDensity: VisualDensity.compact,
                  onSelected: _exporting
                      ? null
                      : (_) => setState(() => _template = tpl),
                ),
              IconButton(
                tooltip: _centerAlign ? '切换左对齐' : '切换居中对齐',
                icon: Icon(
                  _centerAlign
                      ? Icons.format_align_center_rounded
                      : Icons.format_align_left_rounded,
                  size: 18,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: _exporting
                    ? null
                    : () => setState(() => _centerAlign = !_centerAlign),
              ),
              IconButton(
                tooltip: _showChapter ? '隐藏章节' : '显示章节',
                icon: Icon(
                  _showChapter
                      ? Icons.subtitles_outlined
                      : Icons.subtitles_off_outlined,
                  size: 18,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: _exporting
                    ? null
                    : () => setState(() => _showChapter = !_showChapter),
              ),
              IconButton(
                tooltip: _showWatermark ? '隐藏水印' : '显示水印',
                icon: Icon(
                  _showWatermark
                      ? Icons.branding_watermark_outlined
                      : Icons.hide_source_outlined,
                  size: 18,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: _exporting
                    ? null
                    : () => setState(() => _showWatermark = !_showWatermark),
              ),
              IconButton(
                tooltip: '编辑书名',
                icon: const Icon(Icons.edit_outlined, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: _canUseBookTitle ? _editBookTitle : null,
              ),
              IconButton(
                tooltip: 'AI 金句解读',
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed:
                    _canUseBookTitle && !_interpreting ? _interpretQuote : null,
              ),
            ],
          ),
        ),
        // 底部控制栏：字号调节 + 导出按钮
        Container(
          decoration: BoxDecoration(
            color: palette.surface,
          ),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              // 字号标签
              Icon(Icons.format_size_rounded, size: 18, color: ReadAmberPalette.of(context).muted),
              // 字号滑块
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: ReadAmberPalette.of(context).action,
                    thumbColor: ReadAmberPalette.of(context).action,
                    overlayColor: ReadAmberPalette.of(context).action.withValues(alpha: 0.1),
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
                style: TextStyle(fontSize: 12, color: ReadAmberPalette.of(context).muted, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              // 导出按钮
              SizedBox(
                height: 34,
                child: ElevatedButton.icon(
                  onPressed: _canUseBookTitle ? _exportAsImage : null,
                  icon: _exporting
                      ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: ReadAmberPalette.of(context).ink))
                      : const Icon(Icons.ios_share_rounded, size: 16),
                  label: Text(_exporting ? '导出中...' : '导出图片', style: const TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ReadAmberPalette.of(context).action,
                    foregroundColor: ReadAmberPalette.of(context).onAction,
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

class _QuoteCardSheet extends StatelessWidget {
  final Bookmark bookmark;
  final DatabaseService database;
  final _CardExportScope scope;
  final CardImageRenderer renderer;
  final AIService Function(AppConfig)? aiServiceFactory;
  final ValueChanged<bool> onExportChanged;

  const _QuoteCardSheet({
    required this.bookmark,
    required this.database,
    required this.scope,
    required this.renderer,
    this.aiServiceFactory,
    this.onExportChanged = _noopExport,
  });

  @override
  Widget build(BuildContext context) {
    final sheet = DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: ReadAmberPalette.of(context).surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: ReadAmberPalette.of(context).outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: _CardPreview(
                  key: ValueKey((bookmark.bookId, bookmark.bookmarkId)),
                  bookmark: bookmark,
                  database: database,
                  scope: scope,
                  scrollController: scrollController,
                  renderer: renderer,
                  aiServiceFactory: aiServiceFactory,
                  onExportChanged: onExportChanged,
                ),
              ),
            ],
          ),
        );
      },
    );
    return AccountSessionGuard(database: database, child: sheet);
  }
}
