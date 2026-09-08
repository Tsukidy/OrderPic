import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/settings/app_settings.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  test('fresh load returns behavior-preserving defaults', () async {
    final p = await UploadPrefs.load(store: InMemorySettingsStore());
    expect(p.useOrderFolders, isFalse);
    expect(p.batchMode, isFalse);
    expect(p.format, ImageFormat.jpeg);
    expect(p.jpegQuality, JpegQuality.original);
  });

  test('round-trips every field including custom quality', () async {
    final store = InMemorySettingsStore();
    final p = UploadPrefs(
      useOrderFolders: true,
      batchMode: true,
      format: ImageFormat.png,
      jpegQuality: JpegQuality.custom,
      customQuality: 65,
      customMaxEdgePx: 2048,
    );
    await p.save(store: store);
    expect(await UploadPrefs.load(store: store), p);
  });

  test('corrupt store falls back to defaults', () async {
    final store = InMemorySettingsStore()..failReads = true;
    expect(await UploadPrefs.load(store: store), UploadPrefs.defaults);
  });

  group('jpegPickParams', () {
    test('original means no re-encode (null params)', () {
      expect(jpegPickParams(UploadPrefs.defaults), isNull);
    });

    // The exact preset table the Settings UI promises.
    test('preset table maps exactly', () {
      expect(
        jpegPickParams(const UploadPrefs(jpegQuality: JpegQuality.high)),
        (quality: 90, maxEdge: null),
      );
      expect(
        jpegPickParams(const UploadPrefs(jpegQuality: JpegQuality.balanced)),
        (quality: 80, maxEdge: 2560),
      );
      expect(
        jpegPickParams(const UploadPrefs(jpegQuality: JpegQuality.small)),
        (quality: 70, maxEdge: 1080),
      );
      expect(
        jpegPickParams(
          const UploadPrefs(
            jpegQuality: JpegQuality.custom,
            customQuality: 65,
            customMaxEdgePx: 2048,
          ),
        ),
        (quality: 65, maxEdge: 2048),
      );
    });

    test('png format yields null even with custom quality set', () {
      expect(
        jpegPickParams(
          const UploadPrefs(
            format: ImageFormat.png,
            jpegQuality: JpegQuality.custom,
            customQuality: 65,
            customMaxEdgePx: 2048,
          ),
        ),
        isNull,
      );
    });
  });
}
