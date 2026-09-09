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

/// Bound on the best-effort connection close in `uploadSession`'s `finally`.
/// After a stalled write the transport's send mutex can stay held, and
/// `conn.close()` (session logoff → sendrecv) would then wait on it forever —
/// the very hang this file exists to prevent.
const Duration _connCloseTimeout = Duration(seconds: 5);

/// User-readable text for a shot that outlived [smbWriteTimeout]. Sub-second
/// durations (tests) render as ms.
String _writeTimeoutMessage(Duration d) => d.inSeconds >= 1
    ? 'Write timed out after ${d.inSeconds}s'
    : 'Write timed out after ${d.inMilliseconds}ms';

/// Writes one shot's bytes to [remotePath]. The production writer opens the
/// file on the shared SMB connection; tests inject a recording fake instead.
typedef ShotWriter = Future<void> Function(String remotePath, Uint8List bytes);

/// Best-effort creation of [path] (errors when it already exists — callers
/// swallow). The share itself must pre-exist.
typedef FolderEnsurer = Future<void> Function(String path);

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

/// Uploads every staged shot of [session] in order, writing each to its
/// [uploadTargetPath] target. One SMB connection serves the whole session
/// (closed in `finally`) — unless [writeShot] is injected, which replaces
/// the connection AND the writer entirely (tests; then no connection opens
/// at all). [ensureFolder] may be injected alone; the connection still
/// opens for the writes and the injected ensurer is used for both folders.
///
/// [only] narrows the pass to a subset of the staged shots (the review
/// page uploads the READY ones and leaves PENDING/FAILED entries staged) —
/// null means all of [CaptureSession.shots]. Outcomes, progress totals and
/// cleanup consider only the shots actually attempted.
///
/// Folder ensures: the share path always (best-effort — it must already
/// exist, and "already exists" errors are expected), plus
/// `sharePath/orderNumber` when order folders are on. A write failure keeps
/// that shot staged for retry and does not abort the rest; a local-read
/// failure is likewise a failed outcome, not a crash. [onProgress] fires
/// after each processed shot with the running count. A session whose shots
/// all uploaded has its temp dir reclaimed via
/// [CaptureSession.cleanupIfEmpty] (a session still holding staged entries
/// — e.g. a flagged failed conversion — keeps its dir).
///
/// Each shot's write is bounded by [writeTimeout] (default
/// [smbWriteTimeout]): a stalled write fails that shot with a
/// "Write timed out" error instead of hanging the batch, and later shots
/// still get their outcomes. [writeTimeout] is injectable for tests.
Future<UploadSummary> uploadSession(
  CaptureSession session,
  AppSettings settings, {
  List<Shot>? only,
  ShotWriter? writeShot,
  FolderEnsurer? ensureFolder,
  void Function(int done, int total)? onProgress,
  Duration? writeTimeout,
}) async {
  final timeout = writeTimeout ?? smbWriteTimeout;
  // Injections replace the connection AND the writer — never open a
  // connection that nothing will use.
  if (writeShot != null) {
    return _runAll(
      session,
      settings,
      only: only,
      writer: writeShot,
      ensurer: ensureFolder,
      onProgress: onProgress,
      writeTimeout: timeout,
    );
  }

  final conn = await connect(settings.connection);
  try {
    Future<void> defaultWriter(String remotePath, Uint8List bytes) async {
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

    Future<void> defaultEnsure(String path) async {
      try {
        // Errors when the folder already exists — expected, ignore.
        await conn.createFolder(path);
      } catch (_) {
        // Best-effort: the share must pre-exist; deeper nesting failing
        // surfaces as the shot's own upload error.
      }
    }

    return await _runAll(
      session,
      settings,
      only: only,
      writer: defaultWriter,
      ensurer: ensureFolder ?? defaultEnsure,
      onProgress: onProgress,
      writeTimeout: timeout,
    );
  } finally {
    // Best-effort: after a timed-out write the transport's send mutex may
    // never be released, so the logoff in close() can block forever — the
    // UI must not wait on it. (SmbConnect.close → tree.close → session
    // logoff → sendrecv, all behind sendrecvMutex.)
    await conn.close().timeout(_connCloseTimeout).catchError((_) {});
  }
}

/// The per-shot loop shared by the default and injected paths. [ensurer] is
/// always resolvable here and its errors are swallowed — folder creation is
/// never worth failing a shot over. Each shot's write phase is bounded by
/// [writeTimeout]; a timeout fails only that shot (kept staged for retry)
/// and the remaining shots still get their outcomes.
Future<UploadSummary> _runAll(
  CaptureSession session,
  AppSettings settings, {
  required List<Shot>? only,
  required ShotWriter writer,
  required FolderEnsurer? ensurer,
  void Function(int done, int total)? onProgress,
  required Duration writeTimeout,
}) async {
  final c = settings.connection;
  final u = settings.upload;

  Future<void> safeEnsure(String path) async {
    try {
      await ensurer?.call(path);
    } catch (_) {
      /* best-effort — see [uploadSession] */
    }
  }

  // The share itself must already exist; sub-folders are created here.
  await safeEnsure(c.sharePath);
  if (u.useOrderFolders) {
    await safeEnsure('${c.sharePath}/${session.orderNumber}');
  }

  final outcomes = <UploadOutcome>[];
  // [only] is a caller-filtered subset of the staged list (the page passes
  // the READY entries verbatim); null → everything staged.
  final shots = only ?? session.shots;
  for (final shot in shots) {
    UploadOutcome outcome;
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
      // Stalled write — same handling as any other failure (kept staged,
      // batch continues) but with the user-readable timeout message rather
      // than a bare "TimeoutException: ...".
      outcome = UploadOutcome(shot, false, e.message ?? e.toString());
    } catch (e) {
      // Kept staged — a later retry pass can re-upload it.
      outcome = UploadOutcome(shot, false, e.toString());
    }
    outcomes.add(outcome);
    onProgress?.call(outcomes.length, shots.length);
  }

  await session.cleanupIfEmpty();
  return UploadSummary(outcomes);
}
