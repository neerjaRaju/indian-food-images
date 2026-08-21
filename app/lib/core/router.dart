import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/compare/compare_screen.dart';
import '../features/diary/diary_screen.dart';
import '../features/favorites/favorites_screen.dart';
import '../features/food_detail/food_detail_screen.dart';
import '../features/home/home_screen.dart';
import '../features/more/about_screen.dart';
import '../features/more/more_screen.dart';
import '../features/more/settings_screen.dart';
import '../features/planner/meal_planner_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/scan/barcode_scan_screen.dart';
import '../features/search/category_screen.dart';
import '../features/search/search_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/tools/calculators_screen.dart';
import '../features/tools/tools_screen.dart';
import '../features/tools/weight_planner_screen.dart';
import '../features/trackers/water_screen.dart';
import '../features/trackers/weight_screen.dart';

/// Route names kept in one place so no screen hard-codes a path string.
class Routes {
  const Routes._();

  static const home = '/';
  static const search = '/search';
  static const diary = '/diary';
  static const tools = '/tools';
  static const more = '/more';

  static const food = '/food';
  static const category = '/category';
  static const scan = '/scan';
  static const compare = '/compare';
  static const planner = '/planner';
  static const water = '/water';
  static const weight = '/weight';
  static const reports = '/reports';
  static const favorites = '/favorites';
  static const settings = '/settings';
  static const about = '/about';
  static const calculators = '/calculators';
  static const weightPlanner = '/weight-planner';

  static String foodPath(int id) => '$food/$id';
  static String categoryPath(int id, String name) =>
      '$category/$id?name=${Uri.encodeComponent(name)}';
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _shellKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

GoRouter createRouter({String initialLocation = Routes.home}) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: Routes.home,
            pageBuilder: (_, state) =>
                const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: Routes.search,
            pageBuilder: (_, state) => NoTransitionPage(
              child: SearchScreen(
                initialQuery: state.uri.queryParameters['q'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: Routes.diary,
            pageBuilder: (_, __) =>
                const NoTransitionPage(child: DiaryScreen()),
          ),
          GoRoute(
            path: Routes.tools,
            pageBuilder: (_, __) =>
                const NoTransitionPage(child: ToolsScreen()),
          ),
          GoRoute(
            path: Routes.more,
            pageBuilder: (_, __) => const NoTransitionPage(child: MoreScreen()),
          ),
        ],
      ),
      GoRoute(
        path: '${Routes.food}/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => FoodDetailScreen(
          foodId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '${Routes.category}/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => CategoryScreen(
          categoryId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          categoryName: state.uri.queryParameters['name'] ?? 'Category',
        ),
      ),
      GoRoute(
        path: Routes.scan,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const BarcodeScanScreen(),
      ),
      GoRoute(
        path: Routes.compare,
        parentNavigatorKey: _rootKey,
        builder: (_, state) => CompareScreen(
          initialFoodId: int.tryParse(state.uri.queryParameters['a'] ?? ''),
        ),
      ),
      GoRoute(
        path: Routes.planner,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const MealPlannerScreen(),
      ),
      GoRoute(
        path: Routes.water,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const WaterScreen(),
      ),
      GoRoute(
        path: Routes.weight,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const WeightScreen(),
      ),
      GoRoute(
        path: Routes.reports,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const ReportsScreen(),
      ),
      GoRoute(
        path: Routes.favorites,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const FavoritesScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.about,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const AboutScreen(),
      ),
      GoRoute(
        path: Routes.calculators,
        parentNavigatorKey: _rootKey,
        builder: (_, state) => CalculatorsScreen(
          initialTab: int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: Routes.weightPlanner,
        parentNavigatorKey: _rootKey,
        builder: (_, state) => WeightPlannerScreen(
          mode: state.uri.queryParameters['mode'] ?? 'lose',
        ),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('No screen for ${state.uri}', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(Routes.home),
                child: const Text('Go home'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
