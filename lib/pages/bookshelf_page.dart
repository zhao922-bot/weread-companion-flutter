import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/app_config_provider.dart';
import '../models/book.dart';
import 'book_detail_page.dart';
import 'sync_page.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  String _searchQuery = '';
  String _selectedFilter = '全部';
  final TextEditingController _searchController = TextEditingController();

  final List<String> _filters = ['全部', '读完', '在读中', '未读'];

  @override
  void initState() {
    super.initState();
    // 首次加载数据
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<BookshelfProvider>().loadBooks();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _getProgressColor(int progress) {
    if (progress >= 85) return Colors.green;
    if (progress > 0) return const Color(0xFF2196F3);
    return Colors.grey;
  }

  String _getStatusText(Book book) {
    if (book.isFinished || book.progress >= 85) return '已读完';
    if (book.progress >= 5) return '在读中';
    return '未读';
  }

  List<Book> _filterBooks(List<Book> books) {
    return books.where((book) {
      final matchesSearch = _searchQuery.isEmpty ||
          book.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          book.author.toLowerCase().contains(_searchQuery.toLowerCase());
      bool matchesFilter;
      switch (_selectedFilter) {
        case '读完':
          matchesFilter = book.isFinished || book.progress >= 85;
          break;
        case '在读中':
          matchesFilter = !book.isFinished && book.progress >= 5 && book.progress < 85;
          break;
        case '未读':
          matchesFilter = book.progress < 5 && !book.isFinished;
          break;
        default:
          matchesFilter = true;
      }
      return matchesSearch && matchesFilter;
    }).toList();
  }

  /// 同步书架，带错误处理和反馈
  Future<void> _doSync(BookshelfProvider provider) async {
    try {
      final appConfig = context.read<AppConfigProvider>();
      final msg = await provider.syncFromServer(config: appConfig.config);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: const Color(0xFF07C160), duration: const Duration(seconds: 3)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e'), backgroundColor: Colors.red, duration: const Duration(seconds: 3)),
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
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth < 380 ? 2 : 3;
    final childAspectRatio = screenWidth < 380 ? 0.48 : 0.5;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('书架'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_sync_rounded),
            tooltip: '同步数据',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SyncPage()),
            ),
          ),
        ],
      ),
      body: Consumer<BookshelfProvider>(
        builder: (context, provider, _) {
          final filteredBooks = _filterBooks(provider.books);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 搜索栏 + 筛选按钮（合并为一个白色容器，消除中间缝隙）
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
                          hintText: '搜索书名或作者...',
                          hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                          prefixIcon: Icon(Icons.search, color: Colors.grey[400], size: 20),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    setState(() {
                                      _searchController.clear();
                                      _searchQuery = '';
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
                          });
                        },
                      ),
                    ),
                    // 过滤按钮
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _filters.map((filter) {
                            final isSelected = _selectedFilter == filter;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GestureDetector(
                                onTap: () => setState(() => _selectedFilter = filter),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isSelected ? const Color(0xFF2196F3) : const Color(0xFFF0F0F0),
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
      ),
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
            Text('正在加载书架...', style: TextStyle(color: Colors.grey)),
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
              Icon(Icons.cloud_off_rounded, size: 72, color: Colors.grey[300]),
              const SizedBox(height: 20),
              Text(
                '加载失败',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey[700]),
              ),
              const SizedBox(height: 8),
              Text(
                errorMsg,
                style: TextStyle(fontSize: 14, color: Colors.grey[500], height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => _doSync(provider),
                icon: const Icon(Icons.sync_rounded, size: 20),
                label: const Text('同步书架', style: TextStyle(fontSize: 15)),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4A7CF7),
                  foregroundColor: Colors.white,
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
                    Icon(Icons.menu_book, size: 64, color: Colors.grey[300]),
                    const SizedBox(height: 16),
                    Text(
                      provider.books.isEmpty ? '暂无书籍，请先登录同步' : '没有匹配的书籍',
                      style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                    ),
                    if (provider.books.isEmpty) ...[
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
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => BookDetailPage(book: book),
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
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
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
                  color: Colors.grey[200],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (book.cover.isNotEmpty)
                        Image.network(
                          book.cover,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return _buildCoverFallback();
                          },
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.grey[300],
                              ),
                            );
                          },
                        )
                      else
                        _buildCoverFallback(),
                      // 已读完标记
                      if (book.isFinished || book.progress >= 85)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '✓',
                              style: TextStyle(
                                color: Colors.white,
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
                  color: Colors.black87,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                book.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ),
            // 进度条
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: book.progress / 100.0,
                  backgroundColor: Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                  minHeight: 4,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                '${book.progress}% · $statusText',
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
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
      color: Colors.grey[200],
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.book, size: 36, color: Colors.grey[400]),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                book.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
