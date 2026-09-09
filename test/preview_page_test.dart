import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:orderpic/capture/image_processor.dart';
import 'package:orderpic/capture/session.dart';
import 'package:orderpic/capture/uploader.dart';
import 'package:orderpic/pages/camera_page.dart';
import 'package:orderpic/pages/preview_page.dart';
import 'package:orderpic/settings/app_settings.dart';

/// Everything this file creates under Directory.systemTemp, so tearDown can
/// remove it without touching anything the user put there. Only ever dirs
/// made by [CaptureSession.create] (plus one scratch dir for the fake
/// processor's "picked" files).
final List<Directory> _created = [];

/// A valid 1x1 grayscale PNG (CRC-verified) — the batch UI renders
/// [Image.file] of the staged shots, so the staged bytes must decode as a
/// real image even in the test engine's software codec.
const List<int> _pngBytes = <int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02, 0x00, 0x00, 0x00,
  0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64, 0x60, 0x00, 0x00,
  0x00, 0x06, 0x00, 0x02, 0x30, 0x81, 0xd0, 0x2f, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

/// The two runAsync wrappers every real-IO touch in a testWidgets body must
/// go through: the FakeAsync zone a test body runs in never dispatches IO
/// completions, so awaiting file operations directly hangs the test forever
/// (learned the hard way — see the report).
///
/// [_real] runs [body] on the REAL event loop and unwraps runAsync's T?
/// (its signature is nullable for historical reasons; it never yields null
/// here).
Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async {
  final r = await tester.runAsync(body);
  return r as T;
}

