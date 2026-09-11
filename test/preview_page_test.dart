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
  String? reason,
}) async {
  for (var round = 0; round < maxRounds && !done(); round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(done(), isTrue,
      reason: reason ??
          'condition not reached after $maxRounds IO-settle rounds');
}

/// Real session with [count] real staged READY files.
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

/// [names.length] scratch "picked" files, in the order the gallery sheet
/// would return them.
Future<List<String>> _pickedFiles(List<String> names) async => [
  for (final name in names) (await _pickedFile(name)).path,
];

/// The names of the live `mmcpic-session-<orderNumber>-*` dirs under the
/// system temp — the "a session dir exists on disk" witness for the
/// assertion that must NOT mint one (Task 4.2: a dismissed continuation
/// must not create the fresh session's dir — it would leak until the
/// startup sweep). Scoped to ONE order number, and that number must be
/// unique across the whole test corpus: `flutter test` runs the test files
/// CONCURRENTLY against the same shared system temp, so an unscoped listing
/// sees other files' dirs appear and vanish mid-test (their orders differ,
/// and capture_session_test's sweep group even deletes every session dir).
/// Call through [_real]; assert on the DIFFERENCE against a snapshot taken
/// before the action under test — only a dir this test's own page created
/// can show up there.
Future<Set<String>> _sessionDirNames(String orderNumber) async {
  final prefix = '${CaptureSession.dirPrefix}$orderNumber-';
  final names = <String>{};
  await for (final e in Directory.systemTemp.list()) {
    if (e is! Directory) continue;
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name.startsWith(prefix)) names.add(name);
  }
  return names;
}

/// [format]/[jpegQuality] default to this file's working PNG shape; the
/// gallery params test overrides them to pin the JPEG preset mapping.
AppSettings _settings({
  required bool batch,
  ImageFormat format = ImageFormat.png,
  JpegQuality jpegQuality = JpegQuality.original,
}) => AppSettings(
  connection: const ConnectionSettings(
    host: '192.0.2.1',
    sharePath: '/zdrive/InvoiceData',
    domain: '',
    username: '',
    password: '',
  ),
  upload: UploadPrefs(
    batchMode: batch,
    format: format,
    jpegQuality: jpegQuality,
  ),
);

/// The seam shape PreviewPage expects: the extra named parameters mirror
/// the real `uploadSession` signature (only = the READY subset the page
/// uploads) so the default (real) uploader is directly assignable; fakes
/// record the subset and ignore the callback unless they need it.
typedef _Uploader =
    Future<UploadSummary> Function(
      CaptureSession,
      AppSettings, {
      List<Shot>? only,
      void Function(int done, int total)? onProgress,
    });

/// Records every call (session + the READY subset it was handed) and
/// replays a scripted [UploadSummary] per pass. The fake does NOT touch
/// the session's files — how the real uploader mutates staged state is
/// covered in test/uploader_test.dart; here it only feeds the page's
/// state machine.
class _FakeUploader {
  final List<CaptureSession> sessions = [];
  final List<List<Shot>?> onlys = [];
  final List<UploadSummary> next = [];

  Future<UploadSummary> call(
    CaptureSession session,
    AppSettings settings, {
    List<Shot>? only,
    void Function(int done, int total)? onProgress,
  }) {
    sessions.add(session);
    onlys.add(only);
    return Future.value(next.removeAt(0));
  }
}

/// A well-formed [UploadSummary] over [shots]: the ones in [failed] marked
/// !ok with a canned error.
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
  NavigatorObserver? nav,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [?nav],
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

/// Copies the picked bytes into the session dir under the reserved name —
/// the same shape the real processor returns, minus any codec.
class _CopyProcessor implements ImageProcessor {
  const _CopyProcessor();

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async {
    await File(pickedPath).copy(destPath);
  }
}

/// Always throws the way a codec failure would — admission flags the
/// PENDING entry failed instead of abandoning the flow.
class _ThrowingProcessor implements ImageProcessor {
  const _ThrowingProcessor();

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async => throw Exception('codec failed');
}

/// Never settles — the entry stays PENDING for as long as the test wants,
/// released by completing [gate] (the slow PNG codec stand-in).
class _HeldProcessor implements ImageProcessor {
  _HeldProcessor(this.gate);

  final Completer<void> gate;

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async {
    await gate.future;
    await File(pickedPath).copy(destPath);
  }
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

  /// Sentinel multi-pick script entry: hold the gallery sheet open until
  /// released — the "picker is up" state [heldPick] provides for the
  /// camera, resolved through [heldMulti].
  static const List<String> heldMultiPick = <String>['__held-multi__'];

  /// The camera-shaped script (the existing single-pick suites stay
  /// positional; empty = every pick behaves as "user backed out").
  _FakePickerPlatform([this.pickedPaths = const <String?>[]])
    : multiPicks = const <Object>[];

  /// The gallery-shaped script: one entry per multi-pick call, nothing for
  /// the camera — a gallery test reads as the whole story of its launch.
  _FakePickerPlatform.gallery(this.multiPicks)
    : pickedPaths = const <String?>[];

  final List<String?> pickedPaths;

  /// Gallery multi-pick script, one entry per [ImagePicker.pickMultiImage]
  /// call. An entry is either a list of canned picked paths in sheet order
  /// (an EMPTY list is the real plugin's cancel shape — the sheet closed
  /// with nothing selected), [heldMultiPick], or a [_MultiPickThrow]. An
  /// exhausted script degrades to that same empty list, so a scriptless
  /// fake stays safe for a gallery push (the single-pick script's
  /// post-exhaustion null, gallery twin).
  final List<Object> multiPicks;

  final List<_HeldPick> held = [];
  final List<_HeldMultiPick> heldMulti = [];

  /// The source every single-pick call received — the witness that the
  /// CAMERA leg (not the gallery) drove the seam (Task 4.2's done-state
  /// continuation asserts exactly this).
  final List<ImageSource> sources = [];

  /// The options every multi-pick call received — the pick-time params the
  /// page forwarded (the JPEG preset's quality/edge caps travel inside
  /// [MultiImagePickerOptions.imageOptions]).
  final List<MultiImagePickerOptions> multiOptions = [];

  int _calls = 0;
  int _multiCalls = 0;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    sources.add(source);
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

  /// [ImagePicker.pickMultiImage]'s delegate in
  /// image_picker_platform_interface 2.11.1 — the exact method the app's
  /// gallery path drives, so overriding it (and only it) keeps the fake on
  /// the real code path. The older `getMultiImage` stays unimplemented on
  /// purpose: if the page ever drifts off `pickMultiImage`, the test fails
  /// loudly instead of silently faking a different call.
  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    multiOptions.add(options);
    final Object entry = _multiCalls < multiPicks.length
        ? multiPicks[_multiCalls++]
        : const <String>[];
    if (identical(entry, heldMultiPick)) {
      final h = _HeldMultiPick();
      heldMulti.add(h);
      return h.completer.future;
    }
    if (entry is _MultiPickThrow) throw entry.error;
    return <XFile>[for (final path in entry as List<String>) XFile(path)];
  }
}

/// The release handle for a [heldMultiPick] script entry: the "gallery
/// sheet is up" state, resolved by the test.
class _HeldMultiPick {
  final completer = Completer<List<XFile>>();

  /// The sheet came back with these files, in selection order.
  void resolve(List<String> paths) =>
      completer.complete(<XFile>[for (final p in paths) XFile(p)]);

  /// The sheet came back with nothing (the real plugin's cancel shape).
  void cancel() => completer.complete(const <XFile>[]);
}

/// Multi-pick script entry: the platform call itself throws — the gallery
/// twin of [_CrashingPickerPlatform], but scriptable per call.
class _MultiPickThrow {
  const _MultiPickThrow(this.error);

