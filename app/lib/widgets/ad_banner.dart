import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';

import '../data/services/ads_service.dart';
import '../state/premium_controller.dart';

/// Anchored adaptive banner.
///
/// Renders nothing at all (zero height, no reserved space) when the user has an
/// ad-free session or when the ad fails to load — a permanently empty grey
/// strip is worse than no ad slot.
class AdaptiveAdBanner extends StatefulWidget {
  const AdaptiveAdBanner({super.key, this.maxWidthFraction = 1.0});

  final double maxWidthFraction;

  @override
  State<AdaptiveAdBanner> createState() => _AdaptiveAdBannerState();
}

class _AdaptiveAdBannerState extends State<AdaptiveAdBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_requested) {
      _requested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (context.read<PremiumController>().adFree) return;
    final ads = context.read<AdsService>();
    if (!ads.isReady) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || !ads.isReady) return;
    }
    final width =
        (MediaQuery.sizeOf(context).width * widget.maxWidthFraction).truncate();
    final size =
        await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted) return;
    final ad = ads.createBanner(
      size: size,
      onLoaded: () {
        if (mounted) setState(() => _loaded = true);
      },
      onFailed: (_) {
        if (mounted) setState(() => _ad = null);
      },
    );
    if (ad == null) return;
    _ad = ad;
    await ad.load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final adFree = context.watch<PremiumController>().adFree;
    final ad = _ad;
    if (adFree || ad == null || !_loaded) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
