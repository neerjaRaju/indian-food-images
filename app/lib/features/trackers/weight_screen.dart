import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/models/diary.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/preferences_service.dart';
import '../../domain/calculators.dart';

class WeightScreen extends StatefulWidget {
  const WeightScreen({super.key});

  @override
  State<WeightScreen> createState() => _WeightScreenState();
}

class _WeightScreenState extends State<WeightScreen> {
  late Future<List<WeightEntry>> _future = _load();

  Future<List<WeightEntry>> _load() =>
      context.read<UserRepository>().weightHistory();

  Future<void> _logWeight() async {
    final prefs = context.read<PreferencesService>();
    final users = context.read<UserRepository>();
    final controller =
        TextEditingController(text: prefs.weightKg.toStringAsFixed(1));
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log weight'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'kg'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || value < 25 || value > 300) return;
    await users.logWeight(
      WeightEntry(date: isoDate(DateTime.now()), kg: value),
    );
    await prefs.saveProfile(weightKg: value);
    if (!mounted) return;
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Weight')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _logWeight,
        icon: const Icon(Icons.add),
        label: const Text('Log weight'),
      ),
      body: SafeArea(
        // Edge-to-edge: this screen is pushed full-screen, so
        // nothing else keeps its last row clear of the gesture
        // bar. The app bar already owns the top inset.
        top: false,
        child: FutureBuilder<List<WeightEntry>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final entries = snapshot.requireData;
            final bmi = BodyMetrics.bmi(
              weightKg: prefs.weightKg,
              heightCm: prefs.heightCm,
            );
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${prefs.weightKg.toStringAsFixed(1)} kg',
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                              Text(
                                'BMI ${bmi.toStringAsFixed(1)} · '
                                '${BodyMetrics.bmiCategory(bmi)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (entries.length >= 2)
                          _Trend(
                            delta: entries.last.kg - entries.first.kg,
                            days: entries.length,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (entries.length < 2)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Log your weight on at least two days to see a trend line. '
                      'Weighing at the same time of day — usually first thing in '
                      'the morning — makes the line far less noisy.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                else
                  SizedBox(height: 240, child: _WeightChart(entries: entries)),
                const SizedBox(height: 24),
                Text('History', style: theme.textTheme.titleMedium),
                for (final e in entries.reversed)
                  ListTile(
                    title: Text('${e.kg.toStringAsFixed(1)} kg'),
                    subtitle: Text(DateFormat('EEE, d MMM yyyy')
                        .format(DateTime.parse(e.date))),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await context
                            .read<UserRepository>()
                            .deleteWeight(e.date);
                        if (!context.mounted) return;
                        setState(() => _future = _load());
                      },
                    ),
                  ),
                const SizedBox(height: 80),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend({required this.delta, required this.days});

  final double delta;
  final int days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final down = delta < 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          children: [
            Icon(down ? Icons.arrow_downward : Icons.arrow_upward,
                size: 16,
                color: down
                    ? theme.colorScheme.primary
                    : theme.colorScheme.tertiary),
            Text('${delta.abs().toStringAsFixed(1)} kg',
                style: theme.textTheme.titleSmall),
          ],
        ),
        Text('over $days entries', style: theme.textTheme.labelSmall),
      ],
    );
  }
}

class _WeightChart extends StatelessWidget {
  const _WeightChart({required this.entries});

  final List<WeightEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spots = <FlSpot>[
      for (var i = 0; i < entries.length; i++)
        FlSpot(i.toDouble(), entries[i].kg),
    ];
    final values = entries.map((e) => e.kg).toList()..sort();
    final min = values.first - 1;
    final max = values.last + 1;
    return LineChart(
      LineChartData(
        minY: min,
        maxY: max,
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 38,
              getTitlesWidget: (v, meta) => Text(
                v.toStringAsFixed(0),
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (entries.length / 4).ceilToDouble(),
              getTitlesWidget: (v, meta) {
                final i = v.round();
                if (i < 0 || i >= entries.length) {
                  return const SizedBox.shrink();
                }
                return Text(
                  DateFormat('d/M').format(DateTime.parse(entries[i].date)),
                  style: theme.textTheme.labelSmall,
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            barWidth: 3,
            color: theme.colorScheme.primary,
            dotData: FlDotData(show: entries.length <= 30),
            belowBarData: BarAreaData(
              show: true,
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
            ),
          ),
        ],
      ),
    );
  }
}
