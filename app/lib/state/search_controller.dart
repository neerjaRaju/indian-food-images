import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/food.dart';
import '../data/repositories/food_repository.dart';
import '../data/repositories/user_repository.dart';

/// Debounced, paged food search.
///
/// The debounce matters more than usual here: FTS over ~100k rows is fast, but
/// firing a query on every keystroke on a budget Android device still burns
/// frames. 220 ms is short enough to feel instant and long enough to skip most
/// intermediate queries.
class FoodSearchController extends ChangeNotifier {
  FoodSearchController(this._foods, this._users);

  final FoodRepository _foods;
  final UserRepository _users;

  static const debounce = Duration(milliseconds: 220);
  static const pageSize = 40;

  Timer? _timer;
  int _requestId = 0;

  String _query = '';
  FoodFilter _filter = const FoodFilter();
  List<Food> _results = const [];
  List<String> _recent = const [];
  List<String> _suggestions = const [];
  bool _loading = false;
  bool _hasMore = false;
  String _error = '';

  String get query => _query;
  FoodFilter get filter => _filter;
  List<Food> get results => _results;
  List<String> get recentSearches => _recent;
  List<String> get suggestions => _suggestions;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  String get error => _error;
  bool get isEmptyState => _query.isEmpty && _filter.isEmpty;

  Future<void> init() async {
    _recent = await _users.recentSearches();
    notifyListeners();
    await _run(immediate: true);
  }

  void setQuery(String value) {
    if (value == _query) return;
    _query = value;
    _timer?.cancel();
    _timer = Timer(debounce, () => _run());
    notifyListeners();
  }

  void setFilter(FoodFilter filter) {
    _filter = filter;
    _run(immediate: true);
  }

  void clear() {
    _timer?.cancel();
    _query = '';
    _filter = const FoodFilter();
    _suggestions = const [];
    _run(immediate: true);
  }

  Future<void> _run({bool immediate = false}) async {
    final id = ++_requestId;
    _loading = true;
    _error = '';
    notifyListeners();
    try {
      final rows = await _foods.search(_query,
          filter: _filter, limit: pageSize, offset: 0);
      if (id != _requestId) return;
      _results = rows;
      _hasMore = rows.length == pageSize;
      _loading = false;
      if (_query.trim().length >= 2) {
        unawaited(_users.recordSearch(_query.trim(), rows.length));
      }
      notifyListeners();
    } catch (e) {
      if (id != _requestId) return;
      _loading = false;
      _error = 'Search failed: $e';
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    final id = _requestId;
    _loading = true;
    notifyListeners();
    try {
      final rows = await _foods.search(_query,
          filter: _filter, limit: pageSize, offset: _results.length);
      if (id != _requestId) return;
      _results = [..._results, ...rows];
      _hasMore = rows.length == pageSize;
    } catch (e) {
      _error = 'Could not load more: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshRecents() async {
    _recent = await _users.recentSearches();
    notifyListeners();
  }

  Future<void> clearRecents() async {
    await _users.clearRecentSearches();
    _recent = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
