import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models/food.dart';

String formatNutrient(Nutrient n, double? value) {
  if (value == null) return '—';
  return '${value.toStringAsFixed(n.decimals)} ${n.unit}';
}

/// Full nutrient table with %RDA bars. Values are already scaled to the chosen
/// portion by the caller.
class NutritionTable extends StatelessWidget {
  const NutritionTable({
    super.key,
    required this.values,
    this.microsEstimated = false,
    this.showRda = true,
  });

  final Map<Nutrient, double?> values;
  final bool microsEstimated;
  final bool showRda;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final n in Nutrient.values)
          if (n != Nutrient.calories)
            _NutrientRow(
              nutrient: n,
              value: values[n],
              showRda: showRda,
            ),
        if (microsEstimated)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Micronutrients marked for this food are estimated from a food-class '
              'profile because the source table does not publish them. Macros and '
              'calories are from the source data.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _NutrientRow extends StatelessWidget {
  const _NutrientRow({
    required this.nutrient,
    required this.value,
    required this.showRda,
  });

  final Nutrient nutrient;
  final double? value;
  final bool showRda;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rda = nutrient.rda;
    final pct = (rda == null || value == null) ? null : (value! / rda);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(nutrient.label, style: theme.textTheme.bodyMedium),
              ),
              Text(
                formatNutrient(nutrient, value),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: nutrient.isMacro ? FontWeight.w600 : null,
                ),
              ),
              if (showRda && pct != null)
                SizedBox(
                  width: 52,
                  child: Text(
                    '${(pct * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          if (showRda && pct != null) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: pct > 1
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Protein / carbs / fat split as a single stacked bar plus legend.
class MacroBar extends StatelessWidget {
  const MacroBar({
    super.key,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.height = 12,
    this.showLegend = true,
  });

  final double protein;
  final double carbs;
  final double fat;
  final double height;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final pKcal = protein * 4;
    final cKcal = carbs * 4;
    final fKcal = fat * 9;
    final total = math.max(1.0, pKcal + cKcal + fKcal);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                Expanded(
                  flex: math.max(1, (pKcal / total * 1000).round()),
                  child: Container(color: AppTheme.macroProtein),
                ),
                Expanded(
                  flex: math.max(1, (cKcal / total * 1000).round()),
                  child: Container(color: AppTheme.macroCarbs),
                ),
                Expanded(
                  flex: math.max(1, (fKcal / total * 1000).round()),
                  child: Container(color: AppTheme.macroFat),
                ),
              ],
            ),
          ),
        ),
        if (showLegend) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _MacroLegend(
                color: AppTheme.macroProtein,
                label: 'Protein',
                grams: protein,
                percent: pKcal / total,
              ),
              _MacroLegend(
                color: AppTheme.macroCarbs,
                label: 'Carbs',
                grams: carbs,
                percent: cKcal / total,
              ),
              _MacroLegend(
                color: AppTheme.macroFat,
                label: 'Fat',
                grams: fat,
                percent: fKcal / total,
              ),
            ],
          ),
        ],
        if (showLegend)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Percentages are of calories, not grams.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _MacroLegend extends StatelessWidget {
  const _MacroLegend({
    required this.color,
    required this.label,
    required this.grams,
    required this.percent,
  });

  final Color color;
  final String label;
  final double grams;
  final double percent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label ${grams.toStringAsFixed(1)} g · ${(percent * 100).round()}%',
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
  }
}

/// Big calorie ring used on the diary and home screens.
class CalorieRing extends StatelessWidget {
  const CalorieRing({
    super.key,
    required this.consumed,
    required this.goal,
    this.size = 132,
  });

  final double consumed;
  final int goal;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = goal <= 0 ? 0.0 : (consumed / goal);
    final over = progress > 1;
    final remaining = goal - consumed;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              strokeWidth: 11,
              strokeCap: StrokeCap.round,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: over ? theme.colorScheme.error : theme.colorScheme.primary,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${remaining.abs().round()}',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                over ? 'kcal over' : 'kcal left',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '${consumed.round()} / $goal',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
