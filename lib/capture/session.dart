import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where a staged [Shot] is in its (background) processing lifecycle:
///
/// - [pending] — the pick is admitted but its conversion is still in
///   flight; `localPath` points where the bytes WILL land.
/// - [ready] — the processed file exists at [Shot.localPath]; the only
///   status [uploadSession] will upload.
/// - [failed] — the conversion errored; no file exists. The entry stays
///   staged so review can flag it and offer a retake.
enum ShotStatus { pending, ready, failed }

/// One captured photo staged inside a [CaptureSession]: where the bytes
/// live locally ([localPath]) and the upload name they will carry
/// ([fileName], from `buildUploadFileName`), plus the processing
/// [status] (background conversion: admitted pending, then ready/failed).
/// The file's lifetime is the caller's once the shot leaves the session
/// via [CaptureSession.removeLast].
class Shot {
  const Shot({
    required this.localPath,
    required this.fileName,
    this.status = ShotStatus.ready,
  });

  final String localPath;
  final String fileName;
  final ShotStatus status;

  /// The same slot with [status] changed — used by the background
  /// admission driver to settle a PENDING entry to ready/failed.
  Shot copyWith({ShotStatus? status}) =>
      Shot(localPath: localPath, fileName: fileName, status: status ?? this.status);

  @override
  bool operator ==(Object other) =>
      other is Shot &&
      other.localPath == localPath &&
      other.fileName == fileName &&
      other.status == status;

  @override
  int get hashCode => Object.hash(localPath, fileName, status);

  @override
  String toString() => 'Shot($fileName @ $localPath, $status)';
}

/// Session-owned storage for one order's captures. Batch mode writes every
/// shot into a private temp dir (so the camera app's copy and our staged
/// copy never collide); the dir is removed as soon as it empties, and a
/// startup sweep reclaims dirs left behind by a crash or force-kill.
///
/// A [ChangeNotifier] so review UIs re-render as the staged list changes —
/// including the pending → ready/failed transitions a background
/// conversion drives via [replace].
class CaptureSession extends ChangeNotifier {
  /// Dirs under the system temp matching this prefix are ours to sweep.
  static const String dirPrefix = 'mmcpic-session-';

  final String orderNumber;
  final Directory dir;
  final List<Shot> _shots = [];

  CaptureSession._(this.orderNumber, this.dir);

  /// Creates `<systemTemp>/mmcpic-session-<orderNumber>-<epochMillis>`.
  /// The epoch suffix keeps concurrent sessions for the same order apart.
  static Future<CaptureSession> create(String orderNumber) async {
    final dir = Directory(
      '${Directory.systemTemp.path}/'
      '$dirPrefix$orderNumber-${DateTime.now().millisecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    return CaptureSession._(orderNumber, dir);
  }

  /// Shots currently staged, oldest first — PENDING and FAILED entries
  /// included (a pending shot has reserved its index; a failed one stays
  /// flagged for retake). Unmodifiable — mutate via [add] / [removeLast] /
  /// [deleteLocal] / [replace] so [nextIndex] stays truthful.
  List<Shot> get shots => List.unmodifiable(_shots);

  /// The shot index to stamp into the next file name (1-based). Counts
  /// every staged entry — including PENDING ones, so a quick follow-up
  /// pick reserves the next index before the previous conversion ends.
  ///
  /// Removing a MIDDLE entry (only possible for a conversion-failed one,
  /// via the review page) means the next admission reuses its NNN: a
  /// numbering gap plus the same index appearing twice across seconds.
  /// Known and harmless — the per-shot timestamp in the name keeps every
  /// filename unique.
  int get nextIndex => _shots.length + 1;

  /// Staged shots whose conversion is still in flight.
  List<Shot> get pendingShots => [
    for (final s in _shots)
      if (s.status == ShotStatus.pending) s,
  ];

  /// Admits [shot] and notifies listeners. Adding the entry IS reserving
  /// its slot: [nextIndex] advances the moment a pick is admitted, before
  /// any slow conversion runs.
  void add(Shot shot) {
    _shots.add(shot);
    notifyListeners();
  }

  /// Removes and returns the newest shot (null when empty). The caller owns
  /// deleting the backing file — the shot may be re-`add`ed elsewhere.
  Shot? removeLast() {
    if (_shots.isEmpty) return null;
    final shot = _shots.removeLast();
    notifyListeners();
    return shot;
  }

  /// Best-effort local delete of [shot]'s file; also drops it from the
  /// staged list if still present. Never throws — a missing/unwritable
  /// file must not break the capture flow.
  Future<void> deleteLocal(Shot shot) async {
    _shots.remove(shot);
    notifyListeners();
    try {
      final f = File(shot.localPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      /* best effort — the startup sweep catches stragglers */
    }
  }

  /// Swaps the staged entry that IS [from] (identity — a pending entry and
  /// its settled form are different [Shot] values) for [to], and notifies.
  /// Returns false (and touches nothing) when that entry is gone — removed
  /// by a retake while its conversion was in flight; the caller then owns
  /// dropping the result.
  bool replace(Shot from, Shot to) {
    final i = _shots.indexWhere((s) => identical(s, from));
    if (i < 0) return false;
    _shots[i] = to;
    notifyListeners();
    return true;
  }

  /// True when some staged entry carries [fileName] — i.e. the slot is
  /// claimed. The background admission driver checks this before deleting
  /// a file whose entry was removed mid-conversion (a retake may already
  /// have re-reserved the same name for a replacement shot).
  bool claimsFile(String fileName) => _shots.any((s) => s.fileName == fileName);

  /// [claimsFile] ignoring [shot] itself — for the failure path, where the
  /// still-staged failing entry trivially claims its own name but a
  /// partial file under it must still be cleaned up.
  bool claimsFileExcluding(Shot shot) =>
      _shots.any((s) => s.fileName == shot.fileName && !identical(s, shot));

  /// Removes the session dir (recursively) iff no shots remain staged —
  /// PENDING entries count as staged, so a dir never vanishes under an
  /// in-flight conversion.
  Future<void> cleanupIfEmpty() async {
    if (_shots.isNotEmpty) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      /* best effort — the startup sweep catches stragglers */
    }
  }
}

/// Deletes every `mmcpic-session-*` directory under the system temp.
/// Called at startup: dirs only outlive their session via crash or
/// force-kill, so anything found is garbage. Best-effort throughout —
/// a locked or half-deletable dir waits for the next launch.
Future<void> sweepStaleSessions() async {
  try {
    await for (final e in Directory.systemTemp.list()) {
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!name.startsWith(CaptureSession.dirPrefix)) continue;
      try {
        await e.delete(recursive: true);
      } catch (_) {
        /* best effort per dir */
      }
    }
  } catch (_) {
    /* unreadable temp dir — nothing to sweep */
  }
}
