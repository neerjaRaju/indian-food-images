import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../data/services/ads_service.dart';
import '../../widgets/food_image.dart';
import '../../widgets/nutrition_widgets.dart';
import '../../widgets/premium_gate.dart';

class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key, this.initialFoodId});

  final int? initialFoodId;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  Food? _left;
  Food? _right;
  bool _per100 = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialFoodId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final food =
            await context.read<FoodRepository>().byId(widget.initialFoodId!);
        if (mounted) setState(() => _left = food);
      });
    }
  }

  Future<void> _pick(bool isLeft) async {
    final repo = context.read<FoodRepository>();
    final food = await showModalBottomSheet<Food>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FoodPickerSheet(repo: repo),
    );
    if (food == null) return;
    final full = await repo.byId(food.id);
    if (!mounted) return;
    setState(() {
      if (isLeft) {
        _left = full;
      } else {
        _right = full;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compare foods')),
      body: PremiumGate(
        feature: PremiumFeature.compareFoods,
        description: 'Put two dishes side by side across all 17 nutrients and '
            'see which one actually fits your day.',
        child: _CompareBody(
          left: _left,
          right: _right,
          per100: _per100,
          onPick: _pick,
          onTogglePer100: (v) => setState(() => _per100 = v),
        ),
      ),
    );
  }
}

class _CompareBody extends StatelessWidget {
  const _CompareBody({
    required this.left,
    required this.right,
    required this.per100,
    required this.onPick,
    required this.onTogglePer100,
  });

  final Food? left;
  final Food? right;
  final bool per100;
  final void Function(bool isLeft) onPick;
  final ValueChanged<bool> onTogglePer100;

  double _grams(Food food) => per100 ? 100 : food.defaultServing.grams;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(child: _Slot(food: left, onTap: () => onPick(true))),
            const SizedBox(width: 12),
            Expanded(child: _Slot(food: right, onTap: () => onPick(false))),
          ],
        ),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Per 100 g')),
            ButtonSegment(value: false, label: Text('Per serving')),
          ],
          selected: {per100},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onTogglePer100(s.first),
        ),
        const SizedBox(height: 16),
        if (left == null || right == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Pick two foods to compare.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          )
        else ...[
          if (!per100)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${left!.defaultServing.label} (${_grams(left!).round()} g) vs '
                '${right!.defaultServing.label} (${_grams(right!).round()} g)',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall,
              ),
            ),
          for (final n in Nutrient.values)
            _CompareRow(
              nutrient: n,
              leftValue: left!.valueFor(n, _grams(left!)),
              rightValue: right!.valueFor(n, _grams(right!)),
              // For most nutrients less is better; for these, more is.
              higherIsBetter: n == Nutrient.protein ||
                  n == Nutrient.fiber ||
                  n == Nutrient.calcium ||
                  n == Nutrient.iron ||
                  n == Nutrient.potassium ||
                  n == Nutrient.magnesium ||
                  n.name.startsWith('vitamin'),
            ),
          const SizedBox(height: 24),
          Text(
            'Green marks the better value for that nutrient — more protein, '
            'fibre and micronutrients; less energy, sugar, sodium and '
            'saturated fat. "Better" still depends on your goal.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.food, required this.onTap});

  final Food? food;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          height: 168,
          child: food == null
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_circle_outline, size: 30),
                      SizedBox(height: 8),
                      Text('Pick a food'),
                    ],
                  ),
                )
              : Column(
                  children: [
                    FoodImage(
                      food: food!,
                      size: FoodImageSize.medium,
                      height: 92,
                      width: double.infinity,
                      borderRadius: 0,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              food!.name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _CompareRow extends StatelessWidget {
  const _CompareRow({
    required this.nutrient,
    required this.leftValue,
    required this.rightValue,
    required this.higherIsBetter,
  });

  final Nutrient nutrient;
  final double? leftValue;
  final double? rightValue;
  final bool higherIsBetter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    int? winner;
    if (leftValue != null && rightValue != null && leftValue != rightValue) {
      final leftWins =
          higherIsBetter ? leftValue! > rightValue! : leftValue! < rightValue!;
      winner = leftWins ? 0 : 1;
    }
    Color? colorFor(int side) =>
        winner == side ? const Color(0xFF2E7D32) : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              formatNutrient(nutrient, leftValue),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorFor(0),
                fontWeight: winner == 0 ? FontWeight.w700 : null,
              ),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              nutrient.label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ),
          Expanded(
            child: Text(
              formatNutrient(nutrient, rightValue),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorFor(1),
                fontWeight: winner == 1 ? FontWeight.w700 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FoodPickerSheet extends StatefulWidget {
  const _FoodPickerSheet({required this.repo});

  final FoodRepository repo;

  @override
  State<_FoodPickerSheet> createState() => _FoodPickerSheetState();
}

class _FoodPickerSheetState extends State<_FoodPickerSheet> {
  final _controller = TextEditingController();
  List<Food> _results = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() => _loading = true);
    final rows = await widget.repo.search(q, limit: 30);
    if (!mounted) return;
    setState(() {
      _results = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search a food',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final f = _results[i];
                return ListTile(
                  leading: FoodImage(food: f, width: 40, height: 40),
                  title: Text(f.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${f.calories.round()} kcal / 100 g'),
                  onTap: () => Navigator.of(context).pop(f),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
