import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/app_config_provider.dart';
import '../models/book.dart';
import '../models/bookshelf_filter.dart';
import '../models/reading_constants.dart';
import '../services/database.dart';
import 'book_detail_page.dart';
import 'sync_page.dart';

class BookshelfPage extends StatefulWidget {
  final bool isActive;
  const BookshelfPage({super.key, this.isActive = true});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  static const _densityKey = 'bookshelf_columns';
  int _crossAxisCount = 3;
  bool _densityLoaded = false;
  final TextEditingController _searchController = TextEditingController();
  BookshelfProvider? _provider;

  @override
  void initState() {
    super.initState();
    _loadDensity();
    // 首次加载数据
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _provider = context.read<BookshelfProvider>();
      _provider!.setActive(widget.isActive);
    });
  }

  @override
  void didUpdateWidget(covariant BookshelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    if (!widget.isActive) {
      _provider?.setActive(false);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _provider?.setActive(widget.isActive);
      });
    }
  }

  Future<void> _loadDensity() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final columns = prefs.getInt(_densityKey);
    setState(() {
      _crossAxisCount = columns == 4 ? 4 : 3;
      _densityLoaded = true;
    });
  }

  Future<void> _setDensity(int columns) async {
    setState(() => _crossAxisCount = columns);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_densityKey, columns);
  }

  @override
  void dispose() {
    _provider?.setActive(false);
    _searchController.dispose();
    super.dispose();
  }

  Color _getProgressColor(int progress) {
    if (progress >= finishedProgress) return ReadAmberColors.success;
    if (progress >= nearlyFinishedProgress) return ReadAmberColors.amberText;
    if (progress >= readingStartedProgress) return ReadAmberColors.inkSoft;
    return ReadAmberColors.muted;
  }

  String _getStatusText(Book book) {
    return book.readingStatus;
  }

  /// 同步书架，带错误处理和反馈
  Future<void> _doSync(BookshelfProvider provider) async {
    final appConfig = context.read<AppConfigProvider>();
    final revision = appConfig.sessionRevision;
    bool isCurrent() => revision == appConfig.sessionRevision;
    try {
      if (!appConfig.isLoggedIn && !await appConfig.verifyForSync()) {
        if (!mounted || !isCurrent()) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appConfig.loginError ?? '本地数据可浏览；同步需要联网验证'),
        ));
        return;
      }
      if (!mounted || !isCurrent()) return;
      final msg = await provider.syncFromServer(config: appConfig.config);
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: provider.lastSyncResult?.failureCount == 0
                ? ReadAmberColors.ink : ReadAmberColors.amberText,
            duration: const Duration(seconds: 3),
            action: provider.lastSyncResult?.failureCount == 0 ? null : SnackBarAction(
              label: '失败清单',
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => SyncPage(initialResult: provider.lastSyncResult),
              )),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e'), backgroundColor: ReadAmberColors.error, duration: const Duration(seconds: 3)),
        );
      }
    }
  }

  /// 将技术错误转为用户友好的提示
  String _friendlyError(String error) {
    if (error.contains('404')) return '接口地址有误，请检查网络后重试';
    if (error.contains('401') || error.contains('302')) return 'Cookie 已过期，请重新导入';
    if (error.contains('超时') || error.contains('timeout')) return '网络连接超时，请检查网络';
    if (error.contains('SocketException') || error.contains('Connection')) return '无法连接服务器，请检查网络';
    if (error.contains('Cookie') && error.contains('导入')) return '请先在设置中导入 Cookie';
    if (error.contains('errcode')) return 'Cookie 已失效，请重新导入';
    return '加载失败，请下拉刷新或检查网络';
  }

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = _crossAxisCount;
    final appConfig = context.watch<AppConfigProvider>();
    const childAspectRatio = 0.5;

    return Scaffold(
      backgroundColor: ReadAmberColors.canvas,
      appBar: AppBar(
        title: const Text('书架'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: ReadAmberColors.canvas,
        foregroundColor: ReadAmberColors.ink,
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.grid_view_rounded),
            tooltip: '显示密度：当前 $_crossAxisCount 列',
            enabled: _densityLoaded,
            initialValue: _crossAxisCount,
            onSelected: _setDensity,
            itemBuilder: (context) => [
              for (final columns in [3, 4])
                CheckedPopupMenuItem(
                  value: columns,
                  checked: _crossAxisCount == columns,
                  child: Text('$columns 列 · ${columns == 3 ? '紧凑' : '更紧凑'}'),
                ),
            ],
          ),
          IconButton(
            icon: Icon(appConfig.needsOnlineSync
                ? Icons.cloud_off_rounded : Icons.cloud_sync_rounded),
            tooltip: appConfig.needsOnlineSync ? '离线：同步需要联网验证' : '同步数据',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SyncPage()),
            ),
          ),
        ],
      ),
      body: ReadAmberContent(maxWidth: 760, child: Consumer<BookshelfProvider>(
        builder: (context, provider, _) {
          final filteredBooks = provider.books;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 搜索栏 + 筛选按钮（合并为一个白色容器，消除中间缝隙）
              Container(
                color: ReadAmberColors.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 搜索栏
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '搜索书名或作者...',
                          hintStyle: TextStyle(color: ReadAmberColors.muted, fontSize: 14),
                          prefixIcon: Icon(Icons.search, color: ReadAmberColors.muted, size: 20),
                          suffixIcon: provider.searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    provider.setSearch('');
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: ReadAmberColors.surfaceMuted,
                          contentPadding: const EdgeInsets.symmetric(vertical: 0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 14),
                        onChanged: provider.setSearch,
                      ),
                    ),
                    // 过滤按钮
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: BookshelfFilter.values.map((filter) {
                            final isSelected = provider.filter == filter;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GestureDetector(
                                onTap: () => provider.setFilter(filter),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isSelected ? ReadAmberColors.amber : ReadAmberColors.surfaceMuted,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    filter.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                      color: isSelected ? ReadAmberColors.ink : ReadAmberColors.inkSoft,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 书架列表
              Expanded(
                child: _buildBody(context, provider, filteredBooks, crossAxisCount, childAspectRatio),
              ),
            ],
          );
        },
      )),
    );
  }

  Widget _buildBody(
    BuildContext context,
    BookshelfProvider provider,
    List<Book> filteredBooks,
    int crossAxisCount,
    double childAspectRatio,
  ) {
    // 加载中（首次）
    if (provider.isLoading && provider.books.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在加载书架...', style: TextStyle(color: ReadAmberColors.muted)),
          ],
        ),
      );
    }

    // 错误状态 — 友好提示，不显示技术细节
    if (provider.error != null && provider.books.isEmpty) {
      final errorMsg = _friendlyError(provider.error!);
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 72, color: ReadAmberColors.outline),
              const SizedBox(height: 20),
              Text(
                '加载失败',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: ReadAmberColors.inkSoft),
              ),
              const SizedBox(height: 8),
              Text(
                errorMsg,
                style: TextStyle(fontSize: 14, color: ReadAmberColors.muted, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => _doSync(provider),
                icon: const Icon(Icons.sync_rounded, size: 20),
                label: const Text('同步书架', style: TextStyle(fontSize: 15)),
                style: FilledButton.styleFrom(
                  backgroundColor: ReadAmberColors.ink,
                  foregroundColor: ReadAmberColors.paper,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 空状态
    if (filteredBooks.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _doSync(provider),
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.menu_book, size: 64, color: ReadAmberColors.outline),
                    const SizedBox(height: 16),
                    Text(
                      provider.totalCount == 0 ? '暂无书籍，请先登录同步' : '没有匹配的书籍',
                      style: TextStyle(fontSize: 16, color: ReadAmberColors.muted),
                    ),
                    if (provider.totalCount == 0) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () => _doSync(provider),
                        icon: const Icon(Icons.sync),
                        label: const Text('同步书架'),
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
      onRefresh: () => _doSync(provider),
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: childAspectRatio,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        itemCount: filteredBooks.length,
        itemBuilder: (context, index) {
          final book = filteredBooks[index];
          return _BookCard(
            book: book,
            progressColor: _getProgressColor(book.progress),
            statusText: _getStatusText(book),
            onTap: () {
              final db = DatabaseService.instance;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => BookDetailPage(book: book, database: db),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  final Book book;
  final Color progressColor;
  final String statusText;
  final VoidCallback onTap;

  const _BookCard({
    required this.book,
    required this.progressColor,
    required this.statusText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: ReadAmberColors.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: ReadAmberColors.ink.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  color: ReadAmberColors.surfaceMuted,
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (book.cover.isNotEmpty)
                        LayoutBuilder(builder: (context, constraints) {
                          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
                          return Image.network(
                            book.cover,
                            fit: BoxFit.cover,
                            cacheWidth: (constraints.maxWidth * pixelRatio).ceil(),
                            cacheHeight: (constraints.maxHeight * pixelRatio).ceil(),
                            errorBuilder: (context, error, stackTrace) {
                              return _buildCoverFallback();
                            },
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: ReadAmberColors.outline,
                                ),
                              );
                            },
                          );
                        })
                      else
                        _buildCoverFallback(),
                      // 已读完标记
                       if (book.isFinished)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ReadAmberColors.success.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '✓',
                              style: TextStyle(
                                color: ReadAmberColors.surface,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // 信息
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
              child: Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ReadAmberColors.ink,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                book.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: ReadAmberColors.muted),
              ),
            ),
            // 进度条
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (book.progress / finishedProgress).clamp(0.0, 1.0),
                  backgroundColor: ReadAmberColors.surfaceMuted,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                  minHeight: 4,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                '${book.progress}% · $statusText',
                style: TextStyle(fontSize: 10, color: ReadAmberColors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverFallback() {
    return Container(
      color: ReadAmberColors.surfaceMuted,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 88,
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.book, size: 36, color: ReadAmberColors.muted),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                book.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: ReadAmberColors.muted),
              ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}
