import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/db/food_database.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Indian Food Calories', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'A calorie and nutrition reference for Indian food that works with '
            'no internet, no account and no backend. The whole food database '
            'ships inside the app; only photographs are fetched from a CDN, and '
            'they are cached after the first view.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final info = snapshot.data;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('App version'),
                subtitle: Text(info == null
                    ? '—'
                    : '${info.version} (${info.buildNumber})'),
              );
            },
          ),
          FutureBuilder<Map<String, String>>(
            future: FoodDatabase.instance.meta(),
            builder: (context, snapshot) {
              final meta = snapshot.data ?? const <String, String>{};
              final counts = meta['counts'] == null
                  ? const <String, dynamic>{}
                  : jsonDecode(meta['counts']!) as Map<String, dynamic>;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Database built'),
                    subtitle: Text(meta['database_date'] ?? '—'),
                  ),
                  if (counts.isNotEmpty)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Contents'),
                      subtitle: Text(
                        '${counts['foods'] ?? 0} foods · '
                        '${counts['recipes'] ?? 0} recipes · '
                        '${counts['packaged'] ?? 0} packaged · '
                        '${counts['with_images'] ?? 0} with photos',
                      ),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 32),
          Text('Where the data comes from', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          const _Source(
            name: 'Indian Food Composition Tables 2017 (NIN/ICMR)',
            detail: 'Reference values for Indian foods and cooked dishes.',
            url: 'https://www.nin.res.in/ifct2017.html',
          ),
          const _Source(
            name: 'USDA FoodData Central',
            detail:
                'Public-domain micronutrient panels for shared ingredients.',
            url: 'https://fdc.nal.usda.gov/',
          ),
          const _Source(
            name: 'Open Food Facts',
            detail: 'Packaged products and barcodes, licensed under ODbL 1.0.',
            url: 'https://world.openfoodfacts.org/',
          ),
          const _Source(
            name: 'Wikipedia',
            detail: 'Dish descriptions and regional names, CC BY-SA 4.0.',
            url: 'https://en.wikipedia.org/',
          ),
          const _Source(
            name: 'Wikimedia Commons',
            detail:
                'Food photography under CC BY, CC BY-SA, CC0 and public-domain '
                'licences. Each photo credits its author in the app.',
            url: 'https://commons.wikimedia.org/',
          ),
          const Divider(height: 32),
          Text('How accurate is this?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Cooked Indian dishes vary enormously between households — the same '
            'dal can differ by 40 % in calories depending on how much oil goes '
            'in. Values here are representative averages, cross-checked so that '
            'the calories match the macros. Some micronutrients are estimated '
            'from a food-class profile where the source tables do not publish '
            'them; those rows say so on the food page.\n\n'
            'This app is a reference tool, not medical advice. If you are '
            'managing diabetes, kidney disease, pregnancy or any condition '
            'where nutrition matters clinically, work with a doctor or a '
            'registered dietitian.',
            style: theme.textTheme.bodyMedium,
          ),
          const Divider(height: 32),
          Text('Privacy', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Your diary, weight, water and plans stay on your phone in a local '
            'database. There is no account and nothing is uploaded. The app '
            'talks to the network only to fetch food photographs and to check '
            'for a new database release. Ads are served by Google AdMob, which '
            'has its own data practices.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _Source extends StatelessWidget {
  const _Source({required this.name, required this.detail, required this.url});

  final String name;
  final String detail;
  final String url;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      subtitle: Text(detail),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
  }
}
