import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/favorites_controller.dart';
import '../../widgets/food_tile.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesController>();
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Saved'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Favourites'),
              Tab(text: 'Recently viewed'),
            ],
          ),
        ),
        body: SafeArea(
          // Edge-to-edge: this screen is pushed full-screen, so
          // nothing else keeps its last row clear of the gesture
          // bar. The app bar already owns the top inset.
          top: false,
          child: favorites.loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    if (favorites.favorites.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'Tap the heart on any food to keep it here for quick '
                            'logging.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      )
                    else
                      ListView.separated(
                        itemCount: favorites.favorites.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 84),
                        itemBuilder: (_, i) =>
                            FoodTile(food: favorites.favorites[i]),
                      ),
                    if (favorites.recentlyViewed.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text('Foods you open will show up here.',
                              style: theme.textTheme.bodyMedium),
                        ),
                      )
                    else
                      ListView.separated(
                        itemCount: favorites.recentlyViewed.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 84),
                        itemBuilder: (_, i) =>
                            FoodTile(food: favorites.recentlyViewed[i]),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
