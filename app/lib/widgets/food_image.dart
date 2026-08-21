import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../data/models/food.dart';
import '../data/services/image_hosting_service.dart';

/// Cache tuned for a food catalogue: thumbnails are tiny and worth keeping for
/// a long time, so a large object count with a month-long TTL costs very
/// little disk while making repeat browsing fully offline.
class FoodImageCacheManager extends CacheManager {
  static const key = 'foodImageCache';

  static final FoodImageCacheManager instance = FoodImageCacheManager._();

  FoodImageCacheManager._()
      : super(Config(
          key,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 3000,
        ));
}

enum FoodImageSize { thumbnail, medium, large }

/// Network food image with placeholder, fade-in, retry and host fallback.
///
/// If the active CDN fails, the widget walks the configured fallback list
/// before giving up — a jsDelivr outage should degrade to GitHub Pages, not to
/// a screen full of grey boxes.
class FoodImage extends StatefulWidget {
  const FoodImage({
    super.key,
    required this.food,
    this.size = FoodImageSize.thumbnail,
    this.width,
    this.height,
    this.borderRadius = 12,
    this.heroTag,
    this.fit = BoxFit.cover,
  });

  final Food food;
  final FoodImageSize size;
  final double? width;
  final double? height;
  final double borderRadius;
  final Object? heroTag;
  final BoxFit fit;

  @override
  State<FoodImage> createState() => _FoodImageState();
}

class _FoodImageState extends State<FoodImage> {
  int _attempt = 0;
  late List<String> _urls = _resolve();

  List<String> _resolve() {
    final stored = switch (widget.size) {
      FoodImageSize.thumbnail => widget.food.thumbnailUrl,
      FoodImageSize.medium => widget.food.imageUrl,
      FoodImageSize.large => widget.food.largeUrl,
    };
    if (stored.isEmpty) return const [];
    return ImageHostingService.instance.resolveWithFallbacks(stored);
  }

  @override
  void didUpdateWidget(covariant FoodImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.food.id != widget.food.id || oldWidget.size != widget.size) {
      _attempt = 0;
      _urls = _resolve();
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    Widget child;
    if (_urls.isEmpty || _attempt >= _urls.length) {
      child =
          _FoodImagePlaceholder(food: widget.food, failed: _urls.isNotEmpty);
    } else {
      child = CachedNetworkImage(
        imageUrl: _urls[_attempt],
        cacheManager: FoodImageCacheManager.instance,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        fadeInDuration: const Duration(milliseconds: 220),
        memCacheWidth: switch (widget.size) {
          FoodImageSize.thumbnail => 200,
          FoodImageSize.medium => 512,
          FoodImageSize.large => 1024,
        },
        placeholder: (context, _) =>
            _FoodImagePlaceholder(food: widget.food, shimmer: true),
        errorWidget: (context, _, __) {
          // Try the next host on the next frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _attempt < _urls.length) {
              setState(() => _attempt++);
            }
          });
          return _FoodImagePlaceholder(food: widget.food, shimmer: true);
        },
      );
    }

    final clipped = ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: child,
      ),
    );
    if (widget.heroTag == null) return clipped;
    return Hero(tag: widget.heroTag!, child: clipped);
  }
}

/// Deterministic coloured tile with the dish's initial — far better than a
/// generic grey box when 40 % of rows have no photo yet.
class _FoodImagePlaceholder extends StatelessWidget {
  const _FoodImagePlaceholder({
    required this.food,
    this.shimmer = false,
    this.failed = false,
  });

  final Food food;
  final bool shimmer;
  final bool failed;

  static const _emojiByClass = {
    'grain': '🫓',
    'legume': '🍲',
    'vegetable': '🥘',
    'meat': '🍗',
    'seafood': '🐟',
    'egg': '🥚',
    'dairy': '🥛',
    'sweet': '🍮',
    'snack': '🥨',
    'beverage': '🥤',
    'fruit': '🥭',
    'fried': '🧆',
    'street': '🛺',
    'soup': '🍜',
    'fat': '🧈',
    'mixed': '🍛',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hue = (food.slug.hashCode.abs() % 360).toDouble();
    final base = HSLColor.fromAHSL(
      1,
      hue,
      0.32,
      Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.88,
    ).toColor();
    return Container(
      color: shimmer ? scheme.surfaceContainerHighest : base,
      alignment: Alignment.center,
      child: shimmer
          ? const SizedBox.shrink()
          : Text(
              _emojiByClass[food.foodClass] ?? '🍽️',
              style: const TextStyle(fontSize: 26),
            ),
    );
  }
}

/// Attribution line required by the CC licences the photos ship under.
class ImageCreditLine extends StatelessWidget {
  const ImageCreditLine({super.key, required this.food});

  final Food food;

  @override
  Widget build(BuildContext context) {
    if (food.imageCredit.isEmpty && food.license.isEmpty) {
      return const SizedBox.shrink();
    }
    final text = [
      if (food.imageCredit.isNotEmpty) food.imageCredit,
      if (food.license.isNotEmpty) food.license,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        'Photo: $text',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
