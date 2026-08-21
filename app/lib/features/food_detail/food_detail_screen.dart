import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import '../../data/models/diary.dart';
import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../state/diary_controller.dart';
import '../../state/favorites_controller.dart';
import '../../widgets/food_image.dart';
import '../../widgets/food_tile.dart';
import '../../widgets/nutrition_widgets.dart';
import '../../widgets/portion_selector.dart';

class FoodDetailScreen extends StatefulWidget {
  const FoodDetailScreen({super.key, required this.foodId});

  final int foodId;

  @override
  State<FoodDetailScreen> createState() => _FoodDetailScreenState();
}

class _FoodDetailScreenState extends State<FoodDetailScreen> {
  late Future<_DetailData> _future;
  Portion? _portion;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DetailData> _load() async {
    final repo = context.read<FoodRepository>();
    final food = await repo.byId(widget.foodId);
    if (food == null) throw StateError('Food not found');
    final recipe = await repo.recipeFor(food.id);
    final alternatives = await repo.alternativesFor(food.id);
    if (mounted) {
      unawaited(context.read<FavoritesController>().recordView(food));
    }
    return _DetailData(food: food, recipe: recipe, alternatives: alternatives);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DetailData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text('${snapshot.error}')),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return _DetailBody(
          data: snapshot.requireData,
          portion: _portion,
          onPortionChanged: (p) => setState(() => _portion = p),
        );
      },
    );
  }
}

class _DetailData {
  const _DetailData({
    required this.food,
    required this.recipe,
    required this.alternatives,
  });

