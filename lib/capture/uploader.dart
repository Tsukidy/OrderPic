import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// Bound on the best-effort connection close in `uploadSession`'s per-round
/// `finally`. After a stalled write the transport's send mutex can stay
/// held, and `conn.close()` (session logoff → sendrecv) would then wait on
/// it forever — the very hang this file exists to prevent.
const Duration _connCloseTimeout = Duration(seconds: 5);

/// Error text for a shot skipped because the connection died under a
/// previous shot: its write hit [smbWriteTimeout], so every remaining shot
/// is abandoned on that connection at once instead of each grinding out its
/// own 30s timeout. The wording is the operator's contract — a later
/// auto-retry round (or the Retry button) picks these shots back up.
const String connectionLostSkipMessage =
    'Connection lost — skipped (will retry)';

/// How many auto-retry rounds `uploadSession` may run after a
/// connection-death abort: the initial pass plus at most this many
/// redial-and-resume rounds. Deliberately tiny — a network that stays dead
/// must end in a failed summary with the Retry button, not in an endless
/// redial loop.
const int defaultMaxAutoRetries = 2;

/// Backoff before each auto-retry round — first entry before the first
/// retry, second before the second (the last entry repeats should
/// [defaultMaxAutoRetries] ever grow past the list). Short on purpose: the
/// common case is a share that blinks out for a few seconds mid-batch.
const List<Duration> defaultRetryDelays = [
  Duration(seconds: 3),
  Duration(seconds: 8),
];

/// User-readable text for a shot that outlived [smbWriteTimeout]. Sub-second
/// durations (tests) render as ms.
String _writeTimeoutMessage(Duration d) => d.inSeconds >= 1
    ? 'Write timed out after ${d.inSeconds}s'
    : 'Write timed out after ${d.inMilliseconds}ms';

/// Writes one shot's bytes to [remotePath]. The production writer opens the
/// file on that round's SMB connection; tests inject a recording fake
/// instead.
typedef ShotWriter = Future<void> Function(String remotePath, Uint8List bytes);

/// Best-effort creation of [path] (errors when it already exists — callers
/// swallow). The share itself must pre-exist.
typedef FolderEnsurer = Future<void> Function(String path);

/// One upload round's SMB surface: the writer and folder ensurer bound to
/// that round's (fresh) connection, plus its best-effort bounded close.
typedef _RoundConnection = ({
  ShotWriter writer,
  FolderEnsurer ensurer,
  Future<void> Function() close,
});

/// The result of uploading one [Shot]: [ok] with the writer's error text
/// ([error]) when it failed. Failed shots stay staged for a retry pass.
class UploadOutcome {
  final Shot shot;
  final bool ok;
  final String? error;

  const UploadOutcome(this.shot, this.ok, this.error);
}

/// The whole session's upload: one [UploadOutcome] per staged shot, in
/// [CaptureSession.shots] order. With auto-retry the summary spans ALL
/// rounds — each shot's FINAL state.
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

