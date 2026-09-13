import 'dart:async';

import 'package:tracelet/tracelet.dart' as tl;

import 'location_source.dart';
import 'tracked_location.dart';

/// Real GPS-backed location source for Android/iOS, using the Tracelet
/// background geolocation plugin. Not available on Linux desktop — Tracelet
/// only ships Android and iOS implementations, which is exactly why
/// SimulatedLocationSource exists for development on this machine.
class TraceletLocationSource implements LocationSource {
  final _controller = StreamController<TrackedLocation>.broadcast();
  bool _ready = false;

  @override
  Stream<TrackedLocation> get locationStream => _controller.stream;

  /// "ready" (one-time init/config) is distinct from "start" (begin
  /// continuous background tracking) — a one-shot getCurrentPosition()
  /// only needs the former, not the latter.
  Future<void> _ensureReady() async {
    if (_ready) return;

    tl.Tracelet.onLocation((tl.Location location) {
      _controller.add(_toTrackedLocation(location));
    });

    await tl.Tracelet.ready(tl.Config(
      geo: tl.GeoConfig(
        desiredAccuracy: tl.DesiredAccuracy.high,
        distanceFilter: 50.0, // meters
        // Automatically reduces GPS polling when stationary or battery is
        // low, increases resolution while actually driving — added after
        // a real Tracelet Doctor export confirmed this Samsung device has
        // an aggressive OEM battery-management rating (4) and this wasn't
        // yet turned on.
        enableAdaptiveMode: true,
        // Target ~2% battery drain per hour from tracking — the adaptive
        // sampling engine throttles accuracy/frequency to try to stay
        // under this. Chosen as a moderate middle ground since whether
        // the phone is charging during a drive varies; tight enough to
        // protect multi-day unplugged use, loose enough not to visibly
        // degrade tracking on drives where it is charging.
        batteryBudgetPerHour: 2.0,
      ),
      app: const tl.AppConfig(
        stopOnTerminate: false,
        startOnBoot: true,
      ),
      android: const tl.AndroidConfig(
        // Drops the partial wakelock while stationary, re-asserts it on
        // movement — a targeted saving for long parked/idle stretches.
        releaseWakelockWhenStationary: true,
      ),
      http: const tl.HttpConfig(
        // We never use Tracelet's own native sync — ApiClient and
        // PendingLocationStore handle all real sync/retry ourselves.
        // Leaving this on was causing repeated "No SyncProvider
        // registered" failures, and raised a real question: does
        // maxDaysToPersist purge records regardless of sync status, or
        // only after a successful sync? Since Tracelet's own sync can
        // never succeed for us, that ambiguity could mean records
        // accumulate forever rather than being purged after 3 days.
        // Disabling it outright removes the question entirely.
        autoSync: false,
      ),
      geofence: const tl.GeofenceConfig(
        // Added after two real drives (parked ~40min, then drove home)
        // failed to resume tracking on the return leg. Tracelet's own
        // changelog describes exactly this symptom: the stationary
        // geofence's ENTER fires correctly on parking, but without
        // high-accuracy mode, the EXIT transition can fail to fire at
        // all — the same distanceFilter that controls how often points
        // get saved was also gating the fixes needed to detect leaving
        // the zone, so a parked device could sit inside the geofence
        // indefinitely with no EXIT ever evaluated. This field's exact
        // Dart nesting is inferred from Tracelet's own diagnostic JSON
        // export (a "geofence" group containing this exact field name),
        // not independently verified against the package's Dart API —
        // worth confirming it compiles before assuming it's correct.
        geofenceModeHighAccuracy: true,
      ),
    ));
    _ready = true;
  }

  TrackedLocation _toTrackedLocation(tl.Location location) {
    return TrackedLocation(
      lat: location.coords.latitude,
      lon: location.coords.longitude,
      accuracy: location.coords.accuracy,
      altitude: location.coords.altitude,
      speed: location.coords.speed,
      timestamp: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> start() async {
    await _ensureReady();
    await tl.Tracelet.start();
  }

  @override
  Future<void> stop() async {
    // Pause continuous tracking only — do NOT dispose/tear down here, since
    // the same instance needs to survive a later Start Tracking or a manual
    // "send now" without re-initializing from scratch.
    await tl.Tracelet.stop();
  }

  @override
  Future<TrackedLocation> getCurrentPosition() async {
    await _ensureReady();
    final location = await tl.Tracelet.getCurrentPosition();
    return _toTrackedLocation(location);
  }

  @override
  void dispose() {
    _controller.close();
  }
}
