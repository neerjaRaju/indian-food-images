import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/router.dart';
import '../../data/models/diary.dart';
import '../../state/diary_controller.dart';
import '../../widgets/food_tile.dart';
import '../../widgets/nutrition_widgets.dart';

class DiaryScreen extends StatelessWidget {
  const DiaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: diary.load,
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                title: const Text('Diary'),
                actions: [
                  IconButton(
                    tooltip: 'Reports',
                    icon: const Icon(Icons.insights_outlined),
                    onPressed: () => context.push(Routes.reports),
                  ),
                ],
              ),
              const SliverToBoxAdapter(child: _DateBar()),
              const SliverToBoxAdapter(child: _SummaryCard()),
              const SliverToBoxAdapter(child: _WaterRow()),
              for (final slot in MealSlot.values)
                SliverToBoxAdapter(child: _MealSection(slot: slot)),
              const SliverToBoxAdapter(child: _QuickAddSection()),
              const SliverToBoxAdapter(child: SizedBox(height: 90)),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.search),
        icon: const Icon(Icons.add),
        label: const Text('Add food'),
      ),
    );
  }
}

class _DateBar extends StatelessWidget {
  const _DateBar();

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final label =
        diary.isToday ? 'Today' : DateFormat('EEE, d MMM').format(diary.date);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => diary.shiftDay(-1),
          ),
          TextButton.icon(
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(label),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: diary.date,
                firstDate: DateTime.now().subtract(const Duration(days: 730)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) unawaited(diary.setDate(picked));
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: diary.isToday ? null : () => diary.shiftDay(1),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard();

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final totals = diary.totals;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CalorieRing(consumed: totals.calories, goal: diary.calorieGoal),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${totals.entries} items logged',
                      style: theme.textTheme.labelMedium),
                  const SizedBox(height: 10),
                  MacroBar(
                    protein: totals.protein,
                    carbs: totals.carbs,
                    fat: totals.fat,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaterRow extends StatelessWidget {
  const _WaterRow();

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            const Icon(Icons.water_drop_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${diary.waterMl} / ${diary.waterGoalMl} ml',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: diary.waterGoalMl == 0
                          ? 0
                          : (diary.waterMl / diary.waterGoalMl).clamp(0.0, 1.0),
                      minHeight: 5,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Add 250 ml',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => diary.addWater(250),
            ),
            IconButton(
              tooltip: 'Water tracker',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => context.push(Routes.water),
            ),
          ],
        ),
      ),
    );
  }
}

class _MealSection extends StatelessWidget {
  const _MealSection({required this.slot});

  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    final entries = diary.bySlot[slot] ?? const <DiaryEntry>[];
    final kcal = entries.fold<double>(0, (sum, e) => sum + e.calories);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Row(
            children: [
              Text('${slot.emoji}  ${slot.label}',
                  style: theme.textTheme.titleMedium),
              const Spacer(),
              Text('${kcal.round()} kcal', style: theme.textTheme.labelLarge),
            ],
          ),
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'Nothing logged yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final entry in entries)
            Dismissible(
              key: ValueKey('diary-${entry.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: theme.colorScheme.errorContainer,
                child: const Icon(Icons.delete_outline),
              ),
              onDismissed: (_) async {
                await diary.remove(entry);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${entry.foodName} removed'),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () => diary.undoRemove(entry),
                    ),
                  ),
                );
              },
              child: ListTile(
                onTap: () => context.push(Routes.foodPath(entry.foodId)),
                title: Text(entry.foodName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle:
                    Text('${entry.servingLabel} · ${entry.grams.round()} g'),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${entry.calories.round()} kcal',
                        style: theme.textTheme.labelLarge),
                    Text(
                      'P${entry.protein.round()} C${entry.carbs.round()} F${entry.fat.round()}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _QuickAddSection extends StatelessWidget {
  const _QuickAddSection();

  @override
  Widget build(BuildContext context) {
    final diary = context.watch<DiaryController>();
    if (diary.quickAdd.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text('Quick add', style: theme.textTheme.titleMedium),
        ),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: diary.quickAdd.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => FoodCard(food: diary.quickAdd[i]),
          ),
        ),
      ],
    );
  }
}
