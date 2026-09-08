import 'dart:io';

import 'package:flutter/material.dart';

import '../capture/session.dart';
import '../capture/uploader.dart';
import '../settings/app_settings.dart';
import 'camera_page.dart';

/// Stage 3 — review the newest photo of the session, then retake it, add
/// more (batch mode), or upload every staged shot to the SMB share.
///
/// The upload itself lives in [uploadSession] (Task 4.1); this page only
/// owns the state machine around it. [PreviewPage.uploader] is the test
/// seam — null means the real thing, exactly like the `SettingsStore` /
/// `ImageProcessor` seams.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.session,
    required this.settingsNotifier,
    this.uploader,
  });

  final CaptureSession session;
  final ValueNotifier<AppSettings> settingsNotifier;

  /// Injectable upload — null → the real [uploadSession]. Tests pass a
  /// fake that records calls and returns a canned [UploadSummary]. The
  /// extra named [onProgress] parameter keeps the injected shape
  /// assignable from the real `uploadSession` while letting fakes ignore
  /// progress.
  final Future<UploadSummary> Function(
    CaptureSession,
    AppSettings, {
    void Function(int done, int total)? onProgress,
  })? uploader;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

enum _UploadStatus { idle, uploading, done, failed }

class _PreviewPageState extends State<PreviewPage> {
  _UploadStatus _status = _UploadStatus.idle;

  /// The file name shown by the batch-off done banner (the session's last
  /// uploaded shot) — 'Uploaded: {fileName}' preserves today's shape.
  String? _uploadedName;

  /// Upload-progress overlay counters. `done` counts PROCESSED shots
  /// (uploader contract) — never used as the "N uploaded" figure; that is
  /// the summary's [UploadSummary.uploadedCount].
  int _done = 0;
  int _total = 0;
  UploadSummary? _summary;

  /// Thrown-uploader escape text (per-shot errors live in [_summary]).
  String? _error;

  /// Last path the full-screen image pointed at. A successful upload
  /// empties the session (the uploader deletes each local file and reclaims
  /// the dir), but today's page keeps showing the just-uploaded photo
  /// behind the done banner — the image cache still holds it. Pin the path
  /// so that survives the session emptying.
  String? _lastShownPath;

  /// The folder-bundling UI switch: count chip, thumb strip, Add photo,
  /// Upload all. Batch OFF must stay exactly today's single-shot UX.
  bool get _batchOn => widget.settingsNotifier.value.upload.batchMode;

