import 'dart:io';

/// One captured photo staged inside a [CaptureSession]: where the bytes
/// live locally ([localPath]) and the upload name they will carry
/// ([fileName], from `buildUploadFileName`). The file's lifetime is the
/// caller's once the shot leaves the session via [CaptureSession.removeLast].
class Shot {
  final String localPath;
  final String fileName;

  const Shot({required this.localPath, required this.fileName});

  @override
  bool operator ==(Object other) =>
      other is Shot && other.localPath == localPath && other.fileName == fileName;

  @override
  int get hashCode => Object.hash(localPath, fileName);

  @override
  String toString() => 'Shot($fileName @ $localPath)';
}

/// Session-owned storage for one order's captures. Batch mode writes every
/// shot into a private temp dir (so the camera app's copy and our staged
/// copy never collide); the dir is removed as soon as it empties, and a
/// startup sweep reclaims dirs left behind by a crash or force-kill.
class CaptureSession {
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

  /// Shots currently staged, oldest first. Unmodifiable — mutate via
  /// [add] / [removeLast] / [deleteLocal] so [nextIndex] stays truthful.
  List<Shot> get shots => List.unmodifiable(_shots);

  /// The shot index to stamp into the next file name (1-based).
  int get nextIndex => _shots.length + 1;

  void add(Shot shot) => _shots.add(shot);

  /// Removes and returns the newest shot (null when empty). The caller owns
  /// deleting the backing file — the shot may be re-`add`ed elsewhere.
  Shot? removeLast() => _shots.isEmpty ? null : _shots.removeLast();

  /// Best-effort local delete of [shot]'s file; also drops it from the
  /// staged list if still present. Never throws — a missing/unwritable
  /// file must not break the capture flow.
  Future<void> deleteLocal(Shot shot) async {
    _shots.remove(shot);
    try {
      final f = File(shot.localPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      /* best effort — the startup sweep catches stragglers */
    }
  }

  /// Removes the session dir (recursively) iff no shots remain staged.
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
