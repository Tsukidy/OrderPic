import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:orderpic/capture/image_processor.dart';
import 'package:orderpic/capture/session.dart';
import 'package:orderpic/settings/app_settings.dart';

/// Everything this file creates under Directory.systemTemp, so tearDown can
/// remove it without touching anything the user put there. Only ever paths
/// built from [seed]/planted names with the exact mmcpic-session- prefix.
final List<Directory> _created = [];

Directory _plant(String name) {
  final d = Directory('${Directory.systemTemp.path}/$name')
    ..createSync(recursive: true);
  _created.add(d);
  return d;
}

File _picked(String dirPath, String name) {
  final f = File('$dirPath/$name')..writeAsBytesSync([1, 2, 3, 4, 5]);
  return f;
}

/// The admission wrapper Task 4.3 wires into the UI: process, then — and
/// only then — add. Pinned here so a processor throw can be shown to leave
/// the session (shots and nextIndex) untouched.
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
    // The UI guard decides what the user sees (Task 4.3); the batch that
    // is already admitted stays intact.
  }
}

/// ORDER_YYYYMMDD_HHMMSS_NNN.ext, as built by the 4-part rule:
/// 1 = order, 2 = YYYYMMDD_HHMMSS, 3 = index, 4 = extension.
final _nameParts = RegExp(r'^(.+)_(\d{8}_\d{6})_(\d{3})\.(jpg|png)$');

/// The stamp segment of a 4-part name as a DateTime.
DateTime _stamp(Match m) {
  final s = m.group(2)!;
  return DateTime(
    int.parse(s.substring(0, 4)),
    int.parse(s.substring(4, 6)),
    int.parse(s.substring(6, 8)),
    int.parse(s.substring(9, 11)),
    int.parse(s.substring(11, 13)),
    int.parse(s.substring(13, 15)),
  );
}

void main() {
  tearDown(() {
    for (final d in _created.toList().reversed) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {/* best effort — test cleanup only */}
    }
    _created.clear();
  });

  group('sanitizeMaxEdge (carried constraint)', () {
    test('0 and negatives mean "no cap", never a degenerate edge', () {
      expect(sanitizeMaxEdge(null), isNull);
      expect(sanitizeMaxEdge(0), isNull);
      expect(sanitizeMaxEdge(-1080), isNull);
      expect(sanitizeMaxEdge(1), 1);
      expect(sanitizeMaxEdge(2048), 2048);
    });
  });

  group('CopyOnlyProcessor.process', () {
    test('materializes an existing file in session.dir under the 4-part name',
        () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final prefs = UploadPrefs.defaults;

      final shot = await const CopyOnlyProcessor().process(
        pickedPath: picked.path,
        prefs: prefs,
        session: session,
      );

      final staged = File(shot.localPath);
      expect(staged.existsSync(), isTrue);
      expect(staged.parent.path, session.dir.path);
      expect(shot.localPath.endsWith('/${shot.fileName}'), isTrue);
      expect(shot.fileName, matches(RegExp(r'^100438_\d{8}_\d{6}_001\.jpg$')));
      expect(staged.readAsBytesSync(), picked.readAsBytesSync());
    });

    test('the png format stamps a .png extension on the copied bytes',
        () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');

      final shot = await const CopyOnlyProcessor().process(
        pickedPath: picked.path,
        prefs: const UploadPrefs(format: ImageFormat.png),
        session: session,
      );

      expect(shot.fileName, matches(RegExp(r'^100438_\d{8}_\d{6}_001\.png$')));
      expect(File(shot.localPath).existsSync(), isTrue);
    });

    test('two admissions in the same second get 001 then 002', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final processor = const CopyOnlyProcessor();

      // Admit between shots — nextIndex only advances on add, so this is
      // the pattern the index disambiguation (and Task 4.3) depends on.
      await _admit(
        processor,
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
      );
      await _admit(
        processor,
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
      );

      final names = session.shots.map((s) => s.fileName).toList();
      // Index is what disambiguates the pair, whichever second they land in.
      expect(_nameParts.firstMatch(names[0])!.group(3), '001');
      expect(_nameParts.firstMatch(names[1])!.group(3), '002');
      expect(names[0], isNot(names[1]));
      // The two calls are back-to-back, so their stamps are at most one
      // second apart — i.e. same-second shots differ ONLY by the index.
      final aStamp = _stamp(_nameParts.firstMatch(names[0])!);
      final bStamp = _stamp(_nameParts.firstMatch(names[1])!);
      expect(bStamp.isBefore(aStamp), isFalse);
      expect(
        bStamp.difference(aStamp),
        lessThanOrEqualTo(const Duration(seconds: 1)),
      );
    });

    test('does NOT admit the shot — the caller does', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final processor = const CopyOnlyProcessor();

      final shot = await processor.process(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
      );
      expect(session.shots, isEmpty);
      expect(session.nextIndex, 1);

      session.add(shot);
      expect(session.shots, [shot]);
      expect(session.nextIndex, 2);
    });
  });

  group('NativeImageProcessor (JPEG branch only — no platform channels)',
      () {
    test('copies the already-encoded JPEG into the session dir', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');

      final shot = await const NativeImageProcessor().process(
        pickedPath: picked.path,
        prefs: const UploadPrefs(
          format: ImageFormat.jpeg,
          jpegQuality: JpegQuality.original,
        ),
        session: session,
      );

      expect(shot.fileName, matches(RegExp(r'^100438_\d{8}_\d{6}_001\.jpg$')));
      expect(File(shot.localPath).readAsBytesSync(), picked.readAsBytesSync());
    });
  });

  group('admission failure semantics', () {
    test('a throwing processor leaves the batch intact', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');

      // One shot already admitted — the batch the retry must preserve.
      await _admit(
        const CopyOnlyProcessor(),
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
      );
      expect(session.shots, hasLength(1));
      expect(session.nextIndex, 2);

      await _admit(
        const ThrowingProcessor(),
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
      );

      expect(session.shots, hasLength(1));
      expect(session.nextIndex, 2);
      // Nothing half-written either: no new file appeared in the dir.
      expect(
        session.dir.listSync().whereType<File>().length,
        1,
      );
    });
  });
}

/// Always fails the way a real codec failure would — before any Shot
/// exists, so the caller's `add` is never reached.
class ThrowingProcessor implements ImageProcessor {
  const ThrowingProcessor();

  @override
  Future<Shot> process({
    required String pickedPath,
    required UploadPrefs prefs,
    required CaptureSession session,
  }) async => throw Exception('codec failed for $pickedPath');
}
