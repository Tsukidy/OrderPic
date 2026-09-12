import 'dart:async';
import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../settings/app_settings.dart';
import 'naming.dart';
import 'session.dart';

/// The long-edge cap handed to any codec, sanitized. A stored cap of 0 or a
/// negative number is degenerate, never "shrink to 0 px" — treat it as no
/// cap so neither image_picker nor a compress plugin can receive one.
int? sanitizeMaxEdge(int? edge) => (edge == null || edge <= 0) ? null : edge;

/// The upload name for a shot being admitted NOW: the capture-time stamp
/// plus the session's next shot index. Called at PICK time — admission
/// reserves the name before any conversion runs, so two quick picks get
/// 001/002 deterministically even when their conversions finish much
/// later (the 4-part contract has this one source).
String reserveShotName(CaptureSession session, UploadPrefs prefs) =>
    buildUploadFileName(
      orderNumber: session.orderNumber,
      admittedAt: DateTime.now(),
      shotIndex: session.nextIndex,
      format: prefs.format,
    );

/// Turns a picked file into processed bytes on disk. Injectable so tests
/// can substitute [CopyOnlyProcessor] instead of the native codec (mirrors
/// the `SettingsStore` seam).
abstract class ImageProcessor {
  /// Writes [pickedPath]'s PROCESSED bytes to [destPath] — a session-dir
  /// path whose name was already reserved via [reserveShotName]. The
  /// reserved name's extension is the contract: `.png` must produce the
  /// lossless full-size conversion, `.jpg` the JPEG bytes — byte-copied
  /// when the source already starts with the JPEG magic, re-encoded
  /// (full size, quality 100) otherwise ([NativeImageProcessor]'s guard:
  /// gallery picks can arrive non-JPEG under a `.jpg` name). Pick-time
  /// quality/edge caps were applied by image_picker.
  ///
  /// Throws on failure and never touches the session — admission state
  /// ([ShotStatus.pending] → ready/failed) is [admitPicked]'s job.
  Future<void> process({required String pickedPath, required String destPath});
}

/// Does [head] open with the JPEG magic `FF D8`? A `.jpg` reserved name is
/// a contract the file's bytes must honour — History's viewer and every
/// SMB consumer assume the extension tells the truth. Camera picks always
/// do, but a gallery pick can arrive as HEIC or another container under
/// that name (pick-time compression is format-gated), so admission sniffs
/// the leading bytes instead of trusting the extension. A head too short
/// to carry the magic (including empty) is not a JPEG.
bool isJpegBytes(List<int> head) =>
    head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8;

/// The production processor. A `.png` dest decodes the picked file and
/// re-encodes it losslessly (EXIF orientation baked in; PNG carries no
/// EXIF). A `.jpg` dest is a straight byte copy when the bytes really are
/// JPEG — quality/edge caps were already applied at pick time (or
/// [JpegQuality.original] means the camera's bytes are correct as-is) —
/// and a codec re-encode when they are not ([isJpegBytes] says which).
class NativeImageProcessor implements ImageProcessor {
  const NativeImageProcessor();

  /// flutter_image_compress treats minWidth/minHeight as an upper bound on
  /// the output and clamps its scale at 1 (never upscales), so a pair far
  /// larger than any sensor output means "convert at native size". Left at
  /// the plugin's defaults (1920x1080) a full-res photo would be silently
  /// shrunk — PNG is contractually lossless AND full-size (design D4).
  static const int _fullSizeEdge = 100000;

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async {
    if (destPath.endsWith('.png')) {
      final bytes = await FlutterImageCompress.compressWithFile(
        pickedPath,
        minWidth: _fullSizeEdge,
        minHeight: _fullSizeEdge,
        format: CompressFormat.png,
      );
      if (bytes == null || bytes.isEmpty) {
        throw Exception('PNG conversion produced no data for $pickedPath');
      }
      await File(destPath).writeAsBytes(bytes, flush: true);
      return;
    }

    // `.jpg` dest: sniff before trusting the extension. Reading the first
    // 3 bytes is enough for the FF D8 magic and costs nothing next to a
    // decode.
    final head = await File(pickedPath)
        .openRead(0, 3)
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    if (isJpegBytes(head)) {
      // Genuine JPEG: the bytes are already correct — same copy as the
      // test seam.
      await const CopyOnlyProcessor().process(
        pickedPath: pickedPath,
        destPath: destPath,
      );
      return;
    }

    // Non-JPEG bytes under a `.jpg` name (a gallery HEIC pick, say):
    // re-encode to real JPEG — full size, max quality — so the file
    // matches the extension's contract. The `minWidth`/`minHeight`
    // sentinel means native size, exactly as the PNG branch above.
    final bytes = await FlutterImageCompress.compressWithFile(
      pickedPath,
      minWidth: _fullSizeEdge,
      minHeight: _fullSizeEdge,
      format: CompressFormat.jpeg,
      quality: 100,
    );
    if (bytes == null || bytes.isEmpty) {
      throw Exception('JPEG re-encode produced no data for $pickedPath');
    }
    await File(destPath).writeAsBytes(bytes, flush: true);
  }
}

