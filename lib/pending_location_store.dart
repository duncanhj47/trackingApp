import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'tracked_location.dart';

class PendingLocation {
  const PendingLocation({
    required this.id,
    required this.vehicleId,
    required this.location,
  });

  final int id;
  final String vehicleId;
  final TrackedLocation location;
}

/// A durable, on-disk queue of locations that failed to send. Survives app
/// restarts — important since a backlog could realistically build up to
/// thousands of entries during an extended outage, and none of that should
/// be lost just because the app got closed in the meantime.
class PendingLocationStore {
  static const _dbName = 'pending_locations.db';
  static const _table = 'pending_locations';

  Database? _db;

  Future<Database> _database() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);
    _db = await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            vehicle_id TEXT NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            accuracy REAL,
            altitude REAL,
            speed REAL,
            poi_note TEXT,
            poi_type TEXT,
            photo_base64 TEXT,
            device_timestamp TEXT NOT NULL,
            cached_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE $_table ADD COLUMN poi_note TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE $_table ADD COLUMN poi_type TEXT');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE $_table ADD COLUMN photo_base64 TEXT');
        }
      },
    );
    return _db!;
  }

  Future<void> add(String vehicleId, TrackedLocation location) async {
    final db = await _database();
    await db.insert(_table, {
      'vehicle_id': vehicleId,
      'lat': location.lat,
      'lon': location.lon,
      'accuracy': location.accuracy,
      'altitude': location.altitude,
      'speed': location.speed,
      'poi_note': location.poiNote,
      'poi_type': location.poiType,
      'photo_base64': location.photoBase64,
      'device_timestamp': location.timestamp.toIso8601String(),
      'cached_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<int> count() async {
    final db = await _database();
    final result = await db.rawQuery('SELECT COUNT(*) as c FROM $_table');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Oldest-first, so a long backlog drains in the order it was recorded.
  Future<List<PendingLocation>> peekOldest({int limit = 50}) async {
    final db = await _database();
    final rows = await db.query(_table, orderBy: 'id ASC', limit: limit);
    return rows.map((row) {
      double? toDouble(Object? v) => v == null ? null : (v as num).toDouble();
      return PendingLocation(
        id: row['id'] as int,
        vehicleId: row['vehicle_id'] as String,
        location: TrackedLocation(
          lat: (row['lat'] as num).toDouble(),
          lon: (row['lon'] as num).toDouble(),
          accuracy: toDouble(row['accuracy']),
          altitude: toDouble(row['altitude']),
          speed: toDouble(row['speed']),
          poiNote: row['poi_note'] as String?,
          poiType: row['poi_type'] as String?,
          photoBase64: row['photo_base64'] as String?,
          timestamp: DateTime.parse(row['device_timestamp'] as String),
        ),
      );
    }).toList();
  }

  Future<void> remove(int id) async {
    final db = await _database();
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }
}