/// Uploads every staged shot of [session] in order, writing each to its
/// [uploadTargetPath] target.
///
/// Connections: the initial pass opens ONE SMB connection and runs the whole
/// pass on it. A shot write that stalls is failed by [writeTimeout] (default
/// [smbWriteTimeout]) — and a timeout means the connection is DEAD, so the
/// pass aborts at once: the remaining shots are skipped with
/// [connectionLostSkipMessage] (their local files stay staged) instead of
/// each grinding out its own 30s timeout on a socket that will never answer.
/// Non-timeout write errors (access denied, bytes-read failure) stay
/// per-shot: the pass continues on the same connection.
///
/// Auto-retry: after a connection-death abort — and ONLY then — if not-ok
/// shots remain, the uploader waits `retryDelays[retryIndex]`, redials a
/// FRESH connection (folder ensures run on it again) and re-runs every
/// remaining shot. Bounded to `maxAutoRetries` rounds (defaults:
/// [defaultMaxAutoRetries], [defaultRetryDelays]; tests inject millisecond
/// values) and gated on progress so a still-dead network cannot spin it: the
/// first retry always runs, and after that a round earns another only if it
/// uploaded something OR at least came up (dialed) — a round with zero
/// progress and a failed dial ends the loop. A failed redial consumes that
/// attempt. Whatever the outcome, the manual Retry path is unchanged:
/// failed/timed-out/skipped shots stay staged and re-upload on the next
/// [uploadSession] call.
///
/// [only] narrows the pass to a subset of the staged shots (the review
/// page uploads the READY ones and leaves PENDING/FAILED entries staged) —
/// null means all of [CaptureSession.shots]. Outcomes, progress totals and
/// cleanup consider only the shots actually attempted.
///
/// Folder ensures: the share path always (best-effort — it must already
/// exist, and "already exists" errors are expected), plus
/// `sharePath/orderNumber` when order folders are on — once per round, since
/// every round may hold a fresh connection. A write failure keeps that shot
/// staged for retry and (unless it was a timeout) does not abort the rest; a
/// local-read failure is likewise a failed outcome, not a crash.
/// [onProgress] fires with the running count and stays monotonic across
/// rounds: `done` counts successes plus FINALIZED failures over the whole
/// call (a shot re-attempted by a later round is counted once, when it
/// settles for good) and `total` is the number of shots attempted this call,
/// so the last fire reaches `(total, total)` even when nothing uploaded. A
/// session whose shots all uploaded has its temp dir reclaimed via
/// [CaptureSession.cleanupIfEmpty] (a session still holding staged entries
/// — e.g. a flagged failed conversion — keeps its dir).
///
/// The returned [UploadSummary] covers ALL shots across rounds — each
/// shot's final state, in session order.
///
/// Injections: [writeShot] replaces the connection AND the writer entirely
/// (tests; then no connection opens at all and a redial is a no-op — but a
/// timeout under injection still triggers the skip-remaining-and-retry
/// semantics, so the loop is exercisable without SMB). [ensureFolder] may be
/// injected alone; the connection still opens for the writes and the
/// injected ensurer is used for both folders.
Future<UploadSummary> uploadSession(
  CaptureSession session,
  AppSettings settings, {
  List<Shot>? only,
  ShotWriter? writeShot,
  FolderEnsurer? ensureFolder,
  void Function(int done, int total)? onProgress,
  Duration? writeTimeout,
  int maxAutoRetries = defaultMaxAutoRetries,
  List<Duration> retryDelays = defaultRetryDelays,
}) async {
  final timeout = writeTimeout ?? smbWriteTimeout;
  // Injections replace the connection AND the writer — never open a
  // connection that nothing will use.
  if (writeShot != null) {
    return _uploadWithAutoRetry(
      session,
      settings,
      only: only,
      writeTimeout: timeout,
      onProgress: onProgress,
      maxAutoRetries: maxAutoRetries,
      retryDelays: retryDelays,
      injectedWriter: writeShot,
      injectedEnsurer: ensureFolder,
    );
  }

  Future<_RoundConnection> dial() async {
    final conn = await connect(settings.connection);

    Future<void> writer(String remotePath, Uint8List bytes) async {
      dynamic remoteFile;
      try {
        remoteFile = await conn.createFile(remotePath);
      } catch (_) {
        // smb1 dialects open with O_CREAT|O_EXCL → FILE_CREATE, which FAILS
        // when the name already exists — a partial file left by a previous
        // timed-out attempt is exactly that. Probe + delete + re-create so
        // Retry overwrites; smb2's FILE_OPEN_IF (the normal dialect against
        // Windows shares) succeeds on the first call and never lands here.
        // If recovery itself fails, that error propagates — the shot fails
        // into the retry path either way.
        final existing = await conn.file(remotePath);
        if (existing.isExists) {
          try {
            await conn.delete(existing);
          } catch (_) {
            // Best-effort — the re-create below surfaces the real error.
          }
        }
        remoteFile = await conn.createFile(remotePath);
      }
      final sink = await conn.openWrite(remoteFile);
      sink.add(bytes);
      await sink.flush();
      await sink.close();
    }

    Future<void> ensurer(String path) async {
      try {
        // Errors when the folder already exists — expected, ignore.
        await conn.createFolder(path);
      } catch (_) {
        // Best-effort: the share must pre-exist; deeper nesting failing
        // surfaces as the shot's own upload error.
      }
    }

    return (
      writer: writer,
      ensurer: ensurer,
      close: () => conn.close().timeout(_connCloseTimeout).catchError((_) {}),
    );
  }

  return _uploadWithAutoRetry(
    session,
    settings,
    only: only,
    writeTimeout: timeout,
    onProgress: onProgress,
    maxAutoRetries: maxAutoRetries,
    retryDelays: retryDelays,
    injectedEnsurer: ensureFolder,
    dial: dial,
  );
}

