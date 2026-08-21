import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/router.dart';
import '../../data/services/preferences_service.dart';
import '../../domain/calculators.dart';

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final bmi = BodyMetrics.bmi(
      weightKg: prefs.weightKg,
      heightCm: prefs.heightCm,
    );
    final bmr = BodyMetrics.bmr(
      sex: prefs.sex,
      weightKg: prefs.weightKg,
      heightCm: prefs.heightCm,
      age: prefs.age,
    );
    final tdee = BodyMetrics.tdee(bmr: bmr, activity: prefs.activity);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Tools', style: theme.textTheme.headlineSmall),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your numbers', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _Stat(
                          label: 'BMI',
                          value: bmi.toStringAsFixed(1),
                          sub: BodyMetrics.bmiCategory(bmi),
                        ),
                        _Stat(
                          label: 'BMR',
                          value: bmr.round().toString(),
                          sub: 'kcal/day',
                        ),
                        _Stat(
                          label: 'TDEE',
                          value: tdee.round().toString(),
                          sub: 'kcal/day',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => context.push(Routes.settings),
                      icon: const Icon(Icons.person_outline),
                      label: const Text('Update height, weight, activity'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _ToolTile(
              icon: Icons.monitor_weight_outlined,
              title: 'BMI calculator',
              subtitle: 'With the lower Indian cut-offs',
              onTap: () => context.push('${Routes.calculators}?tab=0'),
            ),
            _ToolTile(
              icon: Icons.local_fire_department_outlined,
              title: 'BMR & TDEE calculator',
              subtitle: 'Mifflin–St Jeor with activity multipliers',
              onTap: () => context.push('${Routes.calculators}?tab=1'),
            ),
            _ToolTile(
              icon: Icons.pie_chart_outline,
              title: 'Macro calculator',
              subtitle: 'Split a calorie target into protein, carbs and fat',
              onTap: () => context.push('${Routes.calculators}?tab=2'),
            ),
            _ToolTile(
              icon: Icons.egg_outlined,
              title: 'Protein calculator',
              subtitle:
                  'How much you need, and Indian foods that get you there',
              onTap: () => context.push('${Routes.calculators}?tab=3'),
            ),
            const Divider(height: 24),
            _ToolTile(
              icon: Icons.trending_down,
              title: 'Weight loss planner',
              subtitle: 'Safe rate, daily calories and a projected date',
              onTap: () => context.push('${Routes.weightPlanner}?mode=lose'),
            ),
            _ToolTile(
              icon: Icons.trending_up,
              title: 'Weight gain planner',
              subtitle: 'Surplus that adds mass without excess fat',
              onTap: () => context.push('${Routes.weightPlanner}?mode=gain'),
            ),
            const Divider(height: 24),
            _ToolTile(
              icon: Icons.restaurant_menu,
              title: 'Meal planner',
              subtitle: 'Build a week of Indian meals around your target',
              onTap: () => context.push(Routes.planner),
            ),
            _ToolTile(
              icon: Icons.compare_arrows,
              title: 'Compare foods',
              subtitle: 'Put two dishes side by side',
              onTap: () => context.push(Routes.compare),
            ),
            _ToolTile(
              icon: Icons.insights_outlined,
              title: 'Nutrition reports',
              subtitle: 'Weekly trends and a PDF export',
              onTap: () => context.push(Routes.reports),
            ),
            _ToolTile(
              icon: Icons.water_drop_outlined,
              title: 'Water tracker',
              subtitle: 'Daily goal based on your weight',
              onTap: () => context.push(Routes.water),
            ),
            _ToolTile(
              icon: Icons.show_chart,
              title: 'Weight tracker',
              subtitle: 'Log and chart your weight over time',
              onTap: () => context.push(Routes.weight),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.sub});

  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(sub,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
        ],
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(icon, size: 20),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