  final Object error;
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

/// Counts route replaces — the only way to see a STRAY second hand-off to
/// review: two stacked `pushReplacement`s leave a single PreviewPage in the
/// tree, which `findsOneWidget` cannot distinguish.
class _NavRecorder extends NavigatorObserver {
  int replaces = 0;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      replaces += 1;
}

/// [_CopyProcessor] plus a record of every (picked → reserved dest) pair in
/// call order. The gallery picks in these tests are byte-identical, so the
/// pairing — not the file bytes — is the evidence that each returned file
/// was admitted exactly once, in sheet order.
class _PairRecordingProcessor implements ImageProcessor {
  // Not const: the recorded pairs are per-instance mutable state (a const
  // constructor would force a constant field initializer).
  _PairRecordingProcessor();

  final List<({String picked, String dest})> pairs = [];

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async {
    // Recorded BEFORE the await: record order IS admission call order.
    pairs.add((picked: pickedPath, dest: destPath));
    await File(pickedPath).copy(destPath);
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

    testWidgets('Upload all → uploader called once with the session and the '
        'READY subset; allOk → done banner counts photos', (tester) async {
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
      expect(fake.onlys.single, session.shots.toList(),
          reason: 'all shots ready → the subset IS the staged list');
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
        uploader: (s, settings, {only, onProgress}) async {
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
        'order → sheet → fresh empty CameraPage (camera) for the same '
        'order', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final fake = _FakeUploader()..next.add(_summary(session.shots));
      final nav = _NavRecorder();
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
        nav: nav,
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

      // Task 4.2 retarget: the continuation now asks WHERE first (the same
      // sheet Add photo uses) — the camera here is the sheet's answer.
      await tester.tap(find.text('More for this order'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source_sheet')), findsOneWidget,
          reason: 'the choice is asked before anything is created');
      expect(find.byType(CameraPage), findsNothing);

      await tester.tap(find.byKey(const Key('sheet_take_photo')));
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      // The pushed page carries a FRESH session — the finished one is
      // never reused (new dir, numbering restarted, still empty).
      final pushed = tester.widget<CameraPage>(find.byType(CameraPage));
      final fresh = pushed.session;
      _created.add(fresh.dir);
      expect(pushed.source, CaptureSource.camera,
          reason: 'the sheet camera answer rides the plain camera leg');
      expect(identical(fresh, session), isFalse,
          reason: 'a brand-new session, not the one that just finished');
      expect(fresh.dir.path, isNot(session.dir.path),
          reason: 'the fresh session starts a NEW dir');
      expect(fresh.shots, isEmpty,
          reason: 'nothing was staged into it yet');
      expect(nav.replaces, 1, reason: 'the continuation is one replace, '
          'exactly what the old direct push did (plus the sheet question)');
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

  group('PreviewPage Add-photo source sheet (batch on)', () {
    // Task 4.1: Add photo no longer jumps straight to the camera — it asks
    // WHERE the next photos come from first (design D4). The choice is a
    // bottom sheet, NOT a new button in an action row: the narrow-screen
    // contract keeps those rows at Retake / Add photo / the gated or upload
    // button, and a 360dp screen has no room for a fourth sibling.
    //
    // Disarm timing (controller ruling): the armed upload gate is cancelled
    // the moment the sheet OPENS — today's Add photo already cancels it on
    // tap, so this is the same disarm one step earlier — because a
    // conversion settling mid-sheet must never auto-start an upload behind
    // it. What the sheet round-trip must NOT do is navigate, stage, drop,
    // or reset the pinned selection; a dismissal leaves the page exactly as
    // the disarm left it.

    testWidgets('Add photo opens the sheet in place: no navigation, '
        'nothing staged or dropped', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final shots = session.shots.toList();
      // Scriptless on purpose: if the sheet round-trip launched anything,
      // the fake would answer "backed out" — visible below as a replace.
      final picker = _FakePickerPlatform([]);
      ImagePickerPlatform.instance = picker;
      final nav = _NavRecorder();
      await _pumpPreview(tester, session: session, batch: true, nav: nav);

      await tester.tap(find.byKey(const Key('add_photo_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('source_sheet')), findsOneWidget);
      expect(find.byKey(const Key('sheet_take_photo')), findsOneWidget);
      expect(find.byKey(const Key('sheet_gallery')), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Choose from gallery'), findsOneWidget);

      // A question, not a launch: the review page is still the route, no
      // camera was pushed, nothing was replaced and no picker call fired.
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.byType(CameraPage), findsNothing);
      expect(nav.replaces, 0);
      expect(picker.held, isEmpty);
      expect(picker.multiOptions, isEmpty);
      expect(session.shots, shots,
          reason: 'opening the sheet stages nothing and drops nothing');
      expect(find.text('Order: 100438 — 2 photos'), findsOneWidget);
    });

    testWidgets('choosing Take photo pushes the SAME-session camera with '
        'the staged batch intact', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final shots = session.shots.toList();
      final picked = await _real(tester, () => _pickedFile('IMG_0003.jpg'));
      // The camera pick is HELD so the pushed page stays observable — the
      // real system camera behaves the same way (the pick settles on
      // return).
      final picker = _FakePickerPlatform([_FakePickerPlatform.heldPick]);
      ImagePickerPlatform.instance = picker;
      final nav = _NavRecorder();
      await _pumpPreview(tester, session: session, batch: true, nav: nav);

      await tester.tap(find.byKey(const Key('add_photo_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet_take_photo')));
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      expect(find.text('Opening camera…'), findsOneWidget,
          reason: 'the same-session camera leg Add photo used to push '
              'directly');
      expect(session.shots, shots,
          reason: 'add keeps every staged shot — nothing was removed or '
              'renamed by the choice');
      expect(File(shots[0].localPath).existsSync(), isTrue);
      expect(File(shots[1].localPath).existsSync(), isTrue);

      // The launch is a real one on the SAME session: the new shot
      // continues the numbering (003) and the hand-off to review is the
      // ordinary single replace.
      expect(picker.held, hasLength(1));
      picker.held.single.resolve(picked.path);
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 3 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();

      expect(session.shots.last.fileName, matches(RegExp(r'_003\.png$')));
      expect(nav.replaces, 2,
          reason: 'both hand-offs are replaces: preview → camera (the '
              'choice) and camera → review (the admission)');
    });

    testWidgets('choosing Choose from gallery multi-picks into the SAME '
        'session with continuing indexes', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final shots = session.shots.toList();
      final picked = await _real(
        tester,
        () => _pickedFiles(['IMG_0003.jpg', 'IMG_0004.jpg']),
      );
      final picker = _FakePickerPlatform.gallery([picked]);
      final processor = _PairRecordingProcessor();
      ImagePickerPlatform.instance = picker;
      final nav = _NavRecorder();
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        nav: nav,
        processor: processor,
      );

      await tester.tap(find.byKey(const Key('add_photo_button')));
      await tester.pumpAndSettle();
      expect(picker.multiOptions, isEmpty,
          reason: 'the sheet alone launches nothing');

      await tester.tap(find.byKey(const Key('sheet_gallery')));
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 4 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();

      expect(picker.multiOptions, hasLength(1),
          reason: 'the choice fired exactly ONE multi-pick');
      expect(find.byType(CameraPage), findsNothing);
      expect(nav.replaces, 2,
          reason: 'both hand-offs are replaces: preview → camera (the '
              'choice) and camera → review (the admission)');
      expect(session.shots.sublist(0, 2), shots,
          reason: 'the staged batch is untouched — the picks join it');
      expect(session.shots[2].fileName, matches(RegExp(r'_003\.png$')),
          reason: 'numbering continues from where the session stood: '
              '2 staged + a 2-pick → 003');
      expect(session.shots[3].fileName, matches(RegExp(r'_004\.png$')));
      expect(
        [for (final p in processor.pairs) p.picked],
        picked,
        reason: 'each returned file admitted exactly once, in sheet order',
      );
      for (final s in session.shots.sublist(2)) {
        expect(File(s.localPath).existsSync(), isTrue,
            reason: '${s.fileName} was converted into the session dir');
      }
    });

    testWidgets('opening the sheet cancels the armed gate: a conversion '
        'settling mid-sheet never uploads; dismissing leaves the page idle, '
        'batch and selection untouched', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final ready = session.shots.single;
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      // A pending conversion plus an ARMED gate: the operator asked for the
      // upload to start the moment the conversion settles. Opening the sheet
      // cancels that wait — today's Add photo cancels it on tap, the sheet
      // just moves the disarm one step earlier — so the settle below (while
      // the sheet is still up) must find NOBODY waiting.
      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );
      final fake = _FakeUploader()
        ..next.add(_summary([
          ready,
          admission.pending.copyWith(status: ShotStatus.ready),
        ]));
      final nav = _NavRecorder();
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
        nav: nav,
      );

      // Pin the FIRST thumbnail: the selection is review-time state whose
      // survival across the sheet round-trip is part of the contract.
      final stripTiles = find.descendant(
        of: find.byKey(const Key('thumb_strip')),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(stripTiles.first);
      await tester.pump();
      expect(_fullScreenFile(tester).path, ready.localPath);

      // Arm the gate...
      await tester.tap(find.byKey(const Key('waiting_button')));
      await tester.pump();
      expect(find.text('Waiting… (1)'), findsOneWidget);

      // ...and open the sheet, which is where the armed wait is cancelled.
      await tester.tap(find.byKey(const Key('add_photo_button')));
      // Plain pumps, not pumpAndSettle: the pending tile's spinner never
      // settles while the conversion is held open.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // sheet transition
      expect(find.byKey(const Key('source_sheet')), findsOneWidget);

      // The settle fires WHILE the sheet is up. This is the ruling's pin:
      // the disarm already happened at open, so the settle auto-starts
      // nothing — no uploader call, no upload pass, no done banner behind
      // the sheet (had the gate survived, _onSessionChanged would have
      // uploaded here).
      gate.complete();
      await _ioSettle(
        tester,
        () => session.shots.length == 2 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      expect(fake.sessions, isEmpty,
          reason: 'the armed wait was cancelled at sheet-open — a settle '
              'behind the sheet must never auto-start the upload');
      expect(find.text('Uploaded 2 photos'), findsNothing);
      expect(find.text('Uploading 0 / 2'), findsNothing);

      // Barrier tap = dismissal: the sheet answers null.
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('source_sheet')), findsNothing);
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.byType(CameraPage), findsNothing);
      expect(nav.replaces, 0, reason: 'a dismissal navigates nowhere');
      // Disarmed AND settled: the row is back to plain idle — Upload all,
      // not the armed Waiting button.
      expect(find.byKey(const Key('upload_all_button')), findsOneWidget,
          reason: 'the sheet round-trip left the page idle (the armed wait '
              'was cancelled at open), everything ready to upload');
      expect(find.text('Waiting… (1)'), findsNothing);
      expect(fake.sessions, isEmpty, reason: 'still no upload ran');
      expect(_fullScreenFile(tester).path, ready.localPath,
          reason: 'the pinned selection was not reset');
      expect(session.shots, hasLength(2),
          reason: 'nothing was staged or dropped by opening + dismissing');
      expect(File(session.shots[1].localPath).existsSync(), isTrue);
    });
  });

