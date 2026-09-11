import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:orderpic/capture/session.dart';
import 'package:orderpic/pages/camera_page.dart';
import 'package:orderpic/pages/scanner_page.dart';
import 'package:orderpic/route_observer.dart';
import 'package:orderpic/settings/app_settings.dart';

/// Everything this file creates under Directory.systemTemp.
final List<Directory> _created = [];

/// Real IO in rounds — same shape as preview_page_test's helpers: the
/// FakeAsync zone a test body runs in never dispatches IO completions, so
/// file operations must be pumped through [tester.runAsync]. Each round
/// also advances the FAKE clock (the transition animations run on it —
/// runAsync's real-time delay does not touch it).
Future<void> _ioSettle(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 40,
}) async {
  for (var round = 0; round < maxRounds && !done(); round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue,
      reason: 'condition not reached after $maxRounds IO-settle rounds');
}

/// Picker platform whose picks hang until released: the "system camera is
/// open" state, resolved by the test (see [held]).
///
/// The gallery twin lives here too: [heldMulti] is the "multi-select sheet
/// is up" state, and [sources] records every single-pick source the page
/// asked for — the source-choice suites below assert WHICH picker a launch
/// drove, not just that one was in flight.
class _HeldPickPlatform extends ImagePickerPlatform {
  final List<Completer<XFile?>> held = [];

  /// The gallery sheet's held multi-picks, resolved by the test.
  final List<Completer<List<XFile>>> heldMulti = [];

  /// The source of every [getImageFromSource] call, in call order.
  final List<ImageSource> sources = [];

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) {
    sources.add(source);
    final c = Completer<XFile?>();
    held.add(c);
    return c.future;
  }

  /// [ImagePicker.pickMultiImage]'s delegate — overriding it (and only it)
  /// keeps the fake on the real gallery code path, the same seam
  /// preview_page_test fakes.
  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) {
    final c = Completer<List<XFile>>();
    heldMulti.add(c);
    return c.future;
  }
}

/// Empty fake platform: the scanner "starts" (a deterministic placeholder
/// view) and "stops" without ever touching a camera. Without this, the
/// method-channel platform throws MissingPluginException out of start().
class _FakeScannerPlatform extends MobileScannerPlatform {
  int starts = 0;
  int stops = 0;

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    starts += 1;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(640, 480),
      numberOfCameras: 1,
    );
  }

  @override
  Future<void> stop() async {
    stops += 1;
  }

  @override
  Widget buildCameraView() => const SizedBox.shrink();

  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();

  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<void> resetZoomScale() async {}

  @override
  Future<void> setZoomScale(double zoomScale) async {}

  @override
  Future<void> setFocusPoint(Offset position) async {}

  @override
  Future<void> toggleTorch() async {}

  @override
  Future<BarcodeCapture?> analyzeImage(
    String path, {
    List<BarcodeFormat> formats = const <BarcodeFormat>[],
  }) async => null;

  @override
  Future<Set<CameraLensType>> getSupportedLenses({CameraFacing? facing}) async =>
      {};

  @override
  Future<CameraLensType?> getBestCloseRangeScanningLens({
    CameraFacing facing = CameraFacing.back,
  }) async => null;
}

Future<void> _pumpScanner(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      // Production registers the shared observer (main.dart) — the
      // scanner's covered-route tracking depends on it.
      navigatorObservers: [routeObserver],
      home: ScannerPage(
        settingsNotifier: ValueNotifier(AppSettings.defaults),
      ),
    ),
  );
  await tester.pump(); // scanner starts (fake platform — no camera)
}

/// The scanner's own onDetect, grabbed off the rendered MobileScanner.
void Function(BarcodeCapture) _onDetectOf(WidgetTester tester) {
  final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
  return scanner.onDetect!;
}