  final Food food;
  final Recipe? recipe;
  final List<FoodAlternative> alternatives;
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.data,
    required this.portion,
    required this.onPortionChanged,
  });

  final _DetailData data;
  final Portion? portion;
  final ValueChanged<Portion> onPortionChanged;

  @override
  Widget build(BuildContext context) {
    final food = data.food;
    final theme = Theme.of(context);
    final favorites = context.watch<FavoritesController>();
    final grams = portion?.grams ?? food.defaultServing.grams;
    final values = food.scaled(grams);
    final kcal = values[Nutrient.calories] ?? 0;

    return Scaffold(
      body: SafeArea(
        // Edge-to-edge: this screen is pushed full-screen, so
        // nothing else keeps its last row clear of the gesture
        // bar. The app bar already owns the top inset.
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: food.hasImage ? 240 : 100,
              pinned: true,
              actions: [
                IconButton(
                  tooltip: 'Compare',
                  icon: const Icon(Icons.compare_arrows),
                  onPressed: () =>
                      context.push('${Routes.compare}?a=${food.id}'),
                ),
                IconButton(
                  tooltip: favorites.isFavorite(food.id)
                      ? 'Remove from favourites'
                      : 'Save to favourites',
                  icon: Icon(favorites.isFavorite(food.id)
                      ? Icons.favorite
                      : Icons.favorite_border),
                  onPressed: () => favorites.toggle(food),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                title: Text(
                  food.name,
                  style: const TextStyle(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                background: food.hasImage
                    ? FoodImage(
                        food: food,
                        size: FoodImageSize.large,
                        borderRadius: 0,
                        heroTag: 'food-${food.id}',
                      )
                    : null,
              ),
            ),
            SliverList.list(children: [
              if (food.hasImage) ImageCreditLine(food: food),
              _Header(food: food),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Portion', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    PortionSelector(food: food, onChanged: onPortionChanged),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _CaloriesCard(kcal: kcal, values: values, grams: grams),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child:
                    Text('Full nutrition', style: theme.textTheme.titleMedium),
              ),
              NutritionTable(
                values: values,
                microsEstimated: food.microsEstimated,
              ),
              if (food.description.isNotEmpty) ...[
                const Divider(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('About', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(food.description, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
              if (data.recipe != null) _RecipeSection(recipe: data.recipe!),
              if (food.regionalNames.isNotEmpty) _RegionalNames(food: food),
              if (data.alternatives.isNotEmpty)
                _Alternatives(alternatives: data.alternatives),
              _SourceFooter(food: food),
              const SizedBox(height: 96),
            ]),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context, food, portion),
        icon: const Icon(Icons.add),
        label: Text('Add ${kcal.round()} kcal'),
      ),
    );
  }
}

Future<void> _showAddSheet(
    BuildContext context, Food food, Portion? portion) async {
  final diary = context.read<DiaryController>();
  final slot = MealSlot.forHour(DateTime.now().hour);
  final chosen = await showModalBottomSheet<(MealSlot, Portion)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _AddToDiarySheet(
      food: food,
      initialPortion: portion,
      initialSlot: slot,
    ),
  );
  if (chosen == null || !context.mounted) return;
  await diary.addFood(
    food,
    slot: chosen.$1,
    grams: chosen.$2.grams,
    servingLabel: chosen.$2.label,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('${food.name} added to ${chosen.$1.label.toLowerCase()}'),
      action: SnackBarAction(
        label: 'View diary',
        onPressed: () => context.go(Routes.diary),
      ),
    ),
  );
}

class _AddToDiarySheet extends StatefulWidget {
  const _AddToDiarySheet({
    required this.food,
    required this.initialPortion,
    required this.initialSlot,
  });

  final Food food;
  final Portion? initialPortion;
  final MealSlot initialSlot;

  @override
  State<_AddToDiarySheet> createState() => _AddToDiarySheetState();
}

class _AddToDiarySheetState extends State<_AddToDiarySheet> {
  late MealSlot _slot = widget.initialSlot;
  Portion? _portion;

  @override
  void initState() {
    super.initState();
    _portion = widget.initialPortion;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grams = _portion?.grams ?? widget.food.defaultServing.grams;
    final kcal = widget.food.valueFor(Nutrient.calories, grams) ?? 0;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.food.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          SegmentedButton<MealSlot>(
            segments: [
              for (final s in MealSlot.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_slot},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _slot = s.first),
          ),
          const SizedBox(height: 16),
          PortionSelector(
            food: widget.food,
            initial: _portion,
            onChanged: (p) => setState(() => _portion = p),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _portion == null
                ? null
                : () => Navigator.of(context).pop((_slot, _portion!)),
            icon: const Icon(Icons.check),
            label: Text('Add ${kcal.round()} kcal to ${_slot.label}'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.food});

  final Food food;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (food.hindiName.isNotEmpty)
            Text(food.hindiName, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                avatar: Icon(Icons.circle,
                    size: 12, color: AppTheme.dietColor(food.diet)),
                label: Text(switch (food.diet) {
                  'vegan' => 'Vegan',
                  'egg' => 'Contains egg',
                  'nonveg' => 'Non-vegetarian',
                  _ => 'Vegetarian',
                }),
              ),
              Chip(label: Text(food.categoryName)),
              if (food.region.isNotEmpty) Chip(label: Text(food.region)),
              if (food.isJain) const Chip(label: Text('Jain')),
              if (food.isRecipe) const Chip(label: Text('Recipe')),
              if (food.brand.isNotEmpty) Chip(label: Text(food.brand)),
              if (food.barcode.isNotEmpty)
                Chip(
                  avatar: const Icon(Icons.qr_code, size: 14),
                  label: Text(food.barcode),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CaloriesCard extends StatelessWidget {
  const _CaloriesCard({
    required this.kcal,
    required this.values,
    required this.grams,
  });

  final double kcal;
  final Map<Nutrient, double?> values;
  final double grams;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  kcal.round().toString(),
                  style: theme.textTheme.displaySmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('kcal per ${grams.round()} g',
                      style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
            const SizedBox(height: 12),
            MacroBar(
              protein: values[Nutrient.protein] ?? 0,
              carbs: values[Nutrient.carbs] ?? 0,
              fat: values[Nutrient.fat] ?? 0,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeSection extends StatelessWidget {
  const _RecipeSection({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Recipe', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (recipe.totalMinutes > 0)
                Text('${recipe.totalMinutes} min total',
                    style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 12),
          if (recipe.ingredients.isNotEmpty) ...[
            Text('Ingredients', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final ing in recipe.ingredients)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(
                        child: Text(ing, style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
          ],
          if (recipe.steps.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Method', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            for (var i = 0; i < recipe.steps.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 11,
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 11)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(recipe.steps[i],
                          style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RegionalNames extends StatelessWidget {
  const _RegionalNames({required this.food});

  final Food food;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Also called', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in food.regionalNames.entries)
                Chip(
                  label: Text('${entry.value}  ·  ${entry.key}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Alternatives extends StatelessWidget {
  const _Alternatives({required this.alternatives});

  final List<FoodAlternative> alternatives;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text('Lighter swaps', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Similar kind of dish, fewer calories for the same 100 g.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final alt in alternatives)
          FoodTile(
            food: alt.food,
            showFavorite: false,
            trailing: Text(
              '${alt.kcalDelta.round()}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }
}

class _SourceFooter extends StatelessWidget {
  const _SourceFooter({required this.food});

  final Food food;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Data source', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            food.source.isEmpty ? 'Compiled nutrition tables' : food.source,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (food.sourceUrl.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => launchUrl(Uri.parse(food.sourceUrl),
                  mode: LaunchMode.externalApplication),
              child: const Text('Open source'),
            ),
          const SizedBox(height: 8),
          Text(
            'Values are per 100 g of the cooked dish and vary with how it is '
            'made at home. Use them as a good estimate, not a lab result.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
