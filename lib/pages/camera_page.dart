import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../settings/app_settings.dart';
import 'preview_page.dart';

/// Stage 2 — take a photo of the item with the system camera app, so the
/// user gets the full native camera experience (zoom, flash, timer,
/// portrait and landscape, etc.).
class CameraPage extends StatefulWidget {
  const CameraPage({
    super.key,
    required this.orderNumber,
    required this.settingsNotifier,
  });

  final String orderNumber;
  final ValueNotifier<SmbSettings> settingsNotifier;

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
              settingsNotifier: widget.settingsNotifier,
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
