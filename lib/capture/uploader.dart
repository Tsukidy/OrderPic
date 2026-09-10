import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/smb_connect.dart' show SmbConnect;

import '../settings/app_settings.dart';
import '../smb/smb.dart';
import 'session.dart';

/// Bounds ONE shot's write phase (createFile → openWrite → add → flush →
/// close). smb_connect's sink has no socket-level write timeout, so a
/// connection dropped mid-write leaves the await pending forever — this
/// fails the shot into the retry path instead. Per-shot on purpose: a whole
/// batch of slow-but-progressing writes must not fail, and 30s for one photo
/// on a LAN is generous.
const Duration smbWriteTimeout = Duration(seconds: 30);

/// Pause before redialing after a write timeout — gives a blipped network a
/// moment to come back before the retry burns its attempt.
const Duration smbRedialDelay = Duration(seconds: 2);

/// Bound on each dial. A dial into a dead network can hang on the OS-level
/// connect timeout for minutes; the uploader must fail into its abort path
/// instead.
const Duration smbDialTimeout = Duration(seconds: 10);

/// Bound on the best-effort connection close. After a stalled write the
/// transport's send mutex can stay held, and `conn.close()` (session logoff
/// → sendrecv) would then wait on it forever — the very hang this file
/// exists to prevent.
const Duration _connCloseTimeout = Duration(seconds: 5);

/// Error text for a shot skipped because the network could not come up:
/// its write (or an earlier shot's) hit [smbWriteTimeout] and no redial
/// succeeded, so the remaining shots are abandoned at once instead of each
/// grinding out its own 30s timeout. The wording is the operator's
/// contract — the Retry button picks these shots back up.
const String connectionLostSkipMessage =
    'Connection lost — skipped (will retry)';

/// Appended to a finally-failed shot's error when the broken remote partial
/// was removed — the operator must know the share is clean.
const String _partialRemovedNote =
    ' — partial server copy removed; Retry re-uploads it';

/// Appended when the server REFUSED the cleanup delete: a dead session's
/// open handle keeps the partial file locked until the server reaps it
/// (typically a minute or two on Windows). Nothing client-side can release
/// it sooner; Retry after the window overwrites cleanly.
const String _partialHeldNote =
    ' — the server still holds a partial copy (it clears in a minute or two); '
    'Retry overwrites it';

/// User-readable text for a shot that outlived [smbWriteTimeout]. Sub-second
/// durations (tests) render as ms.
String _writeTimeoutMessage(Duration d) => d.inSeconds >= 1
    ? 'Write timed out after ${d.inSeconds}s'
    : 'Write timed out after ${d.inMilliseconds}ms';

/// One upload connection's SMB surface: everything [uploadSession] needs
/// from one (possibly freshly redialed) connection. Production wraps a real
/// [SmbConnect]; tests script instances from the `dial` seam, so the retry
/// machinery is exercised end-to-end without platform channels.
abstract interface class UploadConnection {
  /// Writes [bytes] to [remotePath], overwriting a partial file a previous
  /// attempt may have left ( smb1 dialects need probe+delete+recreate).
  Future<void> write(String remotePath, Uint8List bytes);

  /// Best-effort folder creation (errors when it exists — swallowed).
  Future<void> ensureFolder(String path);

  /// Whether [remotePath] exists — the partial-file probe.
  Future<bool> exists(String remotePath);

  /// Deletes [remotePath] — the partial-file cleanup.
  Future<void> delete(String remotePath);

  /// Closes the connection (bounded, must never throw).
  Future<void> close();
}

/// Builds one [UploadConnection]. Called for the initial dial and again for
/// every redial after a connection death.
typedef UploadConnectionFactory = Future<UploadConnection> Function();

/// The result of uploading one [Shot]: [ok] with the writer's error text
/// ([error]) when it failed. Failed shots stay staged for a retry pass.
class UploadOutcome {
  final Shot shot;
  final bool ok;
  final String? error;

  const UploadOutcome(this.shot, this.ok, this.error);
}

/// The whole session's upload: one [UploadOutcome] per staged shot, in
/// [CaptureSession.shots] order.
class UploadSummary {
  final List<UploadOutcome> outcomes;

