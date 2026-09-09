import 'dart:io';
import 'dart:typed_data';

import '../settings/app_settings.dart';
import '../smb/smb.dart';
import 'session.dart';

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
Future<UploadSummary> uploadSession(
  CaptureSession session,
  AppSettings settings, {
  List<Shot>? only,
  ShotWriter? writeShot,
  FolderEnsurer? ensureFolder,
  void Function(int done, int total)? onProgress,
}) async {
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
    );
  }

  final conn = await connect(settings.connection);
  try {
    Future<void> defaultWriter(String remotePath, Uint8List bytes) async {
      final remoteFile = await conn.createFile(remotePath);
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
    );
  } finally {
    await conn.close();
  }
}

/// The per-shot loop shared by the default and injected paths. [ensurer] is
/// always resolvable here and its errors are swallowed — folder creation is
/// never worth failing a shot over.
Future<UploadSummary> _runAll(
  CaptureSession session,
  AppSettings settings, {
  required List<Shot>? only,
  required ShotWriter writer,
  required FolderEnsurer? ensurer,
  void Function(int done, int total)? onProgress,
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
      await writer(target, bytes);
      await session.deleteLocal(shot);
      outcome = UploadOutcome(shot, true, null);
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
