import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'data/db/food_database.dart';
import 'data/db/user_database.dart';
import 'data/repositories/food_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/ads_service.dart';
import 'data/services/database_update_service.dart';
import 'data/services/image_hosting_service.dart';
import 'data/services/preferences_service.dart';
import 'features/startup/startup_screen.dart';
import 'state/diary_controller.dart';
import 'state/favorites_controller.dart';
import 'state/premium_controller.dart';
import 'state/search_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Draw behind the status and navigation bars. Android 15 enforces this for
  // anything targeting API 35+, so opting in explicitly is what makes the
  // result look the same on older versions instead of only on the newest.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final prefs = await PreferencesService.create();
  runApp(IndianFoodApp(prefs: prefs));
}

class IndianFoodApp extends StatelessWidget {
  const IndianFoodApp({super.key, required this.prefs});

  final PreferencesService prefs;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<PreferencesService>.value(
      value: prefs,
      child: Consumer<PreferencesService>(
        builder: (context, prefs, _) => MaterialApp(
          title: 'Indian Food Calories',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: prefs.themeMode,
          builder: _systemBars,
          home: const AppBootstrap(),
        ),
      ),
    );
  }
}

/// Opens both databases, wires the object graph, then hands off to the router.
///
/// Everything below this widget can assume the databases are open, which keeps
/// null checks out of every repository call.
class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  late final Future<_AppServices> _future = _boot();

  Future<_AppServices> _boot() async {
    final prefs = context.read<PreferencesService>();
    await ImageHostingService.load();
    await Future.wait([
      FoodDatabase.instance.open(),
      UserDatabase.instance.open(),
    ]);
    final foods = FoodRepository(FoodDatabase.instance);
    final users = UserRepository(UserDatabase.instance);
    final ads = AdsService();
    // Ads must never block first paint — initialise in the background.
    unawaited(ads.initialise());
    final premium = PremiumController(users, ads);
    await premium.load();
    return _AppServices(
      foods: foods,
      users: users,
      ads: ads,
      premium: premium,
      updates: DatabaseUpdateService(prefs),
      prefs: prefs,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AppServices>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return StartupErrorScreen(error: '${snapshot.error}');
        }
        if (!snapshot.hasData) {
          return const StartupSplash();
        }
        final services = snapshot.requireData;
        return MultiProvider(
          providers: [
            Provider<FoodRepository>.value(value: services.foods),
            Provider<UserRepository>.value(value: services.users),
            Provider<AdsService>.value(value: services.ads),
            ChangeNotifierProvider<PremiumController>.value(
                value: services.premium),
            ChangeNotifierProvider<DatabaseUpdateService>.value(
                value: services.updates),
            ChangeNotifierProvider<FoodSearchController>(
              create: (_) =>
                  FoodSearchController(services.foods, services.users)..init(),
            ),
            ChangeNotifierProvider<DiaryController>(
              create: (_) => DiaryController(
                  services.users, services.foods, services.prefs)
                ..load(),
            ),
            ChangeNotifierProvider<FavoritesController>(
              create: (_) =>
                  FavoritesController(services.users, services.foods)..load(),
            ),
          ],
          child: const _RoutedApp(),
        );
      },
    );
  }
}

class _RoutedApp extends StatefulWidget {
  const _RoutedApp();

  @override
  State<_RoutedApp> createState() => _RoutedAppState();
}

class _RoutedAppState extends State<_RoutedApp> {
  late final router = createRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Background update check — silent, and never blocks the UI.
      context.read<DatabaseUpdateService>().checkIfDue();
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    return MaterialApp.router(
      title: 'Indian Food Calories',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: prefs.themeMode,
      builder: _systemBars,
      routerConfig: router,
    );
  }
}

/// Publishes the transparent system-bar style for screens that have no
/// [AppBar] to publish one of their own.
///
/// This sits inside [MaterialApp] so `Theme.of` has already resolved
/// themeMode against the platform brightness — reading the preference
/// directly would get "system" wrong half the time.
Widget _systemBars(BuildContext context, Widget? child) {
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: AppTheme.systemBarsFor(Theme.of(context).brightness),
    child: child ?? const SizedBox.shrink(),
  );
}

class _AppServices {
  const _AppServices({
    required this.foods,
    required this.users,
    required this.ads,
    required this.premium,
    required this.updates,
    required this.prefs,
  });

  final FoodRepository foods;
  final UserRepository users;
  final AdsService ads;
  final PremiumController premium;
  final DatabaseUpdateService updates;
  final PreferencesService prefs;
}