  Future<void> _uploadAll() async {
    if (_status == _UploadStatus.uploading) return;
    setState(() {
      _status = _UploadStatus.uploading;
      _uploadedName = null;
      _done = 0;
      _total = widget.session.shots.length;
      _summary = null;
      _error = null;
    });

    try {
      // Retry is this same call: failed shots stay staged, so re-invoking
      // the uploader on the session covers exactly the remaining shots.
      final summary = await _runUpload();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _status = summary.allOk ? _UploadStatus.done : _UploadStatus.failed;
        if (summary.allOk && summary.outcomes.isNotEmpty) {
          _uploadedName = summary.outcomes.last.shot.fileName;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _UploadStatus.failed;
          _summary = null;
          _error = e.toString();
        });
      }
    }
  }

  Future<UploadSummary> _runUpload() {
    final injected = widget.uploader;
    if (injected != null) {
      return injected(
        widget.session,
        widget.settingsNotifier.value,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
      );
    }
    return uploadSession(
      widget.session,
      widget.settingsNotifier.value,
      onProgress: (done, total) {
        if (mounted) setState(() => _done = done);
      },
    );
  }

  /// Back to the camera for the SAME session. [removeLast] is true only for
  /// Retake (drop the newest shot, delete its file — that shot never
  /// happened, [CaptureSession.nextIndex] rolls back with it); Add photo
  /// keeps every staged shot. Either way the session survives, so shot
  /// numbering and the batch keep accumulating.
  Future<void> _openCamera({required bool removeLast}) async {
    if (removeLast) {
      final shot = widget.session.removeLast();
      if (shot != null) await widget.session.deleteLocal(shot);
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraPage(
          session: widget.session,
          settingsNotifier: widget.settingsNotifier,
        ),
      ),
    );
  }

  /// Post-upload continuation for the same order — a FRESH session (new
  /// dir, numbering restarted), never a reuse of the one that just
  /// finished. Both 'More for this order' (batch on) and 'Another photo
  /// (same order)' (batch off) land here.
  Future<void> _moreForThisOrder() async {
    final session = await CaptureSession.create(widget.session.orderNumber);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraPage(
          session: session,
          settingsNotifier: widget.settingsNotifier,
        ),
      ),
    );
  }

  void _scanNext() {
    // Pop the capture flow and land back on the tab shell (Scan tab).
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// One line per failed outcome, in session order — a dead local file
  /// would otherwise be invisible behind a single blob message.
  List<String> get _failedLines => [
    for (final o in _summary?.outcomes ?? const <UploadOutcome>[])
      if (!o.ok) '${o.shot.fileName}: ${o.error ?? 'failed'}',
  ];

  @override
  Widget build(BuildContext context) {
    final shots = widget.session.shots;
    if (shots.isNotEmpty) _lastShownPath = shots.last.localPath;
    final shownPath = _lastShownPath;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: shownPath == null
                ? const SizedBox.shrink()
                : Image.file(
                    File(shownPath),
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
                    if (_status == _UploadStatus.done)
                      _doneBanner()
                    else if (_batchOn)
                      _batchChip(shots.length)
                    else
                      _qrChip(),
                  ],
                ),
                if (_batchOn && _status != _UploadStatus.done)
                  _thumbStrip(shots),
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
                'Uploading $_done / $_total',
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
    return _pill(
      color: Colors.black54,
      text: 'Order: ${widget.session.orderNumber}',
      fontSize: 16,
    );
  }

  /// Batch-mode header: the order plus how many photos are staged so far.
  Widget _batchChip(int count) {
    final noun = count == 1 ? 'photo' : 'photos';
    return _pill(
      color: Colors.black54,
      text: 'Order: ${widget.session.orderNumber} — $count $noun',
      fontSize: 16,
    );
  }

  /// Display-only thumbnails of every staged shot, oldest first; the
  /// newest is highlighted.
  Widget _thumbStrip(List<Shot> shots) {
    return SizedBox(
      key: const Key('thumb_strip'),
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: shots.length,
        itemBuilder: (context, i) => Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            border: Border.all(
              color: i == shots.length - 1 ? Colors.white : Colors.white30,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Image.file(
              File(shots[i].localPath),
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        ),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
      ),
    );
  }

  Widget _doneBanner() {
    if (_batchOn) {
      final n = _summary?.uploadedCount ?? 0;
      return _pill(
        color: Colors.green,
        text: 'Uploaded $n photo${n == 1 ? '' : 's'}',
      );
    }
    return _pill(color: Colors.green, text: 'Uploaded: ${_uploadedName ?? ''}');
  }

  Widget _pill({
    required Color color,
    required String text,
    double fontSize = 14,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _errorBanner() {
    final lines = _failedLines;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Upload failed:',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          if (lines.isEmpty)
            Text(_error ?? 'unknown error', style: const TextStyle(color: Colors.white))
          else
            ...lines.map((line) => Text(line, style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }

  OutlinedButton _outlined({IconData? icon, required String label, VoidCallback? onPressed, Key? key}) {
    return OutlinedButton.icon(
      key: key,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white),
      ),
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
    );
  }

  FilledButton _filled({
    IconData? icon,
    required String label,
    VoidCallback? onPressed,
    Key? key,
  }) {
    return FilledButton.icon(
      key: key,
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
    );
  }

  Widget _bottomButtons() {
    switch (_status) {
      case _UploadStatus.uploading:
        return const SizedBox.shrink();

      case _UploadStatus.done:
        if (_batchOn) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _outlined(
                icon: Icons.add_a_photo,
                label: 'More for this order',
                onPressed: _moreForThisOrder,
              ),
              _filled(
                icon: Icons.qr_code_scanner,
                label: 'Scan next QR code',
                onPressed: _scanNext,
              ),
            ],
          );
        }
        // Today's single-shot done row, labels verbatim.
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _outlined(
              icon: Icons.photo_camera,
              label: 'Another photo\n(same order)',
              onPressed: _moreForThisOrder,
            ),
            _filled(
              icon: Icons.qr_code_scanner,
              label: 'Scan next\nQR code',
              onPressed: _scanNext,
            ),
          ],
        );

      case _UploadStatus.failed:
        if (_batchOn) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _outlined(
                icon: Icons.refresh,
                label: 'Retry upload',
                onPressed: _uploadAll,
              ),
              _filled(
                icon: Icons.qr_code_scanner,
                label: 'Scan next QR code',
                onPressed: _scanNext,
              ),
            ],
          );
        }
        // Today's single-shot failed row (Retake stays; the QR icon above
        // is the scan-next escape, as before).
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _outlined(
              icon: Icons.refresh,
              label: 'Retake',
              onPressed: () => _openCamera(removeLast: true),
            ),
            _filled(icon: Icons.refresh, label: 'Retry upload', onPressed: _uploadAll),
          ],
        );

      case _UploadStatus.idle:
        if (_batchOn) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _outlined(
                icon: Icons.refresh,
                label: 'Retake',
                onPressed: () => _openCamera(removeLast: true),
              ),
              _outlined(
                key: const Key('add_photo_button'),
                icon: Icons.add_a_photo,
                label: 'Add photo',
                onPressed: () => _openCamera(removeLast: false),
              ),
              _filled(
                key: const Key('upload_all_button'),
                icon: Icons.cloud_upload,
                label: 'Upload all',
                onPressed: _uploadAll,
              ),
            ],
          );
        }
        // Today's single-shot idle row.
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _outlined(
              icon: Icons.refresh,
              label: 'Retake',
              onPressed: () => _openCamera(removeLast: true),
            ),
            _filled(icon: Icons.cloud_upload, label: 'Upload', onPressed: _uploadAll),
          ],
        );
    }
  }
}
