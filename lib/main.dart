import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'api_client.dart';
import 'app_log_store.dart';
import 'diagnostics_page.dart';
import 'location_source.dart';
import 'pending_location_store.dart';
import 'real_location_source.dart';
import 'settings_page.dart';
import 'tracked_location.dart';

void main() {
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Must run before runApp() per Tracelet's docs. Guarded the same way
  // _createLocationSource() picks the simulator — Tracelet has no Linux
  // implementation, so this would have nothing to register against there.
  if (!Platform.isLinux) {
    registerTraceletHeadlessTask();
  }

  runApp(const VehicleTrackerApp());
}

class VehicleTrackerApp extends StatelessWidget {
  const VehicleTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Duncan Tracking',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF3F4F6),
      ),
      home: const TrackerHomePage(),
    );
  }
}

class TrackerHomePage extends StatefulWidget {
  const TrackerHomePage({super.key});

  @override
  State<TrackerHomePage> createState() => _TrackerHomePageState();
}

class _TrackerHomePageState extends State<TrackerHomePage>
    with WidgetsBindingObserver {
  String? _fleetId;
  String _serverAddress = defaultServerAddress;
  String? _apiKey;

  // Created once and reused for the app's whole lifetime — NOT recreated
  // on every Start Tracking press, and its stream is listened to exactly
  // once, to avoid double-handling locations on repeated start/stop cycles.
  LocationSource? _locationSource;
  bool _tracking = false;
  TrackedLocation? _lastLocation;
  String _lastSendStatus = 'Not sent yet';

  final _pendingStore = PendingLocationStore();
  int _pendingCount = 0;
  int _totalSentCount = 0;
  Timer? _flushTimer;

  // Independent of Tracelet entirely — see app_log_store.dart. Proves this
  // app's own Dart isolate is being scheduled at all, on a clock this app
  // owns end to end.
  final _appLogStore = AppLogStore();
  Timer? _appPulseTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _updatePendingCount();
    _flushTimer = Timer.periodic(const Duration(seconds: 20), (_) => _flushQueue());
    _requestNotificationPermissionOnce();
    // Cold start (including iOS relaunching the app after killing it in
    // the background) — this widget's own `_tracking = false` default is
    // just a guess until checked against what the native engine is
    // actually doing.
    _resumeTrackingIfIntended();

    _appLogStore.add('App launched');
    _appPulseTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _recordAppPulse(),
    );
  }

  /// Cold-start recovery. Different from the foreground-resume check
  /// below (didChangeAppLifecycleState), which just reads Tracelet's
  /// current state — this is specifically for a genuine process kill.
  ///
  /// Found 2026-09-14 → 2026-09-15 overnight: on a true cold start,
  /// isTracking()'s getState() call came back with a blank default
  /// (engineEnabled=false, odometer=0) rather than the real persisted
  /// session — Tracelet's own log confirmed ready()/start() were never
  /// called again in that fresh process at all. That was very likely
  /// caused by my own earlier change to isTracking() (removing its
  /// _ensureReady() call to fix a different, real problem — repeated
  /// ready() calls on ordinary foreground events). This restores that
  /// re-initialization, but only for a genuine cold start, specifically
  /// to avoid reintroducing the problem that first fix solved.
  ///
  /// Persisted intent, not the ephemeral `_tracking` bool, is what's
  /// checked here — `_tracking` resets to false by construction on every
  /// fresh process and would tell us nothing about what was intended.
  Future<void> _resumeTrackingIfIntended() async {
    if (Platform.isLinux) {
      await _syncTrackingStateFromNative();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final intendedTracking = prefs.getBool(trackingIntentPrefsKey) ?? false;

    if (!intendedTracking) {
      await _syncTrackingStateFromNative();
      return;
    }

    await _ensureLocationSource();
    final actuallyTracking = await _locationSource!.isTracking();
    if (actuallyTracking) {
      // A session that genuinely survived the relaunch — just confirm
      // the UI, nothing to resume.
      if (mounted) setState(() => _tracking = true);
      return;
    }

    _appLogStore.add(
      'Cold start: intent was tracking=true but native reported false — '
      'calling start() to actively resume rather than mirroring blank state',
    );
    await _locationSource!.start();
    if (mounted) setState(() => _tracking = true);
  }

  /// The independent "is the app itself still alive" signal requested
  /// separately from Tracelet's own heartbeat. Records current tracking
  /// status as cheap, useful context — not because this depends on
  /// Tracelet in any way, just because "was the app alive AND did it
  /// still think it was tracking" is more useful than "was the app alive"
  /// alone, at zero extra cost.
  ///
  /// Stated plainly: this can only fire while the Dart isolate is
  /// actually running. A gap in this log on a phone that stayed on the
  /// whole time IS the finding — it pinpoints exactly when the app's own
  /// process stopped being scheduled, independent of anything Tracelet
  /// reports about itself.
  void _recordAppPulse() {
    _appLogStore.add('Pulse — tracking=$_tracking');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      // How long since this app's own log last wrote anything —
      // directly measures how long the Dart isolate itself was frozen,
      // independent of whatever Tracelet reports about its own engine.
      // Read BEFORE adding this resume's own entry, or it would just
      // measure itself.
      final priorEntries = await _appLogStore.recent(limit: 1);
      if (priorEntries.isNotEmpty) {
        final gap = DateTime.now()
            .toUtc()
            .difference(priorEntries.first.timestampUtc);
        _appLogStore.add(
            'Lifecycle: resumed — ${_formatDuration(gap)} since last app-log entry');
      } else {
        _appLogStore.add('Lifecycle: resumed');
      }

      // A second, independent measurement: how long since Tracelet's own
      // engine last proved life via a heartbeat. This can legitimately
      // be long while driving (heartbeat is stationary-only) — read it
      // alongside the state snapshot below, not in isolation.
      final prefs = await SharedPreferences.getInstance();
      final lastHeartbeatUtc = prefs.getString(heartbeatTimestampPrefsKey);
      if (lastHeartbeatUtc != null) {
        final beatGap = DateTime.now()
            .toUtc()
            .difference(DateTime.parse(lastHeartbeatUtc));
        _appLogStore
            .add('Time since last Tracelet heartbeat: ${_formatDuration(beatGap)}');
      }

      await _logTraceletSnapshot('Resumed, Tracelet state');

      // Coming back to the foreground doesn't necessarily mean the
      // process was killed — but it's exactly the moment a native-side
      // change (an OS-level stop, a background failure, or a
      // kill-and-relaunch that happened while the screen was off) would
      // otherwise go unnoticed until the next button press. This is the
      // fix for "brought it forward and the button said Start Tracking,
      // but I never touched it".
      await _syncTrackingStateFromNative();
    } else {
      _appLogStore.add('Lifecycle: ${state.name}');
      if (state == AppLifecycleState.paused) {
        // A "last known good" snapshot immediately before backgrounding,
        // to bookend against whatever gets logged on the next resume —
        // the difference between these two IS the failure window, if
        // one opens up.
        await _logTraceletSnapshot('Backgrounding, Tracelet state');
      }
    }
  }

  /// The OS telling the app it's under memory pressure — a direct,
  /// previously-untapped signal for the exact "silently killed with no
  /// crash log, no Jetsam event" failure chased on 2026-09-14. If this
  /// fires shortly before a gap begins, that's real evidence pointing at
  /// memory pressure specifically, rather than the OS's background
  /// execution budget declining to wake the app for other reasons.
  @override
  void didHaveMemoryPressure() {
    _appLogStore.add('⚠ OS memory pressure warning received');
  }

  Future<void> _logTraceletSnapshot(String label) async {
    if (Platform.isLinux) return; // Nothing Tracelet-specific to read.
    final snapshot = await traceletStateSnapshot();
    _appLogStore.add('$label — $snapshot');
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  /// Re-checks the native engine's actual tracking state and corrects
  /// `_tracking` if it disagrees. `_tracking` is only ever this widget's
  /// in-memory assumption, set by `_toggleTracking()` — nothing previously
  /// kept it honest against what Tracelet is actually doing underneath.
  Future<void> _syncTrackingStateFromNative() async {
    if (Platform.isLinux) return; // Simulator's own state can't diverge.
    await _ensureLocationSource();
    final actuallyTracking = await _locationSource!.isTracking();
    if (mounted && actuallyTracking != _tracking) {
      _appLogStore.add(
        'Tracking state corrected — UI said $_tracking, '
        'native said $actuallyTracking',
      );
      setState(() => _tracking = actuallyTracking);
    }
  }

  /// Requests notification permission exactly once, ever — tracked with
  /// our own persisted flag rather than trusting Android's permission
  /// status API, since a status of "denied" is ambiguous on Android
  /// between "never asked" and "user explicitly declined/revoked via
  /// Settings". Trusting that status would re-trigger the exact prompt a
  /// user deliberately turned off. This only affects whether the
  /// background-tracking notification is visible, never whether location/
  /// tracking itself works.
  Future<void> _requestNotificationPermissionOnce() async {
    if (Platform.isLinux) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('notification_permission_asked') ?? false) return;
    await Permission.notification.request();
    await prefs.setBool('notification_permission_asked', true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
    _appPulseTimer?.cancel();
    _locationSource?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _fleetId = prefs.getString('fleet_id');
      _serverAddress = prefs.getString('server_address') ?? defaultServerAddress;
      _apiKey = prefs.getString('api_key');
      _totalSentCount = prefs.getInt('total_sent_count') ?? 0;
    });
  }

  Future<void> _incrementTotalSent() async {
    final prefs = await SharedPreferences.getInstance();
    final newTotal = _totalSentCount + 1;
    await prefs.setInt('total_sent_count', newTotal);
    if (mounted) setState(() => _totalSentCount = newTotal);
  }

  Future<void> _updatePendingCount() async {
    final c = await _pendingStore.count();
    if (mounted) setState(() => _pendingCount = c);
  }

  LocationSource _createLocationSource() {
    if (Platform.isLinux) {
      return SimulatedLocationSource();
    }
    return TraceletLocationSource(appLog: _appLogStore);
  }

  /// Creates the location source and attaches its stream listener exactly
  /// once, reusing the same instance across the app's lifetime. Called
  /// lazily by both Start Tracking and the manual Send Now button.
  Future<void> _ensureLocationSource() async {
    if (_locationSource != null) return;
    _locationSource = _createLocationSource();
    _locationSource!.locationStream.listen(_handleLocation);
  }

  /// Guards against a location being handled more than once. Originally
  /// just checked the single most-recent point within 5 seconds, but that
  /// wasn't strong enough: a real drive showed Tracelet's native start()/
  /// stop() leaking an extra internal listener each time tracking was
  /// toggled, producing up to 5 copies of the same reading, arriving
  /// spread out over minutes rather than back-to-back.
  ///
  /// Since two genuinely different real GPS fixes essentially never share
  /// an identical device_timestamp, rejecting exact repeats is a strong
  /// guard — but a trip could realistically run for days, so this can't
  /// just remember every timestamp ever seen (that grows forever). The
  /// observed duplication was always clustered within minutes of a
  /// Stop/Start toggle, never spanning hours, so a rolling 1-hour window
  /// (self-pruning on every check) is a generous safety margin that keeps
  /// memory bounded no matter how long the app stays open.
  final Map<String, DateTime> _seenTimestamps = {};
  static const _dedupWindow = Duration(hours: 1);

  bool _isDuplicateTimestamp(TrackedLocation location) {
    final now = DateTime.now();
    _seenTimestamps.removeWhere((_, addedAt) => now.difference(addedAt) > _dedupWindow);

    final key = location.timestamp.toIso8601String();
    if (_seenTimestamps.containsKey(key)) {
      return true;
    }
    _seenTimestamps[key] = now;
    return false;
  }

  /// Formats as yyyy-mm-dd hh:mm:ss.
  String _formatDateTime(DateTime dt) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
        '${pad(dt.hour)}:${pad(dt.minute)}:${pad(dt.second)}';
  }

  /// Single place that handles any captured location, whether it came from
  /// the continuous tracked stream or a one-off manual "send now"/POI press.
  Future<void> _handleLocation(TrackedLocation location) async {
    // POI submissions generate their own fresh timestamp at button-press
    // time and must never be silently dropped, so they skip this guard —
    // though in practice they'd essentially never collide with a prior one.
    if (location.poiNote == null && _isDuplicateTimestamp(location)) {
      return;
    }

    setState(() => _lastLocation = location);

    if ((_fleetId == null || _fleetId!.isEmpty) ||
        (_apiKey == null || _apiKey!.isEmpty)) {
      _setSendStatus('Not sent — Fleet ID/API Key not set');
      return;
    }

    final apiClient = ApiClient(serverAddress: _serverAddress, apiKey: _apiKey!);
    try {
      await apiClient.postLocation(_fleetId!, location);
      await _incrementTotalSent();
      _setSendStatus('Sent at ${_formatDateTime(DateTime.now())}');
    } catch (e) {
      await _pendingStore.add(_fleetId!, location);
      await _updatePendingCount();
      _setSendStatus('Send failed — cached for retry');
    }

    await _flushQueue();
  }

  /// Every location fix goes through here while driving — logging every
  /// single one to the app log would flood it in minutes. Only the
  /// *category* transition (ok → failed, failed → ok, etc.) is logged,
  /// not every fix, which keeps the log about what changed rather than a
  /// duplicate of the location stream itself.
  String? _lastLoggedSendCategory;

  void _setSendStatus(String status) {
    setState(() => _lastSendStatus = status);
    final category = status.startsWith('Sent at')
        ? 'ok'
        : status.startsWith('Send failed')
            ? 'failed'
            : 'blocked';
    if (category != _lastLoggedSendCategory) {
      _appLogStore.add('Send status changed: $status');
      _lastLoggedSendCategory = category;
    }
  }

  // Guards against re-logging "flush failed" every 20 seconds for the
  // whole duration of an outage — only the start of a failed streak is
  // worth a line, not every retry of it.
  bool _pendingBacklogFailureLogged = false;

  Future<void> _flushQueue() async {
    if (_apiKey == null || _apiKey!.isEmpty) return;
    final apiClient = ApiClient(serverAddress: _serverAddress, apiKey: _apiKey!);
    final startCount = await _pendingStore.count();
    var sentThisPass = 0;
    var hitFailure = false;

    while (true) {
      final batch = await _pendingStore.peekOldest(limit: 50);
      if (batch.isEmpty) break;

      var anyFailed = false;
      for (final pending in batch) {
        try {
          await apiClient.postLocation(
            pending.vehicleId,
            pending.location,
            wasCached: true,
          );
          await _pendingStore.remove(pending.id);
          await _incrementTotalSent();
          sentThisPass++;
        } catch (_) {
          anyFailed = true;
          hitFailure = true;
          break;
        }
      }
      if (anyFailed) break;
    }

    // This runs on a 20-second timer as well as after every fix — logging
    // every silent no-op tick (or every retry of an ongoing outage) would
    // swamp the log. Only worth a line when something actually changed:
    // the backlog drained, or a failure streak just started.
    if (sentThisPass > 0) {
      _appLogStore.add('Flushed $sentThisPass cached location(s) to server');
      _pendingBacklogFailureLogged = false;
    } else if (hitFailure && startCount > 0 && !_pendingBacklogFailureLogged) {
      _appLogStore.add('Flush attempt failed — $startCount still queued');
      _pendingBacklogFailureLogged = true;
    }

    await _updatePendingCount();
  }

  Future<void> _openSettings() async {
    final prevFleetId = _fleetId;
    final prevServer = _serverAddress;
    final prevApiKeySet = _apiKey != null && _apiKey!.isNotEmpty;

    _appLogStore.add('Settings screen opened');
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const SettingsPage()),
    );
    await _loadSettings();

    // Never log the API key's value itself — just whether it changed.
    final changes = <String>[];
    if (_fleetId != prevFleetId) changes.add('Fleet ID');
    if (_serverAddress != prevServer) changes.add('server address');
    final newApiKeySet = _apiKey != null && _apiKey!.isNotEmpty;
    if (newApiKeySet != prevApiKeySet) changes.add('API key presence');
    _appLogStore.add(
      changes.isEmpty
          ? 'Settings screen closed — no changes'
          : 'Settings screen closed — changed: ${changes.join(', ')}',
    );
  }

  Future<bool> _ensurePermissions() async {
    if (Platform.isLinux) {
      return true;
    }

    // Notification permission is handled once, at startup — see
    // _requestNotificationPermissionOnce() — since it only affects whether
    // the background-tracking notification is visible, not whether GPS
    // itself works. It has no place gating this per-action location flow.

    final whenInUse = await Permission.locationWhenInUse.request();
    if (!whenInUse.isGranted) {
      return false;
    }

    final always = await Permission.locationAlways.request();
    return always.isGranted;
  }

  bool _settingsAreComplete() {
    return (_fleetId != null && _fleetId!.isNotEmpty) &&
        (_apiKey != null && _apiKey!.isNotEmpty);
  }

  Future<void> _toggleTracking() async {
    if (_tracking) {
      await _locationSource?.stop();
      await _persistTrackingIntent(false);
      _appLogStore.add('Stop Tracking pressed');
      setState(() => _tracking = false);
      return;
    }

    if (!_settingsAreComplete()) {
      _appLogStore.add('Start Tracking blocked — Fleet ID/API Key not set');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set Fleet ID and API Key in Settings first')),
      );
      return;
    }

    final hasPermission = await _ensurePermissions();
    if (!hasPermission) {
      _appLogStore.add('Start Tracking blocked — location permission denied');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission (including "Allow all the time") is required'),
          ),
        );
      }
      return;
    }

    await _ensureLocationSource();
    await _locationSource!.start();
    await _persistTrackingIntent(true);
    _appLogStore.add('Start Tracking pressed — tracking started');
    setState(() => _tracking = true);
  }

  Future<void> _persistTrackingIntent(bool intent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(trackingIntentPrefsKey, intent);
  }

  Future<void> _sendCurrentPositionNow() async {
    if (!_settingsAreComplete()) {
      _appLogStore.add('Send Now blocked — Fleet ID/API Key not set');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set Fleet ID and API Key in Settings first')),
      );
      return;
    }

    final hasPermission = await _ensurePermissions();
    if (!hasPermission) {
      _appLogStore.add('Send Now blocked — location permission denied');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission is required')),
        );
      }
      return;
    }

    await _ensureLocationSource();
    try {
      final location = await _locationSource!.getCurrentPosition();
      _appLogStore.add('Send Now pressed — got a fix, handing off to send');
      await _handleLocation(location);
    } catch (e) {
      _appLogStore.add('Send Now failed — could not get current position: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get current position: $e')),
        );
      }
    }
  }

  Future<void> _addPointOfInterest() async {
    if (!_settingsAreComplete()) {
      _appLogStore.add('POI submission blocked — Fleet ID/API Key not set');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set Fleet ID and API Key in Settings first')),
      );
      return;
    }

    final controller = TextEditingController();
    const poiTypes = ['Campsite', 'Attraction', 'Issue', 'Observation', 'Note'];
    String selectedType = poiTypes.last; // defaults to 'Note'
    Uint8List? pickedPhotoBytes;

    final result = await showDialog<(String, String, Uint8List?)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          title: const Text(
            'Add Point of Interest',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  decoration: InputDecoration(
                    labelText: 'Type',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  items: poiTypes
                      .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedType = value);
                    }
                  },
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: "What's here?",
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 16),
                if (pickedPhotoBytes != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        height: 120,
                        // No explicit width here — the Column's
                        // crossAxisAlignment.stretch already gives this a
                        // finite width. Combining that with an explicit
                        // width: double.infinity on Image (as before) made
                        // Flutter try to compute an infinite intrinsic
                        // width inside the dialog and crash with
                        // 'input.isFinite': is not true.
                        child: Image.memory(
                          pickedPhotoBytes!,
                          fit: BoxFit.cover,
                          // Decode at roughly thumbnail resolution rather
                          // than the full multi-MB gallery original, just
                          // to show a 120px-tall preview — much lighter on
                          // memory, and reduces risk on lower-end devices.
                          cacheHeight: 240,
                        ),
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('Take Photo'),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () async {
                    final picker = ImagePicker();
                    final picked = await picker.pickImage(source: ImageSource.camera);
                    if (picked != null) {
                      final bytes = await picked.readAsBytes();
                      setDialogState(() => pickedPhotoBytes = bytes);
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Choose from Gallery'),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () async {
                    final picker = ImagePicker();
                    final picked = await picker.pickImage(source: ImageSource.gallery);
                    if (picked != null) {
                      final bytes = await picked.readAsBytes();
                      setDialogState(() => pickedPhotoBytes = bytes);
                    }
                  },
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => Navigator.of(dialogContext)
                  .pop((controller.text.trim(), selectedType, pickedPhotoBytes)),
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.$1.isEmpty) return; // cancelled or left blank
    final note = result.$1;
    final type = result.$2;
    final photoBytes = result.$3;

    final hasPermission = await _ensurePermissions();
    if (!hasPermission) {
      _appLogStore.add('POI submission blocked — location permission denied');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission is required')),
        );
      }
      return;
    }

    await _ensureLocationSource();
    try {
      final base = await _locationSource!.getCurrentPosition();

      String? photoBase64;
      if (photoBytes != null) {
        try {
          final compressed = await FlutterImageCompress.compressWithList(
            photoBytes,
            minWidth: 1024,
            minHeight: 1024,
            quality: 72,
            format: CompressFormat.jpeg,
          );
          photoBase64 = base64Encode(compressed);
        } catch (e) {
          // Compression failing shouldn't lose the whole POI submission —
          // proceed without the photo rather than blocking on it.
          photoBase64 = null;
        }
      }

      final withNote = TrackedLocation(
        lat: base.lat,
        lon: base.lon,
        accuracy: base.accuracy,
        altitude: base.altitude,
        speed: base.speed,
        timestamp: base.timestamp,
        poiNote: note,
        poiType: type,
        photoBase64: photoBase64,
      );
      await _handleLocation(withNote);
      _appLogStore.add(
        'POI added — type=$type${photoBase64 != null ? ', with photo' : ''}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Point of interest submitted')),
        );
      }
    } catch (e) {
      _appLogStore.add('POI submission failed — could not get position: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get position: $e')),
        );
      }
    }
  }

  Future<void> _openDiagnostics() async {
    // Ensure Tracelet has been initialized at least once so the Doctor
    // overlay has something real to report rather than an uninitialized
    // plugin — harmless no-op if it's already set up.
    await _ensureLocationSource();
    final prefs = await SharedPreferences.getInstance();
    final lastHeartbeatUtc = prefs.getString(heartbeatTimestampPrefsKey);
    final heartbeatCount = prefs.getInt(heartbeatCountPrefsKey) ?? 0;
    final heartbeatIsMoving = prefs.getBool(heartbeatIsMovingPrefsKey);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => DiagnosticsPage(
          fleetId: _fleetId ?? '',
          serverAddress: _serverAddress,
          apiKeySet: _apiKey != null && _apiKey!.isNotEmpty,
          tracking: _tracking,
          lastSendStatus: _lastSendStatus,
          pendingCount: _pendingCount,
          totalSentCount: _totalSentCount,
          lastHeartbeatUtc: lastHeartbeatUtc,
          heartbeatCount: heartbeatCount,
          heartbeatIsMoving: heartbeatIsMoving,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fleetIdDisplay =
        (_fleetId == null || _fleetId!.isEmpty) ? '(not set)' : _fleetId!;

    final sentOk = _lastSendStatus.startsWith('Sent');
    final sentTrouble = _lastSendStatus.contains('failed') ||
        _lastSendStatus.contains('cached') ||
        _lastSendStatus.contains('Not sent');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Duncan Tracking'),
        centerTitle: true,
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Status card: tracking state + fleet ID ---
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _tracking ? Icons.gps_fixed : Icons.gps_off,
                            color: _tracking ? Colors.green[700] : Colors.grey,
                            size: 26,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _tracking ? 'Tracking Active' : 'Tracking Stopped',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          if (Platform.isLinux) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.orange[100],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'SIMULATOR',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.orange[900],
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const Divider(height: 28),
                      Row(
                        children: [
                          Icon(Icons.directions_car, size: 18, color: Colors.grey[600]),
                          const SizedBox(width: 6),
                          Text('Fleet ID', style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey[600])),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fleetIdDisplay,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // --- Last position card ---
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.location_on, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Text('Last Known Position', style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey[600])),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _lastLocation != null
                            ? '${_lastLocation!.lat.toStringAsFixed(5)}, '
                                '${_lastLocation!.lon.toStringAsFixed(5)}'
                            : 'No location yet',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            sentOk
                                ? Icons.check_circle
                                : sentTrouble
                                    ? Icons.cloud_off
                                    : Icons.info_outline,
                            size: 16,
                            color: sentOk
                                ? Colors.green[700]
                                : sentTrouble
                                    ? Colors.orange[800]
                                    : Colors.grey,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _lastSendStatus,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey[700]),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // --- Stats row ---
              Row(
                children: [
                  Expanded(
                    child: _StatTile(
                      icon: Icons.cloud_upload,
                      iconColor: Colors.blue[700]!,
                      label: 'Total Sent',
                      value: '$_totalSentCount',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatTile(
                      icon: Icons.pending_actions,
                      iconColor: _pendingCount > 0 ? Colors.orange[800]! : Colors.grey,
                      label: 'Pending Upload',
                      value: '$_pendingCount',
                      highlight: _pendingCount > 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),

              // --- Actions ---
              FilledButton.icon(
                onPressed: _toggleTracking,
                icon: Icon(_tracking ? Icons.stop_circle : Icons.play_circle_fill),
                label: Text(
                  _tracking ? 'Stop Tracking' : 'Start Tracking',
                  style: const TextStyle(fontSize: 16),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _tracking ? Colors.red[600] : Colors.green[700],
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _sendCurrentPositionNow,
                icon: const Icon(Icons.my_location),
                label: const Text('Send Current Position Now'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _lastLocation != null ? _addPointOfInterest : null,
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Add Point of Interest'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openDiagnostics,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: const Text('Diagnostics'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small stat card used in the home screen's summary row.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      color: highlight ? Colors.orange[50] : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(height: 10),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}
