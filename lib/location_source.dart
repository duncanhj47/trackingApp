import 'dart:async';
import 'dart:math';

import 'tracked_location.dart';

/// Common interface so the rest of the app doesn't care whether locations
/// are coming from real GPS hardware or a fake simulator.
abstract class LocationSource {
  Stream<TrackedLocation> get locationStream;

  Future<void> start();
  Future<void> stop();

  /// A one-off reading, independent of the continuous distance-filtered
  /// stream — used for a manual "send current position now" action.
  Future<TrackedLocation> getCurrentPosition();

  /// Release any resources (timers, stream controllers, native listeners).
  void dispose();
}

/// Generates fake movement for development/testing where there's no real
/// GPS — specifically Linux desktop, since Tracelet only implements
/// Android and iOS. Walks outward from a starting point (defaults to
/// Adelaide), emitting a new point every few seconds that's roughly 50-100m
/// from the last one, to mimic crossing a real distance filter threshold.
class SimulatedLocationSource implements LocationSource {
  SimulatedLocationSource({
    double startLat = -34.9285,
    double startLon = 138.6007,
    this.interval = const Duration(seconds: 3),
  })  : _lat = startLat,
        _lon = startLon;

  final Duration interval;
  double _lat;
  double _lon;
  Timer? _timer;
  final _controller = StreamController<TrackedLocation>.broadcast();
  final _random = Random();

  @override
  Stream<TrackedLocation> get locationStream => _controller.stream;

  @override
  Future<void> start() async {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _controller.add(_generatePoint()));
    _controller.add(_generatePoint());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<TrackedLocation> getCurrentPosition() async {
    return _generatePoint();
  }

  TrackedLocation _generatePoint() {
    const metersPerDegreeLat = 111320.0;
    final metersMoved = 50 + _random.nextDouble() * 50;
    final bearing = _random.nextDouble() * 2 * pi;

    final deltaLat = (metersMoved * cos(bearing)) / metersPerDegreeLat;
    final metersPerDegreeLon = metersPerDegreeLat * cos(_lat * pi / 180);
    final deltaLon = (metersMoved * sin(bearing)) / metersPerDegreeLon;

    _lat += deltaLat;
    _lon += deltaLon;

    final simulatedSpeedMs = metersMoved / interval.inSeconds;

    return TrackedLocation(
      lat: _lat,
      lon: _lon,
      accuracy: 5.0,
      altitude: 50.0,
      speed: simulatedSpeedMs,
      timestamp: DateTime.now().toUtc(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
