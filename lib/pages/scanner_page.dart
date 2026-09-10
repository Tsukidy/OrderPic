import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../capture/session.dart';
import '../route_observer.dart';
import '../settings/app_settings.dart';
import 'camera_page.dart';

/// Stage 1 — scan the QR code
class ScannerPage extends StatefulWidget {
  const ScannerPage({
    super.key,
    required this.settingsNotifier,
    this.onOpenSettings,
    this.paused = false,
  });

  final ValueNotifier<AppSettings> settingsNotifier;
  final VoidCallback? onOpenSettings;

  /// True while another tab is on top — pauses the camera.
  final bool paused;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage>
    with RouteAware, WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final TextEditingController _entryController = TextEditingController();
  bool _processing = false;

  /// True while a page route covers the shell (set by [didPushNext], cleared
  /// by [didPopNext]). Lookup-free by design: a covered route's subtree can
  /// be deactivated, where inherited-widget lookups like ModalRoute.of would
  /// throw — and `pushReplacement` between capture stages never re-fires
  /// didPushNext, which keeps this correctly true through the whole
  /// multi-photo loop.
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    // The PAGE owns lifecycle handling (see [didChangeAppLifecycleState]):
    // the MobileScanner widget's own handler restarts the camera on every
    // app resume — including the resume from the system camera mid-capture
    // flow, which would set the scanner scanning under the covered shell.
    WidgetsBinding.instance.addObserver(this);
  }

  // RouteAware: the camera must also stop while a route is pushed over the
  // tab shell (Settings, the capture flow) — `paused` only covers tab
  // switches. Subscribe in didChangeDependencies rather than initState:
  // ModalRoute.of() is an inherited-widget lookup, which is not allowed
  // before initState completes. Runs again when the ModalRoute dependency
  // changes (never here: the page sits in an IndexedStack under one route),
  // so double-subscription is not a concern; RouteAware re-subscription is
  // additive anyway (a Set add).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of returns ModalRoute<Object?>; this page only ever lives
    // under the shell's MaterialPageRoute, so the downcast is safe.
    routeObserver.subscribe(this, ModalRoute.of(context) as PageRoute);
  }

  /// App resume must NOT blindly restart the camera: coming back from the
  /// system camera (mid capture flow) resumes the app while a route still
  /// covers the scanner — starting there re-arms QR detection under the
  /// flow. Only a scanner that is actually on screen resumes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (!widget.paused && !_processing && !_covered) {
          unawaited(_controller.start());
        }
      case AppLifecycleState.paused:
        unawaited(_controller.stop());
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void didUpdateWidget(ScannerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paused != oldWidget.paused && !_processing) {
      unawaited(widget.paused ? _controller.stop() : _controller.start());
    }
  }

  /// A page route was pushed on top of this one (Settings, CameraPage) —
  /// stop the camera so the scanner can't fire while covered.
  ///
  /// Dialogs (showDialog) are popup routes and don't reach here; the QR
  /// confirm dialog keeps relying on `_processing` + the explicit `stop()`
  /// in `_onDetect`.
  @override
  void didPushNext() {
    _covered = true;
    unawaited(_controller.stop());
  }

  /// The route above was popped — the scanner is visible again. Resume only
  /// when the History tab isn't on top and no capture/dialog flow owns the
  /// controller. When `_startCapture`'s awaited push returns right after
  /// this (popUntil back from the flow), it does its own restart — starting
  /// here as well would race it (`start()` throws if a start is pending).
  @override
  void didPopNext() {
    _covered = false;
    if (!widget.paused && !_processing) {
      unawaited(_controller.start());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    _controller.dispose();
    _entryController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    // A detection is only ours to handle when the scanner is the page on
    // screen. The camera can restart underneath a covering route (the
    // app-resume path from the system camera — see
    // [didChangeAppLifecycleState]); a detection from such a restart must
    // never open the QR dialog over the capture flow.
    if (!mounted || widget.paused || _covered) return;
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
  ///
  /// The session is born here so the whole flow (camera → preview →
  /// retakes/adds → upload) shares one [CaptureSession] and its shot
  /// numbering. When it empties, the flow reclaims the dir itself
  /// (uploadSession's cleanupIfEmpty / CameraPage's cancel path); shots
  /// still staged at pop are left for the next-launch sweep.
  Future<void> _startCapture(String orderNumber) async {
    await _controller.stop();
    if (!mounted) return;
    final CaptureSession session;
    try {
      session = await CaptureSession.create(orderNumber);
    } catch (e) {
      // A failed session create must not leave the scanner frozen with
      // _processing stuck true — mirror the dialog-cancel path.
      if (!mounted) return;
      _processing = false;
      unawaited(_controller.start());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not start capture: $e')));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraPage(
          session: session,
          settingsNotifier: widget.settingsNotifier,
        ),
      ),
    );
    // Flow finished or was cancelled with shots still staged? They stay on
    // disk under the session dir; a later 'More for this order' path or the
    // next-launch sweep owns them from here.
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
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // Lifecycle is handled by THIS page route-awarely; the widget's
            // own handler would restart the camera on every app resume.
            useAppLifecycleState: false,
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
