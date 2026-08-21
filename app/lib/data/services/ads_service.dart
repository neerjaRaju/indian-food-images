import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Every gated capability. A rewarded ad unlocks exactly one of these for a
/// bounded time — there are no subscriptions and nothing is unlocked forever.
enum PremiumFeature {
  unlimitedMealPlans('Unlimited meal plans', Duration(days: 7)),
  advancedMacros('Advanced macro analysis', Duration(hours: 12)),
  nutritionReports('Nutrition reports', Duration(hours: 12)),
  compareFoods('Compare foods', Duration(hours: 6)),
  pdfExport('PDF export', Duration(hours: 2)),
  smartRecommendations('Smart recommendations', Duration(hours: 12)),
  advancedFilters('Advanced filters', Duration(hours: 6)),
  adFreeSession('Ad-free session', Duration(hours: 1));

  const PremiumFeature(this.label, this.duration);

  final String label;
  final Duration duration;
}

/// AdMob unit IDs. The Google test IDs are used in debug builds so a developer
/// never risks their account by clicking their own live ads.
class AdUnits {
  static const _testBanner = 'ca-app-pub-3940256099942544/6300978111';
  static const _testInterstitial = 'ca-app-pub-3940256099942544/1033173712';
  static const _testRewarded = 'ca-app-pub-3940256099942544/5224354917';
  static const _testNative = 'ca-app-pub-3940256099942544/2247696110';

  /// Replace via --dart-define=ADMOB_BANNER=... at build time.
  static const _liveBanner = String.fromEnvironment('ADMOB_BANNER');
  static const _liveInterstitial = String.fromEnvironment('ADMOB_INTERSTITIAL');
  static const _liveRewarded = String.fromEnvironment('ADMOB_REWARDED');
  static const _liveNative = String.fromEnvironment('ADMOB_NATIVE');

  static String get banner =>
      (kReleaseMode && _liveBanner.isNotEmpty) ? _liveBanner : _testBanner;
  static String get interstitial =>
      (kReleaseMode && _liveInterstitial.isNotEmpty)
          ? _liveInterstitial
          : _testInterstitial;
  static String get rewarded => (kReleaseMode && _liveRewarded.isNotEmpty)
      ? _liveRewarded
      : _testRewarded;
  static String get native =>
      (kReleaseMode && _liveNative.isNotEmpty) ? _liveNative : _testNative;
}

/// Owns the ad SDK, keeps one rewarded ad warm, and rate-limits interstitials.
class AdsService {
  AdsService();

  bool _initialised = false;
  RewardedAd? _rewarded;
  bool _loadingRewarded = false;
  InterstitialAd? _interstitial;
  DateTime _lastInterstitial = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum gap between interstitials. Showing them more often than this is
  /// the fastest way to get uninstalled.
  static const interstitialCooldown = Duration(minutes: 4);

  bool get isReady => _initialised;

  /// Whether a rewarded ad is loaded and can be shown right now.
  ///
  /// This is a [Listenable] rather than a plain getter because loading happens
  /// in the background: anything offering an unlock has to be told when the ad
  /// arrives, or its button sits on "Preparing ad…" until some unrelated
  /// rebuild happens to notice.
  final ValueNotifier<bool> rewardedAvailable = ValueNotifier<bool>(false);

  bool get rewardedReady => rewardedAvailable.value;

  void _setRewarded(RewardedAd? ad) {
    _rewarded = ad;
    rewardedAvailable.value = ad != null;
  }

  Future<void> initialise() async {
    if (_initialised) return;
    try {
      await MobileAds.instance.initialize();
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          // Replaces tagForChildDirectedTreatment, deprecated in
          // google_mobile_ads 9. `unspecified` carries the same meaning: we
          // make no age claim about the audience, so AdMob applies its
          // default treatment.
          ageRestrictedTreatment: AgeRestrictedTreatment.unspecified,
          maxAdContentRating: MaxAdContentRating.g,
        ),
      );
      _initialised = true;
      unawaited(preloadRewarded());
      unawaited(_preloadInterstitial());
    } catch (e) {
      debugPrint('AdsService: init failed ($e) — running without ads');
    }
  }

  // ------------------------------------------------------------------ //
  BannerAd? createBanner({
    required AdSize size,
    void Function()? onLoaded,
    void Function(LoadAdError)? onFailed,
  }) {
    if (!_initialised) return null;
    return BannerAd(
      adUnitId: AdUnits.banner,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) => onLoaded?.call(),
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          onFailed?.call(error);
        },
      ),
    );
  }

  // ------------------------------------------------------------------ //
  Future<void> preloadRewarded() async {
    if (!_initialised || _rewarded != null || _loadingRewarded) return;
    _loadingRewarded = true;
    await RewardedAd.load(
      adUnitId: AdUnits.rewarded,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _setRewarded(ad);
          _loadingRewarded = false;
        },
        onAdFailedToLoad: (error) {
          _setRewarded(null);
          _loadingRewarded = false;
          debugPrint('AdsService: rewarded load failed ${error.code}');
        },
      ),
    );
  }

  /// Shows a rewarded ad. Returns true only when the user actually earned the
  /// reward — dismissing early must not unlock anything.
  Future<bool> showRewarded() async {
    if (!_initialised) return false;
    final ad = _rewarded;
    if (ad == null) {
      await preloadRewarded();
      return false;
    }
    _setRewarded(null);
    final completer = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        unawaited(preloadRewarded());
        if (!completer.isCompleted) completer.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        unawaited(preloadRewarded());
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    await ad.show(onUserEarnedReward: (_, __) => earned = true);
    return completer.future;
  }

  // ------------------------------------------------------------------ //
  Future<void> _preloadInterstitial() async {
    if (!_initialised || _interstitial != null) return;
    await InterstitialAd.load(
      adUnitId: AdUnits.interstitial,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (_) => _interstitial = null,
      ),
    );
  }

  /// Shows an interstitial if one is loaded, the cooldown has elapsed and the
  /// user has not bought an ad-free session with a rewarded view.
  Future<void> maybeShowInterstitial({required bool adFreeActive}) async {
    if (!_initialised || adFreeActive) return;
    if (DateTime.now().difference(_lastInterstitial) < interstitialCooldown) {
      return;
    }
    final ad = _interstitial;
    if (ad == null) {
      unawaited(_preloadInterstitial());
      return;
    }
    _interstitial = null;
    _lastInterstitial = DateTime.now();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        unawaited(_preloadInterstitial());
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        unawaited(_preloadInterstitial());
      },
    );
    await ad.show();
  }

  void dispose() {
    _rewarded?.dispose();
    _interstitial?.dispose();
    _setRewarded(null);
    _interstitial = null;
    rewardedAvailable.dispose();
  }
}
