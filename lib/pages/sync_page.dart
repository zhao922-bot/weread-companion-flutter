import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_config_provider.dart';
import '../services/sync_service.dart';

/// 同步进度页
class SyncPage extends StatefulWidget {
  final SyncResult? initialResult;
  const SyncPage({super.key, this.initialResult});

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
  SyncService? _service;
  SyncResult? _result;
  final Map<int, BookSyncResult> _retryLogs = {};

  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.initialResult != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final config = context.read<AppConfigProvider>();
        final revision = config.sessionRevision;
        _service = SyncService.current(isCancelled: () =>
            _cancelled || !mounted || revision != config.sessionRevision);
        _result = widget.initialResult;
        _totalBooks = _result!.totalBooks;
        _syncedBooks = _result!.books.length;
        _showResult();
      });
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    _logScrollController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    if (!mounted) return;
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
      _retryLogs.clear();
      _result = null;
      _error = null;
      _totalBooks = 0;
      _syncedBooks = 0;
      _totalBookmarks = 0;
      _totalNotes = 0;
    });

    try {
      final appConfig = context.read<AppConfigProvider>();
      final revision = appConfig.sessionRevision;
      final config = appConfig.config;

      if (!appConfig.isLoggedIn && !await appConfig.verifyForSync()) {
        if (!mounted) return;
        setState(() {
          _error = appConfig.loginError ?? '同步需要联网并验证登录';
          _syncing = false;
        });
        return;
      }

      if (_cancelled || !mounted || revision != appConfig.sessionRevision) return;
      _addLog('🚀 开始同步...');

      _service = await SyncService.connect(config: config, isCancelled: () =>
          _cancelled || !mounted || revision != appConfig.sessionRevision);
      if (_cancelled || !mounted || revision != appConfig.sessionRevision) return;

      _addLog('📚 正在同步书架...');
      final result = await _service!.syncAll(
        onBooks: (total) {
          _totalBooks = total;
          _addLog('✅ 书架同步完成，共 $total 本书');
        },
        onProgress: (book, processed) {
          _syncedBooks = processed;
          _addLog('📖 [$processed/$_totalBooks] ${book.book.title}');
          _addLog('   ✏️ ${book.bookmarks} 条划线 / 📝 ${book.notes} 条笔记');
        },
      );
      if (!mounted || revision != appConfig.sessionRevision) return;
      _result = result;
      _showResult();
    } catch (e) {
      _error = e.toString();
      _addLog('❌ 同步失败: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _showResult() {
    final result = _result!;
    _totalBookmarks = result.bookmarks;
    _totalNotes = result.notes;
    _retryLogs.clear();
    _addLog('${result.cancelled || result.failureCount > 0 ? '⚠️' : '✅'} ${result.summary}');
    for (final failure in result.failures) {
      _retryLogs[_logs.length] = failure;
      _addLog('❌ ${failure.book.title}：${failure.reason}（点击重试此书）');
    }
  }

  Future<void> _retryBook(BookSyncResult failure) async {
    if (_syncing || _service == null) return;
    setState(() {
      _syncing = true;
      _cancelled = false;
    });
    try {
      final retried = await _service!.retryBook(failure.book);
      if (!mounted) return;
      _result = _result!.replace(retried);
      _showResult();
    } catch (e) {
      _addLog('❌ 重试失败：$e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalBooks > 0 ? _syncedBooks / _totalBooks : 0.0;
    final appConfig = context.watch<AppConfigProvider>();

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
                           onPressed: appConfig.isBusy ? null : _startSync,
                          icon: const Icon(Icons.sync_rounded),
                           label: Text(appConfig.needsOnlineSync
                               ? '需要联网 · 验证并同步'
                               : _error != null ? '重新同步' : '开始同步'),
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
                         _error ?? (appConfig.needsOnlineSync
                             ? '本地数据可浏览；请联网后验证并同步'
                             : '点击「开始同步」同步微信读书数据'),
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
                          child: GestureDetector(
                            onTap: !_syncing && _retryLogs.containsKey(index)
                                ? () => _retryBook(_retryLogs[index]!) : null,
                            child: Text(
                              log,
                              style: TextStyle(
                                color: color,
                                fontSize: 13,
                                fontFamily: 'monospace',
                                height: 1.5,
                              ),
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
