import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppLogEntry {
  const AppLogEntry({
    required this.id,
    required this.message,
    required this.timestampUtc,
  });

  final int id;
  final String message;
  final DateTime timestampUtc;
}

/// A durable, on-disk log of the app's own activity — deliberately separate
/// from Tracelet's log store (Tracelet.getLogs()) and from its heartbeat
/// (which only proves Tracelet's own engine is alive, only while it
/// considers itself stationary). This proves the Flutter app's Dart
/// isolate itself is being scheduled at all, on a clock this app owns
/// end to end, independent of anything Tracelet-side.
///
/// Same on-disk pattern as PendingLocationStore — a lazily-opened sqflite
/// database, its own file so it never competes with Tracelet's or that
/// store's schema.
///
/// Important limitation, stated plainly rather than left implicit: this
/// can only record an entry while the Dart isolate is actually running.
/// If iOS suspends the app outright, nothing here fires — no workaround
/// exists for that in pure Dart. That's not a flaw in this design, it's
/// the point: a gap in this log, on a phone that was on the whole time
/// and never rebooted, IS the evidence — it pinpoints exactly when the
/// app's own process stopped being scheduled, which nothing else in this
/// project currently shows directly.
class AppLogStore {
  static const _dbName = 'app_log.db';
  static const _table = 'app_log';

  // Keep the table from growing forever — this is meant to run
  // indefinitely, unlike PendingLocationStore, which naturally drains via
  // successful sends. Generous enough to hold weeks of 5-minute pulses
  // plus lifecycle transitions without needing to think about it.
  static const _maxRows = 5000;

  Database? _db;

  Future<Database> _database() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message TEXT NOT NULL,
            timestamp_utc TEXT NOT NULL
          )
        ''');
      },
    );
    return _db!;
  }

  Future<void> add(String message) async {
    final db = await _database();
    await db.insert(_table, {
      'message': message,
      'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
    });
    await _pruneIfNeeded(db);
  }

  Future<void> _pruneIfNeeded(Database db) async {
    final result = await db.rawQuery('SELECT COUNT(*) as c FROM $_table');
    final count = (result.first['c'] as int?) ?? 0;
    if (count <= _maxRows) return;
    // Delete everything except the newest _maxRows rows.
    await db.rawDelete('''
      DELETE FROM $_table WHERE id NOT IN (
        SELECT id FROM $_table ORDER BY id DESC LIMIT $_maxRows
      )
    ''');
  }

  /// Newest first, matching how the Tracelet log viewer already reads.
  Future<List<AppLogEntry>> recent({int limit = 1000}) async {
    final db = await _database();
    final rows = await db.query(_table, orderBy: 'id DESC', limit: limit);
    return rows
        .map((row) => AppLogEntry(
              id: row['id'] as int,
              message: row['message'] as String,
              timestampUtc: DateTime.parse(row['timestamp_utc'] as String),
            ))
        .toList();
  }

  Future<void> clear() async {
    final db = await _database();
    await db.delete(_table);
  }
}
