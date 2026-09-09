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

  /// Production listing: delegates to the shared one-connection-per-listing
  /// helper with this page's settings snapshot.
  Future<List<SmbFile>> _listDirReal(String path) =>
      listDirReal(widget.settingsNotifier.value.connection, path);

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

  bool _isImage(String name) => isImageName(name);

  String _formatSize(int bytes) => formatSize(bytes);

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
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(folder.name),
      subtitle: const Text('Folder', style: TextStyle(color: Colors.grey)),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OrderFilesPage(
            folderName: folder.name,
            folderPath: folder.path,
            settingsNotifier: widget.settingsNotifier,
            listDir: widget.listDir ?? _listDirReal,
          ),
        ),
      ),
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

/// Shared image-extension check (this file's two listing pages).
bool isImageName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
}

/// Shared byte-size rendering (this file's two listing pages).
String formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}

/// Production listing for any path: one fresh connection per directory
/// listing. [path] is any share-relative dir path (the share root, or a
/// folder inside it) — both listing pages go through this exact call.
Future<List<SmbFile>> listDirReal(ConnectionSettings s, String path) async {
  final conn = await connect(s);
  try {
    final folder = await conn.file(path);
    return await conn.listFiles(folder);
  } finally {
    await conn.close();
  }
}

/// One order folder's contents: images only, newest-first, tappable into the
/// existing full-screen viewer. Reached by tapping a folder tile on
/// [HistoryPage]; shares the same [listDir] seam so tests fake both levels.
class OrderFilesPage extends StatefulWidget {
  const OrderFilesPage({
    super.key,
    required this.folderName,
    required this.folderPath,
    required this.settingsNotifier,
    this.listDir,
  });

  final String folderName;

  /// Full share-relative path of the folder (what `conn.file()` gets in
  /// production — passed to the listing seam verbatim).
  final String folderPath;

  final ValueNotifier<AppSettings> settingsNotifier;

  /// Same seam as [HistoryPage.listDir]: null (production) → [listDirReal];
  /// tests inject a fake so folder listings never dial the share. History
  /// passes its own resolution straight through, keeping one fake per test.
  final Future<List<SmbFile>> Function(String path)? listDir;

  @override
  State<OrderFilesPage> createState() => _OrderFilesPageState();
}

class _OrderFilesPageState extends State<OrderFilesPage> {
  List<SmbFile>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      // Same one-argument seam shape as HistoryPage: either the injected
      // fake (tests) or the real one-connection listing bound to this
      // page's settings snapshot.
      final entries =
          await (widget.listDir ??
              (String path) => listDirReal(
                widget.settingsNotifier.value.connection,
                path,
              ))(widget.folderPath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      body: _error != null
          ? _errorView()
          : entries == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _refresh, child: _imageList(entries)),
    );
  }

  /// This folder's images only, newest-first via the name contract.
  Widget _imageList(List<SmbFile> entries) {
    final files =
        entries.where((e) => !e.isDirectory() && isImageName(e.name)).toList()
          ..sort((a, b) => b.name.compareTo(a.name));
    if (files.isEmpty) {
      return const Center(child: Text('No images in this folder.'));
    }
    return ListView.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final parsed = parseUploadName(file.name);
        return ListTile(
          leading: const Icon(Icons.image_outlined),
          title: Text(parsed?.$2 ?? file.name),
          subtitle: Text(file.name),
          trailing: Text(formatSize(file.size)),
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
              'Could not list \\\\${widget.settingsNotifier.value.connection.host}'
              '${widget.folderPath}\n\n$_error',
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
