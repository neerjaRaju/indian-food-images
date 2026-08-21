import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/food.dart';
import '../../data/repositories/food_repository.dart';
import '../../widgets/food_tile.dart';

class CategoryScreen extends StatefulWidget {
  const CategoryScreen({
    super.key,
    required this.categoryId,
    required this.categoryName,
  });

  final int categoryId;
  final String categoryName;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  static const _pageSize = 40;

  final _scroll = ScrollController();
  final List<Food> _foods = [];
  FoodSort _sort = FoodSort.relevance;
  bool _loading = false;
  bool _hasMore = true;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        _load();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || (!_hasMore && !reset)) return;
    setState(() => _loading = true);
    final repo = context.read<FoodRepository>();
    final filter = FoodFilter(categoryId: widget.categoryId, sort: _sort);
    if (reset) {
      _foods.clear();
      _hasMore = true;
      _total = await repo.countMatching(filter);
    }
    final rows = await repo.browse(
      filter: filter,
      limit: _pageSize,
      offset: _foods.length,
    );
    if (!mounted) return;
    setState(() {
      _foods.addAll(rows);
      _hasMore = rows.length == _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.categoryName),
        actions: [
          PopupMenuButton<FoodSort>(
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (s) {
              setState(() => _sort = s);
              _load(reset: true);
            },
            itemBuilder: (_) => [
              for (final s in FoodSort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
          ),
        ],
      ),
      body: SafeArea(
        // Edge-to-edge: this screen is pushed full-screen, so
        // nothing else keeps its last row clear of the gesture
        // bar. The app bar already owns the top inset.
        top: false,
        child: Column(
          children: [
            if (_total > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('$_total foods',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
            Expanded(
              child: _foods.isEmpty && _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      controller: _scroll,
                      itemCount: _foods.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 84),
                      itemBuilder: (context, i) {
                        if (i >= _foods.length) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        return FoodTile(food: _foods[i]);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
