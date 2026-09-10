import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:orderpic/capture/session.dart';
import 'package:orderpic/capture/uploader.dart';
import 'package:orderpic/settings/app_settings.dart';

/// Signifier for "this write never completes" in a [_ScriptedConn]'s plan.
class _Hang {
  const _Hang();
}

const hang = _Hang();

/// One fake connection recording every operation into the shared [log] as
/// `name op argument`. Write behavior is scripted per call in write-order:
/// `null` (or past the plan's end) → success, [hang] → never completes,
/// anything else → thrown. Delete can be made to fail (the server refusing
/// to release a locked partial file); exists answers per-path.
class _ScriptedConn implements UploadConnection {
  _ScriptedConn(this.name, this.log);

  final String name;
  final List<String> log;
  final List<Object?> writePlan = [];
  final Map<String, bool> existsAnswers = {};
  Object? deleteError;
  int writes = 0;

  @override
  Future<void> write(String remotePath, Uint8List bytes) {
    log.add('$name write $remotePath');
    final plan = writes < writePlan.length ? writePlan[writes] : null;
    writes++;
    if (plan is _Hang) return Completer<void>().future;
    if (plan != null) throw plan;
    return Future.value();
  }

  @override
  Future<void> ensureFolder(String path) {
    log.add('$name ensure $path');
    return Future.value();
  }

  @override
  Future<bool> exists(String remotePath) {
    log.add('$name exists $remotePath');
    return Future.value(existsAnswers[remotePath] ?? false);
  }

  @override
  Future<void> delete(String remotePath) {
    log.add('$name delete $remotePath');
    if (deleteError != null) throw deleteError!;
    return Future.value();
  }

  @override
  Future<void> close() {
    log.add('$name close');
    return Future.value();
  }
}

/// Hands out scripted connections from the `dial` seam and records the
/// sequence. `failDialsFrom` makes dial N and every later one fail.
class _Dials {
  final log = <String>[];
  final conns = <_ScriptedConn>[];
  int count = 0;
  int? failDialsFrom;

