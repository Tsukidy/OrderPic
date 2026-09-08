import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../capture/image_processor.dart';
import '../capture/session.dart';
import '../settings/app_settings.dart';
import 'preview_page.dart';

/// Stage 2 — take a photo of the item with the system camera app, so the
/// user gets the full native camera experience (zoom, flash, timer,
/// portrait and landscape, etc.).
///
/// Owns one step of the capture loop: pick → process → admit into the
/// session → hand the session to PreviewPage. [processor] is the test seam
/// (default the real [NativeImageProcessor]); every entry to this page
/// passes a [CaptureSession], so the numbering continues across
/// retakes/adds within one order's batch.
class CameraPage extends StatefulWidget {
  const CameraPage({
    super.key,
    required this.session,
    required this.settingsNotifier,
    this.processor = const NativeImageProcessor(),
  });

  final CaptureSession session;
  final ValueNotifier<AppSettings> settingsNotifier;

  /// Injectable admission — tests pass a fake (copying bytes) or a thrower
  /// (exercising the failure guard). Defaults to production.
  final ImageProcessor processor;

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
      // JPEG quality presets are applied by image_picker itself; null
      // maxWidth/imageQuality leaves the camera's bytes untouched (Original,
      // and the whole PNG path — which needs the full-size JPEG to convert).
      final prefs = widget.settingsNotifier.value.upload;
      final params = prefs.format == ImageFormat.jpeg
          ? jpegPickParams(prefs)
          : null;
      final photo = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: sanitizeMaxEdge(params?.maxEdge)?.toDouble(),
        imageQuality: params?.quality,
      );
      if (!mounted) return;
      if (photo == null) {
        // User backed out — allow retry.
        setState(() => _launching = false);
        return;
      }

      // Admission: process FIRST, add only on success. A throw here (codec
      // failure, unreadable pick) must leave the session exactly as it was
      // — no half-admitted shot, numbering unchanged — so the user can
      // simply try again.
      try {
        final shot = await widget.processor.process(
          pickedPath: photo.path,
          prefs: prefs,
          session: widget.session,
        );
        widget.session.add(shot);
      } catch (_) {
        if (!mounted) return;
        setState(() => _launching = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not process photo')),
        );
        return;
      }

      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PreviewPage(
            session: widget.session,
            settingsNotifier: widget.settingsNotifier,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _launching = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Camera failed: $e')));
    }
  }

  /// Back to the scanner. When nothing is staged the session dir would
  /// otherwise leak until the next launch's sweep — reclaim it now.
  Future<void> _backToScanner() async {
    await widget.session.cleanupIfEmpty();
    if (!mounted) return;
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
        'Order: ${widget.session.orderNumber}',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }
}
