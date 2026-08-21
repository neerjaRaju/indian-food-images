import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/preferences_service.dart';
import '../../domain/calculators.dart';
import '../../state/diary_controller.dart';

class WaterScreen extends StatefulWidget {
  const WaterScreen({super.key});

  @override
  State<WaterScreen> createState() => _WaterScreenState();
}

class _WaterScreenState extends State<WaterScreen> {
  late Future<Map<String, int>> _history;

  static const _presets = [150, 250, 500, 1000];

  @override
  void initState() {
    super.initState();
    _history = _loadHistory();
  }

  Future<Map<String, int>> _loadHistory() {
    final users = context.read<UserRepository>();
    final today = DateTime.now();
    final from = today.subtract(const Duration(days: 6));
    return users.waterRange(isoDate(from), isoDate(today));
  }

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final progress = prefs.waterGoalMl == 0
        ? 0.0
        : (diary.waterMl / prefs.waterGoalMl).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Water'),
        actions: [
          IconButton(
            tooltip: 'Suggest a goal from my weight',
            icon: const Icon(Icons.auto_awesome),
            onPressed: () {
              final suggested = BodyMetrics.waterTargetMl(
                weightKg: prefs.weightKg,
                activity: prefs.activity,
              );
              prefs.setWaterGoal(suggested);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Goal set to $suggested ml')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 14,
                      strokeCap: StrokeCap.round,
                      color: AppTheme.water,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${diary.waterMl}',
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text('of ${prefs.waterGoalMl} ml',
                          style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final ml in _presets)
                FilledButton.tonal(
                  onPressed: () async {
                    await diary.addWater(ml);
                    setState(() => _history = _loadHistory());
                  },
                  child: Text('+$ml ml'),
                ),
              OutlinedButton(
                onPressed: () async {
                  await diary.addWater(-250);
                  setState(() => _history = _loadHistory());
                },
                child: const Text('−250 ml'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('Daily goal', style: theme.textTheme.titleMedium),
          Slider(
            value: prefs.waterGoalMl.toDouble().clamp(1000, 6000),
            min: 1000,
            max: 6000,
            divisions: 50,
            label: '${prefs.waterGoalMl} ml',
            onChanged: (v) => prefs.setWaterGoal(v.round()),
          ),
          const SizedBox(height: 16),
          Text('Last 7 days', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          FutureBuilder<Map<String, int>>(
            future: _history,
            builder: (context, snapshot) {
              final data = snapshot.data ?? const <String, int>{};
              final today = DateTime.now();
              return SizedBox(
                height: 140,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 6; i >= 0; i--)
                      Expanded(
                        child: _Bar(
                          value: data[
                                  isoDate(today.subtract(Duration(days: i)))] ??
                              0,
                          goal: prefs.waterGoalMl,
                          label: _weekday(today.subtract(Duration(days: i))),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'The 35 ml per kilogram rule is a starting point. Hot weather, '
            'physical work and high-fibre Indian diets all push the number up; '
            'thirst and pale urine are better day-to-day signals than a target.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _weekday(DateTime d) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.goal, required this.label});

  final int value;
  final int goal;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = goal == 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(value == 0 ? '' : '${(value / 1000).toStringAsFixed(1)}L',
              style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Container(
            height: 90 * fraction + 2,
            decoration: BoxDecoration(
              color: AppTheme.water.withValues(alpha: fraction >= 1 ? 1 : .7),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
