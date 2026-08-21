import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/services/preferences_service.dart';
import '../../domain/calculators.dart';

class WeightPlannerScreen extends StatefulWidget {
  const WeightPlannerScreen({super.key, this.mode = 'lose'});

  final String mode;

  @override
  State<WeightPlannerScreen> createState() => _WeightPlannerScreenState();
}

class _WeightPlannerScreenState extends State<WeightPlannerScreen> {
  double? _target;
  double _rate = 0.5;

  bool get _isLoss => widget.mode != 'gain';

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final current = prefs.weightKg;
    final target = _target ?? (_isLoss ? current - 5 : current + 5);
    final bmr = BodyMetrics.bmr(
      sex: prefs.sex,
      weightKg: current,
      heightCm: prefs.heightCm,
      age: prefs.age,
    );
    final tdee = BodyMetrics.tdee(bmr: bmr, activity: prefs.activity);
    final plan = WeightPlan.build(
      currentKg: current,
      targetKg: target,
      weeklyRateKg: _rate,
      tdee: tdee,
      sex: prefs.sex,
    );
    final macros = MacroSplit.forTarget(
      calories: plan.dailyCalories,
      weightKg: current,
      activity: prefs.activity,
      goal: _isLoss ? GoalType.lose : GoalType.gain,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isLoss ? 'Weight loss planner' : 'Weight gain planner'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Current weight: ${current.toStringAsFixed(1)} kg',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 16),
          Text('Target weight: ${target.toStringAsFixed(1)} kg',
              style: theme.textTheme.titleSmall),
          Slider(
            value: target.clamp(35, 160),
            min: 35,
            max: 160,
            divisions: 250,
            label: '${target.toStringAsFixed(1)} kg',
            onChanged: (v) => setState(() => _target = v),
          ),
          const SizedBox(height: 8),
          Text(
            _isLoss
                ? 'Rate: ${_rate.toStringAsFixed(2)} kg per week'
                : 'Rate: ${_rate.toStringAsFixed(2)} kg per week',
            style: theme.textTheme.titleSmall,
          ),
          Slider(
            value: _rate,
            min: 0.1,
            max: _isLoss ? 1.0 : 0.5,
            divisions: _isLoss ? 18 : 8,
            label: '${_rate.toStringAsFixed(2)} kg/week',
            onChanged: (v) => setState(() => _rate = v),
          ),
          Text(
            _isLoss
                ? 'Losing more than about 1 % of body weight per week costs '
                    'muscle and is hard to sustain.'
                : 'Gaining faster than ~0.5 kg per week mostly adds fat, not '
                    'muscle.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${plan.dailyCalories} kcal',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text('daily calorie target',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium),
                  const Divider(height: 28),
                  _Row(
                    label: 'Maintenance (TDEE)',
                    value: '${tdee.round()} kcal',
                  ),
                  _Row(
                    label: _isLoss ? 'Daily deficit' : 'Daily surplus',
                    value: '${(plan.dailyCalories - tdee).abs().round()} kcal',
                  ),
                  _Row(label: 'Time to target', value: '${plan.weeks} weeks'),
                  _Row(
                    label: 'Projected date',
                    value: DateFormat('d MMM yyyy').format(plan.projectedDate),
                  ),
                  const Divider(height: 28),
                  _Row(
                      label: 'Protein',
                      value: '${macros.proteinG.round()} g/day'),
                  _Row(label: 'Carbs', value: '${macros.carbsG.round()} g/day'),
                  _Row(label: 'Fat', value: '${macros.fatG.round()} g/day'),
                ],
              ),
            ),
          ),
          if (plan.warning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(plan.warning,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      )),
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              prefs.setCalorieGoal(plan.dailyCalories);
              prefs.setProteinGoal(macros.proteinG.round());
              prefs.saveProfile(goal: _isLoss ? GoalType.lose : GoalType.gain);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Goals updated')),
              );
            },
            icon: const Icon(Icons.check),
            label: const Text('Apply this plan'),
          ),
          const SizedBox(height: 20),
          Text(
            'Estimates assume roughly 7,700 kcal per kilogram of body weight. '
            'Real progress is not linear — water weight, glycogen and the body '
            'adapting to a lower intake all move the line. This is guidance, '
            'not medical advice; check with a doctor if you have a health '
            'condition or take medication.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}
