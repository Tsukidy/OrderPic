import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:smb_connect/smb_connect.dart';

/// SMB share settings. Credentials default to empty and are never
/// compiled into the binary — the user enters them on first startup
/// (settings persist via flutter_secure_storage).
class SmbSettings {
  final String host;
  final String sharePath; // <share>/<sub-folder> (sub-folder is created if missing)
  final String domain;
  final String username;
  final String password;

  const SmbSettings({
    required this.host,
    required this.sharePath,
    required this.domain,
    required this.username,
    required this.password,
  });

  /// Seeds ONLY the non-secret fields; username/password stay empty (Q7).
  static const SmbSettings defaults = SmbSettings(
    host: '192.168.1.29',
    sharePath: '/zdrive/InvoiceData',
    domain: '',
    username: '',
    password: '',
  );

  SmbSettings copyWith({
    String? host,
    String? sharePath,
    String? domain,
    String? username,
    String? password,
  }) =>
      SmbSettings(
        host: host ?? this.host,
        sharePath: sharePath ?? this.sharePath,
        domain: domain ?? this.domain,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  @override
  bool operator ==(Object other) =>
      other is SmbSettings &&
      other.host == host &&
      other.sharePath == sharePath &&
      other.domain == domain &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode =>
      Object.hash(host, sharePath, domain, username, password);
}

void main() {
  runApp(const MmcPicApp());
}

class MmcPicApp extends StatelessWidget {
  const MmcPicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MMCPic',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// Root shell — Scan / History tabs along the bottom.
/// (camera, review) is pushed on top of this shell as process progresses.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  bool _historyVisited = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          ScannerPage(paused: _tab != 0),
          // Build the history tab lazily
          _historyVisited ? const HistoryPage() : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() {
          _tab = index;
          if (index == 1) _historyVisited = true;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Scan',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}

/// Stage 1 — scan the QR code
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key, this.paused = false});

  /// True while another tab is on top — pauses the camera.
  final bool paused;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final TextEditingController _entryController = TextEditingController();
  bool _processing = false;

  @override
  void didUpdateWidget(ScannerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paused != oldWidget.paused && !_processing) {
      unawaited(widget.paused ? _controller.stop() : _controller.start());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _entryController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || capture.barcodes.isEmpty) return;
    final orderNumber = capture.barcodes.first.rawValue;
    if (orderNumber == null || orderNumber.isEmpty) return;

    _processing = true;
    await _controller.stop();
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR code scanned'),
        content: Text(orderNumber),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Rescan'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use this'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (confirmed == true) {
      // Push the capture flow on top of the tab shell; when it eventually
      // pops (upload finished / cancelled), resume scanning.
      await _startCapture(orderNumber);
    } else {
      _processing = false;
      unawaited(_controller.start());
    }
  }

  /// Stop scanning, run the capture flow for [orderNumber], then resume
  /// scanning when it finishes. Shared by the QR and manual entry paths.
  Future<void> _startCapture(String orderNumber) async {
    await _controller.stop();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CameraPage(orderNumber: orderNumber)),
    );
    if (!mounted) return;
    _processing = false;
    unawaited(_controller.start());
  }

  /// Fallback entry: type an order number when the QR code won't scan.
  /// `_processing` suppresses barcode detection while the dialog is open;
  /// confirming starts the same capture flow a scanned code does.
  Future<void> _showEntryDialog() async {
    if (_processing) return;
    _processing = true;
    _entryController.clear();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Type order number'),
        content: TextField(
          controller: _entryController,
          autofocus: true,
          keyboardType: TextInputType.number,
          // Digits-only input keeps the upload filename contract safe by
          // construction — '_' and SMB-hostile characters are untypable,
          // including via paste (formatters run on pasted text too).
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(16),
          ],
          decoration: const InputDecoration(hintText: 'Order number'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _entryController,
            builder: (context, value, _) => FilledButton(
              // Disabled while the trimmed value is empty.
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Use this'),
            ),
          ),
        ],
      ),
    );

    final orderNumber = _entryController.text.trim();

    if (!mounted) return;
    if (confirmed == true && orderNumber.isNotEmpty) {
      await _startCapture(orderNumber);
    } else {
      // Cancelled — nothing was pushed, just resume detecting.
      _processing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan QR code'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera error: ${error.errorCode.name}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          // Fallback for a missing or damaged QR code — always visible so
          // it's findable after a failed scan attempt.
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.keyboard),
              label: const Text('Type order number'),
              onPressed: _showEntryDialog,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stage 2 — take a photo of the item with the system camera app, so the
