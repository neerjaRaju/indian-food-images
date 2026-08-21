import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/router.dart';
import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../data/services/ads_service.dart';
import '../../data/services/database_update_service.dart';
import '../../state/diary_controller.dart';
import '../../widgets/food_tile.dart';
import '../../widgets/nutrition_widgets.dart';
import '../../widgets/premium_gate.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_HomeData> _load() async {
    final repo = context.read<FoodRepository>();
    final results = await Future.wait([
      repo.popular(limit: 12),
      repo.highProtein(limit: 12),
      repo.lowCalorie(limit: 12),
      repo.categories(kind: 'cuisine'),
    ]);
    return _HomeData(
      popular: results[0] as List<Food>,
      highProtein: results[1] as List<Food>,
      lowCalorie: results[2] as List<Food>,
      categories: results[3] as List<FoodCategory>,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diary = context.watch<DiaryController>();
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            setState(() => _future = _load());
            await diary.load();
          },
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                title: const Text('Indian Food Calories'),
                actions: [
                  IconButton(
                    tooltip: 'Scan barcode',
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: () => context.push(Routes.scan),
                  ),
                  IconButton(
                    tooltip: 'Favourites',
                    icon: const Icon(Icons.favorite_border),
                    onPressed: () => context.push(Routes.favorites),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: _SearchLauncher(),
                ),
              ),
              const SliverToBoxAdapter(child: _UpdateBanner()),
              SliverToBoxAdapter(
                child: _TodayCard(),
              ),
              SliverToBoxAdapter(
                child: _QuickActions(),
              ),
              FutureBuilder<_HomeData>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Could not load foods: ${snapshot.error}',
                            style: theme.textTheme.bodySmall),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    );
                  }
                  final data = snapshot.requireData;
                  return SliverList.list(
                    children: [
                      _Recommendations(data: data),
                      _CategoryStrip(categories: data.categories),
                      _FoodCarousel(
                          title: 'Everyday favourites', foods: data.popular),
                      _FoodCarousel(
                          title: 'High protein', foods: data.highProtein),
                      _FoodCarousel(
                          title: 'Light on calories', foods: data.lowCalorie),
                      const SizedBox(height: 24),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeData {
  const _HomeData({
    required this.popular,
    required this.highProtein,
    required this.lowCalorie,
    required this.categories,
  });

  final List<Food> popular;
  final List<Food> highProtein;
  final List<Food> lowCalorie;
  final List<FoodCategory> categories;
}

/// "Recommended for you" — foods that still fit inside today's remaining
/// calorie budget, richest in protein first.
///
/// Deliberately built from the carousels the screen has already loaded rather
/// than a new query: the value here is the ranking against the user's own
/// diary, and a second round trip would delay first paint for it.
class _Recommendations extends StatelessWidget {
  const _Recommendations({required this.data});

  final _HomeData data;

  /// Below this there is no meaningful budget left to fill, and every
  /// suggestion would be a rounding error.
  static const _minimumBudget = 120.0;

  List<Food> _pick(double budget) {
    final seen = <int>{};
    final candidates = <Food>[];
    for (final food in [
      ...data.highProtein,
      ...data.lowCalorie,
      ...data.popular
    ]) {
      if (food.calories <= 0 || food.calories > budget) continue;
      if (!seen.add(food.id)) continue;
      candidates.add(food);
    }
    // Protein per calorie: what actually makes one of two foods that both fit
    // the budget the better choice.
    candidates.sort(
        (a, b) => (b.protein / b.calories).compareTo(a.protein / a.calories));
    return candidates.take(12).toList();
  }

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final budget = diary.caloriesRemaining;
    if (budget < _minimumBudget) return const SizedBox.shrink();
    final picks = _pick(budget);
    if (picks.isEmpty) return const SizedBox.shrink();
    return PremiumGate(
      feature: PremiumFeature.smartRecommendations,
      compact: true,
      icon: Icons.auto_awesome_outlined,
      description: 'Watch one short ad to see which foods fit the '
          '${budget.round()} kcal you have left today, ranked by protein. '
          'Unlocks for ${formatRemaining(PremiumFeature.smartRecommendations.duration)}.',
      child: _FoodCarousel(
        title: 'Fits your remaining ${budget.round()} kcal',
        foods: picks,
      ),
    );
  }
}

class _SearchLauncher extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.go(Routes.search),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(
              'Search roti, दाल, biryani…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final totals = diary.totals;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.go(Routes.diary),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CalorieRing(
                consumed: totals.calories,
                goal: diary.calorieGoal,
                size: 108,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Today', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    MacroBar(
                      protein: totals.protein,
                      carbs: totals.carbs,
                      fat: totals.fat,
                      showLegend: false,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'P ${totals.protein.round()} g · '
                      'C ${totals.carbs.round()} g · '
                      'F ${totals.fat.round()} g',
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.water_drop_outlined,
                            size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('${diary.waterMl} / ${diary.waterGoalMl} ml',
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  static const _actions = <(IconData, String, String)>[
    (Icons.qr_code_scanner, 'Scan', Routes.scan),
    (Icons.restaurant_menu, 'Planner', Routes.planner),
    (Icons.water_drop_outlined, 'Water', Routes.water),
    (Icons.monitor_weight_outlined, 'Weight', Routes.weight),
    (Icons.compare_arrows, 'Compare', Routes.compare),
    (Icons.insights_outlined, 'Reports', Routes.reports),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        itemCount: _actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final (icon, label, route) = _actions[i];
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => context.push(route),
            child: Container(
              width: 76,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22),
                  const SizedBox(height: 6),
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({required this.categories});

  final List<FoodCategory> categories;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Browse by cuisine'),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final c = categories[i];
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => context.push(Routes.categoryPath(c.id, c.name)),
                child: Container(
                  width: 108,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(c.icon, style: const TextStyle(fontSize: 22)),
                      Text(
                        c.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      Text('${c.foodCount}',
                          style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FoodCarousel extends StatelessWidget {
  const _FoodCarousel({required this.title, required this.foods});

  final String title;
  final List<Food> foods;

  @override
  Widget build(BuildContext context) {
    if (foods.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: foods.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => FoodCard(food: foods[i]),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<DatabaseUpdateService>();
    final info = updates.available;
    if (info == null && updates.stage != UpdateStage.staged) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    if (updates.stage == UpdateStage.staged) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Card(
          color: theme.colorScheme.primaryContainer,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'New food data downloaded. It will be in place next time '
                    'you open the app.',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.cloud_download_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Updated food database available',
                        style: theme.textTheme.titleSmall),
                    Text(
                      '${info!.foodCount} foods · ${info.sizeMb.toStringAsFixed(1)} MB',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              if (updates.busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: updates.download,
                  child: const Text('Update'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
