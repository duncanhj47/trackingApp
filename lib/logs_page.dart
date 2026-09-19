import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:tracelet/tracelet.dart' as tl;

/// How many entries to pull from Tracelet's on-device log store. Higher than
/// the Doctor overlay's default 500 — this page exists specifically to dig
/// through an overnight gap, so a bit more headroom costs nothing and could
/// be the difference between the relevant lines being in view or not.
const _logLimit = 1500;

/// A dedicated log viewer, separate from TraceletDoctor's own log tab.
///
/// Reads straight from Tracelet.getLogs(), which is backed by the on-device
/// SQLite log store — not an in-memory buffer — so it survives app restarts
/// and captures background/killed-and-relaunched activity. That's exactly
/// what a "tracking silently stopped overnight" investigation needs: a
/// debugger session attached after the fact would show none of it, but this
/// will, because nothing here depends on the process having stayed alive.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<tl.LogEntry>? _logs;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (Platform.isLinux) {
      // Nothing to read — Tracelet has no Linux implementation, so there's
      // no native log store behind this call at all on the simulator.
      setState(() {
        _loading = false;
        _logs = [];
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final entries = await tl.Tracelet.getLogs(_logLimit);
      // Newest first — when you're checking "what happened right before I
      // noticed tracking had stopped", that's the end of the list you
      // actually want to land on, not the oldest 1500th-ago entry.
      setState(() => _logs = entries.reversed.toList());
    } catch (e) {
      setState(() => _error = 'Could not read logs: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Tracelet's LogEntry.timestamp is documented as ISO-8601, but nothing
  /// guarantees the raw string carries a trailing 'Z' or explicit offset.
  /// If it doesn't, Dart's DateTime.parse() silently treats it as *local*
  /// time rather than UTC — meaning .toLocal() becomes a no-op and the
  /// display keeps showing the raw UTC clock value mislabeled as local
  /// (exactly the "rebuilt and it's still wrong" symptom). Tracelet's
  /// timestamps are UTC regardless of how the string is punctuated — this
  /// app's own TrackedLocation.timestamp is stamped via
  /// DateTime.now().toUtc() elsewhere for the same reason — so force that
  /// interpretation on the parsed value explicitly rather than trust the
  /// string's formatting to declare it.
  String _formatLocal(String isoTimestamp) {
    try {
      var parsed = DateTime.parse(isoTimestamp);
      if (!parsed.isUtc) {
        parsed = DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
      }
      final local = parsed.toLocal();
      String pad(int n) => n.toString().padLeft(2, '0');
      return '${local.year}-${pad(local.month)}-${pad(local.day)} '
          '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
    } catch (_) {
      return isoTimestamp;
    }
  }

  Future<void> _copyAll() async {
    final logs = _logs;
    if (logs == null || logs.isEmpty) return;

    final text = logs
        .map((e) => '${_formatLocal(e.timestamp)} [${e.level}] ${e.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${logs.length} log lines')),
      );
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear stored logs?'),
        content: const Text(
          'This wipes the on-device log history Tracelet has recorded so '
          'far. Do this after you\'ve copied what you need, not before.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await tl.Tracelet.clearLogs();
      await _load();
    }
  }

  /// Tracelet's docs describe levels as DEBUG/INFO/WARN/ERROR but don't
  /// pin down whether `LogEntry.level` is a String or an enum, so this
  /// matches on the string form of whatever it is rather than assuming a
  /// specific enum type — safer than guessing a constant that might not
  /// compile against the version you're pinned to.
  Color? _colorForLevel(Object level) {
    final s = level.toString().toUpperCase();
    if (s.contains('ERROR')) return Colors.red[700];
    if (s.contains('WARN')) return Colors.orange[800];
    if (s.contains('DEBUG')) return Colors.grey[500];
    return null; // INFO and anything else — default text colour.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tracking Logs'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
          IconButton(
            onPressed: (_logs?.isNotEmpty ?? false) ? _copyAll : null,
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy all',
          ),
          IconButton(
            onPressed: (_logs?.isNotEmpty ?? false) ? _confirmClear : null,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (Platform.isLinux) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Tracelet logs are only available on Android/iOS — this is the '
          'Linux simulator, which has no real Tracelet session to log.',
          style: TextStyle(color: Colors.grey[700]),
        ),
      );
    }

    if (_loading && _logs == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error!, style: TextStyle(color: Colors.red[700])),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final logs = _logs ?? [];
    if (logs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No log entries yet. Logging detail depends on your LoggerConfig '
          'log level — raise it to debug/verbose before reproducing an '
          'issue if you need finer detail than this shows.',
          style: TextStyle(color: Colors.grey[700]),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final entry = logs[index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.black87,
                  height: 1.4,
                ),
                children: [
                  TextSpan(
                    text: '${_formatLocal(entry.timestamp)} ',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                  TextSpan(
                    text: '[${entry.level}] ',
                    style: TextStyle(
                      color: _colorForLevel(entry.level),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextSpan(text: entry.message),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
