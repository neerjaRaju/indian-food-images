import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db/food_database.dart';
import 'image_hosting_service.dart';
import 'preferences_service.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.releaseDate,
    required this.foodCount,
    required this.imageCount,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sha256,
    required this.notes,
  });

  final String releaseDate;
  final int foodCount;
  final int imageCount;
  final String downloadUrl;
  final int sizeBytes;
  final String sha256;
  final String notes;

  double get sizeMb => sizeBytes / (1024 * 1024);
}

enum UpdateStage { idle, checking, downloading, verifying, staged, failed }

/// Checks the GitHub Releases feed for a newer food database, downloads the
/// gzipped file, verifies its SHA-256, and stages it for the next app start.
///
/// The download never touches the live database — see [FoodDatabase.stageUpdate].
class DatabaseUpdateService extends ChangeNotifier {
  DatabaseUpdateService(this._prefs, {http.Client? client})
      : _client = client ?? http.Client();

  final PreferencesService _prefs;
  final http.Client _client;

  UpdateStage _stage = UpdateStage.idle;
  double _progress = 0;
  String _error = '';
  UpdateInfo? _available;

  UpdateStage get stage => _stage;
  double get progress => _progress;
  String get error => _error;
  UpdateInfo? get available => _available;
  bool get busy =>
      _stage == UpdateStage.checking ||
      _stage == UpdateStage.downloading ||
      _stage == UpdateStage.verifying;

  static const checkInterval = Duration(days: 3);

  void _set(UpdateStage stage, {double? progress, String error = ''}) {
    _stage = stage;
    if (progress != null) _progress = progress;
    _error = error;
    notifyListeners();
  }

  /// Called on app start. Returns true when an update was found.
  Future<bool> checkIfDue({bool force = false}) async {
    if (!force) {
      if (!_prefs.autoUpdateDatabase) return false;
      final last = _prefs.lastUpdateCheck;
      if (last != null && DateTime.now().difference(last) < checkInterval) {
        return false;
      }
    }
    return check();
  }

  Future<bool> check() async {
    _set(UpdateStage.checking, progress: 0);
    try {
      final feed = ImageHostingService.instance.updateFeed;
      final owner = feed['owner'] as String? ?? '';
      final repo = feed['repo'] as String? ?? '';
      final template = feed['releasesApi'] as String? ?? '';
      if (owner.isEmpty || owner == 'CHANGE_ME' || template.isEmpty) {
        _set(UpdateStage.idle);
        return false;
      }
      final url =
          template.replaceAll('{owner}', owner).replaceAll('{repo}', repo);
      final response = await _client.get(
        Uri.parse(url),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        _set(UpdateStage.idle);
        return false;
      }
      final release = jsonDecode(response.body) as Map<String, dynamic>;
      final assets = (release['assets'] as List?) ?? const [];
      final dbName = feed['assetName'] as String? ?? 'indian_food.db.gz';
      final metaName = feed['metadataAsset'] as String? ?? 'metadata.json';

      Map<String, dynamic>? assetByName(String name) {
        for (final a in assets) {
          if (a is Map<String, dynamic> && a['name'] == name) return a;
        }
        return null;
      }

      final dbAsset = assetByName(dbName);
      if (dbAsset == null) {
        _set(UpdateStage.idle);
        return false;
      }
      var releaseDate =
          (release['published_at'] as String? ?? '').split('T').first;
      var foodCount = 0;
      var imageCount = 0;
      var sha = '';
      final metaAsset = assetByName(metaName);
      if (metaAsset != null) {
        try {
          final metaResponse = await _client
              .get(Uri.parse(metaAsset['browser_download_url'] as String))
              .timeout(const Duration(seconds: 20));
          final meta = jsonDecode(metaResponse.body) as Map<String, dynamic>;
          releaseDate = meta['release_date'] as String? ?? releaseDate;
          foodCount = (meta['food_count'] as num?)?.toInt() ?? 0;
          imageCount = (meta['image_count'] as num?)?.toInt() ?? 0;
          sha = meta['database_sha256'] as String? ?? '';
        } catch (_) {
          // Metadata is a nicety; the download still works without it.
        }
      }

      final installed = _prefs.installedDbDate;
      await _prefs.markUpdateChecked();
      if (installed.isNotEmpty && releaseDate.compareTo(installed) <= 0) {
        _available = null;
        _set(UpdateStage.idle);
        return false;
      }
      _available = UpdateInfo(
        releaseDate: releaseDate,
        foodCount: foodCount,
        imageCount: imageCount,
        downloadUrl: dbAsset['browser_download_url'] as String,
        sizeBytes: (dbAsset['size'] as num?)?.toInt() ?? 0,
        sha256: sha,
        notes: release['body'] as String? ?? '',
      );
      _set(UpdateStage.idle);
      return true;
    } catch (e) {
      _set(UpdateStage.failed, error: 'Could not check for updates: $e');
      return false;
    }
  }

  /// Downloads and stages the update. The new data becomes visible on the next
  /// app launch, which is also when the old file is deleted.
  Future<bool> download() async {
    final info = _available;
    if (info == null) return false;
    _set(UpdateStage.downloading, progress: 0);
    try {
      final request = http.Request('GET', Uri.parse(info.downloadUrl));
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        _set(UpdateStage.failed,
            error: 'Download failed (${response.statusCode})');
        return false;
      }
      final total = response.contentLength ?? info.sizeBytes;
      final chunks = <int>[];
      var received = 0;
      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
        received += chunk.length;
        if (total > 0) {
          _set(UpdateStage.downloading, progress: received / total);
        }
      }
      _set(UpdateStage.verifying, progress: 1);
      final inflated = await compute(_inflate, Uint8List.fromList(chunks));
      if (info.sha256.isNotEmpty) {
        final digest = sha256.convert(inflated).toString();
        if (digest != info.sha256) {
          _set(UpdateStage.failed,
              error: 'Checksum mismatch — the download was discarded.');
          return false;
        }
      }
      await FoodDatabase.instance.stageUpdate(inflated);
      await _prefs.setInstalledDbDate(info.releaseDate);
      _set(UpdateStage.staged, progress: 1);
      return true;
    } catch (e) {
      _set(UpdateStage.failed, error: 'Update failed: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

Uint8List _inflate(Uint8List bytes) =>
    Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
