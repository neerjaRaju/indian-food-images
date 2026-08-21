import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../data/models/food.dart';
import '../state/favorites_controller.dart';
import 'food_image.dart';

/// The row used everywhere a food appears in a list.
class FoodTile extends StatelessWidget {
  const FoodTile({
    super.key,
    required this.food,
    this.onTap,
    this.trailing,
    this.showFavorite = true,
    this.dense = false,
  });

  final Food food;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showFavorite;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favorites = context.watch<FavoritesController>();
    final serving = food.servings.isEmpty ? null : food.defaultServing;
    final servingKcal = serving == null
        ? null
        : food.valueFor(Nutrient.calories, serving.grams);

    return InkWell(
      onTap: onTap ?? () => context.push(Routes.foodPath(food.id)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 6 : 10),
        child: Row(
          children: [
            FoodImage(
              food: food,
              width: dense ? 44 : 56,
              height: dense ? 44 : 56,
              heroTag: 'food-${food.id}',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _DietDot(diet: food.diet),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          food.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    food.displaySubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 10,
                    children: [
                      _Metric(
                          label: '${food.calories.round()} kcal', bold: true),
                      _Metric(label: 'P ${food.protein.toStringAsFixed(1)}'),
                      _Metric(label: 'C ${food.carbs.toStringAsFixed(1)}'),
                      _Metric(label: 'F ${food.fat.toStringAsFixed(1)}'),
                    ],
                  ),
                  if (serving != null && servingKcal != null && !dense)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${serving.label} · ${servingKcal.round()} kcal',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (trailing == null && showFavorite)
              IconButton(
                tooltip: favorites.isFavorite(food.id)
                    ? 'Remove from favourites'
                    : 'Add to favourites',
                icon: Icon(
                  favorites.isFavorite(food.id)
                      ? Icons.favorite
                      : Icons.favorite_border,
                  size: 20,
                ),
                onPressed: () => favorites.toggle(food),
              ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, this.bold = false});

  final String label;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        color: bold
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The green/brown square Indian packaging uses to mark veg and non-veg.
class _DietDot extends StatelessWidget {
  const _DietDot({required this.diet});

  final String diet;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.dietColor(diet);
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.4),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// Compact card used in horizontal carousels on the home screen.
class FoodCard extends StatelessWidget {
  const FoodCard({super.key, required this.food, this.width = 148});

  final Food food;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(Routes.foodPath(food.id)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FoodImage(
                food: food,
                size: FoodImageSize.medium,
                width: width,
                height: 96,
                borderRadius: 0,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      food.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${food.calories.round()} kcal / 100 g',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
