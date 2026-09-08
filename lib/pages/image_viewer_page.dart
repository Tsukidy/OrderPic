import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

import '../settings/app_settings.dart';
import '../smb/smb.dart';

/// Full-screen viewer for one image on the SMB share (pinch to zoom).
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.file,
    required this.settingsNotifier,
  });

  final SmbFile file;
  final ValueNotifier<AppSettings> settingsNotifier;

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
    final s = widget.settingsNotifier.value.connection;
    try {
      final conn = await connect(s);
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
