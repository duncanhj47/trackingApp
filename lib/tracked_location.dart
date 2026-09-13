/// A single location reading, independent of whether it came from real
/// GPS hardware or the simulator.
class TrackedLocation {
  const TrackedLocation({
    required this.lat,
    required this.lon,
    required this.timestamp,
    this.accuracy,
    this.altitude,
    this.speed,
    this.poiNote,
    this.poiType,
    this.photoBase64,
  });

  final double lat;
  final double lon;
  final DateTime timestamp;
  final double? accuracy;
  final double? altitude;
  final double? speed; // meters per second
  final String? poiNote; // set only for a user-submitted Point of Interest
  final String? poiType; // Campsite / Attraction / Issue / Observation / Note
  final String? photoBase64; // compressed JPEG, base64-encoded, POI photos only
}
