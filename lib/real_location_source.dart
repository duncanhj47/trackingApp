import 'dart:async';
import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:tracelet/tracelet.dart' as tl;

import 'app_log_store.dart';
import 'location_source.dart';
import 'tracked_location.dart';

/// Runs once from main(), before runApp() — see call site there. Lets
/// Tracelet deliver events (heartbeats included) even while the app is
/// fully headless (killed, not yet reopened). Without this, any event
/// fired in that state is silently dropped — visible in past logs as
/// "headless: no callbacks registered — dropping 1 queued event(s)",
/// which shows up repeatedly in real sessions, so this was already a
/// live gap independent of the heartbeat feature below.
///
/// Deliberately minimal: it only exists to stop that drop from happening.
/// It does NOT currently also stamp the heartbeat SharedPreferences key
/// the way the foreground onHeartbeat listener below does — that would
/// need matching HeadlessEvent.name against the correct heartbeat
/// identifier, and unlike everything else in this file, I don't have a
/// confirmed source for that exact value. Left as a known gap rather than
/// a guess that might silently never match.
@pragma('vm:entry-point')
void _traceletHeadlessTask(tl.HeadlessEvent event) {}

/// Call once from main(), before runApp().
void registerTraceletHeadlessTask() {
  tl.Tracelet.registerHeadlessTask(_traceletHeadlessTask);
}

/// A one-line snapshot of Tracelet's current state, formatted the same
/// way the heartbeat log line is, so entries using this and heartbeat
/// entries can be compared directly. Returns a plain message even on
/// error rather than throwing — this exists specifically to help
/// investigate failures, so a failed diagnostic read should never itself
/// disappear silently.
Future<String> traceletStateSnapshot() async {
  try {
    final state = await tl.Tracelet.getState();
    return 'engineEnabled=${state.enabled}, trackingMode=${state.trackingMode}, '
        'odometer=${state.odometer.toStringAsFixed(0)}m';
  } catch (e) {
    return 'could not read Tracelet state: $e';
  }
}

/// SharedPreferences keys the Diagnostics page reads to show "last
/// heartbeat" — kept here, next to what writes them, rather than
/// scattered as string literals in the UI file.
const heartbeatTimestampPrefsKey = 'tracelet_last_heartbeat_utc';
const heartbeatCountPrefsKey = 'tracelet_heartbeat_count';
const heartbeatIsMovingPrefsKey = 'tracelet_last_heartbeat_is_moving';

/// Whether the user's last explicit action was to start tracking — set by
/// _toggleTracking() in main.dart, read on cold start. Separate from the
/// widget's own ephemeral `_tracking` bool, which resets to false by
/// construction on every fresh process, telling you nothing about what
/// was actually intended.
const trackingIntentPrefsKey = 'tracking_intent';

/// Real GPS-backed location source for Android/iOS, using the Tracelet
/// background geolocation plugin. Not available on Linux desktop — Tracelet
/// only ships Android and iOS implementations, which is exactly why
/// SimulatedLocationSource exists for development on this machine.
class TraceletLocationSource implements LocationSource {
  TraceletLocationSource({AppLogStore? appLog}) : _appLog = appLog;

