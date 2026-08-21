import 'package:flutter/material.dart';

class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🍛', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 16),
            Text('Indian Food Calories', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Preparing your offline food database…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 160,
              child: LinearProgressIndicator(minHeight: 3),
            ),
          ],
        ),
      ),
    );
  }
}

class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({super.key, required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storage_outlined,
                  size: 52, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('The food database could not be opened',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Freeing some storage and reopening the app usually fixes this, '
                'because the database is unpacked on first launch.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
