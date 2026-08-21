import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../data/services/ads_service.dart';
import '../../data/services/preferences_service.dart';
import '../../domain/calculators.dart';
import '../../widgets/food_tile.dart';
import '../../widgets/nutrition_widgets.dart';
import '../../widgets/premium_gate.dart';

class CalculatorsScreen extends StatefulWidget {
  const CalculatorsScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<CalculatorsScreen> createState() => _CalculatorsScreenState();
}

class _CalculatorsScreenState extends State<CalculatorsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
      length: 4, vsync: this, initialIndex: widget.initialTab.clamp(0, 3));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calculators'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'BMI'),
            Tab(text: 'BMR / TDEE'),
            Tab(text: 'Macros'),
            Tab(text: 'Protein'),
          ],
        ),
      ),
      body: SafeArea(
        // Edge-to-edge: this screen is pushed full-screen, so
        // nothing else keeps its last row clear of the gesture
        // bar. The app bar already owns the top inset.
        top: false,
        child: TabBarView(
          controller: _tabs,
          children: const [
            _BmiTab(),
            _EnergyTab(),
            _MacroTab(),
            _ProteinTab(),
          ],
        ),
      ),
    );
  }
}

/// Shared editable profile inputs so each tab stays in sync with settings.
class _ProfileInputs extends StatelessWidget {
  const _ProfileInputs({this.showActivity = true});

  final bool showActivity;

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NumberField(
          label: 'Weight',
          suffix: 'kg',
          value: prefs.weightKg,
          min: 25,
          max: 250,
          onChanged: (v) => prefs.saveProfile(weightKg: v),
        ),
        _NumberField(
          label: 'Height',
          suffix: 'cm',
          value: prefs.heightCm,
          min: 100,
          max: 230,
          onChanged: (v) => prefs.saveProfile(heightCm: v),
        ),
        _NumberField(
          label: 'Age',
          suffix: 'years',
          value: prefs.age.toDouble(),
          min: 12,
          max: 100,
          onChanged: (v) => prefs.saveProfile(age: v.round()),
        ),
        const SizedBox(height: 8),
        SegmentedButton<Sex>(
          segments: const [
            ButtonSegment(value: Sex.male, label: Text('Male')),
            ButtonSegment(value: Sex.female, label: Text('Female')),
          ],
          selected: {prefs.sex},
          showSelectedIcon: false,
          onSelectionChanged: (s) => prefs.saveProfile(sex: s.first),
        ),
        if (showActivity) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<ActivityLevel>(
            initialValue: prefs.activity,
            decoration: const InputDecoration(labelText: 'Activity level'),
            items: [
              for (final a in ActivityLevel.values)
                DropdownMenuItem(value: a, child: Text(a.label)),
            ],
            onChanged: (a) {
              if (a != null) prefs.saveProfile(activity: a);
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              prefs.activity.description,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.suffix,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String suffix;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: _format(widget.value));

  static String _format(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: widget.label,
          suffixText: widget.suffix,
        ),
        onChanged: (text) {
          final v = double.tryParse(text);
          if (v != null && v >= widget.min && v <= widget.max) {
            widget.onChanged(v);
          }
        },
      ),
    );
  }
}

