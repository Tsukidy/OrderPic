import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:orderpic/capture/session.dart';
import 'package:orderpic/capture/uploader.dart';
import 'package:orderpic/settings/app_settings.dart';
import 'package:orderpic/smb/smb.dart';

/// Records every writeShot / ensureFolder / onProgress call. Injecting both
/// fakes must bypass the SMB connection entirely (asserted via the empty
/// username, which makes any [connect] attempt throw immediately).
class _Recorder {
  final writes = <({String path, List<int> bytes})>[];
  final ensured = <String>[];
  final progress = <({int done, int total})>[];

  Future<void> writeShot(String remotePath, Uint8List bytes) async {
    writes.add((path: remotePath, bytes: bytes.toList()));
  }

  Future<void> ensureFolder(String path) async {
    ensured.add(path);
  }

  void onProgress(int done, int total) {
    progress.add((done: done, total: total));
  }
}

/// Real session dirs/files so deleteLocal + cleanupIfEmpty run for real.
final List<Directory> _created = [];

Future<CaptureSession> _session(
  String orderNumber,
  List<String> fileNames,
) async {
  final s = await CaptureSession.create(orderNumber);
  _created.add(s.dir);
  for (var i = 0; i < fileNames.length; i++) {
    final f = File('${s.dir.path}/${fileNames[i]}')..writeAsBytesSync([i]);
    s.add(Shot(localPath: f.path, fileName: fileNames[i]));
  }
  return s;
}

ConnectionSettings _conn({required String sharePath}) =>
    const ConnectionSettings(
      host: '192.0.2.1',
      sharePath: '/zdrive/InvoiceData',
      domain: '',
      username: '', // empty on purpose: any real connect() throws
      password: '',
    ).copyWith(sharePath: sharePath);

AppSettings _settings({required bool folders}) => AppSettings(
  connection: _conn(sharePath: '/zdrive/InvoiceData'),
  upload: UploadPrefs(useOrderFolders: folders),
);

