import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/notes_provider.dart';
import '../services/api.dart';
import '../services/config.dart';
import '../services/database.dart';

/// 同步进度页
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  bool _syncing = false;
  bool _cancelled = false;
  final List<String> _logs = [];
  int _totalBooks = 0;
  int _syncedBooks = 0;
  int _totalBookmarks = 0;
  int _totalNotes = 0;
  String? _error;

  final ScrollController _logScrollController = ScrollController();

  @override
  void dispose() {
    _logScrollController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
    });
    // 自动滚动到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _startSync() async {
    setState(() {
      _syncing = true;
      _cancelled = false;
      _logs.clear();
      _error = null;
      _totalBooks = 0;
      _syncedBooks = 0;
      _totalBookmarks = 0;
      _totalNotes = 0;
    });

    try {
      final config = AppConfig();
      await config.load();

      if (config.cookie.isEmpty) {
        setState(() {
          _error = '请先导入 Cookie';
          _syncing = false;
        });
        return;
      }

      _addLog('🚀 开始同步...');

      // 初始化 API
      try {
        WeReadApi.instance;
      } catch (_) {
        await WeReadApi.init(config: config, db: DatabaseService.instance);
      }
      WeReadApi.instance.updateCookie(config.cookie);

      // 同步书架
      _addLog('📚 正在同步书架...');
      final books = await WeReadApi.instance.fetchBookshelf();
      _totalBooks = books.length;
      _addLog('✅ 书架同步完成，共 $_totalBooks 本书');

      // 逐本同步划线和笔记
      for (int i = 0; i < books.length; i++) {
        if (_cancelled) {
          _addLog('⚠️ 同步已取消');
          break;
        }

        final book = books[i];
        _addLog('📖 [${i + 1}/$_totalBooks] ${book.title}');

        try {
          final bm = await WeReadApi.instance.fetchBookmarks(book.bookId, book.title);
          _totalBookmarks += bm.length;
          if (bm.isNotEmpty) _addLog('   ✏️ ${bm.length} 条划线');
        } catch (e) {
          _addLog('   ⚠️ 划线同步失败: $e');
        }

        try {
          final nt = await WeReadApi.instance.fetchNotes(book.bookId, book.title);
          _totalNotes += nt.length;
          if (nt.isNotEmpty) _addLog('   📝 ${nt.length} 条笔记');
        } catch (e) {
          _addLog('   ⚠️ 笔记同步失败: $e');
        }

        _syncedBooks = i + 1;
        setState(() {});

        // 请求间隔
        if (i < books.length - 1 && !_cancelled) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      if (!_cancelled) {
        _addLog('');
        _addLog('🎉 同步完成！');
        _addLog('   📚 $_totalBooks 本书');
        _addLog('   ✏️ $_totalBookmarks 条划线');
        _addLog('   📝 $_totalNotes 条笔记');

        // 通知其他 Provider 刷新数据
        if (mounted) {
          context.read<BookshelfProvider>().loadBooks();
          context.read<NotesProvider>().loadNotes();
        }
      }
    } catch (e) {
      _error = e.toString();
      _addLog('❌ 同步失败: $e');
    } finally {
      setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalBooks > 0 ? _syncedBooks / _totalBooks : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('数据同步'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: Column(
        children: [
          // 进度区域
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // 进度条
                if (_syncing) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[200],
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4A7CF7)),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$_syncedBooks / $_totalBooks 本书',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 16),
                ],
                // 统计
                if (!_syncing && _syncedBooks > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _statItem('📚', '$_totalBooks', '本书'),
                      _statItem('✏️', '$_totalBookmarks', '划线'),
                      _statItem('📝', '$_totalNotes', '笔记'),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                // 按钮
                SizedBox(
                  width: double.infinity,
                  child: _syncing
                      ? OutlinedButton.icon(
                          onPressed: () => setState(() => _cancelled = true),
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('取消同步'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        )
                      : FilledButton.icon(
                          onPressed: _startSync,
                          icon: const Icon(Icons.sync_rounded),
                          label: Text(_error != null ? '重新同步' : '开始同步'),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF4A7CF7),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                ),
              ],
            ),
          ),
          // 日志区域
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _logs.isEmpty
                  ? Center(
                      child: Text(
                        '点击「开始同步」同步微信读书数据',
                        style: TextStyle(color: Colors.grey[500], fontSize: 14),
                      ),
                    )
                  : ListView.builder(
                      controller: _logScrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        Color color = Colors.grey[300]!;
                        if (log.startsWith('✅') || log.startsWith('🎉')) color = const Color(0xFF4CAF50);
                        if (log.startsWith('❌')) color = const Color(0xFFFF5252);
                        if (log.startsWith('⚠️')) color = const Color(0xFFFFB74D);
                        if (log.startsWith('🚀')) color = const Color(0xFF42A5F5);

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            log,
                            style: TextStyle(
                              color: color,
                              fontSize: 13,
                              fontFamily: 'monospace',
                              height: 1.5,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String emoji, String value, String label) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 24)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }
}
