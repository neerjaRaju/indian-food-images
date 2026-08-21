import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/router.dart';
import '../../data/services/ads_service.dart';
import '../../state/premium_controller.dart';
import '../../widgets/premium_gate.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumController>();
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('More', style: theme.textTheme.headlineSmall),
            ),
            ListTile(
              leading: const Icon(Icons.favorite_border),
              title: const Text('Favourites & history'),
              onTap: () => context.push(Routes.favorites),
            ),
            ListTile(
              leading: const Icon(Icons.restaurant_menu),
              title: const Text('Meal planner'),
              onTap: () => context.push(Routes.planner),
            ),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('Nutrition reports'),
              onTap: () => context.push(Routes.reports),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () => context.push(Routes.settings),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About & data sources'),
              onTap: () => context.push(Routes.about),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child:
                  Text('Unlocked features', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Everything here is unlocked by watching one short ad. There is '
                'no subscription and no account.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            for (final feature in PremiumFeature.values)
              _FeatureRow(feature: feature, premium: premium),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.feature, required this.premium});

  final PremiumFeature feature;
  final PremiumController premium;

  @override
  Widget build(BuildContext context) {
    final unlocked = premium.isUnlocked(feature);
    final left = premium.remainingFor(feature);
    return ListTile(
      leading: Icon(unlocked ? Icons.lock_open : Icons.lock_outline),
      title: Text(feature.label),
      subtitle: Text(unlocked && left != null
          ? '${formatRemaining(left)} left'
          : 'Unlocks for ${formatRemaining(feature.duration)}'),
      trailing: unlocked
          ? null
          : TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final ok = await premium.unlock(feature);
                messenger.showSnackBar(SnackBar(
                  content: Text(ok
                      ? '${feature.label} unlocked'
                      : 'No reward earned — the ad has to finish.'),
                ));
              },
              child: const Text('Watch ad'),
            ),
    );
  }
}
