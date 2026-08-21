import 'package:flutter/foundation.dart';

import '../data/models/diary.dart';
import '../data/models/food.dart';
import '../data/repositories/food_repository.dart';
import '../data/repositories/user_repository.dart';
import '../data/services/preferences_service.dart';

/// Owns the day the diary screen is looking at, plus water and weight for that
/// day, so every widget on the screen redraws from one source of truth.
class DiaryController extends ChangeNotifier {
  DiaryController(this._users, this._foods, this._prefs);

  final UserRepository _users;
  final FoodRepository _foods;
  final PreferencesService _prefs;

  DateTime _date = DateTime.now();
  List<DiaryEntry> _entries = const [];
  int _waterMl = 0;
  bool _loading = true;
  List<Food> _quickAdd = const [];

  DateTime get date => _date;
  String get dateKey => isoDate(_date);
  List<DiaryEntry> get entries => _entries;
  bool get loading => _loading;
  int get waterMl => _waterMl;
  int get waterGoalMl => _prefs.waterGoalMl;
  List<Food> get quickAdd => _quickAdd;

  DayTotals get totals => DayTotals.of(_entries);
  int get calorieGoal => _prefs.calorieGoal;
  double get calorieProgress =>
      calorieGoal <= 0 ? 0 : (totals.calories / calorieGoal).clamp(0.0, 1.5);
  double get caloriesRemaining => calorieGoal - totals.calories;

  bool get isToday {
    final now = DateTime.now();
    return _date.year == now.year &&
        _date.month == now.month &&
        _date.day == now.day;
  }

  Map<MealSlot, List<DiaryEntry>> get bySlot {
    final map = {for (final s in MealSlot.values) s: <DiaryEntry>[]};
    for (final e in _entries) {
      map[e.slot]!.add(e);
    }
    return map;
  }

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    _entries = await _users.diaryFor(dateKey);
    _waterMl = await _users.waterFor(dateKey);
    _loading = false;
    notifyListeners();
    await _loadQuickAdd();
  }

  Future<void> _loadQuickAdd() async {
    final ids = await _users.frequentFoodIds(limit: 10);
    if (ids.isEmpty) {
      _quickAdd = await _foods.popular(limit: 10);
    } else {
      _quickAdd = await _foods.byIds(ids);
    }
    notifyListeners();
  }

  Future<void> setDate(DateTime value) async {
    _date = DateTime(value.year, value.month, value.day);
    await load();
  }

  Future<void> shiftDay(int days) => setDate(_date.add(Duration(days: days)));

  Future<void> addFood(
    Food food, {
    required MealSlot slot,
    required double grams,
    required String servingLabel,
  }) async {
    final entry = DiaryEntry.fromFood(
      food,
      date: dateKey,
      slot: slot,
      grams: grams,
      servingLabel: servingLabel,
    );
    await _users.addDiaryEntry(entry);
    await load();
  }

  Future<void> remove(DiaryEntry entry) async {
    await _users.deleteDiaryEntry(entry.id);
    _entries = _entries.where((e) => e.id != entry.id).toList(growable: false);
    notifyListeners();
  }

  Future<void> undoRemove(DiaryEntry entry) async {
    await _users.addDiaryEntry(entry);
    await load();
  }

  Future<void> addWater(int ml) async {
    _waterMl = await _users.addWater(dateKey, ml);
    notifyListeners();
  }

  Future<Map<String, DayTotals>> weekTotals() async {
    final end = _date;
    final start = end.subtract(const Duration(days: 6));
    return _users.diaryTotalsRange(isoDate(start), isoDate(end));
  }
}
