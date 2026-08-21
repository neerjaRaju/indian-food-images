import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Opens the read-only food database that ships with the APK (gzipped) and can
/// be replaced at runtime by a newer download.
///
/// Design notes:
///  * The asset is stored gzipped so the APK stays small; it is inflated once
///    on first launch into the app's support directory.
///  * A downloaded update is staged next to the live file and swapped in
///    atomically on the next open, so a half-finished download can never
///    corrupt the working database.
///  * The file is opened read-only with WAL disabled — nothing writes to it, so
///    the extra journal files would be dead weight on device.
class FoodDatabase {
  FoodDatabase._();

  static final FoodDatabase instance = FoodDatabase._();

  static const assetPath = 'assets/db/indian_food.db.gz';
  static const fileName = 'indian_food.db';
  static const stagedSuffix = '.staged';

  Database? _db;
  Completer<Database>? _opening;

  Database get db {
    final d = _db;
    if (d == null) {
      throw StateError('FoodDatabase.open() must complete before use');
    }
    return d;
  }

  bool get isOpen => _db != null;

  Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    final target = Directory(p.join(dir.path, 'db'));
    if (!target.existsSync()) target.createSync(recursive: true);
    return target;
  }

  Future<File> databaseFile() async =>
      File(p.join((await _dir()).path, fileName));

  Future<File> stagedFile() async =>
      File(p.join((await _dir()).path, '$fileName$stagedSuffix'));

  /// Opens the database, extracting the bundled asset on first run and
  /// promoting any staged update that finished downloading.
  Future<Database> open() async {
    if (_db != null) return _db!;
    if (_opening != null) return _opening!.future;
    final completer = Completer<Database>();
    _opening = completer;
    try {
      final file = await databaseFile();
      await _promoteStagedUpdate(file);
      if (!file.existsSync() || file.lengthSync() == 0) {
        await _extractBundledAsset(file);
      }
      final database = await _openFile(file);
      _db = database;
      completer.complete(database);
      return database;
    } catch (error, stack) {
      completer.completeError(error, stack);
      _opening = null;
      rethrow;
    }
  }

  Future<Database> _openFile(File file) async {
    return openDatabase(
      file.path,
      readOnly: true,
      singleInstance: true,
      onConfigure: (db) async {
        // Read-only handle: no journal, no foreign key enforcement cost.
        await db.rawQuery('PRAGMA temp_store = MEMORY');
        await db.rawQuery('PRAGMA cache_size = -8000'); // ~8 MB page cache
        await db.rawQuery('PRAGMA mmap_size = 67108864');
      },
    );
  }

  Future<void> _extractBundledAsset(File target) async {
    final data = await rootBundle.load(assetPath);
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final inflated = await compute(_gunzip, bytes);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(inflated, flush: true);
    await tmp.rename(target.path);
    debugPrint(
        'FoodDatabase: extracted ${inflated.length ~/ 1024} KB from asset');
  }

  Future<void> _promoteStagedUpdate(File live) async {
    final staged = await stagedFile();
    if (!staged.existsSync()) return;
    if (staged.lengthSync() < 1024) {
      await staged.delete();
      return;
    }
    await close();
    if (live.existsSync()) {
      await live.delete();
    }
    await staged.rename(live.path);
    debugPrint('FoodDatabase: promoted staged update');
  }

  /// Writes a downloaded (already inflated) database next to the live one.
  /// It becomes active on the next app start — never mid-session, so open
  /// cursors and the current screen stay valid.
  Future<void> stageUpdate(List<int> inflatedBytes) async {
    final staged = await stagedFile();
    final tmp = File('${staged.path}.part');
    await tmp.writeAsBytes(inflatedBytes, flush: true);
    if (staged.existsSync()) await staged.delete();
    await tmp.rename(staged.path);
  }

  Future<Map<String, String>> meta() async {
    final rows = await db.query('meta');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  Future<int> foodCount() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM foods')) ??
      0;

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _opening = null;
  }
}

Uint8List _gunzip(Uint8List bytes) =>
    Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