/// Pure `File.copy` to the reserved path — no platform channels, so unit
/// tests can run the real seam on the host. NOT the production processor:
/// it skips PNG conversion entirely.
class CopyOnlyProcessor implements ImageProcessor {
  const CopyOnlyProcessor();

  @override
  Future<void> process({
    required String pickedPath,
    required String destPath,
  }) async {
    await File(pickedPath).copy(destPath);
  }
}

/// One fire-and-forget admission: the [pending] entry now staged in the
/// session (its name and index were reserved synchronously), plus the
/// [settled] future that completes once the background conversion has
/// flipped that entry to ready or failed. Tests await [settled]; the UI
/// does not — it re-renders off the session's notifications.
class Admission {
  final Shot pending;
  final Future<void> settled;

  const Admission(this.pending, this.settled);
}

/// Admits a fresh pick WITHOUT blocking on conversion: reserves the
/// upload name and shot index at pick time, stages a PENDING entry, and
/// launches the processing in the background. The caller navigates on
/// immediately — the next photo can be taken while this one converts.
///
/// The background step settles the entry in place via
/// [CaptureSession.replace]: ready (processed file at [Shot.localPath])
/// or failed (no file; the entry stays staged flagged for retake, and
/// upload skips it). If the entry was removed mid-conversion (a retake
/// cancelled it) the just-written bytes are dropped — unless the name was
/// re-reserved by a replacement shot, in which case the file is left for
/// that shot's own conversion to own. A straggler finishing after the
/// replacement's own conversion would overwrite it with THIS pick's bytes
/// (clock-gated to practical unreachability: a same-second collision
/// needs a full camera round trip inside 1 s); the startup sweep catches
/// anything left behind.
Admission admitPicked({
  required String pickedPath,
  required UploadPrefs prefs,
  required CaptureSession session,
  required ImageProcessor processor,
}) {
  final fileName = reserveShotName(session, prefs);
  final pending = Shot(
    localPath: '${session.dir.path}/$fileName',
    fileName: fileName,
    status: ShotStatus.pending,
  );
  // The add IS the reservation: nextIndex advances now, before any slow
  // conversion, so a quick follow-up pick numbers deterministically.
  session.add(pending);
  return Admission(pending, _settleAdmission(pending, pickedPath, session, processor));
}

/// The background half of [admitPicked]: run the conversion, then settle
/// the PENDING entry — or clean up after it if the entry is gone.
Future<void> _settleAdmission(
  Shot pending,
  String pickedPath,
  CaptureSession session,
  ImageProcessor processor,
) async {
  try {
    await processor.process(pickedPath: pickedPath, destPath: pending.localPath);
    if (session.replace(pending, pending.copyWith(status: ShotStatus.ready))) {
      return;
    }
    // Entry removed while converting (retake cancelled it). Drop the bytes
    // we just wrote — unless a replacement shot re-reserved the name, in
    // which case the path is that replacement's now. A straggler over-
    // writing it is clock-gated to practical unreachability (a same-second
    // name collision needs a full camera round trip inside one second) —
    // but the bytes would be THIS pick's, not the replacement's, so the
    // replacement entry could end up describing another photo's file. The
    // entry-removal check above runs at settle time, and anything left
    // behind (locked file, mid-write kill) is swept at the next startup.
    if (!session.claimsFile(pending.fileName)) {
      try {
        final f = File(pending.localPath);
        if (await f.exists()) await f.delete();
      } catch (_) {
        /* best effort — the startup sweep catches stragglers */
      }
    }
  } catch (_) {
    // Conversion failed: flag the entry, keep it staged for retake. The
    // batch (and every other conversion) is untouched. A codec that threw
    // AFTER a partial write leaves a partial file behind — drop it so the
    // retake starts from a clean dir. The failing entry is still staged
    // (and claims its own name) until the replace below, so the claim
    // check must ignore it: cleanup happens only when no OTHER entry
    // re-reserved the name.
    if (!session.claimsFileExcluding(pending)) {
      try {
        final f = File(pending.localPath);
        if (await f.exists()) await f.delete();
      } catch (_) {
        /* best effort — the startup sweep catches stragglers */
      }
    }
    session.replace(pending, pending.copyWith(status: ShotStatus.failed));
  }
}