/// The round loop shared by the default and injected paths — each iteration
/// is one pass over the not-yet-uploaded shots on one connection.
///
/// Progress bookkeeping: [UploadOutcome]s land in [results] as they resolve,
/// but only an `ok` resolution counts toward `settled` immediately (a
/// success is final — the local file is already gone). A failed resolution
/// stays uncounted until the loop is over, because a later auto-retry round
/// may re-attempt it; that keeps `done` monotonic across rounds. Once no
/// further round can run, every outstanding failure is finalized and the
/// last [onProgress] fire reaches `(total, total)`.
Future<UploadSummary> _uploadWithAutoRetry(
  CaptureSession session,
  AppSettings settings, {
  required List<Shot>? only,
  required Duration writeTimeout,
  void Function(int done, int total)? onProgress,
  required int maxAutoRetries,
  required List<Duration> retryDelays,
  ShotWriter? injectedWriter,
  FolderEnsurer? injectedEnsurer,
  Future<_RoundConnection> Function()? dial,
}) async {
  final c = settings.connection;
  final u = settings.upload;

  Future<void> safeEnsure(FolderEnsurer? ensure, String path) async {
    try {
      await ensure?.call(path);
    } catch (_) {
      /* best-effort — see [uploadSession] */
    }
  }

  // [only] is a caller-filtered subset of the staged list (the page passes
  // the READY entries verbatim); null → everything staged. Captured once —
  // the session's list mutates as successes delete their local entries.
  final shots = only ?? session.shots;
  final total = shots.length;

  // Final state per shot, in [shots] order; later rounds overwrite the
  // outcome of any shot they re-attempt.
  final results = List<UploadOutcome?>.filled(total, null);
  final counted = List<bool>.filled(total, false);
  var settled = 0; // successes + finalized failures — never decreases
  void fire() => onProgress?.call(settled, total);

  var retryCount = 0; // auto-retry rounds run so far (0 = the initial pass)
  while (true) {
    var roundProgress = false; // a shot uploaded this round
    var roundAbort = false; // the round ended via connection death
    ShotWriter? writer;
    FolderEnsurer? roundEnsurer;
    Future<void> Function()? close;
    // Injected writers hold no connection, so their round's "dial" is a
    // no-op that always comes up — dialOk starts true there. Production
    // starts false and flips only after THIS round's dial succeeds, so the
    // gate sees each round's real connectivity.
    var dialOk = injectedWriter != null;

    if (injectedWriter != null) {
      writer = injectedWriter;
      roundEnsurer = injectedEnsurer;
    } else {
      dialOk = false;
      try {
        final conn = await dial!();
        writer = conn.writer;
        roundEnsurer = injectedEnsurer ?? conn.ensurer;
        close = conn.close;
        dialOk = true;
      } catch (e) {
        // The initial dial failing is today's behavior: the whole call
        // throws (SmbNotConfiguredException et al). A failed REDIAL merely
        // consumes this attempt — nothing runs, the shots keep their prior
        // outcomes, and the gate below ends the loop instead of hammering a
        // network that cannot even be dialed.
        if (retryCount == 0) rethrow;
      }
    }

    if (writer != null) {
      try {
        // The share itself must already exist; sub-folders are created per
        // round (each round may hold a fresh connection).
        await safeEnsure(roundEnsurer, c.sharePath);
        if (u.useOrderFolders) {
          await safeEnsure(roundEnsurer, '${c.sharePath}/${session.orderNumber}');
        }

        for (var i = 0; i < total; i++) {
          final done = results[i];
          if (done != null && done.ok) continue; // uploaded stays uploaded
          final shot = shots[i];
          UploadOutcome outcome;
          var timedOut = false;
          try {
            final bytes = await File(shot.localPath).readAsBytes();
            final target = uploadTargetPath(
              c: c,
              u: u,
              orderNumber: session.orderNumber,
              fileName: shot.fileName,
            );
            await writer(target, bytes).timeout(
              writeTimeout,
              onTimeout: () => throw TimeoutException(
                _writeTimeoutMessage(writeTimeout),
              ),
            );
            await session.deleteLocal(shot);
            outcome = UploadOutcome(shot, true, null);
          } on TimeoutException catch (e) {
            // Stalled write ⇒ dead connection. The shot keeps its
            // user-readable timeout message and stays staged, but the batch
            // does NOT grind on — the remaining shots are skipped at once
            // (below) and the gate decides on a redial.
            timedOut = true;
            outcome = UploadOutcome(shot, false, e.message ?? e.toString());
          } catch (e) {
            // Per-shot failure (access denied, unreadable local file, …) —
            // the connection itself is fine, so the batch continues on it.
            // Kept staged for a later retry pass.
            outcome = UploadOutcome(shot, false, e.toString());
          }
          results[i] = outcome;
          if (outcome.ok) {
            roundProgress = true;
            counted[i] = true;
            settled++;
            fire();
          } else if (timedOut) {
            roundAbort = true;
            // Dead connection: skip every not-yet-uploaded shot AT ONCE —
            // attempting them would just burn one [writeTimeout] each on a
            // socket that will never answer. Their local files stay staged.
            for (var j = i + 1; j < total; j++) {
              final later = results[j];
              if (later != null && later.ok) continue;
              results[j] = UploadOutcome(
                shots[j],
                false,
                connectionLostSkipMessage,
              );
            }
            break;
          }
        }
      } finally {
        // Best-effort per round: after a timed-out write the transport's
        // send mutex may never be released, so the logoff inside close()
        // can block forever — the UI must not wait on it. (The close itself
        // is bounded by [_connCloseTimeout]; see [uploadSession].)
        try {
          await close?.call();
        } catch (_) {
          /* never let cleanup break the summary */
        }
      }
    }

    // Auto-retry gate. Only a connection-death abort opens the door
    // (non-timeout failures never trigger a redial); the first retry always
    // runs, then a round must have uploaded something OR at least dialed to
    // earn another — bounded by [maxAutoRetries] rounds in total.
    //
    // Seam note: the roundProgress/dialOk arms are PRODUCTION facts — the
    // injected writer path cannot observe them (its dial is a no-op that
    // always comes up, so dialOk is true there by definition). The gate's
    // real-path behavior (dead network stops the loop after a failed dial;
    // a round that dialed but uploaded nothing still earns one more) is
    // device-verified against the 6.1 finding, not seam-tested.
    var remaining = false;
    for (final r in results) {
      if (r == null || !r.ok) {
        remaining = true;
        break;
      }
    }
    final mayRetry = roundAbort &&
        remaining &&
        retryCount < maxAutoRetries &&
        (roundProgress || dialOk || retryCount == 0);
    if (!mayRetry) break;

    // Backoff before this retry (first entry = before the first retry); the
    // last entry repeats if the bound outgrows the list.
    final delayIndex =
        retryCount >= retryDelays.length ? retryDelays.length - 1 : retryCount;
    await Future<void>.delayed(
      retryDelays.isEmpty ? Duration.zero : retryDelays[delayIndex],
    );
    retryCount++;
  }

  // No further round can re-attempt anything: every outstanding failure is
  // now final, so count it in and let the last fire reach (total, total).
  for (var i = 0; i < total; i++) {
    if (counted[i] || results[i] == null) continue;
    counted[i] = true;
    settled++;
    fire();
  }

  await session.cleanupIfEmpty();
  return UploadSummary([
    for (var i = 0; i < total; i++)
      results[i] ??
          // Unreachable — round 0 resolves or skip-marks every shot — but a
          // summary must never carry a hole.
          UploadOutcome(shots[i], false, connectionLostSkipMessage),
  ]);
}
