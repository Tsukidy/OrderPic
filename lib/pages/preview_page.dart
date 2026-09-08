import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../capture/naming.dart';
import '../settings/app_settings.dart';
import '../smb/smb.dart';
import 'camera_page.dart';

/// Stage 3 — review the photo, then retake or upload it to the SMB share.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.orderNumber,
    required this.imagePath,
    required this.settingsNotifier,
  });

  final String orderNumber;
  final String imagePath;
  final ValueNotifier<AppSettings> settingsNotifier;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

enum _UploadStatus { idle, uploading, done, failed }

class _PreviewPageState extends State<PreviewPage> {
  _UploadStatus _status = _UploadStatus.idle;
  String? _uploadedName;
  String? _error;

  Future<void> _upload() async {
    if (_status == _UploadStatus.uploading) return;

    final fileName = buildUploadFileName(widget.orderNumber, DateTime.now());
    setState(() {
      _status = _UploadStatus.uploading;
      _uploadedName = fileName;
      _error = null;
    });

    try {
      final s = widget.settingsNotifier.value.connection;
      final bytes = await File(widget.imagePath).readAsBytes();
      final conn = await connect(s);
      try {
        // The share itself must already exist; sub-folders are created here.
        try {
          await conn.createFolder(s.sharePath);
        } catch (_) {
          // Folder already exists (or deeper nesting is missing) — ignore.
        }
        final remoteFile = await conn.createFile('${s.sharePath}/$fileName');
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
        builder: (_) => CameraPage(
          orderNumber: widget.orderNumber,
          settingsNotifier: widget.settingsNotifier,
        ),
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
