import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:tracelet_doctor/tracelet_doctor.dart';

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
  });

  final String fleetId;
  final String serverAddress;
  final bool apiKeySet;
  final bool tracking;
  final String lastSendStatus;
  final int pendingCount;
  final int totalSentCount;

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
          if (!Platform.isLinux)
            FilledButton.icon(
              onPressed: () => TraceletDoctor.show(context),
              icon: const Icon(Icons.health_and_safety),
              label: const Text('Show Device & GPS Health'),
            )
          else
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
