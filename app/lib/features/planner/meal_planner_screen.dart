import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/router.dart';
import '../../data/models/diary.dart';
import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/ads_service.dart';
import '../../data/services/preferences_service.dart';
import '../../state/premium_controller.dart';
import '../../widgets/premium_gate.dart';

/// Free tier keeps one saved plan; a rewarded ad lifts the cap for a week.
const kFreePlanLimit = 1;

class MealPlannerScreen extends StatefulWidget {
  const MealPlannerScreen({super.key});

  @override
  State<MealPlannerScreen> createState() => _MealPlannerScreenState();
}

class _MealPlannerScreenState extends State<MealPlannerScreen> {
  late Future<List<MealPlan>> _future = _load();
  bool _generating = false;

  Future<List<MealPlan>> _load() => context.read<UserRepository>().plans();

  Future<void> _generate() async {
    final users = context.read<UserRepository>();
    final foods = context.read<FoodRepository>();
    final prefs = context.read<PreferencesService>();
    final premium = context.read<PremiumController>();
    final messenger = ScaffoldMessenger.of(context);

    final existing = await users.planCount();
    if (existing >= kFreePlanLimit &&
        !premium.isUnlocked(PremiumFeature.unlimitedMealPlans)) {
      messenger.showSnackBar(const SnackBar(
        content:
            Text('Free plan limit reached — unlock unlimited plans below.'),
      ));
      return;
    }

    setState(() => _generating = true);
    final target = prefs.calorieGoal;
    final planId = await users.createPlan(
      'Week of ${DateTime.now().day}/${DateTime.now().month}',
      target,
    );
    final meals = await _buildWeek(foods, planId, target, prefs);
    await users.addPlannedMeals(meals);
    if (!mounted) return;
    setState(() {
      _generating = false;
      _future = _load();
    });
  }

  /// Builds a week by drawing from calorie-appropriate pools per slot.
  ///
  /// The split (25 % breakfast, 35 % lunch, 15 % snack, 25 % dinner) matches
  /// how Indian households actually eat — lunch is the biggest meal.
  Future<List<PlannedMeal>> _buildWeek(
    FoodRepository foods,
    int planId,
    int target,
    PreferencesService prefs,
  ) async {
    const shares = {
      MealSlot.breakfast: 0.25,
      MealSlot.lunch: 0.35,
      MealSlot.snack: 0.15,
      MealSlot.dinner: 0.25,
    };
    final vegOnly = prefs.goal != GoalType.gain;
    final pools = <MealSlot, List<Food>>{};
    for (final slot in MealSlot.values) {
      final tag = switch (slot) {
        MealSlot.breakfast => 'breakfast',
        MealSlot.lunch => 'everyday',
        MealSlot.snack => 'snack',
        MealSlot.dinner => 'everyday',
      };
      final rows = await foods.search(
        tag,
        filter: FoodFilter(
          foodType: 'food',
          diet: vegOnly ? null : null,
          sort: FoodSort.relevance,
        ),
        limit: 40,
      );
      pools[slot] = rows.isEmpty ? await foods.popular(limit: 20) : rows;
    }

    final rng = Random(planId);
    final meals = <PlannedMeal>[];
    for (var day = 0; day < 7; day++) {
      for (final slot in MealSlot.values) {
        final pool = pools[slot]!;
        if (pool.isEmpty) continue;
        final food = pool[rng.nextInt(pool.length)];
        final slotKcal = target * shares[slot]!;
        final per100 = food.calories <= 0 ? 100 : food.calories;
        // Round the portion to a sane 10 g step rather than 137.4 g.
        final grams = ((slotKcal / per100 * 100) / 10).round() * 10.0;
        meals.add(PlannedMeal(
          id: 0,
          planId: planId,
          dayIndex: day,
          slot: slot,
          foodId: food.id,
          foodName: food.name,
          grams: grams.clamp(30, 600),
          calories: per100 * grams / 100,
        ));
      }
    }
    return meals;
  }

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Meal planner')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generating ? null : _generate,
        icon: _generating
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_awesome),
        label: Text(_generating ? 'Building…' : 'Generate week'),
      ),
      body: SafeArea(
        // Edge-to-edge: this screen is pushed full-screen, so
        // nothing else keeps its last row clear of the gesture
        // bar. The app bar already owns the top inset.
        top: false,
        child: FutureBuilder<List<MealPlan>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final plans = snapshot.requireData;
            return ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                if (plans.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                      'Generate a week of meals built around your calorie goal. '
                      'Every meal links back to the food, so you can swap '
                      'portions or log it straight to your diary.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final plan in plans)
                  _PlanCard(
                      plan: plan,
                      onChanged: () {
                        setState(() => _future = _load());
                      }),
                if (!premium.isUnlocked(PremiumFeature.unlimitedMealPlans))
                  const PremiumGate(
                    feature: PremiumFeature.unlimitedMealPlans,
                    description:
                        'Keep more than one saved plan for a week, so you can '
                        'build a rotation instead of overwriting.',
                    child: SizedBox.shrink(),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.onChanged});

  final MealPlan plan;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byDay = <int, List<PlannedMeal>>{};
    for (final m in plan.meals) {
      byDay.putIfAbsent(m.dayIndex, () => []).add(m);
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(plan.name, style: theme.textTheme.titleMedium),
                ),
                Text('${plan.targetCalories} kcal/day',
                    style: theme.textTheme.labelMedium),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await context.read<UserRepository>().deletePlan(plan.id);
                    onChanged();
                  },
                ),
              ],
            ),
            for (var day = 0; day < 7; day++)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(_dayName(day)),
                subtitle: Text(
                  '${(byDay[day] ?? []).fold<double>(0, (s, m) => s + m.calories).round()} kcal',
                  style: theme.textTheme.labelSmall,
                ),
                children: [
                  for (final meal in byDay[day] ?? <PlannedMeal>[])
                    ListTile(
                      dense: true,
                      leading: Text(meal.slot.emoji),
                      title: Text(meal.foodName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${meal.grams.round()} g'),
                      trailing: Text('${meal.calories.round()} kcal'),
                      onTap: () => context.push(Routes.foodPath(meal.foodId)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _dayName(int index) => const [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ][index % 7];
}