class _BmiTab extends StatelessWidget {
  const _BmiTab();

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final bmi =
        BodyMetrics.bmi(weightKg: prefs.weightKg, heightCm: prefs.heightCm);
    final category = BodyMetrics.bmiCategory(bmi);
    final (lo, hi) = BodyMetrics.healthyWeightRange(prefs.heightCm);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _ProfileInputs(showActivity: false),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(bmi.toStringAsFixed(1),
                    style: theme.textTheme.displaySmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(category, style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(
                  'A healthy weight for your height is '
                  '${lo.toStringAsFixed(1)}–${hi.toStringAsFixed(1)} kg.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'This app uses the ICMR cut-offs for Indian adults — overweight from '
          '23 and obese from 25 — because cardiometabolic risk rises at a lower '
          'BMI in South Asian populations than the global WHO thresholds assume.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text(
          'BMI does not distinguish muscle from fat and is a screening number, '
          'not a diagnosis. Talk to a doctor before acting on it.',
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
  }
}

class _EnergyTab extends StatelessWidget {
  const _EnergyTab();

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final bmr = BodyMetrics.bmr(
      sex: prefs.sex,
      weightKg: prefs.weightKg,
      heightCm: prefs.heightCm,
      age: prefs.age,
    );
    final tdee = BodyMetrics.tdee(bmr: bmr, activity: prefs.activity);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _ProfileInputs(),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _ResultRow(
                    label: 'BMR (at rest)', value: '${bmr.round()} kcal'),
                const Divider(),
                _ResultRow(
                    label: 'TDEE (with activity)',
                    value: '${tdee.round()} kcal',
                    emphasise: true),
                const Divider(),
                for (final g in GoalType.values)
                  _ResultRow(
                    label: g.label,
                    value:
                        '${BodyMetrics.calorieTarget(tdee: tdee, goal: g, sex: prefs.sex)} kcal',
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () {
            final target = BodyMetrics.calorieTarget(
                tdee: tdee, goal: prefs.goal, sex: prefs.sex);
            prefs.setCalorieGoal(target);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Daily goal set to $target kcal')),
            );
          },
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Use as my daily calorie goal'),
        ),
        const SizedBox(height: 12),
        Text(
          'Mifflin–St Jeor estimates energy at rest, then the activity '
          'multiplier scales it. Real needs vary by ±10 %, so adjust after two '
          'weeks of tracking rather than trusting the first number.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: emphasise
                ? theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)
                : theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _MacroTab extends StatefulWidget {
  const _MacroTab();

  @override
  State<_MacroTab> createState() => _MacroTabState();
}

class _MacroTabState extends State<_MacroTab> {
  int _protein = 25;
  int _carbs = 45;
  int _fat = 30;
  bool _auto = true;

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final split = _auto
        ? MacroSplit.forTarget(
            calories: prefs.calorieGoal,
            weightKg: prefs.weightKg,
            activity: prefs.activity,
            goal: prefs.goal,
          )
        : MacroSplit.ratio(
            calories: prefs.calorieGoal,
            proteinPct: _protein,
            carbsPct: _carbs,
            fatPct: _fat,
          );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Daily target: ${prefs.calorieGoal} kcal',
            style: theme.textTheme.titleMedium),
        Slider(
          value: prefs.calorieGoal.toDouble().clamp(1000, 4000),
          min: 1000,
          max: 4000,
          divisions: 60,
          label: '${prefs.calorieGoal} kcal',
          onChanged: (v) => prefs.setCalorieGoal(v.round()),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Body-weight based split'),
          subtitle: const Text(
              'Protein from your weight and training, fat at 27 %, carbs fill '
              'the rest'),
          value: _auto,
          onChanged: (v) => setState(() => _auto = v),
        ),
        if (!_auto) ...[
          _RatioSlider(
            label: 'Protein',
            value: _protein,
            color: AppTheme.macroProtein,
            onChanged: (v) => setState(() => _protein = v),
          ),
          _RatioSlider(
            label: 'Carbs',
            value: _carbs,
            color: AppTheme.macroCarbs,
            onChanged: (v) => setState(() => _carbs = v),
          ),
          _RatioSlider(
            label: 'Fat',
            value: _fat,
            color: AppTheme.macroFat,
            onChanged: (v) => setState(() => _fat = v),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                MacroBar(
                  protein: split.proteinG,
                  carbs: split.carbsG,
                  fat: split.fatG,
                ),
                const SizedBox(height: 16),
                _ResultRow(
                    label: 'Protein',
                    value: '${split.proteinG.round()} g',
                    emphasise: true),
                _ResultRow(label: 'Carbs', value: '${split.carbsG.round()} g'),
                _ResultRow(label: 'Fat', value: '${split.fatG.round()} g'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        PremiumGate(
          feature: PremiumFeature.advancedMacros,
          description: 'See how your logged meals compare against this split, '
              'day by day, with fibre and saturated-fat checks.',
          child: _AdvancedMacroNotes(split: split),
        ),
      ],
    );
  }
}

class _RatioSlider extends StatelessWidget {
  const _RatioSlider({
    required this.label,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final int value;
  final Color color;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: 5,
            max: 65,
            divisions: 12,
            label: '$value%',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(width: 36, child: Text('$value%')),
      ],
    );
  }
}

class _AdvancedMacroNotes extends StatelessWidget {
  const _AdvancedMacroNotes({required this.split});

  final MacroSplit split;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fibre = (split.calories / 1000 * 14).round();
    final satFatCap = (split.calories * 0.10 / 9).round();
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Beyond the three macros', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            _ResultRow(label: 'Fibre target', value: '$fibre g'),
            _ResultRow(label: 'Saturated fat ceiling', value: '$satFatCap g'),
            _ResultRow(
                label: 'Protein per meal (4 meals)',
                value: '${(split.proteinG / 4).round()} g'),
            const SizedBox(height: 10),
            Text(
              'A typical Indian vegetarian day lands high on carbs and low on '
              'protein. Anchoring each meal with dal, curd, paneer, egg or '
              'soya is the single change that moves the split most.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProteinTab extends StatefulWidget {
  const _ProteinTab();

  @override
  State<_ProteinTab> createState() => _ProteinTabState();
}

class _ProteinTabState extends State<_ProteinTab> {
  late final Future<List<Food>> _future =
      context.read<FoodRepository>().highProtein(
            minProtein: 8,
            limit: 15,
          );

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final theme = Theme.of(context);
    final target = BodyMetrics.proteinTarget(
      weightKg: prefs.weightKg,
      activity: prefs.activity,
      goal: prefs.goal,
    );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _ProfileInputs(),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text('${target.round()} g',
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const Text('protein per day'),
                      const SizedBox(height: 8),
                      Text(
                        '${(target / prefs.weightKg).toStringAsFixed(2)} g per kg '
                        'of body weight',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  prefs.setProteinGoal(target.round());
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content:
                        Text('Protein goal set to ${target.round()} g/day'),
                  ));
                },
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Use as my protein goal'),
              ),
              const SizedBox(height: 24),
              Text('High-protein Indian foods',
                  style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        FutureBuilder<List<Food>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              children: [
                for (final f in snapshot.requireData) FoodTile(food: f),
              ],
            );
          },
        ),
      ],
    );
  }
}
