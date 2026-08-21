import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repositories/user_repository.dart';
import '../data/services/ads_service.dart';

/// Tracks which rewarded-ad unlocks are currently active.
///
/// Unlocks are time-boxed and persisted, so closing the app does not cost the
/// user a reward they already watched an ad for.
class PremiumController extends ChangeNotifier {
  PremiumController(this._users, this._ads) {
    // Rewarded ads load in the background. Without this, every "Watch a short
    // ad" button renders once against `rewardedReady == false` and stays stuck
    // on "Preparing ad…" long after the ad is actually available.
    _ads.rewardedAvailable.addListener(notifyListeners);
  }

  final UserRepository _users;
  final AdsService _ads;

  Map<String, DateTime> _active = {};
  Timer? _expiryTimer;

  Future<void> load() async {
    await _users.clearExpiredRewards();
    _active = await _users.activeRewards();
    _scheduleExpiry();
    notifyListeners();
  }

  bool isUnlocked(PremiumFeature feature) {
    final until = _active[feature.name];
    return until != null && until.isAfter(DateTime.now());
  }

  DateTime? expiryOf(PremiumFeature feature) => _active[feature.name];

  Duration? remainingFor(PremiumFeature feature) {
    final until = _active[feature.name];
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  bool get adFree => isUnlocked(PremiumFeature.adFreeSession);

  bool get rewardedReady => _ads.rewardedReady;

  /// Shows a rewarded ad and, only if the user earned the reward, unlocks
  /// [feature]. Returns true when the unlock happened.
  Future<bool> unlock(PremiumFeature feature) async {
    final earned = await _ads.showRewarded();
    if (!earned) return false;
    await _users.grantReward(feature.name, feature.duration);
    _active = await _users.activeRewards();
    _scheduleExpiry();
    notifyListeners();
    return true;
  }

  /// Debug/testing hook so widget tests can exercise unlocked UI without ads.
  @visibleForTesting
  Future<void> forceUnlock(PremiumFeature feature) async {
    await _users.grantReward(feature.name, feature.duration);
    _active = await _users.activeRewards();
    notifyListeners();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    if (_active.isEmpty) return;
    final next = _active.values.reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = next.difference(DateTime.now());
    if (delay.isNegative) return;
    _expiryTimer = Timer(delay + const Duration(seconds: 1), () async {
      await _users.clearExpiredRewards();
      _active = await _users.activeRewards();
      _scheduleExpiry();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _ads.rewardedAvailable.removeListener(notifyListeners);
    _expiryTimer?.cancel();
    super.dispose();
  }
}