  final AppLogStore? _appLog;
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
      // Added 2026-09-17 (SLC redesign). Any location arriving while
      // nominally parked in low-power mode is itself independent proof
      // of movement — significant-change monitoring only ever delivers
      // on a real cell-tower handoff, so this doesn't depend on trusting
      // the accelerometer-based onMotionChange classifier, which is the
      // exact thing that failed silently for over an hour on 2026-09-16.
      if (_inLowPowerMode) {
        _exitLowPowerMode('a location arrived while in low-power mode');
      }
      _controller.add(_toTrackedLocation(location));
    });

    // Drives the parked/moving mode switch below. This is the *other*
    // half of the cross-check — two independent signals (the
    // accelerometer here, cell-tower handoffs via onLocation above) now
    // both have to fail at the same time for a departure to go unnoticed,
    // instead of relying on the accelerometer alone.
    tl.Tracelet.onMotionChange((tl.Location location) {
      if (location.isMoving) {
        _exitLowPowerMode('onMotionChange reported isMoving=true');
      } else {
        _enterLowPowerMode();
      }
    });

    // Added 2026-09-14 as a proof-of-life signal for the exact failure
    // mode chased all day: a long stationary stretch where the engine
    // goes silent with no crash, no OS kill event, nothing. Per Tracelet's
    // own (FBG-derived) docs, this ONLY fires while stationary — it says
    // nothing while driving, which is fine, since continuous location
    // updates already prove liveness then. On iOS it's also documented to
    // require preventSuspend: true to deliver in the background at all,
    // which is why this is only being added now that that's on — and
    // even with it on, iOS may still throttle the cadence somewhat once
    // unplugged with the screen off for a long stretch, so treat a
    // missed beat or two as a yellow flag, not an instant red one.
    //
    // event.location.isMoving reflects the motion detector's current
    // verdict — Tracelet's own docs note the coordinates on this location
    // can be stale if no fresh GPS fix has come in while stationary, but
    // isMoving itself is the live motion-state read, not a GPS fix.
    //
    // Also pulls a fresh Tracelet.getState() alongside — enabled,
    // trackingMode, odometer — and writes the whole picture into the
    // app's own independent log (app_log_store.dart), not just
    // SharedPreferences. getState() is the same genuinely read-only call
    // used by isTracking() above; safe to call here too.
    tl.Tracelet.onHeartbeat((tl.HeartbeatEvent event) async {
      final prefs = await SharedPreferences.getInstance();
      final count = (prefs.getInt(heartbeatCountPrefsKey) ?? 0) + 1;
      await prefs.setString(
          heartbeatTimestampPrefsKey, DateTime.now().toUtc().toIso8601String());
      await prefs.setInt(heartbeatCountPrefsKey, count);
      await prefs.setBool(heartbeatIsMovingPrefsKey, event.location.isMoving);

      final state = await tl.Tracelet.getState();
      await _appLog?.add(
        'Tracelet heartbeat — isMoving=${event.location.isMoving}, '
        'engineEnabled=${state.enabled}, trackingMode=${state.trackingMode}, '
        'odometer=${state.odometer.toStringAsFixed(0)}m',
      );
    });

    await tl.Tracelet.ready(_buildConfig());
    _ready = true;
  }

  /// True while running in significant-change-only mode (confirmed
  /// parked). See isInLowPowerMode below for the public-facing read of
  /// this, and _enterLowPowerMode/_exitLowPowerMode for the only two
  /// places it changes.
  bool _inLowPowerMode = false;

  @override
  bool get isInLowPowerMode => _inLowPowerMode;

  /// Switches to near-zero-power significant-change monitoring —
  /// cell-tower handoffs only, no continuous GPS, no motion-detection
  /// pipeline running. Added 2026-09-17 to replace the periodic
  /// forced-restart approach for the stationary case: that approach was
  /// found to be actively counterproductive (see _buildConfig below and
  /// main.dart's force-restart gating) — it never let the engine run
  /// long enough uninterrupted to complete a heartbeat or acquire a real
  /// fix. This asks nothing of the engine at all while parked, so there's
  /// nothing to starve.
  ///
  /// Always sends a COMPLETE config via setConfig(), never a partial one.
  /// Tracelet's own changelog documents a real, if since-fixed, bug where
  /// a partial setConfig() on iOS silently reset other fields — including
  /// preventSuspend — back to their defaults. Sending the full config
  /// every time sidesteps that class of bug regardless of which Tracelet
  /// version this is running against.
  Future<void> _enterLowPowerMode() async {
    // Added 2026-09-19. This whole mechanism exists to solve an
    // iOS-specific problem — Android already handles the equivalent job
    // (saving power while stationary, resuming cleanly on movement) via
    // enableAdaptiveMode + releaseWakelockWhenStationary, proven reliable
    // for weeks with none of this. Without this guard, every parked↔moving
    // transition on Android would also call setConfig() below, which
    // Tracelet's own docs describe as restarting the tracking pipeline for
    // at least some field changes — an unverified, unnecessary risk to a
    // platform that never asked for it and was never broken.
    if (Platform.isAndroid) return;
    if (_inLowPowerMode) return;
    _inLowPowerMode = true;
    await tl.Tracelet.setConfig(_buildConfig(useSignificantChangesOnly: true));
    await _appLog?.add(
      'Entered low-power (significant-change-only) mode — confirmed parked',
    );
  }

  /// Restores full continuous GPS + motion detection. Called from either
  /// independent trigger above — whichever notices movement first wins,
  /// and calling this twice in a row is harmless (guarded by
  /// _inLowPowerMode already being false on the second call).
  Future<void> _exitLowPowerMode(String reason) async {
    // Symmetric guard with _enterLowPowerMode above — not strictly
    // reachable on Android since _inLowPowerMode can never become true
    // there, but kept explicit rather than relying on that indirectly.
    if (Platform.isAndroid) return;
    if (!_inLowPowerMode) return;
    _inLowPowerMode = false;
    await tl.Tracelet.setConfig(_buildConfig(useSignificantChangesOnly: false));
    await _appLog?.add('Exited low-power mode — $reason');
  }

  /// Extracted out of `_ensureReady()` purely so the giant literal below
  /// isn't buried inline. Now also the single place that builds a config
  /// for the low-power mode switch above — always called with every
  /// field explicit, never partial, for the reason explained on
  /// _enterLowPowerMode.
  tl.Config _buildConfig({bool useSignificantChangesOnly = false}) {
    return tl.Config(
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
        // 5 minutes. Fires only while stationary — see the onHeartbeat
        // registration above for what this actually enables and why.
        // NOTE (2026-09-17): found to conflict with the periodic forced
        // restart when that was set to 2 minutes — a restart cycle
        // shorter than this interval never lets a heartbeat complete.
        // See main.dart's force-restart gating, which now skips firing
        // entirely while isInLowPowerMode is true.
        heartbeatInterval: 300,
      ),
      android: const tl.AndroidConfig(
        // Drops the partial wakelock while stationary, re-asserts it on
        // movement — a targeted saving for long parked/idle stretches.
        releaseWakelockWhenStationary: true,
      ),
      ios: tl.IosConfig(
        // Added 2026-09-14 after a real, fully-charged, never-force-quit
        // session went completely silent from 07:07 to 15:49 — no crash
        // log, no Jetsam event, no reboot. Every mechanical explanation
        // with a trace was ruled out; what's left is iOS's own background
        // execution budget quietly declining to wake the app that day,
        // which by design leaves nothing for any log to see. This plays
        // silent audio to make the app look actively in-use, which is
        // the documented, direct countermeasure — at a real, ongoing
        // battery cost. Requires the "Audio, AirPlay, and Picture in
        // Picture" Background Mode capability (see Info.plist).
        preventSuspend: true,
        // Added 2026-09-17. Cell-tower/Wi-Fi handoffs only, near-zero
        // battery, and — unlike everything else tried so far — an actual
        // Apple-documented guarantee: one of the few mechanisms that can
        // relaunch a fully TERMINATED app, not just resume a backgrounded
        // one. Toggled by _enterLowPowerMode/_exitLowPowerMode above,
        // never set permanently true, since left on it would give only a
        // 500m-1km resolution — fine as a parked-state wake mechanism,
        // useless as the app's only means of recording an actual drive.
        useSignificantChangesOnly: useSignificantChangesOnly,
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
        // indefinitely with no EXIT ever evaluated. Confirmed via the
        // API reference to run continuous GPS for as long as tracking is
        // active (not just while stationary) — see the battery-budget
        // and point-density discussion elsewhere before changing this.
        geofenceModeHighAccuracy: true,
      ),
    );
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

  /// Asks the native engine whether it's *actually* tracking right now,
  /// rather than trusting whatever this Dart object last assumed. Needed
  /// because native background tracking (or a native-side stop) can
  /// happen independently of this object's lifecycle — in particular, iOS
  /// killing and relaunching the app after a long backgrounded stretch
  /// produces a brand-new TraceletLocationSource with no memory of what
  /// was true before.
  ///
  /// CORRECTED: this previously re-called `Tracelet.ready()` to force a
  /// fresh read, on the unverified assumption that ready() was inert when
  /// called mid-session — it isn't confirmed to be, and calling it on
  /// every single foreground event is the likely cause of the
  /// back-to-back duplicate start()/ready() calls (and the logging outage
  /// that followed) seen on 2026-09-14. getState() is the actual
  /// purpose-built tool here: genuinely read-only, no config involved,
  /// and documented as safe to call even before ready() has ever run.
  @override
  Future<bool> isTracking() async {
    final state = await tl.Tracelet.getState();
    return state.enabled;
  }

  @override
  void dispose() {
    _controller.close();
  }
}