  group('PreviewPage done-state continuations via the source sheet', () {
    // Task 4.2: the done rows' continuations ("More for this order" with
    // the batch on, "Another photo (same order)" without) no longer jump
    // straight to a fresh camera — they ask WHERE first, through the very
    // same sheet Add photo uses (one shared path, no done-state fork; the
    // gate disarm inside it is a harmless no-op here, the done state arms
    // no gate). The choice precedes the session: the fresh CaptureSession
    // (new dir, numbering restarted at 001) is minted only AFTER an answer,
    // because CaptureSession.create creates the dir eagerly and a session
    // minted for a dismissed question would sit in the system temp until
    // the next launch's sweep. A dismissal is a full no-op: no session, no
    // route, the done row intact for another try.

    testWidgets('batch done: More for this order → sheet → gallery '
        'multi-picks into a FRESH session whose numbering restarts at 001',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 3));
      final staged = session.shots.toList();
      final fake = _FakeUploader()..next.add(_summary(staged));
      final picked = await _real(
        tester,
        () => _pickedFiles(['IMG_A.jpg', 'IMG_B.jpg']),
      );
      // The gallery pick is HELD so the pushed page — and its fresh
      // session — stays observable before the admissions run.
      final picker = _FakePickerPlatform.gallery([
        _FakePickerPlatform.heldMultiPick,
      ]);
      ImagePickerPlatform.instance = picker;
      final nav = _NavRecorder();
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
        nav: nav,
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();
      expect(find.text('Uploaded 3 photos'), findsOneWidget);

      await tester.tap(find.text('More for this order'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source_sheet')), findsOneWidget);
      expect(find.byType(CameraPage), findsNothing,
          reason: 'the question comes before any launch');
      expect(picker.multiOptions, isEmpty,
          reason: 'the sheet alone picks nothing');

      await tester.tap(find.byKey(const Key('sheet_gallery')));
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      // The answer launched the gallery — on a FRESH session, never the
      // one that just finished.
      final pushed = tester.widget<CameraPage>(find.byType(CameraPage));
      final fresh = pushed.session;
      _created.add(fresh.dir);
      expect(pushed.source, CaptureSource.gallery);
      expect(identical(fresh, session), isFalse,
          reason: 'a brand-new session for the continued order');
      expect(fresh.dir.path, isNot(session.dir.path),
          reason: 'the fresh session starts a NEW dir');
      expect(fresh.shots, isEmpty,
          reason: 'nothing was staged into it before the pick returned');
      expect(picker.multiOptions, hasLength(1),
          reason: 'the choice fired exactly ONE multi-pick');
      expect(find.text('Opening gallery…'), findsOneWidget);

      // The gallery sheet comes back with two photos → both admitted into
      // the FRESH session as 001/002 — continuing the finished session's
      // three staged shots would have said 004/005.
      picker.heldMulti.single.resolve(picked);
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            fresh.shots.length == 2 &&
            fresh.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();

      expect(fresh.shots[0].fileName, matches(RegExp(r'_001\.png$')),
          reason: 'numbering RESTARTS at 001 in the fresh session');
      expect(fresh.shots[1].fileName, matches(RegExp(r'_002\.png$')));
      for (final s in fresh.shots) {
        expect(File(s.localPath).existsSync(), isTrue,
            reason: '${s.fileName} was converted into the fresh dir');
      }
      expect(session.shots, staged,
          reason: 'the finished session is untouched — the picks joined '
              'the fresh one, not it');
      expect(find.text('Order: 100438 — 2 photos'), findsOneWidget,
          reason: 'same order, fresh session (the review chip counts the '
              'fresh session\'s own two shots)');
    });

    testWidgets('single-shot done: Another photo (same order) → sheet → '
        'camera opens on a FRESH session', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final fake = _FakeUploader()..next.add(_summary(session.shots));
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));
      // The camera pick is HELD so the pushed page stays observable; the
      // single-pick seam firing (not the multi-pick one) is the witness
      // that the CAMERA leg ran.
      final picker = _FakePickerPlatform([_FakePickerPlatform.heldPick]);
      ImagePickerPlatform.instance = picker;
      final nav = _NavRecorder();
      await _pumpPreview(
        tester,
        session: session,
        batch: false,
        uploader: fake.call,
        nav: nav,
      );

      await tester.tap(find.text('Upload'));
      await tester.pump();
      expect(find.textContaining('Uploaded:'), findsOneWidget);