  const UploadSummary(this.outcomes);

  /// True when every staged shot made it to the share.
  bool get allOk => outcomes.every((o) => o.ok);

  int get uploadedCount => outcomes.where((o) => o.ok).length;

  /// Shots that must be retried — still staged locally, so a failed upload
  /// never loses a photo.
  List<Shot> get remaining =>
      outcomes.where((o) => !o.ok).map((o) => o.shot).toList();
}

/// Where [fileName] lands on the share: `sharePath/fileName`, or
/// `sharePath/orderNumber/fileName` when [u] enables per-order folders.
/// [c.sharePath] is used verbatim — it may itself contain sub-folders.
String uploadTargetPath({
  required ConnectionSettings c,
  required UploadPrefs u,
  required String orderNumber,
  required String fileName,
}) =>
    u.useOrderFolders
        ? '${c.sharePath}/$orderNumber/$fileName'
        : '${c.sharePath}/$fileName';

/// Await [f] with a hard [timeout] WITHOUT leaking the error [f] throws
/// after the timeout abandoned it — dart's own `Future.timeout` drops such
/// late errors into the zone as unhandled exceptions (the device log's
/// `Bad state: StreamSink is closed` spam from smb_connect's abandoned
/// writes and closes). Pre-timeout errors propagate normally.
Future<T> _bounded<T>(Future<T> f, Duration timeout, {String? onTimeout}) {
  final completer = Completer<T>();
  Timer? timer;
  var done = false;
  f.then((value) {
    if (done) return; // abandoned — swallow the late result/error silently
    done = true;
    timer?.cancel();
    completer.complete(value);
  }, onError: (Object error, StackTrace stackTrace) {
    if (done) return;
    done = true;
    timer?.cancel();
    completer.completeError(error, stackTrace);
  });
  timer = Timer(timeout, () {
    done = true;
    completer.completeError(
      TimeoutException(onTimeout ?? 'Timed out after ${timeout.inMilliseconds}ms'),
    );
  });
  return completer.future;
}

/// The production connection over a real [SmbConnect].
class _SmbUploadConnection implements UploadConnection {
  _SmbUploadConnection(this._conn);

  final SmbConnect _conn;

  @override
  Future<void> write(String remotePath, Uint8List bytes) async {
    dynamic remoteFile;
    try {
      remoteFile = await _conn.createFile(remotePath);
    } catch (_) {
      // smb1 dialects open with O_CREAT|O_EXCL → FILE_CREATE, which FAILS
      // when the name already exists — a partial file left by a previous
      // timed-out attempt is exactly that. Probe + delete + re-create so
      // Retry overwrites; smb2's FILE_OPEN_IF (the normal dialect against
      // Windows shares) succeeds on the first call and never lands here.
      // If recovery itself fails, that error propagates — the shot fails
      // into the retry path either way.
      final existing = await _conn.file(remotePath);
      if (existing.isExists) {
        try {
          await _conn.delete(existing);
        } catch (_) {
          // Best-effort — the re-create below surfaces the real error.
        }
      }
      remoteFile = await _conn.createFile(remotePath);
    }
    final sink = await _conn.openWrite(remoteFile);
    sink.add(bytes);
    await sink.flush();
    await sink.close();
  }

  @override
  Future<void> ensureFolder(String path) async {
    try {
      await _conn.createFolder(path);
    } catch (_) {
      // Errors when the folder already exists — expected, ignore.
    }
  }

