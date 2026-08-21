import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/router.dart';
import '../../data/repositories/food_repository.dart';
import '../../data/services/ads_service.dart';
import '../../state/premium_controller.dart';
import '../../state/search_controller.dart';
import '../../widgets/food_tile.dart';
import 'filter_sheet.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  final _scrollController = ScrollController();
  final _speech = SpeechToText();
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >
          _scrollController.position.maxScrollExtent - 400) {
        context.read<FoodSearchController>().loadMore();
      }
    });
    if (widget.initialQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<FoodSearchController>().setQuery(widget.initialQuery);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    final search = context.read<FoodSearchController>();
    final messenger = ScaffoldMessenger.of(context);
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!available) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Voice search needs microphone permission.'),
      ));
      return;
    }
    setState(() => _listening = true);
    // Hindi first with an English fallback — most users mix the two.
    await _speech.listen(
      localeId: 'hi_IN',
      onResult: (result) {
        _controller.text = result.recognizedWords;
        search.setQuery(result.recognizedWords);
        if (result.finalResult && mounted) {
          setState(() => _listening = false);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<FoodSearchController>();
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: widget.initialQuery.isEmpty,
                      textInputAction: TextInputAction.search,
                      onChanged: search.setQuery,
                      decoration: InputDecoration(
                        hintText: 'Search food, दाल, brand, barcode…',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_controller.text.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _controller.clear();
                                  search.clear();
                                  setState(() {});
                                },
                              ),
                            IconButton(
                              tooltip: 'Voice search',
                              icon: Icon(
                                  _listening ? Icons.mic : Icons.mic_none,
                                  color: _listening
                                      ? theme.colorScheme.primary
                                      : null),
                              onPressed: _toggleVoice,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Filters',
                    icon: Badge(
                      isLabelVisible: !search.filter.isEmpty,
                      child: const Icon(Icons.tune),
                    ),
                    onPressed: () => _openFilters(context),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Scan barcode',
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: () => context.push(Routes.scan),
                  ),
                ],
              ),
            ),
            if (search.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _Body(controller: _controller)),
          ],
        ),
      ),
    );
  }

  Future<void> _openFilters(BuildContext context) async {
    final search = context.read<FoodSearchController>();
    final premium = context.read<PremiumController>();
    final repo = context.read<FoodRepository>();
    final categories = await repo.categories();
    if (!context.mounted) return;
    final result = await showModalBottomSheet<FoodFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FilterSheet(
        initial: search.filter,
        categories: categories,
        advancedUnlocked: premium.isUnlocked(PremiumFeature.advancedFilters),
      ),
    );
    if (result != null) search.setFilter(result);
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final search = context.watch<FoodSearchController>();
    final theme = Theme.of(context);

    if (search.error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(search.error, textAlign: TextAlign.center),
        ),
      );
    }

    if (search.results.isEmpty && !search.loading) {
      if (search.query.isEmpty) {
        return _RecentSearches(controller: controller);
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_food_outlined, size: 44),
              const SizedBox(height: 12),
              Text('No match for "${search.query}"',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(
                'Try a shorter word, the Hindi name, or clear your filters.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: search.results.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 84),
      itemBuilder: (context, i) {
        if (i == search.results.length) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: search.hasMore
                  ? const CircularProgressIndicator()
                  : Text('${search.results.length} results',
                      style: theme.textTheme.labelSmall),
            ),
          );
        }
        return FoodTile(food: search.results[i]);
      },
    );
  }
}

class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final search = context.watch<FoodSearchController>();
    final theme = Theme.of(context);
    if (search.recentSearches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Search 1,800+ Indian foods, recipes and packaged products — all '
            'offline.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
          child: Row(
            children: [
              Expanded(
                child:
                    Text('Recent searches', style: theme.textTheme.titleSmall),
              ),
              TextButton(
                onPressed: search.clearRecents,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        for (final term in search.recentSearches)
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(term),
            onTap: () {
              controller.text = term;
              search.setQuery(term);
            },
          ),
      ],
    );
  }
}