/// Pumps REAL time + a frame in rounds until [done] turns true — for IO the
/// WIDGET triggers (processor copies, deleteLocal, session-dir creation).
/// Each round lets pending file operations complete on the real loop and
/// then drains the FakeAsync microtasks that continue the chain. Bounded so
/// a regression fails the test instead of hanging the run.
Future<void> _ioSettle(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 40,
}) async {
  for (var round = 0; round < maxRounds && !done(); round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(done(), isTrue,
      reason: 'condition not reached after $maxRounds IO-settle rounds');
}

/// Real session with [count] real staged files.
Future<CaptureSession> _sessionOf(String orderNumber, int count) async {
  final s = await CaptureSession.create(orderNumber);
  _created.add(s.dir);
  for (var i = 0; i < count; i++) {
    final f = File('${s.dir.path}/shot-$i.png');
    await f.writeAsBytes(_pngBytes);
    s.add(Shot(localPath: f.path, fileName: '100438_shot_$i.png'));
  }
  return s;
}

/// A scratch "picked" file, as image_picker would hand one over.
Future<File> _pickedFile(String name) async {
  final scratch = await Directory.systemTemp.createTemp('mmcpic-pick-src');
  _created.add(scratch);
  return File('${scratch.path}/$name')..writeAsBytesSync(_pngBytes);
}

AppSettings _settings({required bool batch}) => AppSettings(
  connection: const ConnectionSettings(
    host: '192.0.2.1',
    sharePath: '/zdrive/InvoiceData',
    domain: '',
    username: '',
    password: '',
  ),
  upload: UploadPrefs(batchMode: batch, format: ImageFormat.png),
);

/// The seam shape PreviewPage expects: the extra named [onProgress] mirrors
/// the real `uploadSession` signature so the default (real) uploader is
/// directly assignable; fakes ignore the callback.
typedef _Uploader =
    Future<UploadSummary> Function(
      CaptureSession,
      AppSettings, {
      void Function(int done, int total)? onProgress,
    });

/// Records every call and replays a scripted [UploadSummary] per pass. The
/// fake does NOT touch the session's files — how the real uploader mutates
/// staged state is covered in test/uploader_test.dart; here it only feeds
/// the page's state machine.
class _FakeUploader {
  final List<CaptureSession> sessions = [];
  final List<UploadSummary> next = [];

  Future<UploadSummary> call(
    CaptureSession session,
    AppSettings settings, {
    void Function(int done, int total)? onProgress,
  }) {
    sessions.add(session);
    return Future.value(next.removeAt(0));
  }
}

/// A well-formed [UploadSummary]: one [UploadOutcome] per [shots], the ones
/// in [failed] marked !ok with a canned error.
UploadSummary _summary(List<Shot> shots, {Set<int> failed = const {}}) =>
    UploadSummary([
      for (var i = 0; i < shots.length; i++)
        failed.contains(i)
            ? UploadOutcome(shots[i], false, 'SMB write failed (shot ${i + 1})')
            : UploadOutcome(shots[i], true, null),
    ]);

Future<void> _pumpPreview(
  WidgetTester tester, {
  required CaptureSession session,
  required bool batch,
  _Uploader? uploader,
  ImageProcessor processor = const _CopyProcessor(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PreviewPage(
        session: session,
        settingsNotifier: ValueNotifier(_settings(batch: batch)),
        uploader: uploader,
        processor: processor,
      ),
    ),
  );
  await tester.pump();
}

/// The file backing the FULL-SCREEN preview. [Image.file] with no
/// cacheWidth wraps its bytes in a bare [FileImage]; the thumbnails' decode
/// cap wraps theirs in a [ResizeImage] — so this predicate matches the big
/// image alone, and the assertion goes through the image's file path.
File _fullScreenFile(WidgetTester tester) {
  final img = tester.widget<Image>(
    find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
  );
  return (img.image as FileImage).file;
}

/// The strip's thumbnail [Image]s, oldest first.
List<Image> _thumbs(WidgetTester tester) => tester
    .widgetList<Image>(
      find.descendant(
        of: find.byKey(const Key('thumb_strip')),
        matching: find.byType(Image),
      ),
    )
    .toList();

/// Copies the picked bytes into the session dir under the 4-part name —
/// the same shape the real processor returns, minus any codec.
class _CopyProcessor implements ImageProcessor {
  const _CopyProcessor();

  @override
  Future<Shot> process({
    required String pickedPath,
    required UploadPrefs prefs,
    required CaptureSession session,
  }) async {
    final fileName = '100438_20260908_101112_'
        '${session.nextIndex.toString().padLeft(3, '0')}.png';
    final target = File('${session.dir.path}/$fileName');
    await File(pickedPath).copy(target.path);
    return Shot(localPath: target.path, fileName: fileName);
  }
}

/// Always throws the way a codec failure would — before any Shot exists,
/// so the caller's `add` is never reached.
class _ThrowingProcessor implements ImageProcessor {
  const _ThrowingProcessor();

  @override
  Future<Shot> process({
    required String pickedPath,
    required UploadPrefs prefs,
    required CaptureSession session,
  }) async => throw Exception('codec failed');
}

/// Feeds [ImagePicker.pickImage] from the platform-interface seam — no
/// method channel, no file_selector (camera source needs no delegate: this
/// fake answers getImageFromSource directly). A null entry (or an exhausted
/// script) means "user backed out" → null, exactly like the real picker.
///
/// A script entry of [heldPick] never completes on its own: the camera is
/// "in flight" until the test releases the matching [_HeldPick] (in [held],
/// call order), which is how the real system camera behaves — the pick
/// future only settles when the user comes back.
class _FakePickerPlatform extends ImagePickerPlatform {
  /// Sentinel script entry: hold the pick open until released.
  static const String heldPick = '__held__';

  _FakePickerPlatform(this.pickedPaths);

  final List<String?> pickedPaths;
  final List<_HeldPick> held = [];

  int _calls = 0;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    final String? path;
    if (_calls < pickedPaths.length) {
      path = pickedPaths[_calls];
      _calls += 1;
    } else {
      path = null;
    }
    if (identical(path, heldPick)) {
      final h = _HeldPick();
      held.add(h);
      return h.completer.future;
    }
    return path == null ? null : XFile(path);
  }
}

/// The release handle for a [heldPick] script entry: the "system camera is
/// open" state, resolved by the test.
class _HeldPick {
  final completer = Completer<XFile?>();

