import 'dart:async';

import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

import '../capture/naming.dart';
import '../settings/app_settings.dart';
import '../smb/smb.dart';
import 'image_viewer_page.dart';

/// History tab — lists the image files currently on the SMB share.
/// Tapping one downloads and displays it full-screen.
class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.settingsNotifier,
    this.onOpenSettings,
    this.active = true,
  });

  final ValueNotifier<AppSettings> settingsNotifier;
  final VoidCallback? onOpenSettings;

  /// True while this is the tab on screen. Flipping back to true (re-entering
  /// the tab) re-lists the share, so uploads made since the last visit show
  /// up without a pull-to-refresh.
  final bool active;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<SmbFile>? _files;
  String? _error;

  /// Connection snapshot the failed refresh used (shown in the error view).
  ConnectionSettings? _errorSettings;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  // The FIRST presentation initializes via initState; every later one arrives
  // here as a false → true flip while the page stays mounted in the stack.
  @override
  void didUpdateWidget(HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && mounted) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final s = widget.settingsNotifier.value.connection;
    try {
      final conn = await connect(s);
      try {
        final folder = await conn.file(s.sharePath);
        final entries = await conn.listFiles(folder);
        // Names encode the capture time, so descending name order is
        // newest-first.
        entries.sort((a, b) => b.name.compareTo(a.name));
        if (!mounted) return;
        setState(() {
          _files = entries.where((f) => _isImage(f.name)).toList();
          _error = null;
          _errorSettings = null;
        });
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _errorSettings = s;
        });
      }
    }
  }

  bool _isImage(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'SMB settings',
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: _error != null
          ? _errorView()
          : files == null
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
          ? const Center(child: Text('No images on the share yet.'))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final file = files[index];
                  final parsed = parseUploadName(file.name);
                  return ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(parsed?.$1 ?? file.name),
                    subtitle: parsed != null ? Text(parsed.$2) : null,
                    trailing: Text(_formatSize(file.size)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ImageViewerPage(
                          file: file,
                          settingsNotifier: widget.settingsNotifier,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not list \\\\${_errorSettings?.host ?? ConnectionSettings.defaults.host}${_errorSettings?.sharePath ?? ConnectionSettings.defaults.sharePath}\n\n$_error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: () => unawaited(_refresh()),
            ),
          ],
        ),
      ),
    );
  }
}