  @override
  Future<bool> exists(String remotePath) async {
    try {
      return (await _conn.file(remotePath)).isExists;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> delete(String remotePath) async {
    final file = await _conn.file(remotePath);
    await _conn.delete(file);
  }

  @override
  Future<void> close() => _bounded(_conn.close(), _connCloseTimeout);
}

/// Uploads every staged shot of [session] in order, writing each to its
/// [uploadTargetPath] target.
///
/// Retry policy (the operator's contract):
/// 1. A shot whose write fails is retried ONCE, IN PLACE, before the batch
///    moves past it — on a fresh connection when the failure was a write
///    timeout (the old one is dead), on the same connection otherwise (the
///    server answered, it may just have been busy or the file briefly
///    locked).
/// 2. After the pass over all shots, every still-failed shot gets one more
///    attempt (the end-of-pass rescue).
/// 3. If that final attempt still fails, the broken partial file it may
///    have left on the share is probed and deleted — the share never keeps
///    a half-written image. When the server refuses the delete (a dead
///    session's open handle keeps it locked until the server reaps it,
///    typically a minute or two) the error says so instead.
///
/// Bounds: a write that outlives [writeTimeout] marks the connection dead
/// (close → pause → redial); TWO write timeouts with no success between
/// them abort the pass — every unattempted shot is skip-marked with
/// [connectionLostSkipMessage] instead of grinding out its own timeout, and
/// a redial that cannot come up aborts the same way. Whatever happens, all
/// failed/skipped shots stay staged locally and the manual Retry path
/// (re-invoking this function) re-uploads exactly those.
///
/// [only] narrows the pass to a subset of the staged shots (the review
/// page uploads the READY ones and leaves PENDING/FAILED entries staged) —
/// null means all of [CaptureSession.shots]. [onProgress] fires with the
/// running count: `done` counts successes plus FINALIZED failures (never
/// moves backwards; the last fire reaches `(total, total)`).
///
/// The initial dial failing throws (first-run misconfiguration must
/// surface); a later redial failing aborts quietly. [dial] replaces the
/// production SMB dial entirely (tests).
Future<UploadSummary> uploadSession(
  CaptureSession session,
  AppSettings settings, {
  List<Shot>? only,
  UploadConnectionFactory? dial,
  void Function(int done, int total)? onProgress,
  Duration? writeTimeout,
  Duration? redialDelay,
  Duration? dialTimeout,
}) async {
  final timeout = writeTimeout ?? smbWriteTimeout;
  final pause = redialDelay ?? smbRedialDelay;
  final dialBound = dialTimeout ?? smbDialTimeout;
  final c = settings.connection;
  final u = settings.upload;
  final dialUp = dial ??
      () async =>
          _SmbUploadConnection(await connect(c));

  // [only] is a caller-filtered subset of the staged list (the page passes
  // the READY entries verbatim); null → everything staged. Captured once —
  // the session's list mutates as successes delete their local entries.
  final shots = only ?? session.shots;
  final total = shots.length;

  // Final state per shot, in [shots] order.
  final results = List<UploadOutcome?>.filled(total, null);
  final counted = List<bool>.filled(total, false);
  var settled = 0; // successes + finalized failures — never decreases
  void fire() => onProgress?.call(settled, total);

  String targetOf(Shot shot) => uploadTargetPath(
        c: c,
        u: u,
        orderNumber: session.orderNumber,
        fileName: shot.fileName,
      );

  UploadConnection? conn;
  var connDead = false; // last we saw, the connection was unusable
  var hadConn = false; // any dial ever succeeded (first-dial vs redial)
  var deadStreak = 0; // write timeouts since the last success
  var aborted = false; // the pass gave up on a dead network

  /// Leaves [conn] live-and-believed-healthy, or returns false when the
  /// network cannot be dialed at all (the abort path). Throws on the FIRST
  /// dial failure — misconfiguration must surface, not silently abort.
  Future<bool> ensureLive() async {
    if (conn != null && !connDead) return true;
    if (conn != null) {
      try {
        await conn!.close();
      } catch (_) {
        /* best-effort — a dead connection may not even close */
      }
      conn = null;
    }
    if (hadConn) await Future<void>.delayed(pause);
    UploadConnection fresh;
    try {
      fresh = await _bounded(
        dialUp(),
        dialBound,
        onTimeout: 'Could not reach the server (dial timed out)',
      );
    } catch (e) {
      if (!hadConn) rethrow;
      return false;
    }
    conn = fresh;
    hadConn = true;
    connDead = false;
    // Folders are ensured per dial: every fresh connection re-creates
    // (best-effort) the share sub-folders it will write into.
    try {
      await conn!.ensureFolder(c.sharePath);
    } catch (_) {/* the share must pre-exist */}
    if (u.useOrderFolders) {
      try {
        await conn!
            .ensureFolder('${c.sharePath}/${session.orderNumber}');
      } catch (_) {/* best-effort, same as above */}
    }
    return true;
  }

  // Marks every not-yet-settled shot from [from] with the skip message.
  void skipMarkFrom(int from) {
    for (var j = from; j < total; j++) {
      if (results[j] == null) {
        results[j] = UploadOutcome(shots[j], false, connectionLostSkipMessage);
      }
    }
  }

  // The main pass — each shot gets up to two attempts (initial + in-place
  // retry) before the batch moves on.
  for (var i = 0; i < total && !aborted; i++) {
    if (results[i] != null && results[i]!.ok) continue;
    final shot = shots[i];
    var attempts = 0;
    while (attempts < 2 && !aborted) {
      attempts++;
      if (!await ensureLive()) {
        // Network down mid-pass: this shot and everything after it are
        // skip-marked without further timeout grinds.
        skipMarkFrom(i);
        aborted = true;
        break;
      }
      try {
        final bytes = await File(shot.localPath).readAsBytes();
        await _bounded(
          conn!.write(targetOf(shot), bytes),
          timeout,
          onTimeout: _writeTimeoutMessage(timeout),
        );
        await session.deleteLocal(shot);
        results[i] = UploadOutcome(shot, true, null);
        deadStreak = 0;
        counted[i] = true;
        settled++;
        fire();
        break;
      } on TimeoutException {
        // Dead connection. The shot keeps its timeout message and stays
        // staged; the retry (this loop) runs on a fresh dial. Two timeouts
        // with no success between them = a network that stays dead → stop.
        connDead = true;
        results[i] =
            UploadOutcome(shot, false, _writeTimeoutMessage(timeout));
        deadStreak++;
        if (deadStreak >= 2) {
          skipMarkFrom(i + 1);
          aborted = true;
        }
      } catch (e) {
        // Per-shot failure on a live connection (access denied, locked
        // file, unreadable local file…) — the in-place retry or the
        // end-of-pass rescue takes it.
        results[i] = UploadOutcome(shot, false, e.toString());
      }
    }
  }

  // End-of-pass rescue: one more attempt per still-failed shot, then the
  // no-broken-files cleanup. Skipped entirely when the pass aborted (there
  // is no live connection to rescue with).
  if (!aborted) {
    for (var i = 0; i < total; i++) {
      final r = results[i];
      if (r == null || r.ok) continue;
      final shot = r.shot;
      if (!await ensureLive()) break; // network dropped mid-rescue — stop
      try {
        final bytes = await File(shot.localPath).readAsBytes();
        await _bounded(
          conn!.write(targetOf(shot), bytes),
          timeout,
          onTimeout: _writeTimeoutMessage(timeout),
        );
        await session.deleteLocal(shot);
        results[i] = UploadOutcome(shot, true, null);
        deadStreak = 0;
        counted[i] = true;
        settled++;
        fire();
      } catch (e) {
        // Final failure — never leave a broken partial on the share.
        var note = '';
        var hadPartial = false;
        try {
          hadPartial = await conn!.exists(targetOf(shot));
        } catch (_) {/* probe failed — try the delete anyway */}
        if (hadPartial) {
          try {
            await conn!.delete(targetOf(shot));
            note = _partialRemovedNote;
          } catch (_) {
            note = _partialHeldNote;
          }
        }
        results[i] = UploadOutcome(shot, false, '${e.toString()}$note');
      }
    }
  }

  // No further attempt can run: every outstanding failure is now final,
  // so count it in and let the last fire reach (total, total).
  for (var i = 0; i < total; i++) {
    if (counted[i] || results[i] == null) continue;
    counted[i] = true;
    settled++;
    fire();
  }

  if (conn != null) {
    try {
      await conn!.close();
    } catch (_) {
      /* best-effort — never let cleanup break the summary */
    }
  }

  await session.cleanupIfEmpty();
  return UploadSummary([
    for (var i = 0; i < total; i++)
      results[i] ??
          // Unreachable — the pass resolves or skip-marks every shot — but
          // a summary must never carry a hole.
          UploadOutcome(shots[i], false, connectionLostSkipMessage),
  ]);
}
