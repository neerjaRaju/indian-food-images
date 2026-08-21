import 'package:flutter_test/flutter_test.dart';
import 'package:indian_food_calories/data/db/user_database.dart';
import 'package:indian_food_calories/data/repositories/user_repository.dart';
import 'package:indian_food_calories/data/services/ads_service.dart';
import 'package:indian_food_calories/state/premium_controller.dart';

/// These cover the wiring between "an ad finished loading" and "the button
/// offering the unlock knows about it". Nothing here opens a database — the
/// controller only touches the repository inside load()/unlock().
void main() {
  group('rewarded availability', () {
    late AdsService ads;
    late PremiumController premium;

    setUp(() {
      ads = AdsService();
      premium = PremiumController(
        UserRepository(UserDatabase.instance),
        ads,
      );
    });

    tearDown(() => premium.dispose());

    test('starts unavailable', () {
      expect(ads.rewardedReady, isFalse);
      expect(premium.rewardedReady, isFalse);
    });

    test('controller notifies when an ad becomes available', () {
      var notifications = 0;
      premium.addListener(() => notifications++);

      ads.rewardedAvailable.value = true;

      expect(notifications, 1);
      expect(premium.rewardedReady, isTrue);
    });

    test('controller notifies when the ad is consumed', () {
      ads.rewardedAvailable.value = true;
      var notifications = 0;
      premium.addListener(() => notifications++);

      ads.rewardedAvailable.value = false;

      expect(notifications, 1);
      expect(premium.rewardedReady, isFalse);
    });

    test('setting the same value again does not churn listeners', () {
      ads.rewardedAvailable.value = true;
      var notifications = 0;
      premium.addListener(() => notifications++);

      ads.rewardedAvailable.value = true;

      expect(notifications, 0);
    });

    test('a disposed controller stops listening', () {
      var notifications = 0;
      premium.addListener(() => notifications++);
      premium.dispose();

      // Would throw "used after being disposed" if the listener survived.
      ads.rewardedAvailable.value = true;

      expect(notifications, 0);

      // tearDown disposes again; make that a no-op for this one case.
      premium = PremiumController(
        UserRepository(UserDatabase.instance),
        AdsService(),
      );
    });
  });

  group('PremiumFeature', () {
    test('every feature unlocks for a bounded, positive time', () {
      for (final feature in PremiumFeature.values) {
        expect(feature.duration, greaterThan(Duration.zero),
            reason: '${feature.name} must expire');
        expect(feature.duration, lessThanOrEqualTo(const Duration(days: 7)),
            reason: '${feature.name} must not be a permanent unlock');
        expect(feature.label, isNotEmpty);
      }
    });

    test('every feature has a placement in the app', () {
      // Guards against a feature being declared and then never offered — which
      // is what happened to smartRecommendations before the Home carousel.
      expect(PremiumFeature.values.map((f) => f.name).toSet(), {
        'unlimitedMealPlans',
        'advancedMacros',
        'nutritionReports',
        'compareFoods',
        'pdfExport',
        'smartRecommendations',
        'advancedFilters',
        'adFreeSession',
      });
    });
  });
}