/// user gets the full native camera experience (zoom, flash, timer,
/// portrait and landscape, etc.).
class CameraPage extends StatefulWidget {
  const CameraPage({super.key, required this.orderNumber});

  final String orderNumber;

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  final ImagePicker _picker = ImagePicker();
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    // Open the system camera straight away after a successful scan.
    unawaited(_takePhoto());
  }

  Future<void> _takePhoto() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      // No maxWidth/imageQuality — hand the original file to the uploader.
      final photo = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (!mounted) return;
      if (photo != null) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => PreviewPage(
              orderNumber: widget.orderNumber,
              imagePath: photo.path,
            ),
          ),
        );
      } else {
        // User backed out allow retry
        setState(() => _launching = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _launching = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Camera failed: $e')));
    }
  }

  void _backToScanner() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  color: Colors.white,
                  tooltip: 'Scan a different QR code',
                  onPressed: _backToScanner,
                ),
                _qrChip(),
              ],
            ),
            const Spacer(),
            const Icon(Icons.photo_camera, color: Colors.white, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Take a photo of the scanned item',
              style: TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: const Text('Open camera'),
              onPressed: _launching ? null : _takePhoto,
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _qrChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Order: ${widget.orderNumber}',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }
}

/// Stage 3 — review the photo, then retake or upload it to the SMB share.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.orderNumber,
    required this.imagePath,
  });

  final String orderNumber;
  final String imagePath;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

enum _UploadStatus { idle, uploading, done, failed }

class _PreviewPageState extends State<PreviewPage> {
  _UploadStatus _status = _UploadStatus.idle;
  String? _uploadedName;
  String? _error;

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  /// {OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg, stamped when the upload starts.
  String _buildFileName(DateTime now) {
    final date = '${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}';
    final time =
        '${_twoDigits(now.hour)}${_twoDigits(now.minute)}${_twoDigits(now.second)}';
    return '${widget.orderNumber}_${date}_$time.jpg';
  }

  Future<void> _upload() async {
    if (_status == _UploadStatus.uploading) return;

    final fileName = _buildFileName(DateTime.now());
    setState(() {
      _status = _UploadStatus.uploading;
      _uploadedName = fileName;
      _error = null;
    });

    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final conn = await SmbConnect.connectAuth(
        host: SmbSettings.defaults.host,
        domain: SmbSettings.defaults.domain,
        username: SmbSettings.defaults.username,
        password: SmbSettings.defaults.password,
      );
      try {
        // The share itself must already exist; sub-folders are created here.
        try {
          await conn.createFolder(SmbSettings.defaults.sharePath);
        } catch (_) {
          // Folder already exists (or deeper nesting is missing) — ignore.
        }
        final remoteFile =
            await conn.createFile('${SmbSettings.defaults.sharePath}/$fileName');
        final sink = await conn.openWrite(remoteFile);
        sink.add(bytes);
        await sink.flush();
        await sink.close();
      } finally {
        await conn.close();
      }

      unawaited(_deleteLocalCapture());
      if (mounted) setState(() => _status = _UploadStatus.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _UploadStatus.failed;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _deleteLocalCapture() async {
    try {
      await File(widget.imagePath).delete();
    } catch (_) {
      // Best effort only — no problem if the capture is already gone.
    }
  }

  /// Open the camera again for the same order number (retake, or the next
  /// photo of the same order after a successful upload).
  void _takeAnotherPhoto() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraPage(orderNumber: widget.orderNumber),
      ),
    );
  }

  void _scanNext() {
    // Pop the capture flow and land back on the tab shell (Scan tab).
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.file(
              File(widget.imagePath),
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      color: Colors.white,
                      tooltip: 'Scan a different QR code',
                      onPressed: _status == _UploadStatus.uploading
                          ? null
                          : _scanNext,
                    ),
                    _status == _UploadStatus.done ? _doneBanner() : _qrChip(),
                  ],
                ),
                const Spacer(),
                if (_status == _UploadStatus.failed) _errorBanner(),
                _bottomButtons(),
                const SizedBox(height: 24),
              ],
            ),
          ),
          if (_status == _UploadStatus.uploading) _uploadingOverlay(),
        ],
      ),
    );
  }

  Widget _uploadingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                'Uploading ${_uploadedName ?? ''}',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _qrChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Order: ${widget.orderNumber}',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }

  Widget _doneBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.green,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Uploaded: ${_uploadedName ?? ''}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Upload failed: $_error',
        style: const TextStyle(color: Colors.white),
      ),
    );
  }

  Widget _bottomButtons() {
    switch (_status) {
      case _UploadStatus.done:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
              ),
              icon: const Icon(Icons.photo_camera),
              label: const Text('Another photo\n(same order)'),
              onPressed: _takeAnotherPhoto,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan next\nQR code'),
              onPressed: _scanNext,
            ),
          ],
        );
      case _UploadStatus.uploading:
        return const SizedBox.shrink();
      case _UploadStatus.failed:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Retake'),
              onPressed: _takeAnotherPhoto,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry upload'),
              onPressed: _upload,
            ),
          ],
        );
      case _UploadStatus.idle:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Retake'),
              onPressed: _takeAnotherPhoto,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Upload'),
              onPressed: _upload,
            ),
          ],
        );
    }
  }
}