void main() {
  /// The fake scanner platform installed for the running test — the
  /// rescan suite counts its starts to prove the scanner resumed.
  late _FakeScannerPlatform scannerPlatform;

  setUp(() {
    scannerPlatform = _FakeScannerPlatform();
    MobileScannerPlatform.instance = scannerPlatform;
  });

  tearDown(() {
    for (final d in _created.toList().reversed) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {/* test cleanup only */}
    }
    _created.clear();
  });

  testWidgets('a detection arriving while another route covers the scanner '
      'is ignored (multi-photo flow: returning from the system camera '
      'restarts the scanner camera underneath)', (tester) async {
    await _pumpScanner(tester);
    // Grab the callback BEFORE the covering route settles — an opaque route
    // unmounts the covered scanner from the element tree (on device the
    // camera restart still feeds it detections via the controller stream).
    final onDetect = _onDetectOf(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('COVERING PAGE'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(
      Future.sync(
        () => onDetect(
          const BarcodeCapture(barcodes: [Barcode(rawValue: '100438')]),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('QR code scanned'), findsNothing,
        reason: 'no QR dialog while the capture flow covers the scanner');
    expect(find.text('COVERING PAGE'), findsOneWidget,
        reason: 'the covering route stays top-most — nothing was pushed');
  });

  testWidgets('scanned QR → camera in flight; backing out of the system '
      'camera (null pick) cancels back to the scanner', (tester) async {
    final session = await _ioSettleFuture(
      tester,
      () => CaptureSession.create('100438'),
    );
    _created.add(session.dir);

    // A HELD pick: the "system camera is open" state. An instant null would
    // tear CameraPage down before the assertions below can see it.
    final picker = _HeldPickPlatform();
    ImagePickerPlatform.instance = picker;

    await _pumpScanner(tester);
    final onDetect = _onDetectOf(tester);
    unawaited(
      Future.sync(
        () => onDetect(
          const BarcodeCapture(barcodes: [Barcode(rawValue: '100438')]),
        ),
      ),
    );
    await tester.pump(); // confirm dialog starts
    await tester.pumpAndSettle();
    expect(find.text('QR code scanned'), findsOneWidget);

    await tester.tap(find.text('Take photo'));
    await tester.pump(); // pop the dialog, start the session create
    await _ioSettle(
      tester,
      () => find.byType(CameraPage).evaluate().isNotEmpty,
    );
    // No pumpAndSettle from here on: the launching spinner is an
    // indeterminate animation and would never settle.
    await tester.pump(const Duration(milliseconds: 400)); // push transition

    expect(find.byType(CameraPage), findsOneWidget);
    expect(find.text('Order: 100438'), findsOneWidget,
        reason: 'the launching state shows the order chip');
    expect(find.text('Opening camera…'), findsOneWidget);
    expect(picker.held, hasLength(1), reason: 'the camera is in flight');

    // Backing out of the system camera → pickImage completes with null →
    // CameraPage must pop the flow (ScannerPage's awaited push returns).
    picker.held.single.complete(null);
    await _ioSettle(
      tester,
      () => find.byType(CameraPage).evaluate().isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400)); // pop transition

    expect(find.byType(CameraPage), findsNothing,
        reason: 'cancel leaves the capture flow');
    expect(find.text('Scan QR code'), findsOneWidget,
        reason: 'the scanner is back on top');
  });

  testWidgets('QR dialog: Gallery confirm opens the gallery multi-pick — '
      'the flow launches with the order chip', (tester) async {
    final picker = _HeldPickPlatform();
    ImagePickerPlatform.instance = picker;

    await _pumpScanner(tester);
    final onDetect = _onDetectOf(tester);
    unawaited(
      Future.sync(
        () => onDetect(
          const BarcodeCapture(barcodes: [Barcode(rawValue: '100438')]),
        ),
      ),
    );
    await tester.pump(); // confirm dialog starts
    await tester.pumpAndSettle();
    expect(find.text('QR code scanned'), findsOneWidget);

    await tester.tap(find.text('Gallery'));
    await tester.pump(); // pop the dialog, start the session create
    await _ioSettle(
      tester,
      () => find.byType(CameraPage).evaluate().isNotEmpty,
    );
    // No pumpAndSettle from here on: the launching spinner is an
    // indeterminate animation and would never settle.
    await tester.pump(const Duration(milliseconds: 400)); // push transition

    expect(find.byType(CameraPage), findsOneWidget);
    expect(find.text('Order: 100438'), findsOneWidget,
        reason: 'the launching state shows the order chip');
    expect(find.text('Opening gallery…'), findsOneWidget,
        reason: 'the GALLERY source drives this launch');
    expect(picker.heldMulti, hasLength(1),
        reason: 'the gallery multi-pick is in flight');
    expect(picker.sources, isEmpty,
        reason: 'a gallery launch never touches the camera pick');

    // Unwind: the sheet comes back empty (the real plugin's cancel shape) —
    // the still-empty session is reclaimed and the scanner resumes. Keeps
    // this test from leaking its held session dir past teardown.
    picker.heldMulti.single.complete(const <XFile>[]);
    await _ioSettle(
      tester,
      () => find.byType(CameraPage).evaluate().isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400)); // pop transition
    expect(find.text('Scan QR code'), findsOneWidget,
        reason: 'the empty sheet cancelled back to the scanner');
  });

  testWidgets('QR dialog: Take photo confirm opens the system camera — the '
      'camera-source launch exactly as before the gallery option', (tester) async {
    final picker = _HeldPickPlatform();
    ImagePickerPlatform.instance = picker;

    await _pumpScanner(tester);
    final onDetect = _onDetectOf(tester);
    unawaited(
      Future.sync(
        () => onDetect(
          const BarcodeCapture(barcodes: [Barcode(rawValue: '100438')]),
        ),
      ),
    );
    await tester.pump(); // confirm dialog starts
    await tester.pumpAndSettle();
    expect(find.text('QR code scanned'), findsOneWidget);

    await tester.tap(find.text('Take photo'));
    await tester.pump(); // pop the dialog, start the session create
    await _ioSettle(
      tester,
      () => find.byType(CameraPage).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400)); // push transition

    expect(find.byType(CameraPage), findsOneWidget);
    expect(find.text('Order: 100438'), findsOneWidget,
        reason: 'the launching state shows the order chip');
    expect(find.text('Opening camera…'), findsOneWidget,
        reason: 'the CAMERA source drives this launch');
    expect(picker.sources.single, ImageSource.camera,
        reason: 'the single pick was asked for the CAMERA source');
    expect(picker.heldMulti, isEmpty,
        reason: 'a camera launch never touches the gallery pick');

    // Unwind (as the first camera suite does): backing out of the system
    // camera cancels back to the scanner.
    picker.held.single.complete(null);
    await _ioSettle(
      tester,
      () => find.byType(CameraPage).evaluate().isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400)); // pop transition
    expect(find.text('Scan QR code'), findsOneWidget);
  });

  testWidgets('QR dialog: Rescan starts nothing — no session dir, no route, '
      'the scanner resumes', (tester) async {
    final dirsBefore = await _sessionDirs(tester);

    await _pumpScanner(tester);
    final startsBefore = scannerPlatform.starts;
    final onDetect = _onDetectOf(tester);
    unawaited(
      Future.sync(
        () => onDetect(
          const BarcodeCapture(barcodes: [Barcode(rawValue: '100438')]),
        ),
      ),
    );
    await tester.pump(); // confirm dialog starts
    await tester.pumpAndSettle();
    expect(find.text('QR code scanned'), findsOneWidget);

    await tester.tap(find.text('Rescan'));
    await tester.pump(); // dialog pops, the dismiss branch runs
    await tester.pumpAndSettle();

    expect(find.text('QR code scanned'), findsNothing,
        reason: 'the dialog is dismissed');
    expect(find.byType(CameraPage), findsNothing,
        reason: 'no capture flow was pushed');
    expect(scannerPlatform.starts, startsBefore + 1,
        reason: 'the scanner restarted after the rescan');

    final dirsAfter = await _sessionDirs(tester);
    expect(dirsAfter.length, dirsBefore.length,
        reason: 'no session dir was born — the flow never started');
  });
}

/// The `mmcpic-session-*` dirs currently under the system temp — the "no
/// flow started" evidence: a capture flow is BORN as one of these.
Future<List<String>> _sessionDirs(WidgetTester tester) async {
  final dirs = await tester.runAsync(() async {
    return [
      for (final e in Directory.systemTemp.listSync())
        if (e is Directory &&
            e.uri.pathSegments.where((s) => s.isNotEmpty).last
                .startsWith(CaptureSession.dirPrefix))
          e.path,
    ];
  });
  return dirs ?? const <String>[];
}

/// runAsync wrapper for a one-shot future.
Future<T> _ioSettleFuture<T>(
  WidgetTester tester,
  Future<T> Function() body,
) async {
  final r = await tester.runAsync(body);
  return r as T;
}