  /// The camera app came back with a photo at [path].
  void resolve(String path) => completer.complete(XFile(path));

  /// The user backed out of the camera app.
  void cancel() => completer.complete(null);
}

/// Every pick throws the way a dead camera app / a pulled permission does —
/// exercises the pick-time `catch` in [_CameraPageState._takePhoto].
class _CrashingPickerPlatform extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => throw PlatformException(
    code: 'camera_error',
    message: 'camera_in_use',
  );
}

/// The admission wrapper CameraPage wires: process, then — and only then —
/// add. Plain `test` (no FakeAsync), so the real file IO is fine.
Future<void> _admit(
  ImageProcessor processor, {
  required String pickedPath,
  required UploadPrefs prefs,
  required CaptureSession session,
}) async {
  try {
    final shot = await processor.process(
      pickedPath: pickedPath,
      prefs: prefs,
      session: session,
    );
    session.add(shot);
  } catch (_) {
    // CameraPage shows the snackbar; the session stays untouched.
  }
}

void main() {
  setUp(() {
    // Default per-test platform: installed but scriptless → every pick
    // behaves as "user backed out" (null), so a pushed CameraPage runs its
    // cancel exit instead of touching the method channel.
    ImagePickerPlatform.instance = _FakePickerPlatform([]);
  });

  tearDown(() {
    for (final d in _created.toList().reversed) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {/* test cleanup only */}
    }
    _created.clear();
  });

  group('PreviewPage batch ON', () {
    testWidgets('session of 3: count chip, 3-image strip, all three buttons',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      await _pumpPreview(tester, session: session, batch: true);

      expect(find.text('Order: 100438 — 3 photos'), findsOneWidget);
      expect(find.byKey(const Key('thumb_strip')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('thumb_strip')),
          matching: find.byWidgetPredicate((w) => w is Image),
        ),
        findsNWidgets(3),
      );
      expect(find.text('Retake'), findsOneWidget);
      expect(find.text('Add photo'), findsOneWidget);
      expect(find.byKey(const Key('upload_all_button')), findsOneWidget);
    });

    testWidgets('one staged photo still singularizes correctly ("1 photo")',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      await _pumpPreview(tester, session: session, batch: true);

      expect(find.text('Order: 100438 — 1 photo'), findsOneWidget);
    });

    testWidgets('default full-screen preview is the LAST shot; tapping the '
        'first thumbnail shows THAT shot; tapping the last thumbnail goes '
        'back', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final shots = session.shots.toList();
      await _pumpPreview(tester, session: session, batch: true);

      // Default: the newest shot fills the screen (today's behavior).
      expect(_fullScreenFile(tester).path, shots.last.localPath);

      // Tap the first thumbnail → shot 1 goes full-screen...
      final stripTiles = find.descendant(
        of: find.byKey(const Key('thumb_strip')),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(stripTiles.first);
      await tester.pump();
      expect(_fullScreenFile(tester).path, shots.first.localPath,
          reason: 'the tapped thumbnail becomes the reviewed shot');

      // ...and tapping the last thumbnail is the way back to the newest.
      await tester.tap(stripTiles.last);
      await tester.pump();
      expect(_fullScreenFile(tester).path, shots.last.localPath);

      // The strip still shows all three thumbnails, untouched.
      expect(_thumbs(tester), hasLength(3));
    });

    testWidgets('Upload all → uploader called once with the session; '
        'allOk → done banner counts photos', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final fake = _FakeUploader()..next.add(_summary(session.shots));
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();

      expect(fake.sessions, [session]);
      expect(find.text('Uploaded 3 photos'), findsOneWidget);
    });

    testWidgets('progress overlay counts processed shots as they land',
        (tester) async {
      // Drive the injected seam (real-shaped: it accepts onProgress): the
      // first shot's pass completes, the second's hangs forever — the
      // overlay must show 'Uploading 1 / 2', not a blob or the final count
      // (onProgress counts PROCESSED shots; the page never derives "done"
      // from it — allOk/failed comes from the summary).
      final session = await _real(tester, () => _sessionOf('100439', 2));
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: (s, settings, {onProgress}) async {
          onProgress?.call(1, 2); // shot 1 processed
          await Completer<void>().future; // shot 2 hangs BEFORE its tick
          // Never reached — the hang above IS the scenario under test.
          throw StateError('unreachable');
        },
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();
      // The fake ticks shot 1 synchronously before hanging, so the very
      // first pumped frame already shows the processed count — proving the
      // overlay renders the LIVE counter, not just the total.
      expect(find.text('Uploading 1 / 2'), findsOneWidget,
          reason: "overlay tracks onProgress's processed count");

      // Give the (hung) pass a few real rounds; it must never finish, so
      // no done banner may appear.
      await _ioSettle(
        tester,
        () => find.text('Uploading 1 / 2').evaluate().isNotEmpty,
      );

      expect(find.text('Uploaded 2 photos'), findsNothing,
          reason: 'the pass never finished — no done banner');
      expect(session.shots, hasLength(2),
          reason: 'the fake never mutates staged state');
    });

    testWidgets('2nd-shot failure → per-shot error banner, Retry re-calls '
        'the uploader on the same session', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final shots = session.shots.toList();
      final fake = _FakeUploader()
        ..next.add(_summary(shots, failed: {1, 2}))
        ..next.add(_summary(shots, failed: {2}));
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();

      expect(find.text('Upload failed:'), findsOneWidget);
      expect(find.textContaining(shots[1].fileName), findsOneWidget,
          reason: 'each failing shot gets its own error line');
      expect(find.textContaining(shots[2].fileName), findsOneWidget);

      await tester.tap(find.text('Retry upload'));
      await tester.pump();

      expect(fake.sessions, [session, session],
          reason: 'retry is a plain re-call on the SAME session — the '
              'remaining shots are whatever is still staged (the real '
              'uploader covers that; see test/uploader_test.dart)');
      expect(find.textContaining(shots[1].fileName), findsNothing,
          reason: 'shot 2 succeeded on the scripted retry');
      expect(find.textContaining(shots[2].fileName), findsOneWidget,
          reason: 'shot 3 fails again — still listed');
    });

    testWidgets('allOk done state: banner + next actions; More for this '
        'order → fresh empty CameraPage for the same order',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final fake = _FakeUploader()..next.add(_summary(session.shots));
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();

      expect(find.text('Uploaded 3 photos'), findsOneWidget);
      expect(find.text('Scan next QR code'), findsOneWidget);
      expect(find.text('More for this order'), findsOneWidget);
      expect(find.text('Retake'), findsNothing);
      expect(find.text('Add photo'), findsNothing);
      expect(find.byKey(const Key('thumb_strip')), findsNothing,
          reason: 'done state hides the working-set chrome');

      await tester.tap(find.text('More for this order'));
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      expect(find.text('Order: 100438'), findsOneWidget,
          reason: 'same order, brand-new session');
      expect(find.text('Opening camera…'), findsOneWidget,
          reason: 'CameraPage is transient — straight into the launch');
    });

    testWidgets('failed pass leaves failed shots staged on disk for retry',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final shots = session.shots.toList();
      final fake = _FakeUploader()..next.add(_summary(shots, failed: {1}));
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();

      expect(File(shots[1].localPath).existsSync(), isTrue,
          reason: 'a failed shot must stay staged');
      expect(session.shots, hasLength(2));
    });

    testWidgets('Retake drops ONLY the last shot (file deleted) and reopens '
        'the camera on the same session', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final shots = session.shots.toList();
      await _pumpPreview(tester, session: session, batch: true);

      await tester.tap(find.text('Retake'));
      expect(session.shots, [shots[0], shots[1]],
          reason: 'removeLast is synchronous — only the newest shot goes');

      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      expect(File(shots[2].localPath).existsSync(), isFalse,
          reason: 'the retaken shot is gone from disk too');
      expect(File(shots[0].localPath).existsSync(), isTrue);
      expect(File(shots[1].localPath).existsSync(), isTrue);
      expect(find.text('Order: 100438'), findsOneWidget,
          reason: 'same session continues — numbering keeps accumulating');
      expect(find.text('Opening camera…'), findsOneWidget,
          reason: 'CameraPage is transient — straight into the launch');
    });

    testWidgets('Retake → transient camera admits the new shot → fresh '
        'preview shows the NEW last shot (selection not stuck on the '
        'pinned thumbnail)', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final shots = session.shots.toList();
      final picked = await _real(tester, () => _pickedFile('IMG_0004.jpg'));
      // The retake pick is HELD until the camera page is up — the test
      // resolves it, as the system camera would.
      final picker = _FakePickerPlatform([_FakePickerPlatform.heldPick]);
      ImagePickerPlatform.instance = picker;

      await _pumpPreview(tester, session: session, batch: true);

      // Review the FIRST shot (pins the selection), then retake — Retake
      // drops the NEWEST shot, and the pinned index must not survive into
      // the fresh preview.
      final stripTiles = find.descendant(
        of: find.byKey(const Key('thumb_strip')),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(stripTiles.first);
      await tester.pump();
      expect(_fullScreenFile(tester).path, shots.first.localPath);

      await tester.tap(find.text('Retake'));
      expect(session.shots, [shots[0], shots[1]],
          reason: 'removeLast drops the newest synchronously');

      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );
      expect(picker.held, hasLength(1));
      picker.held.single.resolve(picked.path);

      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 3,
      );
      await tester.pumpAndSettle();

      expect(session.shots.last.fileName, matches(RegExp(r'_003\.png$')),
          reason: 'numbering re-uses the retaken slot');
      expect(_fullScreenFile(tester).path, session.shots.last.localPath,
          reason: 'the fresh preview presents the NEW last shot — the '
              'pinned selection was review-time state only');
    });
  });

  group('PreviewPage batch OFF (single-shot UX preserved)', () {
    testWidgets('no chip/strip/Add-photo; Upload → done banner shows the '
        'file name; today’s actions present', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final fake = _FakeUploader()..next.add(_summary(session.shots));
      await _pumpPreview(
        tester,
        session: session,
        batch: false,
        uploader: fake.call,
      );

      expect(find.textContaining('—'), findsNothing,
          reason: 'no batch count chip');
      expect(find.byKey(const Key('thumb_strip')), findsNothing);
      expect(find.text('Add photo'), findsNothing);
      expect(find.byKey(const Key('upload_all_button')), findsNothing);
      expect(find.text('Upload'), findsOneWidget);
      expect(find.text('Retake'), findsOneWidget);

      await tester.tap(find.text('Upload'));
      await tester.pump();

      expect(find.text('Uploaded: 100438_shot_0.png'), findsOneWidget,
          reason: "today's done-banner shape ('Uploaded: {fileName}')");
      expect(find.text('Another photo\n(same order)'), findsOneWidget);
      expect(find.text('Scan next\nQR code'), findsOneWidget);
    });

    testWidgets("failed single-shot upload keeps today's Retake/Retry row",
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final fake = _FakeUploader()
        ..next.add(_summary(session.shots, failed: {0}))
        ..next.add(_summary(session.shots));
      await _pumpPreview(
        tester,
        session: session,
        batch: false,
        uploader: fake.call,
      );

      await tester.tap(find.text('Upload'));
      await tester.pump();

      expect(find.text('Retake'), findsOneWidget);
      expect(find.text('Retry upload'), findsOneWidget);

      await tester.tap(find.text('Retry upload'));
      await tester.pump();
      expect(find.text('Uploaded: 100438_shot_0.png'), findsOneWidget);
    });
  });

  group('CameraPage admission', () {
    testWidgets('processing failure: snackbar shown, session untouched, '
        'pops back to the shell (session empty)', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picked = await _real(tester, () => _pickedFile('IMG_0001.jpg'));
      ImagePickerPlatform.instance = _FakePickerPlatform([picked.path]);

      await tester.pumpWidget(
        MaterialApp(
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(_settings(batch: true)),
            processor: const _ThrowingProcessor(),
          ),
        ),
      );

      await _ioSettle(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
      );

      // The failure exit: the session is empty, so the failure abandons the
      // flow — and reclaims the dir (the old screen sat on a retry UI; the
      // new model has nothing to sit on).
      expect(find.text('Could not process photo'), findsOneWidget,
          reason: 'the messenger-held snackbar outlives the exit');
      expect(session.shots, isEmpty, reason: 'no half-admitted shot');
      expect(session.nextIndex, 1, reason: 'numbering untouched');
      await _ioSettle(tester, () => !session.dir.existsSync());
      expect(session.dir.existsSync(), isFalse,
          reason: 'empty session dir reclaimed on the failure exit');
    });

    testWidgets('successful pick: admits via the processor and pushes '
        'PreviewPage with the SAME session', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picked = await _real(tester, () => _pickedFile('IMG_0001.jpg'));
      ImagePickerPlatform.instance = _FakePickerPlatform([picked.path]);

      await tester.pumpWidget(
        MaterialApp(
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(_settings(batch: true)),
            processor: const _CopyProcessor(),
          ),
        ),
      );

      await _ioSettle(
        tester,
        () => session.shots.isNotEmpty &&
            find.byType(PreviewPage).evaluate().isNotEmpty,
      );

      expect(
        session.shots.single.fileName,
        matches(RegExp(r'^100438_\d{8}_\d{6}_001\.png$')),
        reason: 'numbering comes from session.nextIndex',
      );
      expect(File(session.shots.single.localPath).existsSync(), isTrue);
    });
  });

  group('CameraPage transient behavior', () {
    /// Shell stand-in: a stub first route (the tab shell's role) with
    /// [CameraPage] pushed ON TOP — the exact stack ScannerPage._startCapture
    /// builds. Lets the tests assert what cancel leaves VISIBLE (the stub,
    /// not CameraPage) without mounting the scanner's camera controller.
    Widget shellWithCamera(
      CaptureSession session, {
      ImageProcessor processor = const _CopyProcessor(),
    }) {
      return MaterialApp(
        home: Builder(
          builder: (context) {
            // Push the camera once the first frame exists — _startCapture's
            // `await Navigator.push(...)` shape.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CameraPage(
                    session: session,
                    settingsNotifier: ValueNotifier(_settings(batch: true)),
                    processor: processor,
                  ),
                ),
              );
            });
            return const Scaffold(body: Text('SHELL'));
          },
        ),
      );
    }

    testWidgets('no idle screen: launching state only, then the pick runs',
        (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picker = _FakePickerPlatform([_FakePickerPlatform.heldPick]);
      ImagePickerPlatform.instance = picker;

      await tester.pumpWidget(shellWithCamera(session));
      await tester.pump(); // post-frame push
      await tester.pump(); // camera route builds

      expect(find.byType(CameraPage), findsOneWidget);
      expect(find.text('Opening camera…'), findsOneWidget,
          reason: 'minimal launching state while the picker is in flight');
      expect(find.text('Order: 100438'), findsOneWidget);
      expect(find.text('Open camera'), findsNothing,
          reason: 'the manual button is gone — no idle screen');
      expect(find.byIcon(Icons.photo_camera), findsNothing);
      expect(find.byTooltip('Scan a different QR code'), findsNothing,
          reason: 'no manual scan-shortcut affordance');
      expect(find.byTooltip('Settings'), findsNothing,
          reason: 'no settings wheel');
      // The camera is still in flight here — nothing has settled, no exit.
      expect(picker.held, hasLength(1));
    });

    testWidgets('null pick with EMPTY session pops to the shell '
        '(cancel-to-scanner)', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      ImagePickerPlatform.instance = _FakePickerPlatform([null]);

      await tester.pumpWidget(shellWithCamera(session));
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isEmpty &&
            find.text('SHELL').evaluate().isNotEmpty,
      );

      expect(find.byType(CameraPage), findsNothing);
      expect(find.byType(PreviewPage), findsNothing);
      expect(find.text('SHELL'), findsOneWidget,
          reason: 'popped all the way back — the scanner would be on top');
      // Nothing was staged, so the session dir is reclaimed right away.
      await _ioSettle(tester, () => !session.dir.existsSync());
      expect(session.dir.existsSync(), isFalse,
          reason: 'empty session dir reclaimed on cancel (no leak)');
    });

    testWidgets('null pick with STAGED SHOTS returns to PreviewPage with '
        'the batch intact', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final shots = session.shots.toList();
      ImagePickerPlatform.instance = _FakePickerPlatform([null]);

      await tester.pumpWidget(shellWithCamera(session));
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty,
      );
      // pushReplacement keeps the outgoing CameraPage mounted while its
      // exit transition runs — settle the transition before asserting.
      await tester.pumpAndSettle();

      expect(find.byType(CameraPage), findsNothing);
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.text('Order: 100438 — 2 photos'), findsOneWidget,
          reason: 'the batch survived the cancel — nothing was discarded');
      expect(File(shots[0].localPath).existsSync(), isTrue);
      expect(File(shots[1].localPath).existsSync(), isTrue);
      expect(session.shots, hasLength(2));
    });

    testWidgets('processing failure with STAGED SHOTS pops back to '
        'PreviewPage with the snackbar', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final shots = session.shots.toList();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));
      ImagePickerPlatform.instance = _FakePickerPlatform([picked.path]);

      await tester.pumpWidget(
        shellWithCamera(session, processor: const _ThrowingProcessor()),
      );
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty,
      );
      // Settle the pushReplacement transition before asserting: during it,
      // both scaffolds are root-registered and the snack shows on both.
      await tester.pumpAndSettle();

      expect(find.byType(CameraPage), findsNothing);
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.text('Could not process photo'), findsOneWidget,
          reason: 'the messenger-held snackbar survives the exit');
      expect(find.text('Order: 100438 — 1 photo'), findsOneWidget);
      expect(File(shots.single.localPath).existsSync(), isTrue,
          reason: 'the staged shot was never touched');
      expect(session.shots, hasLength(1));
    });

    testWidgets('picker crash (pickImage throws) abandons to the shell '
        'with the error snackbar (session empty)', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      ImagePickerPlatform.instance = _CrashingPickerPlatform();

      await tester.pumpWidget(shellWithCamera(session));
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () =>
            find.byType(SnackBar).evaluate().isNotEmpty &&
            find.text('SHELL').evaluate().isNotEmpty &&
            find.byType(CameraPage).evaluate().isEmpty,
      );
      await tester.pump(const Duration(milliseconds: 400)); // transition

      expect(find.textContaining('Camera failed:'), findsOneWidget);
      expect(find.byType(CameraPage), findsNothing);
      expect(find.text('SHELL'), findsOneWidget,
          reason: 'the crash abandons the flow — no dead screen to sit on');
      await _ioSettle(tester, () => !session.dir.existsSync());
      expect(session.dir.existsSync(), isFalse,
          reason: 'no staged shots → dir reclaimed');
    });
  });

  group('admission into an existing batch', () {
    test('process → add keeps numbering and accumulates shots', () async {
      final session = await _sessionOf('100438', 2);
      final picked = await _pickedFile('IMG_0002.jpg');

      await _admit(
        const _CopyProcessor(),
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
      );

      expect(session.shots, hasLength(3));
      expect(session.shots.last.fileName, matches(RegExp(r'_003\.png$')));
      expect(File(session.shots.last.localPath).existsSync(), isTrue);
    });

    test('a throwing processor leaves the batch intact', () async {
      final session = await _sessionOf('100438', 2);
      final picked = await _pickedFile('IMG_0003.jpg');

      await _admit(
        const _ThrowingProcessor(),
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
      );

      expect(session.shots, hasLength(2));
      expect(session.nextIndex, 3);
      expect(
        session.dir.listSync().whereType<File>(),
        hasLength(2),
        reason: 'nothing half-admitted',
      );
    });
  });
}
