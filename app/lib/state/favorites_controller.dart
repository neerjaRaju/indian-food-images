import 'package:flutter/foundation.dart';

import '../data/models/food.dart';
import '../data/repositories/food_repository.dart';
import '../data/repositories/user_repository.dart';

class FavoritesController extends ChangeNotifier {
  FavoritesController(this._users, this._foods);

  final UserRepository _users;
  final FoodRepository _foods;

  Set<int> _ids = {};
  List<Food> _foodsList = const [];
  List<Food> _recentlyViewed = const [];
  bool _loading = true;

  Set<int> get ids => _ids;
  List<Food> get favorites => _foodsList;
  List<Food> get recentlyViewed => _recentlyViewed;
  bool get loading => _loading;

  bool isFavorite(int id) => _ids.contains(id);

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    _ids = await _users.favoriteIds();
    final ordered = await _users.favoriteIdsOrdered();
    _foodsList = await _foods.byIds(ordered);
    _recentlyViewed = await _foods.byIds(await _users.recentlyViewedIds());
    _loading = false;
    notifyListeners();
  }

  Future<void> toggle(Food food) async {
    await _users.toggleFavorite(food);
    if (_ids.contains(food.id)) {
      _ids = {..._ids}..remove(food.id);
      _foodsList =
          _foodsList.where((f) => f.id != food.id).toList(growable: false);
    } else {
      _ids = {..._ids, food.id};
      _foodsList = [food, ..._foodsList];
    }
    notifyListeners();
  }

  Future<void> recordView(Food food) async {
    await _users.recordView(food);
  }
}
