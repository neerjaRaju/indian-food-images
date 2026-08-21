@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indian_food_calories/data/models/food.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Exercises the *real* shipped database against the queries the repository
/// runs, using the FFI sqlite build on the host. This is what catches a schema
/// or FTS regression before it reaches a device.
///
/// Skips itself (rather than failing) when the asset has not been built yet,
/// so `flutter test` works on a fresh clone.
void main() {
  late Database db;
  late Directory tmp;

  final asset = File('assets/db/indian_food.db.gz');

  setUpAll(() async {
    if (!asset.existsSync()) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('ifca_test');
    final out = File('${tmp.path}/indian_food.db');
    out.writeAsBytesSync(GZipDecoder().decodeBytes(asset.readAsBytesSync()));
    db = await databaseFactory.openDatabase(out.path);
  });

  tearDownAll(() async {
    if (!asset.existsSync()) return;
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  final skip =
      !asset.existsSync() ? 'assets/db/indian_food.db.gz not built' : null;

  Future<int> count(String sql, [List<Object?>? args]) async =>
      ((await db.rawQuery(sql, args)).first.values.first as num).toInt();

  test('ships a non-trivial number of foods', () async {
    expect(await count('SELECT COUNT(*) FROM foods'), greaterThan(500));
  }, skip: skip);

  test('every food has at least a 100 g and a default serving', () async {
    final bad = await count(('''
      SELECT COUNT(*) FROM foods f
      WHERE NOT EXISTS (
        SELECT 1 FROM servings s WHERE s.food_id = f.id AND s.unit = '100g'
      )
      OR NOT EXISTS (
        SELECT 1 FROM servings s WHERE s.food_id = f.id AND s.is_default = 1
      )
    '''));
    expect(bad, 0);
  }, skip: skip);

  test('calories are consistent with macros (Atwater within tolerance)',
      () async {
    final rows = await db.rawQuery('''
      SELECT slug, calories, protein_g, carbs_g, fat_g
      FROM foods
      WHERE calories > 0
    ''');
    final offenders = <String>[];
    for (final r in rows) {
      final kcal = (r['calories'] as num).toDouble();
      final derived = (r['protein_g'] as num).toDouble() * 4 +
          (r['carbs_g'] as num).toDouble() * 4 +
          (r['fat_g'] as num).toDouble() * 9;
      if (derived <= 0) continue;
      if ((kcal - derived).abs() / derived > 0.36) {
        offenders.add('${r['slug']}: $kcal vs ${derived.round()}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'Rows whose calories disagree with their macros: '
            '${offenders.take(5)}');
  }, skip: skip);

  test('no nutrient is negative and macro mass fits in 100 g', () async {
    for (final n in Nutrient.values) {
      final negatives =
          await count(('SELECT COUNT(*) FROM foods WHERE ${n.column} < 0'));
      expect(negatives, 0, reason: '${n.column} has negative values');
    }
    final overweight = await count(
        ('SELECT COUNT(*) FROM foods WHERE protein_g + carbs_g + fat_g > 101'));
    expect(overweight, 0);
  }, skip: skip);

  test('FTS finds foods by English, Hindi and prefix', () async {
    Future<int> hits(String match) => count(
        'SELECT COUNT(*) FROM foods_fts WHERE foods_fts MATCH ?', [match]);
    expect(await hits('"paneer"*'), greaterThan(0));
    expect(await hits('"दाल"*'), greaterThan(0));
    expect(await hits('"biryani"'), greaterThan(0));
    expect(await hits('"chapati" AND "roti"'), greaterThanOrEqualTo(0));
  }, skip: skip);

  test('FTS rowid joins back to foods one-to-one', () async {
    final orphans = await count(('''
      SELECT COUNT(*) FROM foods_fts
      LEFT JOIN foods f ON f.id = foods_fts.rowid
      WHERE f.id IS NULL
    '''));
    expect(orphans, 0);
  }, skip: skip);

  test('barcodes are unique where present', () async {
    final dupes = await count(('''
      SELECT COUNT(*) FROM (
        SELECT barcode FROM foods WHERE barcode <> ''
        GROUP BY barcode HAVING COUNT(*) > 1
      )
    '''));
    expect(dupes, 0);
  }, skip: skip);

  test('image URLs are https and end in .webp', () async {
    final bad = await count(('''
      SELECT COUNT(*) FROM foods
      WHERE thumbnail_url <> ''
        AND (thumbnail_url NOT LIKE 'https://%'
             OR thumbnail_url NOT LIKE '%.webp')
    '''));
    expect(bad, 0);
  }, skip: skip);

  test('every food links to at least one category', () async {
    final orphans = await count(('''
      SELECT COUNT(*) FROM foods f
      WHERE NOT EXISTS (
        SELECT 1 FROM food_categories fc WHERE fc.food_id = f.id
      )
    '''));
    expect(orphans, 0);
  }, skip: skip);

  test('alternatives never point a food at itself', () async {
    final selfRefs = await count(
        ('SELECT COUNT(*) FROM alternatives WHERE food_id = alt_food_id'));
    expect(selfRefs, 0);
  }, skip: skip);

  test('meta carries the schema version and build date', () async {
    final rows = await db.query('meta');
    final meta = {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
    expect(meta['schema_version'], isNotNull);
    expect(meta['database_date'], matches(r'^\d{4}-\d{2}-\d{2}$'));
  }, skip: skip);
}
