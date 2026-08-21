import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/services/ads_service.dart';
import '../state/premium_controller.dart';

/// Wraps a premium feature. When locked it shows an explanation and a single
/// "Watch a short ad" button; when unlocked it shows [child] plus a small
/// countdown so the user knows what they have and for how long.
class PremiumGate extends StatelessWidget {
  const PremiumGate({
    super.key,
    required this.feature,
    required this.child,
    this.description,
    this.icon = Icons.workspace_premium_outlined,
    this.compact = false,
  });

  final PremiumFeature feature;
  final Widget child;
  final String? description;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumController>();
    if (premium.isUnlocked(feature)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) _UnlockedBanner(feature: feature),
          child,
        ],
      );
    }
    return _LockedCard(
      feature: feature,
      description: description,
      icon: icon,
      compact: compact,
    );
  }
}

class _UnlockedBanner extends StatelessWidget {
  const _UnlockedBanner({required this.feature});

  final PremiumFeature feature;

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumController>();
    final left = premium.remainingFor(feature);
    if (left == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_open,
              size: 16, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${feature.label} unlocked — ${formatRemaining(left)} left',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockedCard extends StatefulWidget {
  const _LockedCard({
    required this.feature,
    required this.description,
    required this.icon,
    required this.compact,
  });

  final PremiumFeature feature;
  final String? description;
  final IconData icon;
  final bool compact;

  @override
  State<_LockedCard> createState() => _LockedCardState();
}

class _LockedCardState extends State<_LockedCard> {
  bool _working = false;

  Future<void> _unlock() async {
    setState(() => _working = true);
    final premium = context.read<PremiumController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await premium.unlock(widget.feature);
    if (!mounted) return;
    setState(() => _working = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? '${widget.feature.label} unlocked for '
                '${formatRemaining(widget.feature.duration)}'
            : 'No reward earned. The ad has to finish to unlock this.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = context.watch<PremiumController>().rewardedReady;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(widget.feature.label,
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.description ??
                  'Watch one short ad to use this for '
                      '${formatRemaining(widget.feature.duration)}. '
                      'No subscription, no account.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _working ? null : _unlock,
              icon: _working
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline),
              label: Text(_working
                  ? 'Loading ad…'
                  : ready
                      ? 'Watch a short ad to unlock'
                      : 'Preparing ad…'),
            ),
          ],
        ),
      ),
    );
  }
}

String formatRemaining(Duration d) {
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
  if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
  if (d.inMinutes >= 1) return '${d.inMinutes} min';
  return 'a few seconds';
}
