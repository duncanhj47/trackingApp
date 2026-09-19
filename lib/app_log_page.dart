import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'app_log_store.dart';

/// Viewer for AppLogStore — deliberately a separate page from LogsPage
/// (which reads Tracelet.getLogs()), so the two stay visibly distinct:
/// this one is proof the app's own process is alive, not proof Tracelet's
/// engine is.
class AppLogPage extends StatefulWidget {
  const AppLogPage({super.key});

  @override
  State<AppLogPage> createState() => _AppLogPageState();
}

class _AppLogPageState extends State<AppLogPage> {
  final _store = AppLogStore();
  List<AppLogEntry>? _entries;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await _store.recent();
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  /// Written via DateTime.now().toUtc().toIso8601String() and parsed back
  /// with DateTime.parse() in AppLogStore — that round trip is fully
  /// self-authored, so unlike Tracelet's raw log strings, there's no
  /// ambiguity to guard against here: the 'Z' suffix is always present
  /// and Dart's parse always honours it, so .toLocal() alone is correct.
  String _formatLocal(DateTime utc) {
    final local = utc.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
  }

  Future<void> _copyAll() async {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;
    final text = entries
        .map((e) => '${_formatLocal(e.timestampUtc)}  ${e.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${entries.length} entries')),
      );
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear app log?'),
        content: const Text(
          'Wipes this app-owned history. Do this after copying what you '
          'need, not before.',
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
      await _store.clear();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Log'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
          IconButton(
            onPressed: (_entries?.isNotEmpty ?? false) ? _copyAll : null,
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy all',
          ),
          IconButton(
            onPressed: (_entries?.isNotEmpty ?? false) ? _confirmClear : null,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _entries == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final entries = _entries ?? [];
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No entries yet — the first pulse or lifecycle event will '
          'appear here.',
          style: TextStyle(color: Colors.grey[700]),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
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
                    text: '${_formatLocal(entry.timestampUtc)}  ',
                    style: TextStyle(color: Colors.grey[500]),
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