      await tester.tap(find.text('Another photo\n(same order)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source_sheet')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sheet_take_photo')));
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      final pushed = tester.widget<CameraPage>(find.byType(CameraPage));
      final fresh = pushed.session;
      _created.add(fresh.dir);
      expect(pushed.source, CaptureSource.camera);
      expect(picker.sources.single, ImageSource.camera,
          reason: 'the camera leg drives the single-pick seam with '
              'ImageSource.camera');
      expect(picker.multiOptions, isEmpty,
          reason: 'no multi-pick fired — the sheet answer was the camera');
      expect(identical(fresh, session), isFalse);
      expect(fresh.dir.path, isNot(session.dir.path));
      expect(fresh.shots, isEmpty, reason: 'a brand-new, still-empty session');
      expect(find.text('Opening camera…'), findsOneWidget);

      // The camera comes back with a photo → it lands in the FRESH session
      // as 001 (a reuse of the finished session would have said 002).
      picker.held.single.resolve(picked.path);
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            fresh.shots.length == 1 &&
            fresh.shots.single.status == ShotStatus.ready,
      );
      await tester.pumpAndSettle();

      expect(fresh.shots.single.fileName, matches(RegExp(r'_001\.png$')),
          reason: 'numbering restarts in the fresh session');
      expect(session.shots, hasLength(1),
          reason: 'the finished session is untouched');
    });

    testWidgets('dismissing the sheet cancels the continuation: no route, '
        'page stays done, NO session dir created', (tester) async {
      // A corpus-unique order: the dir-count witness below keys on it, and
      // concurrently-running test files must never mint dirs with it (see
      // [_sessionDirNames]).
      const order = '246813';
      final session = await _real(tester, () => _sessionOf(order, 2));
      final staged = session.shots.toList();
      final fake = _FakeUploader()..next.add(_summary(staged));
      // Scriptless on purpose: any launch would be answered "backed out" —
      // visible below as a picker call.
      final picker = _FakePickerPlatform([]);
      ImagePickerPlatform.instance = picker;
      final nav = _NavRecorder();
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
        nav: nav,
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pump();
      expect(find.text('Uploaded 2 photos'), findsOneWidget);

      // The "no session minted" witness: this order's session dirs on
      // disk, snapshotted before the tap.
      final dirsBefore = await _real(tester, () => _sessionDirNames(order));

      await tester.tap(find.text('More for this order'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source_sheet')), findsOneWidget);
      expect((await _real(tester, () => _sessionDirNames(order)))
          .difference(dirsBefore), isEmpty,
          reason: 'the sheet is only a QUESTION — the fresh session (and '
              'its dir) does not exist before an answer');

      // Barrier tap = dismissal: the sheet answers null.
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('source_sheet')), findsNothing);
      expect(find.byType(PreviewPage), findsOneWidget,
          reason: 'the page never navigated');
      expect(find.byType(CameraPage), findsNothing);
      expect(nav.replaces, 0, reason: 'a dismissal navigates nowhere');
      expect(find.text('Uploaded 2 photos'), findsOneWidget,
          reason: 'still the same done state');
      expect(find.text('More for this order'), findsOneWidget,
          reason: 'the done row is intact — the operator may choose again');
      expect((await _real(tester, () => _sessionDirNames(order)))
          .difference(dirsBefore), isEmpty,
          reason: 'the dismissed choice minted NO session dir — nothing '
              'left to leak until the startup sweep');
      expect(session.shots, staged, reason: 'nothing staged or dropped');
      expect(picker.multiOptions, isEmpty);
      expect(picker.sources, isEmpty, reason: 'no picker call ever fired');
    });
  });

  group('PreviewPage background conversion (Task 6.6)', () {
    testWidgets('PENDING thumb: spinner tile, no Image decode; strip and '
        'chip still count it; ready siblings unaffected', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      await _pumpPreview(tester, session: session, batch: true);
      // Admit the slow pick while the review page is up — exactly what the
      // CameraPage hand-off leaves behind: a pending entry whose conversion
      // is still in flight.
      admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );
      await tester.pump();

      expect(find.text('Order: 100438 — 2 photos'), findsOneWidget,
          reason: 'the pending entry is part of the batch count');
      expect(find.byKey(const Key('thumb_pending_1')), findsOneWidget,
          reason: 'the pending tile renders the spinner overlay');
      expect(_thumbs(tester), hasLength(1),
          reason: 'the pending tile decodes NO image (no file yet)');

      // Upload all is gated while the conversion runs.
      expect(find.byKey(const Key('upload_all_button')), findsNothing);
      expect(find.byKey(const Key('waiting_button')), findsOneWidget);
      expect(find.text('Waiting… (1)'), findsOneWidget);
      expect(find.text('Add photo'), findsOneWidget,
          reason: 'capture never blocks on a pending conversion');

      gate.complete();
      await _ioSettle(
        tester,
        () => session.shots[1].status == ShotStatus.ready,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thumb_pending_1')), findsNothing);
      expect(_thumbs(tester), hasLength(2),
          reason: 'the settled tile now decodes its image');
      expect(find.text('Waiting… (1)'), findsNothing);
      expect(find.byKey(const Key('upload_all_button')), findsOneWidget,
          reason: 'the gate opened — upload is back');
    });

    testWidgets('Upload all with a pending shot WAITS: uploader not called '
        'until the conversion settles, then starts on the ready subset',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final ready = session.shots.single;
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      // The slow pick was admitted before review — the entry is pending.
      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );

      final fake = _FakeUploader()
        ..next.add(
          // The subset is cut at START time — after the settle, so the
          // pending-turned-ready shot is in it.
          _summary([ready, admission.pending.copyWith(status: ShotStatus.ready)]),
        );
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );

      await tester.tap(find.byKey(const Key('waiting_button')));
      await tester.pump();
      expect(fake.sessions, isEmpty,
          reason: 'a pending conversion gates the upload');
      expect(find.text('Waiting… (1)'), findsOneWidget);

      // The conversion settles (ready) → the upload starts BY ITSELF. The
      // done banner is the end signal (the fake completes synchronously
      // once invoked).
      gate.complete();
      await _ioSettle(
        tester,
        () => find.text('Uploaded 2 photos').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();

      expect(fake.sessions, [session],
          reason: 'the gated upload auto-started on settle');
      expect(fake.onlys.single!.map((s) => s.fileName).toList(),
          [ready.fileName, admission.pending.fileName],
          reason: 'the subset is cut at start: every staged shot, now all '
              'ready — nothing was skipped');
      expect(
        fake.onlys.single!.every((s) => s.status == ShotStatus.ready),
        isTrue,
        reason: 'a PENDING or FAILED entry never reaches the uploader',
      );
      expect(find.text('Uploaded 2 photos'), findsOneWidget);
    });

    testWidgets('FAILED conversion: error tile + banner, upload passes the '
        'ready shots only, failed stays staged', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final readyShots = session.shots.toList();
      final picked = await _real(tester, () => _pickedFile('IMG_0003.jpg'));

      admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: const _ThrowingProcessor(),
      );
      final fake = _FakeUploader()..next.add(_summary(readyShots));
      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );
      // The settle path touches real IO (the partial-write cleanup's
      // exists/delete) — drive it with real rounds; the banner appearing
      // proves the entry settled to failed.
      await _ioSettle(
        tester,
        () => session.shots.last.status == ShotStatus.failed &&
            find.byKey(const Key('conversion_banner')).evaluate().isNotEmpty,
      );

      expect(find.byKey(const Key('thumb_failed_2')), findsOneWidget,
          reason: 'the failed tile shows the error tint');
      expect(find.byKey(const Key('conversion_banner')), findsOneWidget);
      final failed = session.shots.last;
      expect(
        find.descendant(
          of: find.byKey(const Key('conversion_banner')),
          matching: find.textContaining(failed.fileName),
        ),
        findsOneWidget,
        reason: 'the banner names the failed conversion',
      );

      await tester.tap(find.byKey(const Key('upload_all_button')));
      await tester.pumpAndSettle();

      expect(fake.sessions, [session]);
      expect(fake.onlys.single, readyShots,
          reason: 'the failed entry is NOT in the upload subset');
      expect(find.text('Uploaded 2 photos'), findsOneWidget);
      expect(session.shots, hasLength(3),
          reason: 'the failed entry stays staged');
      expect(find.byKey(const Key('conversion_banner')), findsOneWidget,
          reason: 'still flagged after the upload');
      expect(find.text('Retake failed photo'), findsOneWidget,
          reason: 'the done row offers the retake-first escape');
    });

    testWidgets('tapping a FAILED thumbnail reviews it full-screen with a '
        'retake button; retake drops the entry and reopens the camera',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final readyShot = session.shots.single;
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: const _ThrowingProcessor(),
      );
      final failed = session.shots.last;

      await _pumpPreview(tester, session: session, batch: true);

      // The settle path touches real IO (the partial-write cleanup's
      // exists/delete) — drive it with real rounds until the entry has
      // settled to failed (the error tile proves it).
      await _ioSettle(
        tester,
        () => session.shots.last.status == ShotStatus.failed &&
            find.byKey(const Key('thumb_failed_1')).evaluate().isNotEmpty,
      );

      await _pumpPreview(tester, session: session, batch: true);

      // Tap the failed tile (second in the strip).
      final stripTiles = find.descendant(
        of: find.byKey(const Key('thumb_strip')),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(stripTiles.last);
      await tester.pump();

      expect(find.byKey(const Key('preview_failed')), findsOneWidget);
      expect(find.text('Could not convert ${failed.fileName}'),
          findsOneWidget);
      expect(find.byKey(const Key('retake_shot_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('retake_shot_button')));
      expect(session.shots, [readyShot],
          reason: 'only the failed entry is dropped');

      // The retake relaunches the camera (transient) on the same session;
      // its scriptless picker cancels, so the round trip lands on a FRESH
      // preview — the chip dropping to '1 photo' proves the camera ran.
      await _ioSettle(
        tester,
        () => find.text('Order: 100438 — 1 photo').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(session.shots, [readyShot],
          reason: 'the batch survives the retake round trip minus the '
              'failed entry');
    });

    testWidgets('full-screen view of a PENDING shot shows the spinner '
        '(no file decode, no crash)', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );

      await _pumpPreview(tester, session: session, batch: true);

      // The newest shot IS the pending one — the default full-screen shows
      // the conversion spinner, and NO FileImage decodes (there is no file
      // yet). The strip's empty-area Image? None either — the tile renders
      // the spinner container instead.
      expect(find.byKey(const Key('preview_pending')), findsOneWidget);
      expect(find.text('Converting…'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
        findsNothing,
        reason: 'there is no file to decode yet',
      );
    });

    testWidgets('Retake of a PENDING last shot drops the entry; the late '
        'conversion is cleaned up (orphan file swept by the settle path)',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 1));
      final readyShot = session.shots.single;
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );
      final pending = admission.pending;

      await _pumpPreview(tester, session: session, batch: true);

      await tester.tap(find.text('Retake'));
      expect(session.shots, [readyShot],
          reason: 'the pending entry is dropped synchronously');

      // The camera page is up; now let the cancelled conversion finish.
      // Wait for the copy to LAND first (exists == true), then for the
      // settle path's cleanup to take it back out — two phases, so the
      // first round's "absent" can't race the copy.
      gate.complete();
      await _ioSettle(
        tester,
        () => File(pending.localPath).existsSync(),
        reason: 'the cancelled conversion still writes its bytes...',
      );
      await _ioSettle(
        tester,
        () => !File(pending.localPath).existsSync(),
        reason: '...and the settle path cleans the orphan up',
      );
      await tester.pumpAndSettle();

      expect(session.shots, [readyShot],
          reason: 'the cancelled conversion never re-adds its entry');
      expect(File(pending.localPath).existsSync(), isFalse,
          reason: 'the settle path deleted the orphan bytes');
    });

    testWidgets('single-shot (batch OFF) pending: gated Upload button '
        'auto-starts on settle', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 0));
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0001.jpg'));

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: false).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );

      final fake = _FakeUploader()
        ..next.add(_summary([admission.pending.copyWith(status: ShotStatus.ready)]));
      await _pumpPreview(
        tester,
        session: session,
        batch: false,
        uploader: fake.call,
      );

      expect(find.byKey(const Key('upload_all_button')), findsNothing);
      expect(find.text('Upload'), findsNothing);
      expect(find.byKey(const Key('waiting_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('waiting_button')));
      await tester.pump();
      expect(fake.sessions, isEmpty, reason: 'still gated');

      gate.complete();
      await _ioSettle(
        tester,
        () => find.textContaining('Uploaded:').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();

      expect(fake.sessions, [session],
          reason: 'the gated upload started after settle');
      expect(find.textContaining('Uploaded:'), findsOneWidget);
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

  group('PreviewPage batch OFF with a multi-pick session (Task 4.3)', () {
    // The state under test is the one production reaches with the toggle
    // OFF: a capture-start gallery multi-pick (the leg the "batch OFF runs
    // the SAME gallery path" suite pinned as ungated) hands THREE staged
    // shots to the ordinary review page. What is new here is the REVIEW
    // side of that state: the single-shot presentation must not grow batch
    // chrome just because the session holds several shots, and the
    // ordinary Retake / Upload controls must already carry the multi-pick
    // semantics — drop the newest only, upload every READY shot.
    //
    // Staging: the presentation suite arrives through the REAL capture path
    // (CameraPage + the gallery fake), never behind the page's back. The
    // retake and upload suites stage directly via [_sessionOf] — the file's
    // established batch-off pattern — because their witnesses ride
    // PreviewPage-only seams (the injected processor that must survive the
    // retake round trip; the injected uploader), and the CameraPage
    // hand-off builds its own review page with the production defaults.

    /// The capture-start staging of the presentation suite: a fresh
    /// session, a 3-file multi-pick, batch OFF — through the real
    /// CameraPage path, ending on the review page with three READY shots.
    Future<CaptureSession> stagedByGallery(
      WidgetTester tester,
      String order,
    ) async {
      final session = await _real(tester, () => CaptureSession.create(order));
      _created.add(session.dir);
      final picked = await _real(
        tester,
        () => _pickedFiles(['IMG_A.jpg', 'IMG_B.jpg', 'IMG_C.jpg']),
      );
      ImagePickerPlatform.instance = _FakePickerPlatform.gallery([picked]);

      await tester.pumpWidget(
        MaterialApp(
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(_settings(batch: false)),
            processor: const _CopyProcessor(),
            source: CaptureSource.gallery,
          ),
        ),
      );
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 3 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('3 shots staged by a batch-off multi-pick: single-shot '
        'presentation — no chip/strip/Add-photo, newest full-screen',
        (tester) async {
      final session = await stagedByGallery(tester, '100441');
      final shots = session.shots.toList();

      // No batch chrome, even with 3 shots staged: no count chip, no strip,
      // no Add photo — by key as well as by label.
      expect(find.textContaining('—'), findsNothing,
          reason: 'no batch count chip — the count lives in the batch chip '
              'only');
      expect(find.text('Order: 100441 — 3 photos'), findsNothing);
      expect(find.text('Order: 100441'), findsOneWidget,
          reason: "today's plain order chip instead");
      expect(find.byKey(const Key('thumb_strip')), findsNothing);
      expect(find.byKey(const Key('add_photo_button')), findsNothing);
      expect(find.text('Add photo'), findsNothing);
      expect(find.byKey(const Key('upload_all_button')), findsNothing);

      // The NEWEST shot fills the screen — the default selection, exactly
      // the single-shot review's behavior over a multi-pick session.
      expect(_fullScreenFile(tester).path, shots.last.localPath,
          reason: 'the newest of the three is the reviewed shot');

      // The ordinary single-shot row, labels verbatim.
      expect(find.text('Retake'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
    });

    testWidgets('Retake with 3 staged drops ONLY the newest, re-launches '
        'the camera on the SAME session, and the re-pick reuses slot 003',
        (tester) async {
      final session = await _real(tester, () => _sessionOf('100442', 3));
      final shots = session.shots.toList();
      final picked = await _real(tester, () => _pickedFile('IMG_D.jpg'));
      // The retake re-pick is HELD while the camera page is observable.
      final picker = _FakePickerPlatform([_FakePickerPlatform.heldPick]);
      ImagePickerPlatform.instance = picker;
      await _pumpPreview(
        tester,
        session: session,
        batch: false,
        // The copy processor must ride the whole loop: the retake camera
        // inherits THIS page's processor, and the re-pick has to land READY
        // for the full-screen assertion below.
        processor: const _CopyProcessor(),
      );

      // The newest shot's full-screen decode was started one pump ago and
      // takes a few real-time rounds to land (~150 ms in the test engine).
      // It MUST land before Retake deletes the file: a codec read of a
      // since-deleted file surfaces as an image-resource error and fails
      // the test on timing alone. (In production the operator has seconds
      // on the review screen before pressing Retake — this wait is that
      // review time.) The image cache's own status is the observable: the
      // entry leaves `pending` for `keepAlive` once decoded.
      await _ioSettle(
        tester,
        () {
          final s = PaintingBinding
              .instance.imageCache.statusForKey(FileImage(File(shots[2].localPath)));
          return !s.pending && s.keepAlive;
        },
        reason: "the retaken shot's full-screen decode must land before its "
            'file is deleted',
      );

      await tester.tap(find.text('Retake'));
      expect(session.shots, [shots[0], shots[1]],
          reason: 'removeLast is synchronous — only the newest shot goes');

      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isNotEmpty,
      );

      // The same session continues (Retake never discards the first two).
      final pushed = tester.widget<CameraPage>(find.byType(CameraPage));
      expect(identical(pushed.session, session), isTrue,
          reason: 'the camera is re-launched on the SAME session');
      expect(pushed.source, CaptureSource.camera,
          reason: 'retake is camera-only — the batch toggle plays no part');
      expect(picker.multiOptions, isEmpty,
          reason: 'no gallery multi-pick fires — retake reopens the camera');
      expect(session.shots.map((s) => s.fileName).toList(),
          [shots[0].fileName, shots[1].fileName],
          reason: 'the survivors keep their reserved names');
      expect(File(shots[0].localPath).existsSync(), isTrue);
      expect(File(shots[1].localPath).existsSync(), isTrue);
      expect(File(shots[2].localPath).existsSync(), isFalse,
          reason: 'the retaken shot is gone from disk too');

      // The re-pick lands in the freed slot: 3 staged again, numbered 003.
      picker.held.single.resolve(picked.path);
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 3 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();

      expect(session.shots.last.fileName, matches(RegExp(r'_003\.png$')),
          reason: 'the re-pick reuses the freed slot — 003 again');
      expect(
        session.shots.take(2).map((s) => s.fileName).toList(),
        [shots[0].fileName, shots[1].fileName],
        reason: 'the first two are unchanged by the round trip',
      );
      expect(_fullScreenFile(tester).path, session.shots.last.localPath,
          reason: 'the fresh review presents the newly admitted (last) shot');
    });

    testWidgets('Upload with 3 READY staged: the injected uploader receives '
        'the session and ALL THREE, in session order', (tester) async {
      final session = await _real(tester, () => _sessionOf('100443', 3));
      final shots = session.shots.toList();
      final fake = _FakeUploader()..next.add(_summary(shots));
      await _pumpPreview(
        tester,
        session: session,
        batch: false,
        uploader: fake.call,
      );

      await tester.tap(find.text('Upload'));
      await tester.pump();

      expect(fake.sessions, [session]);
      expect(fake.onlys, hasLength(1), reason: 'one uploader call, one pass');
      expect(fake.onlys.single, shots,
          reason: 'the ordinary Upload button already sends EVERY READY '
              'shot — the `only:` subset IS the whole ready session, no new '
              'logic needed');
      expect(
        fake.onlys.single!.map((s) => s.fileName).toList(),
        [shots[0].fileName, shots[1].fileName, shots[2].fileName],
        reason: 'in session order',
      );
      expect(
        fake.onlys.single!.every((s) => s.status == ShotStatus.ready),
        isTrue,
      );
      expect(find.textContaining('Uploaded:'), findsOneWidget,
          reason: "today's single-shot done shape, naming the last shot");
    });
  });

  group('CameraPage admission', () {
    testWidgets('failed conversion: pending entry admitted, flagged FAILED '
        'at review — the flow never abandons', (tester) async {
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
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.isNotEmpty &&
            session.shots.single.status == ShotStatus.failed,
      );
      await tester.pumpAndSettle();

      expect(find.byType(PreviewPage), findsOneWidget,
          reason: 'the flow continues to review after the pick');
      expect(session.shots, hasLength(1));
      expect(session.shots.single.status, ShotStatus.failed);
      expect(session.shots.single.fileName,
          matches(RegExp(r'^100438_\d{8}_\d{6}_001\.png$')),
          reason: 'numbering comes from session.nextIndex at pick time');
      expect(find.byKey(const Key('conversion_banner')), findsOneWidget,
          reason: 'review flags the failed conversion immediately');
      expect(find.byType(SnackBar), findsNothing,
          reason: 'a conversion failure is review-time state, not an '
              'abandon-the-flow snackbar anymore');
      expect(session.dir.existsSync(), isTrue,
          reason: 'the flagged entry keeps the session dir alive');
    });

    testWidgets('successful pick: admits PENDING via admitPicked and pushes '
        'PreviewPage; the conversion lands ready behind the navigation',
        (tester) async {
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
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.isNotEmpty &&
            session.shots.single.status == ShotStatus.ready,
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

    testWidgets('failed conversion with STAGED SHOTS lands on PreviewPage '
        'with the failure flagged — batch untouched', (tester) async {
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
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 2 &&
            session.shots.last.status == ShotStatus.failed,
      );
      await tester.pumpAndSettle();

      expect(find.byType(CameraPage), findsNothing);
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.text('Order: 100438 — 2 photos'), findsOneWidget,
          reason: 'the pending pick counts toward the batch, then flags');
      expect(find.byKey(const Key('conversion_banner')), findsOneWidget);
      expect(File(shots.single.localPath).existsSync(), isTrue,
          reason: 'the staged shot was never touched');
      expect(session.shots.first.status, ShotStatus.ready);
      expect(session.shots.last.status, ShotStatus.failed);
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

  group('CameraPage gallery source', () {
    // Task 2.1: the SAME transient page launched with the gallery source.
    // Everything below rides the existing admission/exit machinery — the
    // only new behavior is the multi-pick launch, the loop admitting every
    // returned file, and the single hand-off to review.

    /// Shell stand-in for the two-way exit tests — the same stub-first-
    /// route shape the transient group's shellWithCamera builds, launched
    /// straight into the gallery.
    Widget shellWithGallery(
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
                    source: CaptureSource.gallery,
                  ),
                ),
              );
            });
            return const Scaffold(body: Text('SHELL'));
          },
        ),
      );
    }

    testWidgets('multi-pick of 3 → 3 staged shots numbered 001/002/003 in '
        'sheet order, ONE hand-off to review', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picked = await _real(
        tester,
        () => _pickedFiles(['IMG_A.jpg', 'IMG_B.jpg', 'IMG_C.jpg']),
      );
      final picker = _FakePickerPlatform.gallery([picked]);
      final processor = _PairRecordingProcessor();
      final nav = _NavRecorder();
      ImagePickerPlatform.instance = picker;

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [nav],
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(_settings(batch: true)),
            processor: processor,
            source: CaptureSource.gallery,
          ),
        ),
      );

      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 3 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.byType(CameraPage), findsNothing);
      // Exactly ONE navigation event may follow the launch: a stray second
      // hand-off (or an _exit + hand-off double-fire) replaces another
      // route — replacing the already-replaced review leaves ONE PreviewPage
      // in the tree, invisible to findsOneWidget.
      expect(nav.replaces, 1, reason: 'review is handed to exactly once');
      expect(picker.multiOptions, hasLength(1),
          reason: 'ONE multi-pick call — not one per file');

      final names = session.shots.map((s) => s.fileName).toList();
      expect(names[0], matches(RegExp(r'^100438_\d{8}_\d{6}_001\.png$')));
      expect(names[1], matches(RegExp(r'^100438_\d{8}_\d{6}_002\.png$')));
      expect(names[2], matches(RegExp(r'^100438_\d{8}_\d{6}_003\.png$')),
          reason: 'indexes advance 001, 002, 003 across the returned list');

      expect(
        [for (final p in processor.pairs) p.picked],
        picked,
        reason: 'each returned file admitted EXACTLY once, in sheet order',
      );
      expect(
        [for (final p in processor.pairs) File(p.dest).existsSync()],
        [true, true, true],
        reason: 'every admission converted — nothing half-admitted',
      );
    });

    testWidgets('batch OFF runs the SAME gallery path: 3 picks stage '
        '001/002/003 with ONE hand-off to review (nothing MAY be gated on '
        'the batch toggle)', (tester) async {
      // The pin: no part of the gallery leg may branch on upload.batchMode.
      // Same script, same processor, same assertions as the batch-on suite
      // above — only the settings differ. A future `batchMode` check in the
      // gallery path (e.g. treating batch OFF as single-pick, or bailing to
      // the cancel exit) fails here.
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picked = await _real(
        tester,
        () => _pickedFiles(['IMG_A.jpg', 'IMG_B.jpg', 'IMG_C.jpg']),
      );
      final picker = _FakePickerPlatform.gallery([picked]);
      final processor = _PairRecordingProcessor();
      final nav = _NavRecorder();
      ImagePickerPlatform.instance = picker;

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [nav],
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(_settings(batch: false)),
            processor: processor,
            source: CaptureSource.gallery,
          ),
        ),
      );

      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty &&
            session.shots.length == 3 &&
            session.shots.every((s) => s.status == ShotStatus.ready),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PreviewPage), findsOneWidget,
          reason: 'batch OFF still hands off to review after a multi-pick');
      expect(find.byType(CameraPage), findsNothing);
      expect(nav.replaces, 1,
          reason: 'exactly ONE hand-off with the toggle off, as with it on');
      expect(picker.multiOptions, hasLength(1),
          reason: 'still ONE multi-pick call — the toggle gates nothing');

      final names = session.shots.map((s) => s.fileName).toList();
      expect(names[0], matches(RegExp(r'^100438_\d{8}_\d{6}_001\.png$')));
      expect(names[1], matches(RegExp(r'^100438_\d{8}_\d{6}_002\.png$')));
      expect(names[2], matches(RegExp(r'^100438_\d{8}_\d{6}_003\.png$')),
          reason: 'the batch-on reserved numbering, unchanged by the toggle');

      expect(
        [for (final p in processor.pairs) p.picked],
        picked,
        reason: 'every returned file admitted exactly once, in sheet order',
      );
      expect(
        [for (final p in processor.pairs) File(p.dest).existsSync()],
        [true, true, true],
        reason: 'every admission converted — nothing half-admitted',
      );
    });

    testWidgets('pick-time params follow the SAME jpegPickParams mapping the '
        'camera path uses — no maxHeight, no limit', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picked = await _real(tester, () => _pickedFiles(['IMG_A.jpg']));
      final picker = _FakePickerPlatform.gallery([picked]);
      ImagePickerPlatform.instance = picker;

      await tester.pumpWidget(
        MaterialApp(
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(
              // balanced = quality 80 + 2560 long-edge cap — the exact
              // numbers pickImage receives for the same preset today.
              _settings(
                batch: true,
                format: ImageFormat.jpeg,
                jpegQuality: JpegQuality.balanced,
              ),
            ),
            processor: const _CopyProcessor(),
            source: CaptureSource.gallery,
          ),
        ),
      );

      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty,
      );

      expect(picker.multiOptions, hasLength(1));
      final options = picker.multiOptions.single;
      expect(options.imageOptions.imageQuality, 80);
      expect(options.imageOptions.maxWidth, 2560.0,
          reason: 'the preset cap travels as maxWidth — a long-edge cap, '
              'exactly as the single-pick call sends it');
      expect(options.imageOptions.maxHeight, isNull,
          reason: "today's pick call sends NO maxHeight — neither may the "
              'gallery one');
      expect(options.limit, isNull,
          reason: 'no cap on how many photos the operator picks');
    });

    testWidgets('empty multi-pick with STAGED SHOTS returns to review with '
        'the batch intact (the real plugin cancel shape)', (tester) async {
      final session = await _real(tester, () => _sessionOf('100438', 2));
      final shots = session.shots.toList();
      ImagePickerPlatform.instance =
          _FakePickerPlatform.gallery([const <String>[]]);

      await tester.pumpWidget(shellWithGallery(session));
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () => find.byType(PreviewPage).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();

      expect(find.byType(CameraPage), findsNothing);
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.text('Order: 100438 — 2 photos'), findsOneWidget,
          reason: 'a sheet closed with nothing selected is cancelling — '
              'the staged batch must survive untouched');
      expect(File(shots[0].localPath).existsSync(), isTrue);
      expect(File(shots[1].localPath).existsSync(), isTrue);
      expect(session.shots, hasLength(2));
    });

    testWidgets('empty multi-pick with an EMPTY session pops to the shell '
        'and reclaims the session dir', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      ImagePickerPlatform.instance =
          _FakePickerPlatform.gallery([const <String>[]]);

      await tester.pumpWidget(shellWithGallery(session));
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () => find.byType(CameraPage).evaluate().isEmpty &&
            find.text('SHELL').evaluate().isNotEmpty,
      );

      expect(find.byType(PreviewPage), findsNothing,
          reason: 'nothing was staged, so there is no review to return to');
      expect(find.text('SHELL'), findsOneWidget,
          reason: 'cancel with nothing staged returns to the scanner');
      await _ioSettle(tester, () => !session.dir.existsSync());
      expect(session.dir.existsSync(), isFalse,
          reason: 'empty session dir reclaimed on cancel (no leak)');
    });

    testWidgets('multi-pick crash abandons to the shell with the gallery '
        'error snackbar (session empty)', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      ImagePickerPlatform.instance = _FakePickerPlatform.gallery([
        _MultiPickThrow(
          PlatformException(code: 'photo_access_denied'),
        ),
      ]);

      await tester.pumpWidget(shellWithGallery(session));
      await tester.pump(); // post-frame push
      await _ioSettle(
        tester,
        () =>
            find.byType(SnackBar).evaluate().isNotEmpty &&
            find.text('SHELL').evaluate().isNotEmpty &&
            find.byType(CameraPage).evaluate().isEmpty,
      );
      await tester.pump(const Duration(milliseconds: 400)); // transition

      expect(find.textContaining('Gallery failed:'), findsOneWidget);
      expect(find.byType(CameraPage), findsNothing);
      expect(find.text('SHELL'), findsOneWidget,
          reason: 'the crash abandons the flow — the camera leg contract, '
              'unchanged for the gallery');
      await _ioSettle(tester, () => !session.dir.existsSync());
      expect(session.dir.existsSync(), isFalse,
          reason: 'no staged shots → dir reclaimed');
    });

    testWidgets('launch caption follows the source: "Opening gallery…" '
        'while the sheet is in flight', (tester) async {
      final session = await _real(
        tester,
        () => CaptureSession.create('100438'),
      );
      _created.add(session.dir);
      final picker = _FakePickerPlatform.gallery([
        _FakePickerPlatform.heldMultiPick,
      ]);
      ImagePickerPlatform.instance = picker;

      await tester.pumpWidget(
        MaterialApp(
          home: CameraPage(
            session: session,
            settingsNotifier: ValueNotifier(_settings(batch: true)),
            source: CaptureSource.gallery,
          ),
        ),
      );
      await tester.pump(); // the gallery route builds, sheet in flight

      expect(find.text('Order: 100438'), findsOneWidget);
      expect(find.text('Opening gallery…'), findsOneWidget,
          reason: 'the launch caption names the source actually opening');
      expect(find.text('Opening camera…'), findsNothing);
      expect(picker.heldMulti, hasLength(1),
          reason: 'the sheet is still in flight — nothing has settled');
    });
  });

  group('admission into an existing batch', () {
    test('admitPicked keeps numbering and accumulates shots', () async {
      final session = await _sessionOf('100438', 2);
      final picked = await _pickedFile('IMG_0002.jpg');

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: const _CopyProcessor(),
      );
      await admission.settled;

      expect(session.shots, hasLength(3));
      expect(session.shots.last.fileName, matches(RegExp(r'_003\.png$')));
      expect(session.shots.last.status, ShotStatus.ready);
      expect(File(session.shots.last.localPath).existsSync(), isTrue);
    });

    test('a throwing processor flags the entry failed and keeps the batch',
        () async {
      final session = await _sessionOf('100438', 2);
      final picked = await _pickedFile('IMG_0003.jpg');

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: const _ThrowingProcessor(),
      );
      await admission.settled;

      expect(session.shots, hasLength(3), reason: 'the failed entry stays');
      expect(session.shots.last.status, ShotStatus.failed);
      expect(session.shots.last.fileName, matches(RegExp(r'_003\.png$')),
          reason: 'the slot keeps its reserved name for the retake');
      expect(
        session.dir.listSync().whereType<File>(),
        hasLength(2),
        reason: 'nothing half-written',
      );
    });
  });

  group('PreviewPage narrow-screen layout (Task 6.8)', () {
    // Regression: the gated button used to push its three-button row past
    // the screen edge — a device reported ~24px of yellow/black stripes
    // across it on a 360dp phone. The row now squeezes the button
    // (Flexible) and its label truncates, so the surface must be narrow
    // enough to force that squeeze; the default 800x600 test surface never
    // does.
    //
    // Why the halved text scale: the harness' FlutterTest font draws glyphs
    // ~2x wider than Roboto at the same point size, so a 360dp surface at
    // full scale overflows OTHER chrome too (the order chip row — a
    // pre-existing condition no real device hits, and out of scope here).
    // Halving the scale puts the test back at the real device's label
    // widths on the same 360dp geometry.
    //
    // RenderFlex overflow surfaces in tests as a FlutterError, so
    // takeException() after the frame is the canary. Plain pumps, not
    // pumpAndSettle: the pending tile's spinner never settles while the
    // conversion is held open.
    testWidgets('gated button squeezes into a 360dp row: no RenderFlex '
        'overflow, label keeps the count, tap still arms', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 0.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final session = await _real(tester, () => _sessionOf('100438', 1));
      final ready = session.shots.single;
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0002.jpg'));

      // Admitted BEFORE the page's first pump, so the very first frame is
      // already the pending-state row (no 'Upload all' in it to overflow
      // for unrelated reasons). The held processor keeps the conversion
      // in flight for as long as the test wants.
      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: _settings(batch: true).upload,
        session: session,
        processor: _HeldProcessor(gate),
      );
      final fake = _FakeUploader()
        ..next.add(
          _summary([
            ready,
            admission.pending.copyWith(status: ShotStatus.ready),
          ]),
        );

      await _pumpPreview(
        tester,
        session: session,
        batch: true,
        uploader: fake.call,
      );

      // Idle row with a pending shot: Retake / Add photo / gated button.
      expect(tester.takeException(), isNull,
          reason: 'the pending-state row must fit a 360dp screen');
      expect(find.byKey(const Key('waiting_button')), findsOneWidget);
      expect(find.text('Waiting… (1)'), findsOneWidget,
          reason: 'the label is truncated, not replaced — the count stays');
      expect(
        tester.getSize(find.byKey(const Key('waiting_button'))).width,
        lessThan(360.0),
        reason: 'the gated button shares its row — it must fit, not span '
            'or exceed the screen',
      );

      // Arming the gate re-lays out the same three buttons under status =
      // waiting — the row the device report pointed at.
      await tester.tap(find.byKey(const Key('waiting_button')));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'the armed waiting row must fit a 360dp screen');
      expect(fake.sessions, isEmpty,
          reason: 'the squeeze changed nothing about the tap: still gated '
              '(the uploader must not have run)');
    });

    testWidgets('label truncates instead of wrapping when the row is even '
        'tighter (3 pending, single-line label)', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 0.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final session = await _real(tester, () => _sessionOf('100438', 0));
      final gate = Completer<void>();
      final picked = await _real(tester, () => _pickedFile('IMG_0001.jpg'));

      for (var i = 0; i < 3; i++) {
        admitPicked(
          pickedPath: picked.path,
          prefs: _settings(batch: true).upload,
          session: session,
          processor: _HeldProcessor(gate),
        );
      }

      await _pumpPreview(tester, session: session, batch: true);

      expect(tester.takeException(), isNull,
          reason: 'a longer label (3 pending) must not overflow either — '
              'it truncates');
      expect(find.text('Waiting… (3)'), findsOneWidget);
      final label = tester.getSize(find.text('Waiting… (3)')).width;
      expect(label, lessThan(100.0),
          reason: 'the label is ellipsized to the squeezed button\'s share '
              'of the row, not laid out at its full width');
    });
  });

  testWidgets('landscape shot renders centered in the visible band — '
      'full-screen preview centers between strip and controls (6.13)',
      (tester) async {
    final session = await _real(tester, () async {
      final s = await CaptureSession.create('100438');
      final f = File('${s.dir.path}/shot-0.png')
        ..writeAsBytesSync(_landscapePng);
      s.add(Shot(localPath: f.path, fileName: '100438_shot_0.png'));
      return s;
    });
    await _pumpPreview(tester, session: session, batch: true);
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    final img =
        find.byWidgetPredicate((w) => w is Image && w.image is FileImage);
    expect(img, findsOneWidget);
    final rect = tester.getRect(img);
    // The image must live in the VISIBLE band — below the thumbnail strip,
    // above the bottom buttons — so BoxFit.contain centers it where the
    // operator's eye expects. Centering on the FULL screen leaves more
    // visible letterbox below than above (the top overlay is taller than
    // the bottom one), which reads as "pushed to the top" for landscape
    // shots with their big letterbox (device finding 6.13).
    final strip = tester.getRect(find.byKey(const Key('thumb_strip')));
    expect(rect.top, closeTo(strip.bottom, 0.5),
        reason: 'the full-screen image area starts under the strip');
    expect(rect.height, lessThan(600),
        reason: 'the image band excludes the overlays');
    expect(rect.center.dx, closeTo(400, 0.5),
        reason: 'horizontally centered in the band');
  });
}

/// A valid 160x90 grayscale PNG — a real decodable LANDSCAPE image
/// (generated: IHDR grayscale-8 + zlib IDAT, CRCs computed).
const List<int> _landscapePng = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x5a, 0x08, 0x00, 0x00, 0x00, 0x00, 0x1a, 0xad, 0x02, 0x8e, 0x00, 0x00, 0x00, 0x81, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0xed, 0xd0, 0x31, 0x11, 0x00, 0x20, 0x10, 0xc0, 0xb0, 0x97, 0x83, 0x7f, 0x33, 0xd8, 0x41, 0x02, 0x43, 0x07, 0x18, 0x72, 0x31, 0xd0, 0xeb, 0xec, 0xf5, 0xb7, 0x79, 0x5e, 0x70, 0x31, 0xcf, 0x0b, 0x2e, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0x1c, 0xac, 0xbe, 0x3f, 0x78, 0x00, 0x5a, 0x72, 0x05, 0x85, 0x85, 0x8c, 0xee, 0x05, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82];

