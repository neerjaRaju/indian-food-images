import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../widgets/ad_banner.dart';

/// Bottom-navigation shell. The banner ad lives here so it survives tab
/// switches instead of reloading (and re-billing an impression) each time.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const _destinations = <_Destination>[
    _Destination(Routes.home, Icons.home_outlined, Icons.home, 'Home'),
    _Destination(Routes.search, Icons.search_outlined, Icons.search, 'Search'),
    _Destination(Routes.diary, Icons.book_outlined, Icons.book, 'Diary'),
    _Destination(
        Routes.tools, Icons.calculate_outlined, Icons.calculate, 'Tools'),
    _Destination(Routes.more, Icons.more_horiz, Icons.more_horiz, 'More'),
  ];

  int get _index {
    final i = _destinations.indexWhere((d) => d.path == location);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AdaptiveAdBanner(),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => context.go(_destinations[i].path),
            destinations: [
              for (final d in _destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: d.label,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination(this.path, this.icon, this.selectedIcon, this.label);

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