  Future<UploadConnection> call() {
    count++;
    if (failDialsFrom != null && count >= failDialsFrom!) {
      throw StateError('network unreachable');
    }
    final c = _ScriptedConn('c$count', log);
    conns.add(c);
    return Future.value(c);
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

const ConnectionSettings _conn = ConnectionSettings(
  host: '192.0.2.1',
  sharePath: '/zdrive/InvoiceData',
  domain: '',
  username: '', // empty on purpose: any real dial would refuse
  password: '',
);

AppSettings _settings({required bool folders}) => AppSettings(
  connection: _conn,
  upload: UploadPrefs(useOrderFolders: folders),
);

const _fast = Duration(milliseconds: 50);
const _tick = Duration(milliseconds: 1);

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
        c: const ConnectionSettings(
          host: 'h',
          sharePath: '/zdrive/InvoiceData/Sub',
          domain: '',
          username: 'u',
          password: 'p',
        ),
        u: const UploadPrefs(useOrderFolders: false),
        orderNumber: '100438',
        fileName: '100438_20260908_101112_1.jpg',
      );
      expect(path, '/zdrive/InvoiceData/Sub/100438_20260908_101112_1.jpg');
    });

    test('folders on: sharePath/orderNumber/fileName', () {
      final path = uploadTargetPath(
        c: const ConnectionSettings(
          host: 'h',
          sharePath: '/zdrive/InvoiceData/Sub',
          domain: '',
          username: 'u',
          password: 'p',
        ),
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

  group('uploadSession (dialed fake connections)', () {
    test('two shots → two writes to right paths, locals deleted, allOk, '
        'progress (1,2) then (2,2), session dir cleaned up', () async {
      final session = await _session('100438', [
        '100438_20260908_101112_1.jpg',
        '100438_20260908_101113_2.jpg',
      ]);
      final shot1 = session.shots[0];
      final shot2 = session.shots[1];
      final dials = _Dials();
      final progress = <({int done, int total})>[];

      final summary = await uploadSession(
        session,
        _settings(folders: true),
        dial: dials.call,
        onProgress: (done, total) => progress.add((done: done, total: total)),
      );

      expect(dials.count, 1, reason: 'a healthy pass never redials');
      expect(
        dials.log,
        [
          'c1 ensure /zdrive/InvoiceData',
          'c1 ensure /zdrive/InvoiceData/100438',
          'c1 write /zdrive/InvoiceData/100438/100438_20260908_101112_1.jpg',
          'c1 write /zdrive/InvoiceData/100438/100438_20260908_101113_2.jpg',
          'c1 close',
        ],
      );
      expect(File(shot1.localPath).existsSync(), isFalse);
      expect(File(shot2.localPath).existsSync(), isFalse);
      expect(session.shots, isEmpty);
      expect(summary.allOk, isTrue);
      expect(summary.uploadedCount, 2);
      expect(summary.remaining, isEmpty);
      expect(summary.outcomes.every((o) => o.error == null), isTrue);
      expect(progress, [
        (done: 1, total: 2),
        (done: 2, total: 2),
      ]);
      expect(session.dir.existsSync(), isFalse,
          reason: 'cleanupIfEmpty runs after the loop');
    });

    test('folders off → only the share path is ensured', () async {
      final session = await _session('100438', ['a.jpg']);
      final dials = _Dials();

      await uploadSession(session, _settings(folders: false), dial: dials.call);

      expect(
        dials.log.where((e) => e.contains('ensure')).toList(),
        ['c1 ensure /zdrive/InvoiceData'],
      );
    });

    test('a throwing ensureFolder is swallowed (best-effort, share must '
        'pre-exist)', () async {
      final session = await _session('100438', ['a.jpg']);
      final dials = _Dials();

      // The default _ScriptedConn.ensureFolder cannot throw; script a
      // throwing one by subclassing the seam inline.
      final throwing = _ThrowingEnsureConn('c1', dials.log);
      final summary = await uploadSession(
        session,
        _settings(folders: true),
        dial: () async => throwing,
      );

      expect(summary.allOk, isTrue);
      expect(throwing.writes, 1);
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
      final dials = _Dials();
      final progress = <({int done, int total})>[];

      final summary = await uploadSession(
        session,
        _settings(folders: false),
        dial: dials.call,
        onProgress: (done, total) => progress.add((done: done, total: total)),
      );

      expect(summary.allOk, isFalse);
      expect(summary.uploadedCount, 1);
      expect(summary.remaining, [missing]);
      expect(summary.outcomes[0].ok, isTrue,
          reason: 'the shot before the bad one still uploads');
      expect(summary.outcomes[1].ok, isFalse);
      expect(summary.outcomes[1].error, isNotNull);
      expect(File(good.localPath).existsSync(), isFalse);
      expect(dials.conns.single.writes, 1);
      expect(progress, [
        (done: 1, total: 2),
        (done: 2, total: 2),
      ]);
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
        final dials = _Dials();
        final progress = <({int done, int total})>[];

        final summary = await uploadSession(
          session,
          _settings(folders: true),
          only: [shots[0], shots[1]],
          dial: dials.call,
          onProgress: (done, total) => progress.add((done: done, total: total)),
        );

        expect(dials.conns.single.writes, 2);
        expect(
          dials.log.where((e) => e.contains('write')).toList(),
          [
            'c1 write /zdrive/InvoiceData/100438/100438_20260908_101112_1.jpg',
            'c1 write /zdrive/InvoiceData/100438/100438_20260908_101113_2.jpg',
          ],
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
        expect(progress, [
          (done: 1, total: 2),
          (done: 2, total: 2),
        ]);
        expect(session.dir.existsSync(), isTrue,
            reason: 'staged entries remain — no cleanup');
      });

      test('an empty subset uploads nothing and leaves the session intact',
          () async {
        final session = await _session('100438', ['a.jpg']);
        final dials = _Dials();

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          only: const [],
          dial: dials.call,
        );

        expect(dials.conns, isEmpty, reason: 'nothing to upload — never dials');
        expect(summary.outcomes, isEmpty);
        expect(summary.allOk, isTrue,
            reason: 'nothing attempted, nothing failed');
        expect(session.shots, hasLength(1));
        expect(session.dir.existsSync(), isTrue);
      });
    });
  });

  group('in-place retry (a failed shot is retried before the batch moves on)',
      () {
      test('transient write error: the SAME shot is retried on the same '
          'connection before the next shot runs', () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg']);
        final dials = _Dials();
        // First write attempt fails; the retry succeeds.
        dials.conns.add(_ScriptedConn('c1', dials.log));
        dials.conns.single.writePlan.add(StateError('server busy'));

        Future<UploadConnection> dial() async => dials.conns.single;
        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: dial,
          redialDelay: _tick,
        );

        expect(
          dials.log.where((e) => e.contains('write')).toList(),
          ['c1 write /zdrive/InvoiceData/a.jpg',
           'c1 write /zdrive/InvoiceData/a.jpg',
           'c1 write /zdrive/InvoiceData/b.jpg'],
          reason: 'shot A is retried BEFORE the batch moves to shot B',
        );
        expect(summary.allOk, isTrue);
        expect(session.shots, isEmpty);
      });

      test('write timeout: connection closed, shot retried on a FRESH '
          'connection before the next shot, batch finishes allOk', () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg', 'c.jpg']);
        final dials = _Dials();
        // c1's only write hangs — dead connection. c2 is healthy.
        var count = 0;
        Future<UploadConnection> dial() {
          count++;
          if (count == 1) {
            final c = _ScriptedConn('c1', dials.log)..writePlan.add(hang);
            dials.conns.add(c);
            return Future.value(c);
          }
          final c = _ScriptedConn('c$count', dials.log);
          dials.conns.add(c);
          return Future.value(c);
        }

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: dial,
          writeTimeout: _fast,
          redialDelay: _tick,
        );

        expect(
          dials.log,
          containsAllInOrder([
            'c1 write /zdrive/InvoiceData/a.jpg',
            'c1 close',
            'c2 ensure /zdrive/InvoiceData',
            'c2 write /zdrive/InvoiceData/a.jpg',
            'c2 write /zdrive/InvoiceData/b.jpg',
            'c2 write /zdrive/InvoiceData/c.jpg',
          ]),
          reason: 'the timed-out shot is retried on the redial BEFORE the '
              'batch moves on; folders re-ensured on the fresh connection',
        );
        expect(summary.allOk, isTrue);
        expect(summary.uploadedCount, 3);
        expect(session.shots, isEmpty);
        expect(session.dir.existsSync(), isFalse);
      });

      test('a timeout counts against the write phase only — several slow '
          'shots each get their own budget', () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg', 'c.jpg']);
        final dials = _Dials();

        Future<UploadConnection> dial() async {
          final c = _SlowConn('c${dials.count + 1}', dials.log);
          dials.count++;
          dials.conns.add(c);
          return c;
        }

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: dial,
          writeTimeout: const Duration(milliseconds: 40),
        );

        expect(summary.allOk, isTrue,
            reason: 'each shot got a fresh 40ms budget; 3 slow writes fit');
        expect(dials.conns.single.writes, 3);
      });
  });

  group('end-of-pass rescue + partial-file cleanup', () {
      test('a shot that failed both attempts uploads on the end-of-pass '
          're-attempt (allOk, local deleted)', () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg']);
        final dials = _Dials();
        // a.jpg fails twice, succeeds on the third call (the rescue).
        final c1 = _ScriptedConn('c1', dials.log)
          ..writePlan.addAll([
            StateError('server busy'),
            StateError('server busy'),
          ]);
        dials.conns.add(c1);

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: () async => c1,
          redialDelay: _tick,
        );

        expect(
          dials.log.where((e) => e.contains('write')).toList(),
          [
            'c1 write /zdrive/InvoiceData/a.jpg',
            'c1 write /zdrive/InvoiceData/a.jpg',
            'c1 write /zdrive/InvoiceData/b.jpg',
            'c1 write /zdrive/InvoiceData/a.jpg',
          ],
          reason: 'two in-place attempts, then B, then the rescue re-attempt '
              'of A after the pass ends',
        );
        expect(summary.allOk, isTrue);
        expect(session.shots, isEmpty,
            reason: 'the rescued shot deletes its local file');
      });

      test('final failure with a partial remote file: the rescue re-attempts, '
          'then the broken remote copy is deleted and the error says so',
          () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg']);
        final aPath = '/zdrive/InvoiceData/a.jpg';
        final dials = _Dials();
        // Write order is A, A (retry), B, A (rescue) — B must succeed.
        final c1 = _ScriptedConn('c1', dials.log)
          ..writePlan.addAll([
            StateError('file in use'),
            StateError('file in use'),
            null, // B uploads
            StateError('file in use'), // the rescue re-attempt fails
          ])
          ..existsAnswers[aPath] = true;
        dials.conns.add(c1);

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: () async => c1,
          redialDelay: _tick,
        );

        expect(summary.allOk, isFalse);
        expect(summary.uploadedCount, 1, reason: 'B uploaded');
        expect(summary.remaining, hasLength(1));
        expect(summary.outcomes[0].error, contains('file in use'));
        expect(summary.outcomes[0].error,
            contains('partial server copy removed'),
            reason: 'the operator is told the broken file is gone');
        expect(
          dials.log.where((e) => e.contains('delete')).toList(),
          ['c1 delete $aPath'],
          reason: 'exactly the broken copy is removed — B was never partial',
        );
        expect(File(summary.remaining.single.localPath).existsSync(), isTrue,
            reason: 'the failed shot stays staged for Retry');
        expect(session.shots, hasLength(1));
      });

      test('final failure while the server still holds the partial file: '
          'the delete is refused and the error names the lock window',
          () async {
        final session = await _session('100438', ['a.jpg']);
        final aPath = '/zdrive/InvoiceData/a.jpg';
        final dials = _Dials();
        final c1 = _ScriptedConn('c1', dials.log)
          ..writePlan.addAll([
            StateError('file in use'),
            StateError('file in use'),
            StateError('file in use'),
          ])
          ..existsAnswers[aPath] = true
          ..deleteError = StateError('sharing violation');
        dials.conns.add(c1);

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: () async => c1,
          redialDelay: _tick,
        );

        expect(summary.outcomes.single.error, contains('file in use'));
        expect(summary.outcomes.single.error,
            contains('still holds a partial copy'),
            reason: 'the operator learns the file clears on its own');
        expect(
          dials.log.where((e) => e.contains('delete')).toList(),
          ['c1 delete $aPath'],
          reason: 'the cleanup was attempted, the server refused it',
        );
      });

      test('final failure with NO partial remote file: no delete attempt, '
          'plain error', () async {
        final session = await _session('100438', ['a.jpg']);
        final dials = _Dials();
        final c1 = _ScriptedConn('c1', dials.log)
          ..writePlan.addAll([
            StateError('access denied'),
            StateError('access denied'),
            StateError('access denied'),
          ]);
        dials.conns.add(c1);

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: () async => c1,
          redialDelay: _tick,
        );

        expect(summary.outcomes.single.error, contains('access denied'));
        expect(dials.log.where((e) => e.contains('delete')), isEmpty,
            reason: 'nothing was ever created server-side — nothing to remove');
        expect(dials.log.where((e) => e.contains('exists')).toList(),
            ['c1 exists /zdrive/InvoiceData/a.jpg'],
            reason: 'the probe still ran');
      });
  });

  group('dead-network abort (bounded, no serial timeouts)', () {
      test('two write timeouts with no success in between abort the pass: '
          'remaining shots are skip-marked without being attempted',
          () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg', 'c.jpg']);
        final shots = session.shots.toList();
        final dials = _Dials();
        // Every write on every connection hangs forever.
        Future<UploadConnection> dial() {
          final c = _ScriptedConn('c${dials.count + 1}', dials.log)
            ..writePlan.add(hang);
          dials.count++;
          dials.conns.add(c);
          return Future.value(c);
        }
        final progress = <({int done, int total})>[];

        final sw = Stopwatch()..start();
        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: dial,
          writeTimeout: _fast,
          redialDelay: _tick,
          dialTimeout: _fast,
          onProgress: (done, total) => progress.add((done: done, total: total)),
        );
        sw.stop();

        final writes =
            dials.log.where((e) => e.contains('write')).toList();
        expect(writes, hasLength(2), reason: 'only shot A is ever attempted');
        expect(writes.every((e) => e.endsWith('a.jpg')), isTrue);
        expect(dials.count, 2, reason: 'initial dial + one redial, then stop');
        expect(summary.allOk, isFalse);
        expect(summary.outcomes[0].error, 'Write timed out after 50ms');
        expect(summary.outcomes[1].error, connectionLostSkipMessage);
        expect(summary.outcomes[2].error, connectionLostSkipMessage);
        expect(summary.remaining, shots,
            reason: 'everything stays staged for the manual Retry');
        for (final s in shots) {
          expect(File(s.localPath).existsSync(), isTrue);
        }
        expect(progress, [
          (done: 1, total: 3),
          (done: 2, total: 3),
          (done: 3, total: 3),
        ], reason: 'failures finalize once, at the end');
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 700)),
            reason: '2 timeouts + a redial ≈ 110ms; a serial grind over '
                'every shot would need ≥ 450ms of timeouts alone');
      });

      test('a redial that cannot come up aborts instantly: unattempted shots '
          'are skip-marked, the timed-out shot keeps its message',
          () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg']);
        final dials = _Dials()..failDialsFrom = 2;
        Future<UploadConnection> dial() {
          dials.count++;
          if (dials.count >= 2) {
            return Completer<UploadConnection>().future; // dial hangs → bound
          }
          final c = _ScriptedConn('c1', dials.log)..writePlan.add(hang);
          dials.conns.add(c);
          return Future.value(c);
        }

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: dial,
          writeTimeout: _fast,
          redialDelay: _tick,
          dialTimeout: _fast,
        );

        expect(summary.allOk, isFalse);
        expect(summary.outcomes[0].error, 'Write timed out after 50ms');
        expect(summary.outcomes[1].error, connectionLostSkipMessage);
        expect(dials.log.where((e) => e.contains('write')).toList(),
            ['c1 write /zdrive/InvoiceData/a.jpg'],
            reason: 'shot B is never attempted on a dead network');
      });

      test('the initial dial failing throws (unchanged first-run behavior)',
          () async {
        final session = await _session('100438', ['a.jpg']);
        final dials = _Dials()..failDialsFrom = 1;

        await expectLater(
          uploadSession(session, _settings(folders: false), dial: dials.call),
          throwsStateError,
        );
      });
  });

  group('abandoned futures must not leak unhandled zone errors', () {
      test('a write that errors AFTER its timeout abandoned it stays silent',
          () async {
        final session = await _session('100438', ['a.jpg', 'b.jpg']);
        final dials = _Dials();
        // c1's write completes with an error 150ms after the 50ms timeout
        // fires. Under .timeout() that late error becomes an unhandled zone
        // exception (the device log's "Bad state: StreamSink is closed"
        // spam); the uploader must swallow it.
        final c1 = _LateErrorConn('c1', dials.log);
        dials.conns.add(c1);
        Future<UploadConnection> dial() async {
          if (dials.count++ == 0) return c1;
          final c = _ScriptedConn('c2', dials.log);
          dials.conns.add(c);
          return c;
        }

        final summary = await uploadSession(
          session,
          _settings(folders: false),
          dial: dial,
          writeTimeout: _fast,
          redialDelay: _tick,
        );

        expect(summary.allOk, isTrue,
            reason: 'the redial rescued both shots');
        // Outlive the late error: if it leaks, flutter_test fails this test
        // with "Unhandled exception" after this await.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
  });
}

/// ensureFolder that always throws — the share "must pre-exist" path.
class _ThrowingEnsureConn extends _ScriptedConn {
  _ThrowingEnsureConn(super.name, super.log);

  @override
  Future<void> ensureFolder(String path) {
    log.add('$name ensure $path');
    throw StateError('already exists');
  }
}

/// A write that completes with an error only AFTER the caller abandoned it.
class _LateErrorConn extends _ScriptedConn {
  _LateErrorConn(super.name, super.log);

  @override
  Future<void> write(String remotePath, Uint8List bytes) {
    log.add('$name write $remotePath');
    writes++;
    if (writes == 1) {
      return Future<void>.delayed(
        const Duration(milliseconds: 150),
        () => throw StateError('late socket death'),
      );
    }
    return Future.value();
  }
}

/// Every write takes 30ms — slow but progressing, never timed out.
class _SlowConn extends _ScriptedConn {
  _SlowConn(super.name, super.log);

  @override
  Future<void> write(String remotePath, Uint8List bytes) {
    log.add('$name write $remotePath');
    writes++;
    return Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
