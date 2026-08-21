import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db/food_database.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/ads_service.dart';
import '../../data/services/database_update_service.dart';
import '../../data/services/image_hosting_service.dart';
import '../../data/services/preferences_service.dart';
import '../../state/premium_controller.dart';
import '../../widgets/food_image.dart';
import '../../widgets/premium_gate.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    final updates = context.watch<DatabaseUpdateService>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        // Edge-to-edge: this screen is pushed full-screen, so
        // nothing else keeps its last row clear of the gesture
        // bar. The app bar already owns the top inset.
        top: false,
        child: ListView(
          children: [
            const _Header('Appearance'),
            RadioGroup<ThemeMode>(
              groupValue: prefs.themeMode,
              onChanged: (m) {
                if (m != null) prefs.setThemeMode(m);
              },
              child: const Column(
                children: [
                  RadioListTile<ThemeMode>(
                      value: ThemeMode.system, title: Text('Follow system')),
                  RadioListTile<ThemeMode>(
                      value: ThemeMode.light, title: Text('Light')),
                  RadioListTile<ThemeMode>(
                      value: ThemeMode.dark, title: Text('Dark')),
                ],
              ),
            ),
            const Divider(),
            const _Header('Profile'),
            ListTile(
              title: const Text('Sex'),
              trailing: SegmentedButton<Sex>(
                segments: const [
                  ButtonSegment(value: Sex.male, label: Text('M')),
                  ButtonSegment(value: Sex.female, label: Text('F')),
                ],
                selected: {prefs.sex},
                showSelectedIcon: false,
                onSelectionChanged: (s) => prefs.saveProfile(sex: s.first),
              ),
            ),
            _NumberTile(
              title: 'Age',
              value: prefs.age.toDouble(),
              suffix: 'years',
              min: 12,
              max: 100,
              onChanged: (v) => prefs.saveProfile(age: v.round()),
            ),
            _NumberTile(
              title: 'Height',
              value: prefs.heightCm,
              suffix: 'cm',
              min: 100,
              max: 230,
              onChanged: (v) => prefs.saveProfile(heightCm: v),
            ),
            _NumberTile(
              title: 'Weight',
              value: prefs.weightKg,
              suffix: 'kg',
              min: 25,
              max: 250,
              onChanged: (v) => prefs.saveProfile(weightKg: v),
            ),
            ListTile(
              title: const Text('Activity level'),
              subtitle: Text(prefs.activity.label),
              onTap: () async {
                final choice = await showModalBottomSheet<ActivityLevel>(
                  context: context,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => ListView(
                    shrinkWrap: true,
                    children: [
                      for (final a in ActivityLevel.values)
                        ListTile(
                          title: Text(a.label),
                          subtitle: Text(a.description),
                          onTap: () => Navigator.pop(context, a),
                        ),
                    ],
                  ),
                );
                if (choice != null) {
                  unawaited(prefs.saveProfile(activity: choice));
                }
              },
            ),
            const Divider(),
            const _Header('Goals'),
            _NumberTile(
              title: 'Daily calories',
              value: prefs.calorieGoal.toDouble(),
              suffix: 'kcal',
              min: 800,
              max: 6000,
              onChanged: (v) => prefs.setCalorieGoal(v.round()),
            ),
            _NumberTile(
              title: 'Daily protein',
              value: prefs.proteinGoal.toDouble(),
              suffix: 'g',
              min: 20,
              max: 400,
              onChanged: (v) => prefs.setProteinGoal(v.round()),
            ),
            _NumberTile(
              title: 'Daily water',
              value: prefs.waterGoalMl.toDouble(),
              suffix: 'ml',
              min: 500,
              max: 8000,
              onChanged: (v) => prefs.setWaterGoal(v.round()),
            ),
            const Divider(),
            const _Header('Food database'),
            FutureBuilder<Map<String, String>>(
              future: FoodDatabase.instance.meta(),
              builder: (context, snapshot) {
                final meta = snapshot.data ?? const {};
                return ListTile(
                  title: const Text('Installed data'),
                  subtitle: Text(
                    meta.isEmpty
                        ? 'Loading…'
                        : 'Built ${meta['database_date'] ?? '—'} · '
                            'schema v${meta['schema_version'] ?? '—'}',
                  ),
                );
              },
            ),
            SwitchListTile(
              title: const Text('Check for updates automatically'),
              subtitle: const Text('Every few days, over any connection'),
              value: prefs.autoUpdateDatabase,
              onChanged: prefs.setAutoUpdateDatabase,
            ),
            ListTile(
              title: const Text('Check now'),
              subtitle: Text(switch (updates.stage) {
                UpdateStage.checking => 'Checking…',
                UpdateStage.downloading =>
                  'Downloading ${(updates.progress * 100).round()}%',
                UpdateStage.verifying => 'Verifying…',
                UpdateStage.staged => 'Ready — restart the app to apply',
                UpdateStage.failed => updates.error,
                UpdateStage.idle => updates.available == null
                    ? 'You are on the latest data'
                    : 'Update available',
              }),
              trailing: updates.busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onTap: updates.busy ? null : () => updates.check(),
            ),
            if (updates.available != null && updates.stage == UpdateStage.idle)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton(
                  onPressed: updates.download,
                  child: Text(
                      'Download ${updates.available!.sizeMb.toStringAsFixed(1)} MB update'),
                ),
              ),
            const Divider(),
            const _Header('Ads'),
            const _AdFreeRow(),
            const Divider(),
            const _Header('Images'),
            SwitchListTile(
              title: const Text('Load images only on Wi-Fi'),
              subtitle: const Text('Cached images still work offline'),
              value: prefs.wifiOnlyImages,
              onChanged: prefs.setWifiOnlyImages,
            ),
            ListTile(
              title: const Text('Image host'),
              subtitle: Text(ImageHostingService.instance.activeProvider),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final choice = await showModalBottomSheet<String>(
                  context: context,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => ListView(
                    shrinkWrap: true,
                    children: [
                      for (final name
                          in ImageHostingService.instance.providerNames)
                        ListTile(
                          title: Text(name),
                          onTap: () => Navigator.pop(context, name),
                        ),
                    ],
                  ),
                );
                if (choice != null) {
                  ImageHostingService.instance.setProvider(choice);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Images now served from $choice')),
                    );
                  }
                }
              },
            ),
            ListTile(
              title: const Text('Clear image cache'),
              trailing: const Icon(Icons.delete_outline),
              onTap: () async {
                await FoodImageCacheManager.instance.emptyCache();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Image cache cleared')),
                );
              },
            ),
            const Divider(),
            const _Header('Data'),
            ListTile(
              title: Text('Reset my data',
                  style: TextStyle(color: theme.colorScheme.error)),
              subtitle: const Text(
                  'Deletes diary, favourites, water, weight and plans'),
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Reset all your data?'),
                    content: const Text(
                        'The food database stays. Everything you have logged is '
                        'deleted and cannot be recovered.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                await context.read<UserRepository>().wipe();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Your data has been reset')),
                );
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// Offers the ad-free hour where someone annoyed by ads actually goes looking
/// for a way to turn them off, instead of only in the More tab's feature list.
///
/// It is a row in Settings rather than a control on the banner itself: putting
/// a tappable target against a live ad view is how accidental clicks happen,
/// and AdMob treats those as invalid traffic.
class _AdFreeRow extends StatefulWidget {
  const _AdFreeRow();

