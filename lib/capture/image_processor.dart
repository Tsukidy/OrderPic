import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../settings/app_settings.dart';
import 'naming.dart';
import 'session.dart';

/// The long-edge cap handed to any codec, sanitized. A stored cap of 0 or a
/// negative number is degenerate, never "shrink to 0 px" — treat it as no
/// cap so neither image_picker nor a compress plugin can receive one.
int? sanitizeMaxEdge(int? edge) => (edge == null || edge <= 0) ? null : edge;

/// The finalized upload name for a shot about to be materialized: the
/// capture-time stamp plus the session's next shot index (D5). Shared by
/// every implementation so the 4-part contract has one source.
String _finalName(CaptureSession session, UploadPrefs prefs) =>
    buildUploadFileName(
      orderNumber: session.orderNumber,
      admittedAt: DateTime.now(),
      shotIndex: session.nextIndex,
      format: prefs.format,
    );

/// Turns a picked file into a staged [Shot]: bytes land inside
/// [CaptureSession.dir] under the finalized upload name. Injectable so
/// tests can substitute [CopyOnlyProcessor] instead of the native codec
/// (mirrors the `SettingsStore` seam).
abstract class ImageProcessor {
  /// Materializes [pickedPath] into [session] storage and returns the
  /// resulting [Shot] — localPath inside [CaptureSession.dir], fileName
  /// from the 4-part rule stamped with `session.nextIndex`.
  ///
  /// Does NOT call [CaptureSession.add]: admission is the caller's job
  /// (`try { session.add(await process(...)) }`), so a throw here leaves
  /// the session — shots and nextIndex — exactly as it was.
  Future<Shot> process({
    required String pickedPath,
    required UploadPrefs prefs,
    required CaptureSession session,
  });
}

/// The production processor. JPEG needs no codec here — quality/edge caps
/// were already applied at pick time (or [JpegQuality.original] means the
/// camera's bytes are correct as-is) — so it is a straight byte copy. PNG
/// decodes the picked JPEG and re-encodes it losslessly (EXIF orientation
/// baked in; PNG carries no EXIF).
class NativeImageProcessor implements ImageProcessor {
  const NativeImageProcessor();

  /// flutter_image_compress treats minWidth/minHeight as an upper bound on
  /// the output and clamps its scale at 1 (never upscales), so a pair far
  /// larger than any sensor output means "convert at native size". Left at
  /// the plugin's defaults (1920x1080) a full-res photo would be silently
  /// shrunk — PNG is contractually lossless AND full-size (design D4).
  static const int _fullSizeEdge = 100000;

  @override
  Future<Shot> process({
    required String pickedPath,
    required UploadPrefs prefs,
    required CaptureSession session,
  }) async {
    final fileName = _finalName(session, prefs);
    final target = File('${session.dir.path}/$fileName');

    if (prefs.format == ImageFormat.png) {
      final bytes = await FlutterImageCompress.compressWithFile(
        pickedPath,
        minWidth: _fullSizeEdge,
        minHeight: _fullSizeEdge,
        format: CompressFormat.png,
      );
      if (bytes == null || bytes.isEmpty) {
        throw Exception('PNG conversion produced no data for $pickedPath');
      }
      await target.writeAsBytes(bytes, flush: true);
      return Shot(localPath: target.path, fileName: fileName);
    }

    // JPEG: the bytes are already correct — same copy as the test seam.
    return const CopyOnlyProcessor().process(
      pickedPath: pickedPath,
      prefs: prefs,
      session: session,
    );
  }
}

/// Pure `File.copy` with the same naming rule — no platform channels, so
/// unit tests can run the real seam on the host. NOT the production
/// processor: it skips PNG conversion entirely.
class CopyOnlyProcessor implements ImageProcessor {
  const CopyOnlyProcessor();

  @override
  Future<Shot> process({
    required String pickedPath,
    required UploadPrefs prefs,
    required CaptureSession session,
  }) async {
    final fileName = _finalName(session, prefs);
    final target = File('${session.dir.path}/$fileName');
    await File(pickedPath).copy(target.path);
    return Shot(localPath: target.path, fileName: fileName);
  }
}