void main() {
  tearDown(() {
    for (final d in _created.toList().reversed) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {/* test cleanup only */}
    }
    _created.clear();
  });

  group('uploadTargetPath', () {
    test('flat: sharePath/fileName (sharePath used verbatim)', () {
      final path = uploadTargetPath(
        c: _conn(sharePath: '/zdrive/InvoiceData/Sub'),
        u: const UploadPrefs(useOrderFolders: false),
        orderNumber: '100438',
        fileName: '100438_20260908_101112_1.jpg',
      );
      expect(path, '/zdrive/InvoiceData/Sub/100438_20260908_101112_1.jpg');
    });

    test('folders on: sharePath/orderNumber/fileName', () {
      final path = uploadTargetPath(
        c: _conn(sharePath: '/zdrive/InvoiceData/Sub'),
        u: const UploadPrefs(useOrderFolders: true),
        orderNumber: '100438',
        fileName: '100438_20260908_101112_1.jpg',
      );
      expect(
        path,
        '/zdrive/InvoiceData/Sub/100438/100438_20260908_101112_1.jpg',
      );
    });
  });

  group('uploadSession (injected fakes)', () {
    test('two shots → two writes to right paths, locals deleted, allOk, '
        'progress (1,2) then (2,2), session dir cleaned up', () async {
      final session = await _session('100438', [
        '100438_20260908_101112_1.jpg',
        '100438_20260908_101113_2.jpg',
      ]);
      final shot1 = session.shots[0];
      final shot2 = session.shots[1];
      final rec = _Recorder();

      final summary = await uploadSession(
        session,
        _settings(folders: true),
        writeShot: rec.writeShot,
        ensureFolder: rec.ensureFolder,
        onProgress: rec.onProgress,
      );

      expect(rec.writes, hasLength(2));
      expect(
        rec.writes[0].path,
        '/zdrive/InvoiceData/100438/100438_20260908_101112_1.jpg',
      );
      expect(
        rec.writes[1].path,
        '/zdrive/InvoiceData/100438/100438_20260908_101113_2.jpg',
      );
      expect(rec.writes[0].bytes, [0]);
      expect(rec.writes[1].bytes, [1]);

      expect(File(shot1.localPath).existsSync(), isFalse);
      expect(File(shot2.localPath).existsSync(), isFalse);
      expect(session.shots, isEmpty);
      expect(summary.allOk, isTrue);
      expect(summary.uploadedCount, 2);
      expect(summary.remaining, isEmpty);
      expect(summary.outcomes.every((o) => o.error == null), isTrue);

      expect(rec.progress, [
        (done: 1, total: 2),
        (done: 2, total: 2),
      ]);
      expect(session.dir.existsSync(), isFalse,
          reason: 'cleanupIfEmpty runs after the loop');
    });

    test('writer throws on 2nd of 3: shot1 ok+deleted, shots 2-3 kept and '
        'are exactly remaining, allOk false', () async {
      final session = await _session('100438', [
        '100438_20260908_101112_1.jpg',
        '100438_20260908_101113_2.jpg',
        '100438_20260908_101114_3.jpg',
      ]);
      final shots = session.shots.toList();
      final rec = _Recorder();

      // First write succeeds; everything after fails (share drops mid-run).
      var calls = 0;
      Future<void> writer(String remotePath, Uint8List bytes) async {
        calls += 1;
        if (calls > 1) {
          throw StateError('SMB write failed');
        }
        return rec.writeShot(remotePath, bytes);
      }

      final summary = await uploadSession(
        session,
        _settings(folders: true),
        writeShot: writer,
        ensureFolder: rec.ensureFolder,
        onProgress: rec.onProgress,
      );

      expect(File(shots[0].localPath).existsSync(), isFalse,
          reason: 'shot 1 succeeded → local deleted');
      expect(File(shots[1].localPath).existsSync(), isTrue);
      expect(File(shots[2].localPath).existsSync(), isTrue);

      expect(summary.allOk, isFalse);
      expect(summary.uploadedCount, 1);
      expect(summary.remaining, [shots[1], shots[2]]);
      expect(summary.outcomes[0].ok, isTrue);
      expect(summary.outcomes[1].ok, isFalse);
      expect(summary.outcomes[1].error, contains('SMB write failed'));
      expect(summary.outcomes[2].ok, isFalse);

      expect(rec.progress, [
        (done: 1, total: 3),
        (done: 2, total: 3),
        (done: 3, total: 3),
      ]);
      expect(session.dir.existsSync(), isTrue,
          reason: 'shots remain staged — no cleanup');
    });

    test('ensureFolder: sharePath + sharePath/order when folders on',
        () async {
      final session = await _session('100438', ['a.jpg']);
      final rec = _Recorder();

      await uploadSession(
        session,
        _settings(folders: true),
        writeShot: rec.writeShot,
        ensureFolder: rec.ensureFolder,
      );

      expect(rec.ensured, ['/zdrive/InvoiceData', '/zdrive/InvoiceData/100438']);
    });

    test('ensureFolder: only sharePath when folders off', () async {
      final session = await _session('100438', ['a.jpg']);
      final rec = _Recorder();

      await uploadSession(
        session,
        _settings(folders: false),
        writeShot: rec.writeShot,
        ensureFolder: rec.ensureFolder,
      );

      expect(rec.ensured, ['/zdrive/InvoiceData']);
    });

    test('injected fakes never open a connection (empty username would '
        'throw SmbNotConfiguredException if they did)', () async {
      final session = await _session('100438', ['a.jpg']);
      final rec = _Recorder();

      final summary = await uploadSession(
        session,
        _settings(folders: false),
        writeShot: rec.writeShot,
        ensureFolder: rec.ensureFolder,
      );

      expect(summary.allOk, isTrue);
    });

    test('unreadable local file → failed outcome with error, other shots '
        'unaffected', () async {
      final session = await _session('100438', ['a.jpg']);
      final good = session.shots.single;
      final missing = Shot(
        localPath: '${session.dir.path}/never-written.jpg',
        fileName: '100438_20260908_101113_2.jpg',
      );
      session.add(missing);
      final rec = _Recorder();

      final summary = await uploadSession(
        session,
        _settings(folders: false),
        writeShot: rec.writeShot,
        ensureFolder: rec.ensureFolder,
        onProgress: rec.onProgress,
      );

      expect(summary.allOk, isFalse);
      expect(summary.uploadedCount, 1);
      expect(summary.remaining, [missing]);
      expect(summary.outcomes[0].ok, isTrue,
          reason: 'the shot before the bad one still uploads');
      expect(summary.outcomes[1].ok, isFalse);
      expect(summary.outcomes[1].error, isNotNull);
      expect(File(good.localPath).existsSync(), isFalse);
      expect(rec.writes, hasLength(1));
      expect(rec.progress, [
        (done: 1, total: 2),
        (done: 2, total: 2),
      ]);
    });

    test('throwing ensureFolder is swallowed (best-effort, share must '
        'pre-exist)', () async {
      final session = await _session('100438', ['a.jpg']);
      final rec = _Recorder();

      Future<void> failingEnsurer(String path) async {
        throw StateError('already exists');
      }

      final summary = await uploadSession(
        session,
        _settings(folders: true),
        writeShot: rec.writeShot,
        ensureFolder: failingEnsurer,
      );

      expect(summary.allOk, isTrue);
      expect(rec.writes, hasLength(1));
    });

    group('only (subset pass — the review page uploads READY shots)', () {
      test('uploads exactly the subset, keeps the rest staged, progress '
          'counts the subset', () async {
        final session = await _session('100438', [
          '100438_20260908_101112_1.jpg',
          '100438_20260908_101113_2.jpg',
          '100438_20260908_101114_3.jpg',
        ]);
        final shots = session.shots.toList();
        final rec = _Recorder();

        // The review page's shape: every READY entry, verbatim, in order —
        // here the first two (a conversion-failed third stays behind).
        final summary = await uploadSession(
          session,
          _settings(folders: true),
          only: [shots[0], shots[1]],
          writeShot: rec.writeShot,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
        );

        expect(rec.writes, hasLength(2));
        expect(
          rec.writes[0].path,
          '/zdrive/InvoiceData/100438/100438_20260908_101112_1.jpg',
        );
        expect(
          rec.writes[1].path,
          '/zdrive/InvoiceData/100438/100438_20260908_101113_2.jpg',
        );
        expect(File(shots[0].localPath).existsSync(), isFalse);
        expect(File(shots[1].localPath).existsSync(), isFalse);
        expect(File(shots[2].localPath).existsSync(), isTrue,
            reason: 'a shot outside the subset is never touched');
        expect(session.shots, [shots[2]],
            reason: 'the skipped entry stays staged');
        expect(summary.allOk, isTrue);
        expect(summary.uploadedCount, 2);
        expect(summary.remaining, isEmpty);
        expect(rec.progress, [
          (done: 1, total: 2),
          (done: 2, total: 2),
        ]);
        expect(session.dir.existsSync(), isTrue,
            reason: 'staged entries remain — no cleanup');
      });

      test('an empty subset uploads nothing and leaves the session intact',
          () async {
        final session = await _session('100438', ['a.jpg']);
        final rec = _Recorder();

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          only: const [],
          writeShot: rec.writeShot,
          ensureFolder: rec.ensureFolder,
        );

        expect(rec.writes, isEmpty);
        expect(summary.outcomes, isEmpty);
        expect(summary.allOk, isTrue, reason: 'nothing attempted, nothing failed');
        expect(session.shots, hasLength(1));
        expect(session.dir.existsSync(), isTrue);
      });

      test('a subset with a failing write keeps that shot staged as '
          'remaining', () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg']);
        final shots = session.shots.toList();
        final rec = _Recorder();

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          only: shots,
          writeShot: (path, bytes) async {
            throw StateError('SMB write failed');
          },
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
        );

        expect(summary.allOk, isFalse);
        expect(summary.remaining, shots);
        expect(session.shots, shots);
      });
    });

    group('per-shot write timeout → dead connection (fail-fast + auto-retry)', () {
      test('default timeout is 30s per shot', () {
        expect(smbWriteTimeout, const Duration(seconds: 30));
      });

      test('progress gate: shot 1 uploads, shot 2 hangs → shots skip at '
          'once on the dead connection, the auto-retry redial finishes the '
          'batch allOk', () async {
        final session = await _session('100438', [
          '100438_20260908_101112_1.jpg',
          '100438_20260908_101113_2.jpg',
          '100438_20260908_101114_3.jpg',
        ]);
        final rec = _Recorder();

        // Call 2 (round 1's second shot) never completes — the connection
        // dies under it. The writer is healthy again by the retry round.
        final hang = Completer<void>();
        var calls = 0;
        Future<void> writer(String remotePath, Uint8List bytes) {
          calls += 1;
          if (calls == 2) return hang.future;
          return rec.writeShot(remotePath, bytes);
        }

        final summary = await uploadSession(
          session,
          _settings(folders: true),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
          writeTimeout: const Duration(milliseconds: 100),
          retryDelays: const [Duration(milliseconds: 10)],
        );

        // Round 1: shot 1 uploaded, shot 2 timed out, shot 3 skipped
        // WITHOUT being attempted. Round 2 (fresh redial): shots 2-3.
        expect(calls, 4,
            reason: 'shot 3 must be skipped on the dead connection, not '
                'attempted (a continuing batch would stop at 3 calls)');
        expect(rec.writes, hasLength(3));
        expect(summary.allOk, isTrue);
        expect(summary.uploadedCount, 3);
        expect(summary.remaining, isEmpty);
        expect(rec.progress, [
          (done: 1, total: 3),
          (done: 2, total: 3),
          (done: 3, total: 3),
        ], reason: 'monotonic across rounds, ending at (3,3)');
        expect(session.shots, isEmpty);
        expect(session.dir.existsSync(), isFalse,
            reason: 'everything uploaded → session dir reclaimed');
        // The hung write is abandoned, not awaited to completion.
        expect(hang.isCompleted, isFalse);
      });

      test('dead connection then healthy: after the backoff the remaining '
          'shots resume on the redial and ALL upload (allOk, progress '
          'reaches (3,3))', () async {
        final session = await _session('100438', [
          '100438_20260908_101112_1.jpg',
          '100438_20260908_101113_2.jpg',
          '100438_20260908_101114_3.jpg',
        ]);
        final rec = _Recorder();

        // Only the FIRST write hangs — the connection is dead right at the
        // start and the share is back by the time the uploader redials.
        final hang = Completer<void>();
        var calls = 0;
        Future<void> writer(String remotePath, Uint8List bytes) {
          calls += 1;
          if (calls == 1) return hang.future;
          return rec.writeShot(remotePath, bytes);
        }

        final summary = await uploadSession(
          session,
          _settings(folders: true),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
          writeTimeout: const Duration(milliseconds: 100),
          retryDelays: const [Duration(milliseconds: 10)],
        );

        expect(calls, 4,
            reason: 'round 1 attempted only shot 1 (shots 2-3 were skipped '
                'on the dead connection); the redial re-ran all three');
        expect(
          rec.writes.map((w) => w.path).toList(),
          [
            '/zdrive/InvoiceData/100438/100438_20260908_101112_1.jpg',
            '/zdrive/InvoiceData/100438/100438_20260908_101113_2.jpg',
            '/zdrive/InvoiceData/100438/100438_20260908_101114_3.jpg',
          ],
          reason: 'the retry round re-runs every remaining shot, in order',
        );
        expect(summary.allOk, isTrue);
        expect(summary.uploadedCount, 3);
        expect(summary.remaining, isEmpty);
        expect(rec.progress.last, (done: 3, total: 3));
        expect(session.shots, isEmpty);
        expect(session.dir.existsSync(), isFalse);
      });

      test('connection never recovers: each round attempts only shot 1 and '
          'skips 2-3 instantly; bounded rounds then stop (1 timeout + 2 '
          'skipped in the summary, manual Retry still finishes the batch)',
          () async {
        final session = await _session('100438', [
          '100438_20260908_101112_1.jpg',
          '100438_20260908_101113_2.jpg',
          '100438_20260908_101114_3.jpg',
        ]);
        final shots = session.shots.toList();
        final rec = _Recorder();

        // EVERY write hangs — the share stays unreachable.
        var calls = 0;
        Future<void> writer(String remotePath, Uint8List bytes) async {
          calls += 1;
          await Completer<void>().future;
        }

        final sw = Stopwatch()..start();
        final summary = await uploadSession(
          session,
          _settings(folders: true),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
          writeTimeout: const Duration(milliseconds: 100),
          maxAutoRetries: 2,
          retryDelays: const [
            Duration(milliseconds: 10),
            Duration(milliseconds: 10),
          ],
        );
        sw.stop();

        expect(calls, 3,
            reason: 'exactly one attempted shot per round — shots 2-3 are '
                'skipped instead of each burning their own timeout');
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 700)),
            reason: '3 rounds ≈ 3 timeouts + 2 backoffs ≈ 320ms; the old '
                'serial grind (every shot waiting out its timeout, every '
                'round) needs ≥ 900ms of timeouts alone');
        expect(summary.allOk, isFalse);
        expect(summary.outcomes[0].ok, isFalse);
        expect(summary.outcomes[0].error, 'Write timed out after 100ms');
        expect(summary.outcomes[1].ok, isFalse);
        expect(summary.outcomes[1].error, connectionLostSkipMessage);
        expect(summary.outcomes[2].ok, isFalse);
        expect(summary.outcomes[2].error, connectionLostSkipMessage);
        expect(summary.uploadedCount, 0);
        expect(summary.remaining, shots,
            reason: 'all three stay staged for the manual Retry');
        for (final s in shots) {
          expect(File(s.localPath).existsSync(), isTrue,
              reason: 'timed-out and skipped shots keep their local files');
        }
        expect(session.shots, shots);
        expect(rec.progress, [
          (done: 1, total: 3),
          (done: 2, total: 3),
          (done: 3, total: 3),
        ],
            reason: 'the failures only finalize once no round can re-attempt '
                'them — done never moves backwards');

        // Manual Retry (the review page re-invokes the uploader on the
        // remaining entries) with the share back: finishes the batch.
        final retry = await uploadSession(
          session,
          _settings(folders: true),
          only: summary.remaining,
          writeShot: rec.writeShot,
          ensureFolder: rec.ensureFolder,
          writeTimeout: const Duration(milliseconds: 100),
        );

        expect(retry.allOk, isTrue);
        expect(retry.remaining, isEmpty);
        expect(rec.writes, hasLength(3),
            reason: 'the auto-retry rounds never recorded a write; the '
                'manual Retry wrote all three');
        expect(session.shots, isEmpty);
        expect(session.dir.existsSync(), isFalse);
      });

      test('zero-progress rounds are bounded: a writer that dies instantly '
          'on every call with maxAutoRetries=1 runs exactly 2 rounds, then '
          'stops', () async {
        final session = await _session('100438', [
          '100438_20260908_101112_1.jpg',
          '100438_20260908_101113_2.jpg',
          '100438_20260908_101114_3.jpg',
        ]);
        final rec = _Recorder();

        var calls = 0;
        Future<void> writer(String remotePath, Uint8List bytes) async {
          calls += 1;
          // Throwing TimeoutException IS the dead-connection signal (the
          // real writer surfaces the per-shot .timeout the same way) — and
          // it fires instantly, the injected analog of a dial that cannot
          // come up: every round makes zero progress.
          throw TimeoutException('connection dead instantly');
        }

        final summary = await uploadSession(
          session,
          _settings(folders: true),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
          writeTimeout: const Duration(seconds: 30), // never reached
          maxAutoRetries: 1,
          retryDelays: const [Duration(milliseconds: 5)],
        );

        expect(calls, 2,
            reason: 'initial round + exactly one auto-retry — the first '
                'retry always runs, but a zero-progress round does not earn '
                'a third once the bound is spent');
        expect(summary.allOk, isFalse);
        expect(summary.outcomes[0].error, 'connection dead instantly');
        expect(summary.outcomes[1].error, connectionLostSkipMessage);
        expect(summary.outcomes[2].error, connectionLostSkipMessage);
        expect(summary.remaining, hasLength(3));
        expect(rec.progress.last, (done: 3, total: 3));
      });

      test('BOTH auto-retry rounds run under maxAutoRetries=2 when every '
          'round makes progress: a connection that dies under every second '
          'shot still finishes allOk', () async {
        final session = await _session('100438', [
          '100438_20260908_101112_1.jpg',
          '100438_20260908_101113_2.jpg',
          '100438_20260908_101114_3.jpg',
        ]);
        final rec = _Recorder();

        // Every EVEN call stalls out (the connection dies under it); every
        // odd call succeeds. Round 1 uploads shot 1 and dies under shot 2;
        // retry 1 uploads shot 2 and dies under shot 3; retry 2 uploads
        // shot 3. Each round's progress is what keeps the gate open for the
        // next one — with a bound of 1 the batch would stop at 4 calls.
        final hang = Completer<void>();
        var calls = 0;
        Future<void> writer(String remotePath, Uint8List bytes) {
          calls += 1;
          if (calls.isEven) return hang.future;
          return rec.writeShot(remotePath, bytes);
        }

        final summary = await uploadSession(
          session,
          _settings(folders: true),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
          writeTimeout: const Duration(milliseconds: 100),
          maxAutoRetries: 2,
          retryDelays: const [
            Duration(milliseconds: 10),
            Duration(milliseconds: 10),
          ],
        );

        expect(calls, 5,
            reason: 'three rounds — initial + BOTH retries — pinning the '
                'round-counting machinery: round 2 must be reachable while '
                'retryCount < maxAutoRetries');
        expect(rec.writes, hasLength(3));
        expect(summary.allOk, isTrue);
        expect(summary.uploadedCount, 3);
        expect(summary.remaining, isEmpty);
        expect(rec.progress, [
          (done: 1, total: 3),
          (done: 2, total: 3),
          (done: 3, total: 3),
        ]);
        expect(session.shots, isEmpty);
        expect(session.dir.existsSync(), isFalse);
      });

      test('timeout fires per shot, not per batch — each of several slow '
          'shots gets its own budget', () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg', 'c.jpg']);
        final rec = _Recorder();

        // Every write takes 30ms. With a 40ms PER-SHOT timeout all three
        // fit (3 x 30ms = 90ms total); if the budget were shared across the
        // batch, the third write would blow past the cumulative 40ms mark.
        Future<void> writer(String remotePath, Uint8List bytes) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return rec.writeShot(remotePath, bytes);
        }

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          writeTimeout: const Duration(milliseconds: 40),
        );

        expect(summary.allOk, isTrue,
            reason: 'each shot got a fresh 40ms budget; 3 slow writes fit');
        expect(rec.writes, hasLength(3));
      });

      test('a timeout counts against the write phase only — the injected '
          'writer IS the write phase, so it is bounded end-to-end', () async {
        final session = await _session('100438', ['a.jpg']);
        final rec = _Recorder();

        final gate = Completer<void>();
        Future<void> writer(String remotePath, Uint8List bytes) => gate.future;

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          writeShot: writer,
          ensureFolder: rec.ensureFolder,
          onProgress: rec.onProgress,
          writeTimeout: const Duration(milliseconds: 50),
          // The lone timed-out shot now earns auto-retry rounds too; this
          // test is about the per-shot bound, so keep the backoffs short.
          retryDelays: const [Duration(milliseconds: 1)],
        );

        expect(summary.allOk, isFalse);
        expect(summary.outcomes.single.error, 'Write timed out after 50ms');
        expect(rec.progress, [(done: 1, total: 1)]);
      });
    });
  });
}
