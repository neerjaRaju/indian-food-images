import 'package:flutter/material.dart';

import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../data/services/ads_service.dart';
import '../../widgets/premium_gate.dart';

class FilterSheet extends StatefulWidget {
  const FilterSheet({
    super.key,
    required this.initial,
    required this.categories,
    required this.advancedUnlocked,
  });

  final FoodFilter initial;
  final List<FoodCategory> categories;
  final bool advancedUnlocked;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late FoodFilter _filter = widget.initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Text('Filters', style: theme.textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('Diet', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _choice(
                        'Any',
                        _filter.diet == null,
                        () => setState(
                            () => _filter = _filter.copyWith(clearDiet: true))),
                    for (final d in const [
                      ('veg', 'Vegetarian'),
                      ('vegan', 'Vegan'),
                      ('egg', 'Egg'),
                      ('nonveg', 'Non-veg'),
                    ])
                      _choice(
                          d.$2,
                          _filter.diet == d.$1,
                          () => setState(
                              () => _filter = _filter.copyWith(diet: d.$1))),
                  ],
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Jain-friendly only'),
                  value: _filter.jainOnly,
                  onChanged: (v) =>
                      setState(() => _filter = _filter.copyWith(jainOnly: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only foods with a photo'),
                  value: _filter.withImageOnly,
                  onChanged: (v) => setState(
                      () => _filter = _filter.copyWith(withImageOnly: v)),
                ),
                const Divider(height: 32),
                Text('Type', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _choice(
                        'Any',
                        _filter.foodType == null,
                        () => setState(
                            () => _filter = _filter.copyWith(clearType: true))),
                    for (final t in const [
                      ('food', 'Dishes'),
                      ('recipe', 'Recipes'),
                      ('packaged', 'Packaged'),
                    ])
                      _choice(
                          t.$2,
                          _filter.foodType == t.$1,
                          () => setState(() =>
                              _filter = _filter.copyWith(foodType: t.$1))),
                  ],
                ),
                const Divider(height: 32),
                Text('Cuisine / category', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _choice(
                        'Any',
                        _filter.categoryId == null,
                        () => setState(() =>
                            _filter = _filter.copyWith(clearCategory: true))),
                    for (final c in widget.categories)
                      _choice(
                          '${c.icon} ${c.name}',
                          _filter.categoryId == c.id,
                          () => setState(() =>
                              _filter = _filter.copyWith(categoryId: c.id))),
                  ],
                ),
                const Divider(height: 32),
                Text('Sort by', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final s in FoodSort.values)
                      _choice(
                          s.label,
                          _filter.sort == s,
                          () => setState(
                              () => _filter = _filter.copyWith(sort: s))),
                  ],
                ),
                const Divider(height: 32),
                Text('Advanced', style: theme.textTheme.titleSmall),
                if (!widget.advancedUnlocked)
                  const PremiumGate(
                    feature: PremiumFeature.advancedFilters,
                    compact: true,
                    description: 'Filter by a calorie ceiling and a protein '
                        'floor to find exactly the foods that fit your target.',
                    child: SizedBox.shrink(),
                  )
                else ...[
                  _SliderRow(
                    label: 'Max calories per 100 g',
                    value: _filter.maxCalories ?? 900,
                    min: 40,
                    max: 900,
                    suffix: 'kcal',
                    onChanged: (v) => setState(() => _filter =
                        _filter.copyWith(maxCalories: v >= 900 ? null : v)),
                  ),
                  _SliderRow(
                    label: 'Min protein per 100 g',
                    value: _filter.minProtein ?? 0,
                    min: 0,
                    max: 40,
                    suffix: 'g',
                    onChanged: (v) => setState(() => _filter =
                        _filter.copyWith(minProtein: v <= 0 ? null : v)),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.of(context).pop(const FoodFilter()),
                      child: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(_filter),
                      child: const Text('Apply filters'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choice(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('$label: ${value.round()} $suffix',
            style: Theme.of(context).textTheme.bodyMedium),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / 5).round(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
