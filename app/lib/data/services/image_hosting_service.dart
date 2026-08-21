import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Rewrites the image URLs stored in SQLite onto whichever host is configured.
///
/// The database stores a full URL, but that URL always ends in
/// `.../<folder>/<slug>.webp`. By capturing those two segments we can point the
/// entire catalogue at a different provider by editing one JSON file — no
/// rebuild of the 100k-row database, no app update.
class ImageHostingService {
  ImageHostingService._(this._config, this._active);

  static const assetPath = 'assets/config/image_hosting.json';
  static final _urlTail =
      RegExp(r'/(thumbnails|medium|large)/([A-Za-z0-9_\-]+)\.webp');

  final Map<String, dynamic> _config;
  String _active;

  static ImageHostingService? _instance;
  static ImageHostingService get instance {
    final i = _instance;
    if (i == null) throw StateError('ImageHostingService.load() not called');
    return i;
  }

  static Future<ImageHostingService> load() async {
    if (_instance != null) return _instance!;
    Map<String, dynamic> config;
    try {
      config = jsonDecode(await rootBundle.loadString(assetPath))
          as Map<String, dynamic>;
    } catch (e) {
      debugPrint('ImageHostingService: config missing ($e), using stored URLs');
      config = {'active': 'stored', 'providers': {}};
    }
    _instance =
        ImageHostingService._(config, config['active'] as String? ?? 'stored');
    return _instance!;
  }

  String get activeProvider => _active;

  List<String> get providerNames =>
      ((_config['providers'] as Map?)?.keys ?? const [])
          .cast<String>()
          .toList();

  /// Switch host at runtime (Settings → advanced). Cached images stay valid
  /// because flutter_cache_manager keys on the resolved URL.
  void setProvider(String name) {
    if (providerNames.contains(name)) _active = name;
  }

  /// Returns the URL to actually request for a stored URL.
  String resolve(String storedUrl) {
    if (storedUrl.isEmpty) return storedUrl;
    if (_active == 'stored') return storedUrl;
    final providers = _config['providers'] as Map<String, dynamic>?;
    final provider = providers?[_active] as Map<String, dynamic>?;
    if (provider == null) return storedUrl;
    final match = _urlTail.firstMatch(storedUrl);
    if (match == null) return storedUrl;
    return _render(provider, folder: match.group(1)!, slug: match.group(2)!);
  }

  /// Ordered list of URLs to try: the active provider first, then the
  /// configured fallbacks, then whatever the database stored.
  List<String> resolveWithFallbacks(String storedUrl) {
    if (storedUrl.isEmpty) return const [];
    final match = _urlTail.firstMatch(storedUrl);
    if (match == null) return [storedUrl];
    final folder = match.group(1)!;
    final slug = match.group(2)!;
    final providers = _config['providers'] as Map<String, dynamic>? ?? {};
    final order = <String>[
      _active,
      ...((_config['fallbackOrder'] as List?)?.cast<String>() ?? const []),
    ];
    final urls = <String>[];
    for (final name in order) {
      final provider = providers[name] as Map<String, dynamic>?;
      if (provider == null) continue;
      final url = _render(provider, folder: folder, slug: slug);
      if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
    }
    if (!urls.contains(storedUrl)) urls.add(storedUrl);
    return urls;
  }

  String _render(Map<String, dynamic> provider,
      {required String folder, required String slug}) {
    var template = provider['template'] as String? ?? '';
    if (template.isEmpty) return '';
    final values = <String, String>{
      for (final e in provider.entries)
        if (e.key != 'template') e.key: '${e.value}',
      'folder': folder,
      'slug': slug,
    };
    values.forEach((key, value) {
      template = template.replaceAll('{$key}', value);
    });
    return template;
  }

  Map<String, dynamic> get updateFeed =>
      (_config['updateFeed'] as Map<String, dynamic>?) ?? const {};
}
