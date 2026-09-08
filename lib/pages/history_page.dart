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
    this.listDir,
  });

  final ValueNotifier<AppSettings> settingsNotifier;
  final VoidCallback? onOpenSettings;

  /// Test seam: lists one directory's entries by path. Null (production) →
  /// [_listDirReal] below; tests inject a fake returning hand-built
  /// [SmbFile]s, so no widget test ever dials the share.
  final Future<List<SmbFile>> Function(String path)? listDir;

  /// True while this is the tab on screen. Flipping back to true (re-entering
  /// the tab) re-lists the share, so uploads made since the last visit show
  /// up without a pull-to-refresh.
  final bool active;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  /// Every entry in the listed directory — files AND folders; the build
  /// splits them. (Attribute-based: a folder is whatever reports the
  /// directory bit, never a name pattern.)
  List<SmbFile>? _entries;
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

  /// Production listing: one fresh connection per directory listing.
  /// [path] is any share-relative dir path, so folder listings (Task 5.2)
  /// go through the exact same call.
  Future<List<SmbFile>> _listDirReal(String path) async {
    final s = widget.settingsNotifier.value.connection;
    final conn = await connect(s);
    try {
      final folder = await conn.file(path);
      return await conn.listFiles(folder);
    } finally {
      await conn.close();
    }
  }

  Future<void> _refresh() async {
    final s = widget.settingsNotifier.value.connection;
    try {
      final entries = await (widget.listDir ?? _listDirReal)(s.sharePath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
        _errorSettings = null;
      });
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
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: _error != null
          ? _errorView()
          : entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const Center(child: Text('No images on the share yet.'))
          : RefreshIndicator(onRefresh: _refresh, child: _entryList(entries)),
    );
  }

  /// Folders first (order-number descending — highest first), then the
  /// loose images exactly as before (newest-first via the name contract).
  Widget _entryList(List<SmbFile> entries) {
    final folders = entries.where((e) => e.isDirectory()).toList()
      ..sort((a, b) => b.name.compareTo(a.name));
    final files =
        entries.where((e) => !e.isDirectory() && _isImage(e.name)).toList()
          ..sort((a, b) => b.name.compareTo(a.name));

    return ListView.builder(
      itemCount: folders.length + files.length,
      itemBuilder: (context, index) {
        if (index < folders.length) {
          return _folderTile(folders[index]);
        }
        return _imageTile(files[index - folders.length]);
      },
    );
  }

  Widget _folderTile(SmbFile folder) {
    // TODO(5.2): drill down into this order folder — wire navigation here.
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(folder.name),
      subtitle: const Text('Folder', style: TextStyle(color: Colors.grey)),
      onTap: () {},
    );
  }

  Widget _imageTile(SmbFile file) {
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
