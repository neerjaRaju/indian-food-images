import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Everything the user creates lives here, in a database that is *never*
/// replaced by the weekly content update. Keeping it separate is what makes a
/// full food-database swap a safe, one-file operation.
class UserDatabase {
  UserDatabase._();

  static final UserDatabase instance = UserDatabase._();

  static const fileName = 'user.db';
  static const version = 3;

  Database? _db;
  Completer<Database>? _opening;

  Database get db {
    final d = _db;
    if (d == null) throw StateError('UserDatabase.open() has not completed');
    return d;
  }

  Future<Database> open() async {
    if (_db != null) return _db!;
    if (_opening != null) return _opening!.future;
    final completer = Completer<Database>();
    _opening = completer;
    try {
      final path = p.join(await getDatabasesPath(), fileName);
      final database = await openDatabase(
        path,
        version: version,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, _) async => _migrate(db, 0, version),
        onUpgrade: (db, from, to) async => _migrate(db, from, to),
      );
      _db = database;
      completer.complete(database);
      return database;
    } catch (error, stack) {
      completer.completeError(error, stack);
      _opening = null;
      rethrow;
    }
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    if (from < 1) {
      await db.execute('''
        CREATE TABLE diary (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          date          TEXT NOT NULL,
          slot          TEXT NOT NULL,
          food_id       INTEGER NOT NULL,
          food_name     TEXT NOT NULL,
          grams         REAL NOT NULL,
          serving_label TEXT NOT NULL DEFAULT '',
          calories      REAL NOT NULL DEFAULT 0,
          protein_g     REAL NOT NULL DEFAULT 0,
          carbs_g       REAL NOT NULL DEFAULT 0,
          fat_g         REAL NOT NULL DEFAULT 0,
          thumbnail_url TEXT NOT NULL DEFAULT '',
          created_at    INTEGER NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX idx_diary_date ON diary(date, slot)');

      await db.execute('''
        CREATE TABLE favorites (
          food_id   INTEGER PRIMARY KEY,
          food_name TEXT NOT NULL DEFAULT '',
          added_at  INTEGER NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE recent_searches (
          term        TEXT PRIMARY KEY,
          searched_at INTEGER NOT NULL,
          hits        INTEGER NOT NULL DEFAULT 0
        )
      ''');

      await db.execute('''
        CREATE TABLE water (
          date TEXT PRIMARY KEY,
          ml   INTEGER NOT NULL DEFAULT 0
        )
      ''');

      await db.execute('''
        CREATE TABLE weight (
          date TEXT PRIMARY KEY,
          kg   REAL NOT NULL,
          note TEXT NOT NULL DEFAULT ''
        )
      ''');

      await db.execute('''
        CREATE TABLE meal_plans (
          id              INTEGER PRIMARY KEY AUTOINCREMENT,
          name            TEXT NOT NULL,
          target_calories INTEGER NOT NULL DEFAULT 2000,
          created_at      INTEGER NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE planned_meals (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          plan_id   INTEGER NOT NULL REFERENCES meal_plans(id) ON DELETE CASCADE,
          day_index INTEGER NOT NULL,
          slot      TEXT NOT NULL,
          food_id   INTEGER NOT NULL,
          food_name TEXT NOT NULL,
          grams     REAL NOT NULL,
          calories  REAL NOT NULL DEFAULT 0
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_planned_plan ON planned_meals(plan_id, day_index)');
    }
    if (from < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS recently_viewed (
          food_id   INTEGER PRIMARY KEY,
          food_name TEXT NOT NULL DEFAULT '',
          viewed_at INTEGER NOT NULL
        )
      ''');
    }
    if (from < 3) {
      // Rewards are granted per feature with an expiry, so a rewarded ad can
      // unlock one thing for a session without becoming a permanent purchase.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS rewards (
          feature    TEXT PRIMARY KEY,
          expires_at INTEGER NOT NULL,
          grants     INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _opening = null;
  }

  /// Deletes user content but keeps the schema — used by "reset app data".
  Future<void> wipe() async {
    final batch = db.batch();
    for (final table in [
      'diary',
      'favorites',
      'recent_searches',
      'water',
      'weight',
      'planned_meals',
      'meal_plans',
      'recently_viewed',
      'rewards',
    ]) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
  }
}
