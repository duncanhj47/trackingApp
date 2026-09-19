import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:tracelet_doctor/tracelet_doctor.dart';

import 'app_log_page.dart';
import 'logs_page.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({
    super.key,
    required this.fleetId,
    required this.serverAddress,
    required this.apiKeySet,
    required this.tracking,
    required this.lastSendStatus,
    required this.pendingCount,
    required this.totalSentCount,
    required this.lastHeartbeatUtc,
    required this.heartbeatCount,
    required this.heartbeatIsMoving,
  });

  final String fleetId;
  final String serverAddress;
  final bool apiKeySet;
  final bool tracking;
  final String lastSendStatus;
  final int pendingCount;
  final int totalSentCount;
  final String? lastHeartbeatUtc;
  final int heartbeatCount;
  final bool? heartbeatIsMoving;

  /// Heartbeat timestamps are stamped via DateTime.now().toUtc() — see
  /// real_location_source.dart — so this mirrors the same UTC-forcing
  /// approach used in logs_page.dart rather than trusting string
  /// punctuation to say so.
  String? _formatHeartbeatLocal() {
    final raw = lastHeartbeatUtc;
    if (raw == null) return null;
    try {
      var parsed = DateTime.parse(raw);
      if (!parsed.isUtc) {
        parsed = DateTime.utc(parsed.year, parsed.month, parsed.day,
            parsed.hour, parsed.minute, parsed.second);
      }
      final local = parsed.toLocal();
      String pad(int n) => n.toString().padLeft(2, '0');
      return '${local.year}-${pad(local.month)}-${pad(local.day)} '
          '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: 'App Configuration',
            rows: [
              _DiagRow('Fleet ID', fleetId.isEmpty ? '(not set)' : fleetId, warn: fleetId.isEmpty),
              _DiagRow('Server address', serverAddress),
              _DiagRow('API key configured', apiKeySet ? 'Yes' : 'No', warn: !apiKeySet),
              _DiagRow(
                'Platform',
                Platform.isLinux ? 'Linux (simulator mode)' : Platform.operatingSystem,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Tracking Status',
            rows: [
              _DiagRow('Currently tracking', tracking ? 'Yes' : 'No'),
              _DiagRow(
                'Last send result',
                lastSendStatus,
                warn: lastSendStatus.contains('failed') ||
                    lastSendStatus.contains('Not sent'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Heartbeat',
            rows: [
              _DiagRow(
                'Last heartbeat',
                _formatHeartbeatLocal() ?? 'None yet',
                warn: lastHeartbeatUtc == null,
              ),
              _DiagRow(
                'Device state at last beat',
                heartbeatIsMoving == null
                    ? 'Unknown'
                    : (heartbeatIsMoving! ? 'Moving' : 'Motionless'),
              ),
              _DiagRow('Total heartbeats seen', '$heartbeatCount'),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(
              'Only fires while parked/stationary — a long gap while '
              'driving is expected, not a fault.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Sync Queue',
            rows: [
              _DiagRow(
                'Cached, waiting to upload',
                '$pendingCount',
                warn: pendingCount > 50,
              ),
              _DiagRow('Total positions sent (all time)', '$totalSentCount'),
            ],
          ),
          const SizedBox(height: 20),
          if (!Platform.isLinux) ...[
            FilledButton.icon(
              onPressed: () => TraceletDoctor.show(context),
              icon: const Icon(Icons.health_and_safety),
              label: const Text('Show Device & GPS Health'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const LogsPage()),
              ),
              icon: const Icon(Icons.article_outlined),
              label: const Text('View Tracking Logs'),
            ),
          ] else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Device/GPS health diagnostics (battery, sensors, OEM aggression '
                  'rating) are only available on Android/iOS — this is the Linux '
                  'simulator, which has no real Tracelet session to report on.',
                  style: TextStyle(color: Colors.grey[700]),
                ),
              ),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const AppLogPage()),
            ),
            icon: const Icon(Icons.pending_actions_outlined),
            label: const Text('View App Log'),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.rows});

  final String title;
  final List<_DiagRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          ),
          if (warn) const Icon(Icons.warning_amber, size: 15, color: Colors.orange),
          if (warn) const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: warn ? Colors.orange[800] : null,
            ),
          ),
        ],
      ),
    );
  }
}