/// History tab — lists the image files currently on the SMB share.
/// Tapping one downloads and displays it full-screen.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<SmbFile>? _files;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final conn = await SmbConnect.connectAuth(
        host: SmbSettings.defaults.host,
        domain: SmbSettings.defaults.domain,
        username: SmbSettings.defaults.username,
        password: SmbSettings.defaults.password,
      );
      try {
        final folder = await conn.file(SmbSettings.defaults.sharePath);
        final entries = await conn.listFiles(folder);
        // Names encode the capture time, so descending name order is
        // newest-first.
        entries.sort((a, b) => b.name.compareTo(a.name));
        if (!mounted) return;
        setState(() {
          _files = entries.where((f) => _isImage(f.name)).toList();
          _error = null;
        });
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  bool _isImage(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  /// Split ORDER_YYYYMMDD_HHMMSS.ext into (order, readable date/time).
  (String, String)? _parseName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    final parts = name.substring(0, dot).split('_');
    if (parts.length != 3 || parts[1].length != 8 || parts[2].length != 6) {
      return null;
    }
    final d = parts[1];
    final t = parts[2];
    final iso =
        '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} '
        '${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}';
    return (parts[0], iso);
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
      appBar: AppBar(title: const Text('History')),
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
                  final parsed = _parseName(file.name);
                  return ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(parsed?.$1 ?? file.name),
                    subtitle: parsed != null ? Text(parsed.$2) : null,
                    trailing: Text(_formatSize(file.size)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ImageViewerPage(file: file),
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
              'Could not list \\\\${SmbSettings.defaults.host}${SmbSettings.defaults.sharePath}\n\n$_error',
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

/// Full-screen viewer for one image on the SMB share (pinch to zoom).
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required this.file});

  final SmbFile file;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final conn = await SmbConnect.connectAuth(
        host: SmbSettings.defaults.host,
        domain: SmbSettings.defaults.domain,
        username: SmbSettings.defaults.username,
        password: SmbSettings.defaults.password,
      );
      try {
        final stream = await conn.openRead(widget.file);
        // copy: true is required — smb_connect's openRead reuses one buffer
        // for every chunk it yields, so the chunks must be copied as they
        // arrive or they all alias the final chunk.
        final builder = BytesBuilder();
        await for (final chunk in stream) {
          builder.add(chunk);
        }
        if (!mounted) return;
        setState(() => _bytes = builder.takeBytes());
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.file.name)),
      body: _error != null
          ? Center(
              child: Text(
                'Download failed: $_error',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            )
          : _bytes == null
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: Image.memory(
                  _bytes!,
                  gaplessPlayback: true,
                  errorBuilder: (_, error, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not display image: $error',
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
