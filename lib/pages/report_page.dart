import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/database.dart';
import '../models/book.dart';

class ReportPage extends StatefulWidget {
  const ReportPage({super.key});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  int _totalBooks = 0;
  int _readBooks = 0;
  int _readingBooks = 0;
  int _unreadBooks = 0;
  int _totalNotes = 0;
  List<MapEntry<String, int>> _topHighlights = [];
  List<MapEntry<DateTime, int>> _monthlyActivity = [];

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  // 数据库列表接口默认只返回 500 条，报告需读取全部本地记录。
  Future<List<Map<String, dynamic>>> _loadAllItems(
    Future<List<Map<String, dynamic>>> Function({required int offset, required int limit}) load,
  ) async {
    final items = <Map<String, dynamic>>[];
    const pageSize = 500;
    while (true) {
      final page = await load(offset: items.length, limit: pageSize);
      items.addAll(page);
      if (page.length < pageSize) return items;
    }
  }

  Future<void> _loadStats() async {
    try {
      final db = DatabaseService.instance;
      final rawBooks = await db.getAllBooks();
      final books = rawBooks.map((m) => Book.fromJson(m)).toList();

      // 统计划线 + 笔记（两个表都要查）
      final rawBookmarks = await _loadAllItems(db.getAllBookmarks);
      final rawNotes = await _loadAllItems(db.getAllNotes);
      final totalItemCount = rawBookmarks.length + rawNotes.length;

      final read = books.where((b) => b.isFinished || b.progress >= 85).length;
      final reading = books.where((b) => !b.isFinished && b.progress >= 5 && b.progress < 85).length;
      final unread = books.length - read - reading;

      final titles = {for (final book in books) book.bookId: book.title};
      final highlightCounts = <String, int>{};
      for (final bookmark in rawBookmarks) {
        final bookId = bookmark['book_id'] as String;
        highlightCounts[bookId] = (highlightCounts[bookId] ?? 0) + 1;
        if (titles[bookId]?.isNotEmpty != true) {
          titles[bookId] = bookmark['book_title'] as String? ?? '';
        }
      }
      final topHighlights = highlightCounts.entries.toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });

      // books.updated_at 是更新时间，不能用作读完时间；仅统计划线/笔记创建时间。
      final now = DateTime.now();
      final months = <DateTime, int>{
        for (int i = 5; i >= 0; i--) DateTime(now.year, now.month - i): 0,
      };
      for (final item in [...rawBookmarks, ...rawNotes]) {
        final timestamp = item['created_at'] as int? ?? 0;
        if (timestamp <= 0 || timestamp > now.millisecondsSinceEpoch ~/ 1000) continue;
        final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
        final month = DateTime(date.year, date.month);
        if (months.containsKey(month)) months[month] = months[month]! + 1;
      }

      if (!mounted) return;
      setState(() {
        _totalBooks = books.length;
        _readBooks = read;
        _readingBooks = reading;
        _unreadBooks = unread.clamp(0, books.length);
        _totalNotes = totalItemCount;
        _topHighlights = topHighlights.take(5).map((entry) {
          final title = titles[entry.key];
          return MapEntry(title == null || title.isEmpty ? '未知书籍' : title, entry.value);
        }).toList();
        _monthlyActivity = months.entries.toList();
      });
    } catch (_) {
      // 退出登录时数据库会关闭，丢弃该会话的加载结果。
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('阅读报告')),
      body: RefreshIndicator(
        onRefresh: _loadStats,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // 统计卡片
            Row(
              children: [
                _StatCard('总书数', '$_totalBooks', Icons.book, cs.primary),
                const SizedBox(width: 8),
                _StatCard('已读完', '$_readBooks', Icons.check_circle, const Color(0xFF4CAF50)),
                const SizedBox(width: 8),
                _StatCard('在读中', '$_readingBooks', Icons.menu_book, const Color(0xFFFF9800)),
                const SizedBox(width: 8),
                _StatCard('划线与笔记', '$_totalNotes', Icons.note, const Color(0xFF9C27B0)),
              ],
            ),
            const SizedBox(height: 24),

            // 阅读进度饼图
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('阅读进度', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 200,
                      child: PieChart(
                        PieChartData(
                          sections: [
                            PieChartSectionData(
                              value: _readBooks.toDouble(),
                              color: const Color(0xFF4CAF50),
                              title: '读完\n$_readBooks',
                              radius: 60,
                              titleStyle: const TextStyle(fontSize: 12, color: Colors.white),
                            ),
                            PieChartSectionData(
                              value: _readingBooks.toDouble(),
                              color: const Color(0xFFFF9800),
                              title: '在读\n$_readingBooks',
                              radius: 60,
                              titleStyle: const TextStyle(fontSize: 12, color: Colors.white),
                            ),
                            PieChartSectionData(
                              value: _unreadBooks.toDouble(),
                              color: Colors.grey[300],
                              title: '未读\n$_unreadBooks',
                              radius: 60,
                              titleStyle: const TextStyle(fontSize: 12, color: Colors.black54),
                            ),
                          ],
                          sectionsSpace: 2,
                          centerSpaceRadius: 40,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_monthlyActivity.any((entry) => entry.value > 0)) ...[
              const SizedBox(height: 16),
              _buildMonthlyActivity(cs.primary),
            ],
            if (_topHighlights.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildTopHighlights(cs.primary),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMonthlyActivity(Color color) {
    final maxCount = _monthlyActivity.fold<int>(0, (max, entry) => entry.value > max ? entry.value : max);
    final interval = (maxCount / 4).ceilToDouble().clamp(1.0, double.infinity);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('划线与笔记趋势', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('近 6 个月 · 按本地记录的创建时间统计', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 20),
            SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  maxY: ((maxCount / interval).ceil() + 1) * interval,
                  barGroups: _monthlyActivity.asMap().entries.map((entry) {
                    return BarChartGroupData(
                      x: entry.key,
                      barRods: [
                        BarChartRodData(
                          toY: entry.value.value.toDouble(),
                          color: color,
                          width: 18,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    );
                  }).toList(),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final entry = _monthlyActivity[group.x];
                        return BarTooltipItem(
                          '${entry.key.year}年${entry.key.month}月\n${entry.value} 条',
                          const TextStyle(color: Colors.white, fontSize: 12),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= _monthlyActivity.length) return const SizedBox();
                          final month = _monthlyActivity[index].key;
                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            space: 8,
                            child: Text('${month.year % 100}/${month.month}', style: const TextStyle(fontSize: 11)),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        interval: interval,
                        getTitlesWidget: (value, meta) => SideTitleWidget(
                          axisSide: meta.axisSide,
                          space: 6,
                          child: Text('${value.toInt()}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        ),
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(drawVerticalLine: false, horizontalInterval: interval),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHighlights(Color color) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('划线最多的书 Top5', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('按本地已同步划线数量排序', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            for (final entry in _topHighlights.asMap().entries) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('${entry.key + 1}', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(entry.value.key, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  Text('${entry.value.value} 条', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: entry.value.value / _topHighlights.first.value,
                  minHeight: 6,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.1),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard(this.label, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 8),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
        ),
      ),
    );
  }
}
