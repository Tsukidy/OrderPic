import 'dart:async';
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

  group('reserveShotName', () {
    test('stamps the session NEXT index and the configured extension', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);

      expect(
        reserveShotName(session, UploadPrefs.defaults),
        matches(RegExp(r'^100438_\d{8}_\d{6}_001\.jpg$')),
      );
      expect(
        reserveShotName(session, const UploadPrefs(format: ImageFormat.png)),
        matches(RegExp(r'^100438_\d{8}_\d{6}_001\.png$')),
      );

      // A staged shot advances what the NEXT reservation gets.
      session.add(const Shot(localPath: 'x', fileName: '100438_a_001.jpg'));
      expect(
        reserveShotName(session, UploadPrefs.defaults),
        matches(RegExp(r'_002\.jpg$')),
      );
    });

    test('two reservations WITHOUT an intervening add would collide — '
        'admission must add before reserving again', () async {
      // Documents the invariant the background model depends on: the index
      // only advances via session.add, and admitPicked adds synchronously.
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final first = reserveShotName(session, UploadPrefs.defaults);
      expect(first, matches(RegExp(r'_001\.jpg$')));
      expect(session.nextIndex, 1, reason: 'nothing admitted yet');
    });
  });

  group('CopyOnlyProcessor.process', () {
    test('writes the picked bytes to the given reserved path', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final prefs = UploadPrefs.defaults;
      final fileName = reserveShotName(session, prefs);
      final dest = '${session.dir.path}/$fileName';

      await const CopyOnlyProcessor().process(
        pickedPath: picked.path,
        destPath: dest,
      );

      final staged = File(dest);
      expect(staged.existsSync(), isTrue);
      expect(fileName, matches(RegExp(r'^100438_\d{8}_\d{6}_001\.jpg$')));
      expect(staged.readAsBytesSync(), picked.readAsBytesSync());
    });

    test('is format-agnostic — it writes wherever it is pointed (a .png '
        'dest gets the bytes as-is; conversion is the native codec\'s job)',
        () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final dest =
          '${session.dir.path}/${reserveShotName(session, const UploadPrefs(format: ImageFormat.png))}';

      await const CopyOnlyProcessor().process(
        pickedPath: picked.path,
        destPath: dest,
      );

      expect(dest, matches(RegExp(r'_001\.png$')));
      expect(File(dest).existsSync(), isTrue);
    });
  });

  group('isJpegBytes (the extension-contract sniff)', () {
    test('true iff the head opens with the JPEG magic FF D8', () {
      expect(isJpegBytes(const [0xFF, 0xD8, 0xFF, 0xE0]), isTrue);
    });

    test('false for PNG, HEIC-brand, short, and empty heads', () {
      expect(isJpegBytes(const [0x89, 0x50, 0x4E, 0x47]), isFalse,
          reason: 'PNG magic');
      expect(
        isJpegBytes(const [
          0x00, 0x00, 0x00, 0x18, //
          0x66, 0x74, 0x79, 0x70, // "ftyp"
          0x68, 0x65, 0x69, 0x63, // "heic"
        ]),
        isFalse,
        reason: 'a HEIC container brands itself at bytes 4..7 — it does not '
            'open with FF D8, so it is not a JPEG',
      );
      expect(isJpegBytes(const [0xFF]), isFalse,
          reason: 'too short to decide');
      expect(isJpegBytes(const <int>[]), isFalse, reason: 'no bytes at all');
    });
  });

  group('NativeImageProcessor (JPEG branch only — no platform channels: the '
      'sniff and the copy are host-tested; the re-encode call is '
      'device-only)', () {
    test('a JPEG-headed source copies byte-for-byte to the reserved path '
        '(the sniff must not alter the real-JPEG path)', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      // JPEG-headed but not decodable — the copy branch never decodes; the
      // magic bytes alone decide which branch runs.
      final picked = File('${_plant('mmcpic-pick-src').path}/IMG_0001.jpg')
        ..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final dest =
          '${session.dir.path}/${reserveShotName(session, UploadPrefs.defaults)}';

      await const NativeImageProcessor().process(
        pickedPath: picked.path,
        destPath: dest,
      );

      expect(dest, matches(RegExp(r'_001\.jpg$')));
      expect(File(dest).readAsBytesSync(), picked.readAsBytesSync(),
          reason: 'a genuine JPEG source passes through untouched');
    });
  });

  group('admitPicked (background admission)', () {
    test('stages a PENDING entry immediately with the reserved name, and '
        'nextIndex advances BEFORE the conversion settles', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: const CopyOnlyProcessor(),
      );

      expect(session.shots, [admission.pending]);
      expect(admission.pending.status, ShotStatus.pending);
      expect(admission.pending.fileName, matches(RegExp(r'^100438_\d{8}_\d{6}_001\.jpg$')));
      expect(session.nextIndex, 2,
          reason: 'the index is reserved at pick time, not at settle time');
      // Not settled yet (we have not awaited) — no file required either way
      // until the copy runs; the entry is pending regardless.
      expect(admission.pending.localPath,
          '${session.dir.path}/${admission.pending.fileName}');

      await admission.settled;
      expect(session.shots.single.status, ShotStatus.ready);
      expect(File(session.shots.single.localPath).existsSync(), isTrue);
    });

    test('two quick picks reserve 001/002 even though the first conversion '
        'is still in flight when the second is admitted', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final gate = Completer<void>();

      // A processor whose conversion only finishes when released — the
      // slow PNG codec stand-in.
      Future<void> gated({required String pickedPath, required String destPath}) =>
          gate.future.then((_) => File(pickedPath).copy(destPath));

      final slow = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: _FunctionalProcessor(gated),
      );
      // Second pick while the first conversion is still held.
      final quick = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: const CopyOnlyProcessor(),
      );

      expect(slow.pending.fileName, matches(RegExp(r'_001\.jpg$')));
      expect(quick.pending.fileName, matches(RegExp(r'_002\.jpg$')),
          reason: 'the pending first shot already claimed index 1');
      expect(session.nextIndex, 3);
      expect(session.pendingShots, hasLength(2),
          reason: 'both conversions are still in flight — no await yet');

      // The quick one finishes on its own; the slow one stays pending.
      await quick.settled;
      expect(session.pendingShots, [slow.pending],
          reason: 'only the slow one is still converting');
      expect(session.shots[0].status, ShotStatus.pending);
      expect(session.shots[1].status, ShotStatus.ready);

      gate.complete();
      await slow.settled;
      expect(session.shots.map((s) => s.status).toList(),
          [ShotStatus.ready, ShotStatus.ready]);
    });

    test('a failed conversion flags the entry failed and keeps it staged — '
        'the earlier batch is intact', () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');

      // One ready shot first — the batch the failure must preserve (its
      // file on disk, as a real ready shot has).
      final first = File('${session.dir.path}/a.jpg')..writeAsBytesSync([1]);
      session.add(Shot(localPath: first.path, fileName: 'a.jpg'));
      expect(session.nextIndex, 2);

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: const ThrowingProcessor(),
      );
      await admission.settled;

      expect(session.shots, hasLength(2), reason: 'the failed entry stays');
      expect(session.shots[0].status, ShotStatus.ready);
      expect(session.shots[1].status, ShotStatus.failed);
      expect(session.shots[1].fileName, admission.pending.fileName,
          reason: 'the failed slot keeps its reserved name for the retake');
      expect(session.dir.listSync().whereType<File>(), hasLength(1),
          reason: 'the failed conversion left no half-written file');
    });

    test('a codec failing AFTER a partial write leaves no partial file '
        'behind (unclaimed bytes are cleaned up before flagging)',
        () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: const _PartialWriteProcessor(),
      );
      await admission.settled;

      expect(session.shots.single.status, ShotStatus.failed);
      expect(File(admission.pending.localPath).existsSync(), isFalse,
          reason: 'the partial bytes of the failed conversion are dropped '
              '— the retake must start from a clean dir');
      expect(session.dir.listSync().whereType<File>(), isEmpty);
    });

    test('a conversion settling after its entry was removed (retake '
        'cancel) leaves the session alone and drops the written file',
        () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final gate = Completer<void>();

      Future<void> gated({required String pickedPath, required String destPath}) =>
          gate.future.then((_) => File(pickedPath).copy(destPath));

      final admission = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: _FunctionalProcessor(gated),
      );

      // Retake while converting: the pending entry (and its not-yet-written
      // file) is dropped.
      final removed = session.removeLast();
      expect(removed, admission.pending);
      await session.deleteLocal(removed!);

      gate.complete();
      await admission.settled;

      expect(session.shots, isEmpty,
          reason: 'the cancelled entry was never re-added');
      expect(session.nextIndex, 1, reason: 'the slot is free for the retake');
      // The late conversion wrote its bytes anyway — admission cleans up.
      await _until(() => !File(admission.pending.localPath).existsSync());
      expect(File(admission.pending.localPath).existsSync(), isFalse,
          reason: 'the orphan bytes of a cancelled conversion are dropped');
    });

    test('a conversion settling after the name was re-reserved by a '
        'replacement shot does not delete the replacement\'s file',
        () async {
      final session = await CaptureSession.create('100438');
      _created.add(session.dir);
      final picked = _picked(_plant('mmcpic-pick-src').path, 'IMG_0001.jpg');
      final gate = Completer<void>();

      Future<void> gated({required String pickedPath, required String destPath}) =>
          gate.future.then((_) => File(pickedPath).copy(destPath));

      final cancelled = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: _FunctionalProcessor(gated),
      );

      // Retake, then admit the replacement — same index, same second → the
      // same fileName re-reserved.
      await session.deleteLocal(session.removeLast()!);
      final replacement = admitPicked(
        pickedPath: picked.path,
        prefs: UploadPrefs.defaults,
        session: session,
        processor: const CopyOnlyProcessor(),
      );
      expect(replacement.pending.fileName, cancelled.pending.fileName,
          reason: 'the retake re-uses the freed slot (same-second pick)');
      await replacement.settled;

      gate.complete();
      await cancelled.settled;

      expect(session.shots, hasLength(1));
      expect(session.shots.single.status, ShotStatus.ready,
          reason: 'only the replacement is staged');
      expect(File(session.shots.single.localPath).existsSync(), isTrue,
          reason: 'the cancelled conversion must not have deleted it');
    });
  });
}

/// Polls [done] on the real event loop (a sync settle may trail the await
/// by a microtask round that includes real file IO).
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Routes process() through an arbitrary function — lets a test hold the
/// conversion open (the slow-codec stand-in).
class _FunctionalProcessor implements ImageProcessor {
  _FunctionalProcessor(this._fn);

  final Future<void> Function({required String pickedPath, required String destPath})
      _fn;

  @override
  Future<void> process({required String pickedPath, required String destPath}) =>
      _fn(pickedPath: pickedPath, destPath: destPath);
}

/// Always fails the way a real codec failure would — admission flags the
/// PENDING entry failed; no Shot file ever exists.
class ThrowingProcessor implements ImageProcessor {
  const ThrowingProcessor();

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async => throw Exception('codec failed for $pickedPath');
}

/// Writes a partial file FIRST, THEN throws — the codec-dies-mid-write
/// shape. The settle path must clean the unclaimed bytes up.
class _PartialWriteProcessor implements ImageProcessor {
  const _PartialWriteProcessor();

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async {
    await File(destPath).writeAsBytes([1, 2, 3], flush: true);
    throw Exception('codec died mid-write for $pickedPath');
  }
}
