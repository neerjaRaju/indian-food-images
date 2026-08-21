import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../data/models/diary.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/ads_service.dart';
import '../../data/services/preferences_service.dart';
import '../../state/premium_controller.dart';
import '../../widgets/premium_gate.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int _days = 7;
  late Future<Map<String, DayTotals>> _future = _load();

  Future<Map<String, DayTotals>> _load() {
    final users = context.read<UserRepository>();
    final end = DateTime.now();
    final start = end.subtract(Duration(days: _days - 1));
    return users.diaryTotalsRange(isoDate(start), isoDate(end));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          PopupMenuButton<int>(
            initialValue: _days,
            icon: const Icon(Icons.date_range),
            onSelected: (d) => setState(() {
              _days = d;
              _future = _load();
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 7, child: Text('Last 7 days')),
              PopupMenuItem(value: 14, child: Text('Last 14 days')),
              PopupMenuItem(value: 30, child: Text('Last 30 days')),
            ],
          ),
        ],
      ),
      body: PremiumGate(
        feature: PremiumFeature.nutritionReports,
        description: 'See how your intake trends across the week, where your '
            'macros land on average, and export it as a PDF.',
        child: FutureBuilder<Map<String, DayTotals>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            return _ReportBody(totals: snapshot.requireData, days: _days);
          },
        ),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.totals, required this.days});

  final Map<String, DayTotals> totals;
  final int days;

  List<({String date, DayTotals totals})> get _series {
    final end = DateTime.now();
    return [
      for (var i = days - 1; i >= 0; i--)
        (
          date: isoDate(end.subtract(Duration(days: i))),
          totals: totals[isoDate(end.subtract(Duration(days: i)))] ??
              const DayTotals(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final premium = context.watch<PremiumController>();
    final theme = Theme.of(context);
    final series = _series;
    final logged = series.where((d) => d.totals.entries > 0).toList();
    final avgCalories = logged.isEmpty
        ? 0.0
        : logged.map((d) => d.totals.calories).reduce((a, b) => a + b) /
            logged.length;
    final avgProtein = logged.isEmpty
        ? 0.0
        : logged.map((d) => d.totals.protein).reduce((a, b) => a + b) /
            logged.length;
    final avgCarbs = logged.isEmpty
        ? 0.0
        : logged.map((d) => d.totals.carbs).reduce((a, b) => a + b) /
            logged.length;
    final avgFat = logged.isEmpty
        ? 0.0
        : logged.map((d) => d.totals.fat).reduce((a, b) => a + b) /
            logged.length;

    if (logged.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Nothing logged in the last $days days. Add a few meals to your '
          'diary and the report fills in automatically.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Daily average over ${logged.length} logged days',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _Kpi(
                        label: 'Calories',
                        value: avgCalories.round().toString(),
                        unit: 'kcal'),
                    _Kpi(
                        label: 'Protein',
                        value: avgProtein.round().toString(),
                        unit: 'g'),
                    _Kpi(
                        label: 'Carbs',
                        value: avgCarbs.round().toString(),
                        unit: 'g'),
                    _Kpi(
                        label: 'Fat',
                        value: avgFat.round().toString(),
                        unit: 'g'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  avgCalories > prefs.calorieGoal
                      ? '${(avgCalories - prefs.calorieGoal).round()} kcal/day above your goal'
                      : '${(prefs.calorieGoal - avgCalories).round()} kcal/day below your goal',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: avgCalories > prefs.calorieGoal
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Calories per day', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        SizedBox(
          height: 220,
          child: _CalorieChart(series: series, goal: prefs.calorieGoal),
        ),
        const SizedBox(height: 24),
        Text('Where your calories came from',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        _MacroDonut(protein: avgProtein, carbs: avgCarbs, fat: avgFat),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: premium.isUnlocked(PremiumFeature.pdfExport)
              ? () => _exportPdf(context, series, prefs)
              : () async {
                  final ok = await premium.unlock(PremiumFeature.pdfExport);
                  if (ok && context.mounted) {
                    await _exportPdf(context, series, prefs);
                  }
                },
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: Text(premium.isUnlocked(PremiumFeature.pdfExport)
              ? 'Export as PDF'
              : 'Watch an ad to export a PDF'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _exportPdf(
    BuildContext context,
    List<({String date, DayTotals totals})> series,
    PreferencesService prefs,
  ) async {
    final doc = pw.Document();
    final logged = series.where((d) => d.totals.entries > 0).toList();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(level: 0, text: 'Nutrition report'),
          pw.Paragraph(
            text: 'Period: ${series.first.date} to ${series.last.date}\n'
                'Daily calorie goal: ${prefs.calorieGoal} kcal\n'
                'Days logged: ${logged.length} of ${series.length}',
          ),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Date',
              'Calories',
              'Protein g',
              'Carbs g',
              'Fat g',
              'Items'
            ],
            cellAlignment: pw.Alignment.centerRight,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            data: [
              for (final d in series)
                [
                  d.date,
                  d.totals.calories.round().toString(),
                  d.totals.protein.round().toString(),
                  d.totals.carbs.round().toString(),
                  d.totals.fat.round().toString(),
                  d.totals.entries.toString(),
                ],
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Paragraph(
            text: 'Generated by Indian Food Calories. Nutrition values are '
                'estimates compiled from IFCT 2017, USDA FoodData Central and '
                'Open Food Facts. This report is not medical advice.',
          ),
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'nutrition-report-${isoDate(DateTime.now())}.pdf',
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(value,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(unit, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _CalorieChart extends StatelessWidget {
  const _CalorieChart({required this.series, required this.goal});

  final List<({String date, DayTotals totals})> series;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxY = [
      goal.toDouble(),
      ...series.map((d) => d.totals.calories),
    ].reduce((a, b) => a > b ? a : b);
    return BarChart(
      BarChartData(
        maxY: maxY * 1.15,
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              getTitlesWidget: (v, _) =>
                  Text(v.round().toString(), style: theme.textTheme.labelSmall),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (series.length / 7).ceilToDouble(),
              getTitlesWidget: (v, _) {
                final i = v.round();
                if (i < 0 || i >= series.length) return const SizedBox.shrink();
                return Text(
                  DateFormat('d/M').format(DateTime.parse(series[i].date)),
                  style: theme.textTheme.labelSmall,
                );
              },
            ),
          ),
        ),
        extraLinesData: ExtraLinesData(horizontalLines: [
          HorizontalLine(
            y: goal.toDouble(),
            color: theme.colorScheme.error.withValues(alpha: .7),
            strokeWidth: 1.5,
            dashArray: [6, 4],
          ),
        ]),
        barGroups: [
          for (var i = 0; i < series.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: series[i].totals.calories,
                width: 12,
                borderRadius: BorderRadius.circular(4),
                color: series[i].totals.calories > goal
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ]),
        ],
      ),
    );
  }
}

class _MacroDonut extends StatelessWidget {
  const _MacroDonut({
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final double protein;
  final double carbs;
  final double fat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = protein * 4, c = carbs * 4, f = fat * 9;
    final total = (p + c + f).clamp(1, double.infinity);
    return SizedBox(
      height: 180,
      child: Row(
        children: [
          Expanded(
            child: PieChart(
              PieChartData(
                centerSpaceRadius: 38,
                sectionsSpace: 2,
                sections: [
                  PieChartSectionData(
                    value: p,
                    color: AppTheme.macroProtein,
                    title: '${(p / total * 100).round()}%',
                    radius: 42,
                    titleStyle: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                  ),
                  PieChartSectionData(
                    value: c,
                    color: AppTheme.macroCarbs,
                    title: '${(c / total * 100).round()}%',
                    radius: 42,
                    titleStyle: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                  ),
                  PieChartSectionData(
                    value: f,
                    color: AppTheme.macroFat,
                    title: '${(f / total * 100).round()}%',
                    radius: 42,
                    titleStyle: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Legend(
                    color: AppTheme.macroProtein,
                    label: 'Protein ${protein.round()} g'),
                _Legend(
                    color: AppTheme.macroCarbs,
                    label: 'Carbs ${carbs.round()} g'),
                _Legend(
                    color: AppTheme.macroFat, label: 'Fat ${fat.round()} g'),
                const SizedBox(height: 10),
                Text(
                  'Averages across logged days.',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}
