import 'package:flutter/material.dart';
import 'package:weread_companion/theme/readamber_theme.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/ai_service.dart';
import '../services/config.dart';
import '../services/database.dart';
import '../services/sync_service.dart';

class ReportPage extends StatefulWidget {
  final bool isActive;
  final AIService Function(AppConfig)? aiServiceFactory;
  const ReportPage({super.key, this.isActive = true, this.aiServiceFactory});

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
  int _dataVersion = SyncService.changes.dataVersion;
  int _loadRequest = 0;
  bool _loading = true;
  String? _error;
  bool _refreshPending = false;
  bool _analyzing = false;
  String? _aiInsight;

  @override
  void didUpdateWidget(covariant ReportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && oldWidget.isActive && _loading) {
      _loadRequest++;
      _refreshPending = true;
      _loading = false;
    }
    if (widget.isActive && !oldWidget.isActive && _refreshPending) _loadStats();
  }

  @override
  void initState() {
    super.initState();
    SyncService.changes.addListener(_onSyncChanged);
    _loadStats();
  }

  void _onSyncChanged() {
    if (SyncService.changes.value?.isActive != true ||
        _dataVersion == SyncService.changes.dataVersion) {
      return;
    }
    _dataVersion = SyncService.changes.dataVersion;
    _loadStats();
  }

  @override
  void dispose() {
    SyncService.changes.removeListener(_onSyncChanged);
    _loadRequest++;
    super.dispose();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    if (!widget.isActive) {
      _refreshPending = true;
      return;
    }
    _refreshPending = false;
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = DatabaseService.instance;
      bool isCurrent() => mounted && request == _loadRequest && db.isActive;
      final now = DateTime.now();
      final stats = await db.getReportStats(now: now);
      if (!isCurrent()) return;
      final months = <DateTime, int>{
        for (int i = 5; i >= 0; i--) DateTime(now.year, now.month - i): 0,
      };
      for (final item in stats['monthly'] as List<Map<String, dynamic>>) {
        final date = DateTime.parse('${item['month']}-01');
        months[date] = item['total'] as int;
      }

      setState(() {
        _totalBooks = stats['totalBooks'] as int;
        _readBooks = stats['finishedBooks'] as int;
        _readingBooks = stats['readingBooks'] as int;
        _unreadBooks = _totalBooks - _readBooks - _readingBooks;
        _totalNotes =
            (stats['totalBookmarks'] as int) + (stats['totalNotes'] as int);
        _topHighlights = (stats['top'] as List<Map<String, dynamic>>)
            .map((r) => MapEntry(r['title'] as String, r['total'] as int))
            .toList();
        _monthlyActivity = months.entries.toList();
      });
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && request == _loadRequest) setState(() => _loading = false);
    }
  }

  Future<void> _generateAiInsight() async {
    setState(() => _analyzing = true);
    try {
      final db = DatabaseService.instance;
      final config = AppConfig();
      await config.load();
      final service =
          widget.aiServiceFactory?.call(config) ?? AIService(config: config);
      if (!service.isConfigured) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('请先在设置中配置 AI API')));
        }
        return;
      }
      final books = await db.getAllBooks();
      final titles = books
          .map((b) => (b['title'] as String? ?? '').trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (titles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂无书籍可供分析')));
        }
        return;
      }
      final insight = await service.analyzeReading(titles, _totalNotes);
      if (mounted && db.isActive) setState(() => _aiInsight = insight);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('阅读洞察生成失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final palette = ReadAmberPalette.of(context);
    final statItems = [
      _StatCard('总书数', '$_totalBooks', Icons.book, cs.primary),
      _StatCard('已读完', '$_readBooks', Icons.check_circle, palette.success),
      _StatCard('在读中', '$_readingBooks', Icons.menu_book, palette.amberText),
      _StatCard('划线与笔记', '$_totalNotes', Icons.note, palette.inkSoft),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('阅读报告')),
      body: ReadAmberContent(
        maxWidth: 1000,
        child: RefreshIndicator(
          onRefresh: _loadStats,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 520;
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  if (_loading) const LinearProgressIndicator(),
                  if (_error != null) ...[
                    Text('报告加载失败: $_error'),
                    TextButton(onPressed: _loadStats, child: const Text('重试')),
                  ],
                  // 响应式统计卡片：窄屏 2x2，宽屏 4 列
                  if (narrow) ...[
                    Row(children: [
                      statItems[0],
                      const SizedBox(width: 8),
                      statItems[1],
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      statItems[2],
                      const SizedBox(width: 8),
                      statItems[3],
                    ]),
                  ] else
                    Row(
                      children: [
                        statItems[0],
                        const SizedBox(width: 8),
                        statItems[1],
                        const SizedBox(width: 8),
                        statItems[2],
                        const SizedBox(width: 8),
                        statItems[3],
                      ],
                    ),
                  const SizedBox(height: 20),
                  _buildProgressPieCard(context),
                  if (_monthlyActivity.any((entry) => entry.value > 0)) ...[
                    const SizedBox(height: 16),
                    _buildMonthlyActivity(cs.primary),
                  ],
                  if (_topHighlights.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildTopHighlights(cs.primary),
                  ],
                  const SizedBox(height: 16),
                  _buildAiInsightCard(context),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildProgressPieCard(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    final slices = <(String, int, Color, Color)>[
      ('读完', _readBooks, palette.success, palette.surface),
      ('在读', _readingBooks, palette.amberText, palette.surface),
      ('未读', _unreadBooks, palette.outline, palette.ink),
    ];
    final nonZero = slices.where((s) => s.$2 > 0).toList();
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('阅读进度',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: nonZero.isEmpty
                  ? Center(
                      child: Text('暂无书籍进度数据',
                          style: TextStyle(color: palette.muted)),
                    )
                  : PieChart(
                      PieChartData(
                        sections: [
                          for (final s in nonZero)
                            PieChartSectionData(
                              value: s.$2.toDouble(),
                              color: s.$3,
                              title: '${s.$1}\n${s.$2}',
                              radius: 60,
                              titleStyle: TextStyle(fontSize: 12, color: s.$4),
                            ),
                        ],
                        sectionsSpace: 2,
                        centerSpaceRadius: 40,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final s in slices)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: s.$3,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${s.$1} ${s.$2}',
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiInsightCard(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded,
                    size: 20, color: palette.amberText),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('AI 阅读习惯洞察',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                TextButton.icon(
                  onPressed: _analyzing ? null : _generateAiInsight,
                  icon: _analyzing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.psychology_outlined, size: 18),
                  label: Text(_aiInsight == null ? '生成洞察' : '重新分析'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _aiInsight ?? '结合你的书架与划线量，分析阅读偏好、知识结构与下一步阅读方向。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: _aiInsight == null ? palette.muted : palette.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthlyActivity(Color color) {
    final maxCount = _monthlyActivity.fold<int>(
        0, (max, entry) => entry.value > max ? entry.value : max);
    final interval = (maxCount / 4).ceilToDouble().clamp(1.0, double.infinity);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('划线与笔记趋势',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('近 6 个月 · 按本地记录的创建时间统计',
                style: TextStyle(
                    fontSize: 12, color: ReadAmberPalette.of(context).muted)),
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
                      tooltipBgColor: ReadAmberPalette.of(context).ink,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final entry = _monthlyActivity[group.x];
                        return BarTooltipItem(
                          '${entry.key.year}年${entry.key.month}月\n${entry.value} 条',
                          TextStyle(
                              color: ReadAmberPalette.of(context).surface,
                              fontSize: 12),
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
                          if (index < 0 || index >= _monthlyActivity.length) {
                            return const SizedBox();
                          }
                          final month = _monthlyActivity[index].key;
                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            space: 8,
                            child: Text('${month.year % 100}/${month.month}',
                                style: const TextStyle(fontSize: 11)),
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
                          child: Text('${value.toInt()}',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: ReadAmberPalette.of(context).muted)),
                        ),
                      ),
                    ),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                      drawVerticalLine: false, horizontalInterval: interval),
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
            const Text('划线最多的书 Top5',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('按本地已同步划线数量排序',
                style: TextStyle(
                    fontSize: 12, color: ReadAmberPalette.of(context).muted)),
            for (final entry in _topHighlights.asMap().entries) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('${entry.key + 1}',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, color: color)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(entry.value.key,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  Text('${entry.value.value} 条',
                      style: TextStyle(
                          fontSize: 12,
                          color: ReadAmberPalette.of(context).muted)),
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
              Text(value,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 12, color: ReadAmberPalette.of(context).muted)),
            ],
          ),
        ),
      ),
    );
  }
}
