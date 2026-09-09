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
/// TRANSIENT page: the system camera opens the moment the page appears and
/// the page itself only ever shows a minimal 'Opening camera…' state while
/// the picker is in flight — there is no idle screen to land on, nothing to
/// tap, no way to get stuck here. Every outcome leaves the page:
///
///  - pick succeeds → the shot is admitted PENDING (name and index
///    reserved NOW via [admitPicked]) and [PreviewPage] opens while the
///    conversion still runs in the background — the next photo can be
///    taken immediately; a conversion that later fails is flagged at
///    review ([ShotStatus.failed]), it never abandons the flow;
///  - pick returns null (user backed out of the system camera) → cancel:
///    back to a fresh [PreviewPage] when shots are already staged (Retake /
///    Add photo must never discard the batch), otherwise pop the capture
///    flow to the first route (the Scan tab);
///  - the picker itself throws → SnackBar + that same two-way exit, so no
///    dead screen is ever parked under the user. Retrying means starting
///    the flow again (scan, or Add photo from the preview).
///
/// [processor] is the test seam (default the real [NativeImageProcessor]);
/// every entry to this page passes a [CaptureSession], so the numbering
/// continues across retakes/adds within one order's batch.
class CameraPage extends StatefulWidget {
  const CameraPage({
    super.key,
    required this.session,
    required this.settingsNotifier,
    this.processor = const NativeImageProcessor(),
  });

  final CaptureSession session;
  final ValueNotifier<AppSettings> settingsNotifier;

  /// Injectable admission — tests pass a fake (copying bytes), a thrower
  /// (flagging the entry failed), or a never-settling one (holding the
  /// entry pending). Defaults to production.
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
    // Transient page — open the system camera straight away; that is the
    // only reason this page exists.
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
        // Backed out of the system camera = cancelling — or, with shots
        // already staged, just returning to review. No retry-in-place: the
        // flow restarts from the scanner, or from the preview's Add photo.
        await _exit();
        return;
      }

      // Admission without waiting on the conversion: the name and index
      // are reserved NOW, the PENDING entry is staged, and the processing
      // runs behind the navigation — the next photo can be taken at once.
      // A conversion that fails never abandons the flow: its entry is
      // flagged failed at review for a retake (see [admitPicked]).
      admitPicked(
        pickedPath: photo.path,
        prefs: prefs,
        session: widget.session,
        processor: widget.processor,
      );

      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => _reviewPage()),
      );
    } catch (e) {
      // The picker itself failed (camera app crashed, permission pulled
      // mid-flight) — same contract as a processing failure: tell, leave.
      if (!mounted) return;
      await _abandon('Camera failed: $e');
    }
  }

  /// The review page for this page's session — the exit target whenever
  /// shots are already staged, and the admission target on success. The
  /// [PreviewPage] that launched the camera did so with `pushReplacement`,
  /// so "back to review" means replacing THIS page with a fresh one; the
  /// fresh state starts with the newest shot selected.
  PreviewPage _reviewPage() => PreviewPage(
    session: widget.session,
    settingsNotifier: widget.settingsNotifier,
  );

  /// Leave the page the way the user came in: review of the same session
  /// when shots are staged, the first route (Scan tab) when the session is
  /// still empty. With nothing staged the session dir would otherwise leak
  /// until the next launch's sweep — reclaim it now.
  Future<void> _exit() async {
    if (widget.session.shots.isNotEmpty) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => _reviewPage()),
      );
      return;
    }
    await widget.session.cleanupIfEmpty();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// [message] + [_exit] for a failed pick or processing. The SnackBar goes
  /// through the app-level ScaffoldMessenger BEFORE leaving — it outlives
  /// this page and surfaces on whatever the user lands on.
  Future<void> _abandon(String message) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    await _exit();
  }

  @override
  Widget build(BuildContext context) {
    // Launching state only: the order being captured plus the fact that the
    // system camera is opening. No idle screen, no manual button, no
    // settings wheel — the page's whole life is the picker being in flight
    // (or the exit that follows it).
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: _qrChip(),
              ),
            ),
            const Spacer(),
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            const Text(
              'Opening camera…',
              style: TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
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