  @override
  State<_AdFreeRow> createState() => _AdFreeRowState();
}

class _AdFreeRowState extends State<_AdFreeRow> {
  bool _working = false;

  Future<void> _unlock() async {
    setState(() => _working = true);
    final premium = context.read<PremiumController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await premium.unlock(PremiumFeature.adFreeSession);
    if (!mounted) return;
    setState(() => _working = false);
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? 'Ads are off for '
              '${formatRemaining(PremiumFeature.adFreeSession.duration)}'
          : 'No reward earned — the ad has to finish.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumController>();
    final left = premium.remainingFor(PremiumFeature.adFreeSession);
    if (premium.adFree && left != null) {
      return ListTile(
        leading: const Icon(Icons.block),
        title: const Text('Ad-free session active'),
        subtitle: Text('${formatRemaining(left)} left'),
      );
    }
    return ListTile(
      leading: const Icon(Icons.block_outlined),
      title: const Text('Turn ads off for an hour'),
      subtitle: Text(premium.rewardedReady
          ? 'Watch one short ad — no subscription, no account'
          : 'Preparing ad…'),
      trailing: _working
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_circle_outline),
      onTap: _working ? null : _unlock,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _NumberTile extends StatelessWidget {
  const _NumberTile({
    required this.title,
    required this.value,
    required this.suffix,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String title;
  final double value;
  final String suffix;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: Text(
        '${value == value.roundToDouble() ? value.round() : value.toStringAsFixed(1)} $suffix',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      onTap: () async {
        final controller = TextEditingController(
            text: value == value.roundToDouble()
                ? value.round().toString()
                : value.toStringAsFixed(1));
        final result = await showDialog<double>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(suffixText: suffix),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, double.tryParse(controller.text)),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        if (result != null && result >= min && result <= max) {
          onChanged(result);
        }
      },
    );
  }
}
