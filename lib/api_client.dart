import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tracked_location.dart';

/// Posts locations to the already-deployed FastAPI backend
/// (see API_REFERENCE.md — POST /locations).
class ApiClient {
  ApiClient({required this.serverAddress, required this.apiKey});

  final String serverAddress;
  final String apiKey;

  Future<void> postLocation(
    String vehicleId,
    TrackedLocation location, {
    bool wasCached = false,
  }) async {
    final url = Uri.parse('$serverAddress/locations');

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
      },
      body: jsonEncode({
        'vehicle_id': vehicleId,
        'lat': location.lat,
        'lon': location.lon,
        'accuracy': location.accuracy,
        'altitude': location.altitude,
        'speed': location.speed,
        'was_cached': wasCached,
        'poi_note': location.poiNote,
        'poi_type': location.poiType,
        'photo_base64': location.photoBase64,
        'timestamp': location.timestamp.toIso8601String(),
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Server returned ${response.statusCode}: ${response.body}');
    }
  }
}
