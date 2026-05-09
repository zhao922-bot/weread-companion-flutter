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
  
  List<MapEntry<String, int>> _categories = [];
  List<String> _categoryLabels = [];

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final rawBooks = await DatabaseService.instance.getAllBooks();
    final books = rawBooks.map((m) => Book.fromJson(m)).toList();

    // 统计划线 + 笔记（两个表都要查）
    final rawBookmarks = await DatabaseService.instance.getAllBookmarks();
    final rawNotes = await DatabaseService.instance.getAllNotes();
    final totalItemCount = rawBookmarks.length + rawNotes.length;

    final read = books.where((b) => b.isFinished || b.progress >= 85).length;
    final reading = books.where((b) => !b.isFinished && b.progress >= 5 && b.progress < 85).length;
    final unread = books.length - read - reading;

    // 按分类统计
    final catMap = <String, int>{};
    for (final b in books) {
      final cat = b.category.isNotEmpty ? b.category : '未分类';
      catMap[cat] = (catMap[cat] ?? 0) + 1;
    }
    final cats = catMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    setState(() {
      _totalBooks = books.length;
      _readBooks = read;
      _readingBooks = reading;
      _unreadBooks = unread.clamp(0, books.length);
      _totalNotes = totalItemCount;
      _categories = cats.take(8).toList();
      _categoryLabels = _buildCategoryLabels(_categories);
    });
  }

  List<String> _buildCategoryLabels(List<MapEntry<String, int>> cats) {
    final labels = <String>[];
    final used = <String>{};
    for (final cat in cats) {
      String label = _getCategoryShort(cat.key);
      if (used.contains(label)) {
        for (int i = 2; i <= 9; i++) {
          final candidate = '$label$i';
          if (!used.contains(candidate)) {
            label = candidate;
            break;
          }
        }
      }
      used.add(label);
      labels.add(label);
    }
    return labels;
  }

  String _getCategoryShort(String category) {
    const map = {
      '未分类': '未分',
      '政治军事': '政军',
      '精品小说': '精小',
      '精品散文': '精散',
      '精品诗歌': '精诗',
      '精品科幻': '精幻',
      '文学': '文学',
      '小说': '小说',
      '历史': '历史',
      '哲学': '哲学',
      '经济': '经济',
      '科技': '科技',
      '艺术': '艺术',
      '教育': '教育',
      '生活': '生活',
      '社会': '社会',
      '心理': '心理',
      '传记': '传记',
      '儿童': '儿童',
      '漫画': '漫画',
      '外语': '外语',
      '工具书': '工具',
      '其他': '其他',
      '宗教': '宗教',
      '自然科学': '自然',
      '计算机': '计算',
      '编程': '编程',
      '设计': '设计',
      '音乐': '音乐',
      '电影': '电影',
      '美食': '美食',
      '旅行': '旅行',
      '健康': '健康',
      '运动': '运动',
      '职场': '职场',
      '管理': '管理',
      '法律': '法律',
      '政治': '政治',
      '军事': '军事',
      '诗歌': '诗歌',
      '散文': '散文',
      '科幻': '科幻',
      '悬疑': '悬疑',
      '武侠': '武侠',
      '言情': '言情',
      '奇幻': '奇幻',
      '推理': '推理',
    };
    if (map.containsKey(category)) return map[category]!;
    if (category.startsWith('精品') && category.length > 2) {
      final sub = category.substring(2);
      if (map.containsKey(sub)) return '精${map[sub]!.substring(0, 1)}';
      return '精${sub.substring(0, 1)}';
    }
    if (category.length >= 2) return category.substring(0, 2);
    if (category.isNotEmpty) return category;
    return '未知';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('阅读报告')),
      body: RefreshIndicator(
        onRefresh: _loadStats,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 统计卡片
            Row(
              children: [
                _StatCard('总书数', '$_totalBooks', Icons.book, cs.primary),
                const SizedBox(width: 12),
                _StatCard('已读完', '$_readBooks', Icons.check_circle, const Color(0xFF4CAF50)),
                const SizedBox(width: 12),
                _StatCard('在读中', '$_readingBooks', Icons.menu_book, const Color(0xFFFF9800)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatCard('笔记数', '$_totalNotes', Icons.note, const Color(0xFF9C27B0)),
                const SizedBox(width: 12),
                const Expanded(child: SizedBox()),
                const SizedBox(width: 12),
                const Expanded(child: SizedBox()),
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
                    Text('阅读进度', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
            const SizedBox(height: 16),

            // 分类柱状图
            if (_categories.isNotEmpty)
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('图书分类', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 260,
                        child: BarChart(
                          BarChartData(
                            maxY: _categories.isNotEmpty
                                ? (_categories.first.value / 10).ceil() * 10.0 + 10
                                : 10,
                            barGroups: _categories.asMap().entries.map((e) {
                              final colors = [
                                const Color(0xFF4A7CF7),
                                const Color(0xFF4CAF50),
                                const Color(0xFFFF9800),
                                const Color(0xFFE91E63),
                                const Color(0xFF9C27B0),
                                const Color(0xFF00BCD4),
                                const Color(0xFFFF5722),
                                const Color(0xFF607D8B),
                              ];
                              return BarChartGroupData(
                                x: e.key,
                                barRods: [
                                  BarChartRodData(
                                    toY: e.value.value.toDouble(),
                                    color: colors[e.key % colors.length],
                                    width: 16,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ],
                              );
                            }).toList(),
                            titlesData: FlTitlesData(
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 30,
                                  getTitlesWidget: (value, meta) {
                                    final idx = value.toInt();
                                    if (idx >= 0 && idx < _categoryLabels.length) {
                                      final label = _categoryLabels[idx];
                                      return SideTitleWidget(
                                        axisSide: meta.axisSide,
                                        space: 4,
                                        child: Text(
                                          label,
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                                          textAlign: TextAlign.center,
                                        ),
                                      );
                                    }
                                    return const SizedBox();
                                  },
                                ),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 40,
                                  interval: 10,
                                  getTitlesWidget: (value, meta) {
                                    if (value % 10 != 0) return const SizedBox();
                                    return SideTitleWidget(
                                      axisSide: meta.axisSide,
                                      space: 6,
                                      child: Text(
                                        value.toInt().toString(),
                                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            ),
                            borderData: FlBorderData(show: false),
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              horizontalInterval: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 8),
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
        ),
      ),
    );
  }
}
