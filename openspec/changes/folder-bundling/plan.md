# folder-bundling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-order folder uploads, an opt-in multi-shot batch mode with format/quality control, capture-time collision-proof naming, drill-down History — delivered after a mechanical main.dart split and full OrderPic rebrand.

**Architecture:** A `CaptureSession` (order + accumulated `Shot`s, each a processed local file with a finalized name) is threaded through the existing `CameraPage → PreviewPage` hand-offs. Admission is source-agnostic: the camera producer picks (JPEG quality applied via image_picker params) and `ImageProcessor` materializes the shot (PNG conversion or byte copy) into a session-owned temp dir. `uploadSession()` writes all remaining shots over one SMB connection with per-shot outcomes. Settings become `AppSettings { ConnectionSettings, UploadPrefs }` behind one notifier; History remounts only on connection changes and drills into order folders via native `isDirectory()`.

**Tech Stack:** Flutter (plain StatefulWidgets, no state library), smb_connect 0.0.9, image_picker (camera + pick-time compression), flutter_image_compress (new, PNG conversion), flutter_secure_storage via the injectable `SettingsStore` seam, flutter_test.

**Spec/design references (read these first):** `openspec/changes/folder-bundling/design.md` (decisions D1–D11), `specs/*/spec.md` in the same directory (testable requirements). Task ids below match `tasks.md`.

## Global Constraints

- Filename contract (photo-naming spec): `{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png`, stamped at admission, `NNN` zero-padded 3-digit session index from 001, extension per format. History parser must also accept legacy 3-part names.
- Upload prefs defaults must preserve pre-change behavior: folders off, batch off, JPEG, Original. Storage keys: existing `smb.*` unchanged; new `upload.*`.
- History remounts only on `ConnectionSettings` changes (`ObjectKey(settings.connection)`); upload-pref saves must not remount.
- First-run gate stays `connection.username.isEmpty`; unconfigured guard (`connect()`) unchanged.
- PNG mode: lossless, full-size, quality UI hidden. JPEG presets: Original = untouched bytes; High = q90 uncapped; Balanced = q80 + 2560px; Small = q70 + 1080px; Custom = 30–100 + optional long-edge px.
- `openRead` streams must be copied chunk-by-chunk into a `BytesBuilder` (smb_connect buffer reuse) — do not "simplify".
- No credentials in the binary; `flutter analyze` and `flutter test` green before every commit; device pass mandatory for camera/SMB flows (project memory).
- App identity after phase 0: pubspec `name: orderpic`, `applicationId`/`namespace` `com.mmc.magicmicro.com.orderpic`, label/title "OrderPic".

---

### Task 1.1: Split main.dart into lib/ modules

**Files:**
- Create: `lib/settings/settings_store.dart`, `lib/settings/app_settings.dart`, `lib/smb/smb.dart`, `lib/capture/naming.dart`, `lib/pages/home_page.dart`, `lib/pages/scanner_page.dart`, `lib/pages/camera_page.dart`, `lib/pages/preview_page.dart`, `lib/pages/history_page.dart`, `lib/pages/image_viewer_page.dart`
- Modify: `lib/main.dart` (shrinks to `main()` + `MmcPicApp`), `test/smb_settings_test.dart`, `test/settings_page_test.dart`, `test/home_page_test.dart`, `test/widget_test.dart`
- Test: existing suites are the regression net — no new tests in this task

**Interfaces:**
- Produces: the file layout every later task builds on; all public names unchanged (`SmbSettings`, `SettingsStore`, `connect`, page classes…). `naming.dart` temporarily hosts the existing `_buildFileName`/`_parseName` logic moved from `PreviewPage`/`HistoryPage` as-is (3-part legacy shape — upgraded in Task 3.2).

- [ ] **Step 1: Move each block verbatim** — `SmbSettings`, `smbSettingKeys`, `SettingsStore`, `SecureSettingsStore`, `SmbNotConfiguredException`, `connect` → `settings/settings_store.dart` (store + keys) and `settings/app_settings.dart` (SmbSettings) and `smb/smb.dart` (exception + connect) so each file has one responsibility; pages → `pages/*.dart`; each new file gets the doc-comment of its block. `main.dart` keeps `main()` + `MmcPicApp` with imports.
- [ ] **Step 2: Point `_buildFileName`/`_parseName` at one home** — move `PreviewPage._buildFileName` and `HistoryPage._parseName` bodies into `capture/naming.dart` as top-level `String buildUploadFileName(String orderNumber, DateTime now)` (unchanged 3-part logic) and `(String, String)? parseUploadName(String name)`; both pages now call these.
- [ ] **Step 3: Update test imports** — `package:mmcpicv4/main.dart` stays valid for the app-shell tests; page-level tests import the new files directly where they reference moved types.
- [ ] **Step 4: Verify**

```bash
flutter analyze && flutter test
```
Expected: analyze clean, all tests pass.

- [ ] **Step 5: Commit** `git commit -m "refactor: split main.dart into lib/ modules (no behavior change)"`

### Task 1.2: Full OrderPic rebrand

**Files:**
- Modify: `pubspec.yaml` (`name: orderpic`), every `package:mmcpicv4/` import in `test/`, `android/app/src/main/AndroidManifest.xml:5` (`android:label="OrderPic"`), `android/app/build.gradle.kts` (namespace + applicationId → `com.mmc.magicmicro.com.orderpic`), `android/app/src/main/kotlin/com/mmc/magicmicro/com/mmcpicv4/MainActivity.kt` → relocated to `.../com/mmc/magicmicro/com/orderpic/MainActivity.kt` with `package com.mmc.magicmicro.com.orderpic;`, `lib/main.dart` (`title: 'OrderPic'`, class `OrderPicApp`), `lib/settings/app_settings.dart` doc-comment mentioning MMCPic
- Test: no unit test possible; verification is grep + build

- [ ] **Step 1: Apply all edits above** (pubspec first, then `grep -rl 'package:mmcpicv4' test/ lib/ | xargs sed -i 's/package:mmcpicv4/package:orderpic/g'` and `git mv` MainActivity).
- [ ] **Step 2: Verify no stale identity**

```bash
grep -rn 'mmcpicv4\|MmcPic\|MMCPic' lib/ test/ android/app/ pubspec.yaml
```
Expected: only the `com.mmc.magicmicro.com.orderpic` path segments may historically match nothing; zero hits otherwise. Then `flutter pub get && flutter analyze && flutter test` and `flutter build apk` — all green.
- [ ] **Step 3: Commit** `git commit -m "chore: rebrand app to OrderPic (new applicationId, orderpic package)"`

### Task 1.3: Device smoke pass on the new identity (operator)

- [ ] **Step 1: Install on device** `flutter run -d <device>` (fresh identity → installs alongside old app).
- [ ] **Step 2: Walk the flow** — first-run gate appears (no stored creds); enter SMB login → Scan → shoot → upload → History lists it. Old app still present and untouched.
- [ ] **Step 3: Record result** in the change notes; block further phases on pass.

---

### Task 2.1: UploadPrefs value class

**Files:**
- Create: `lib/settings/app_settings.dart` additions
- Test: `test/upload_prefs_test.dart`

**Interfaces:**
- Produces: `enum ImageFormat { jpeg, png }`, `enum JpegQuality { original, high, balanced, small, custom }`, `class UploadPrefs` with `useOrderFolders`/`batchMode`/`format`/`jpegQuality`/`customQuality` (30–100)/`customMaxEdgePx` (nullable), `==`/`hashCode`/`copyWith`, `static const defaults`, `load({store})`/`save({store})` over keys `upload.use_order_folders`, `upload.batch_mode`, `upload.format`, `upload.jpeg_quality`, `upload.custom_quality`, `upload.custom_max_edge`.

- [ ] **Step 1: Write failing tests**

```dart
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
      useOrderFolders: true, batchMode: true, format: ImageFormat.png,
      jpegQuality: JpegQuality.custom, customQuality: 65, customMaxEdgePx: 2048,
    );
    await p.save(store: store);
    expect(await UploadPrefs.load(store: store), p);
  });

  test('corrupt store falls back to defaults', () async {
    final store = InMemorySettingsStore()..failReads = true;
    expect(await UploadPrefs.load(store: store), UploadPrefs.defaults);
  });
}
```
Add a `failReads` flag to `InMemorySettingsStore` (throws on read when set).

- [ ] **Step 2: Run** `flutter test test/upload_prefs_test.dart` — expect FAIL (types not defined).
- [ ] **Step 3: Implement** in `app_settings.dart` — enums + class mirroring `ConnectionSettings`' load/save pattern: booleans as `'true'/'false'`, enums via `.name`, `customMaxEdgePx` as `''` when null; `try/catch` → defaults (no wipe; no secrets here).
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: UploadPrefs value class with encrypted persistence"`

### Task 2.2: AppSettings umbrella + remount narrowing

**Files:**
- Modify: `lib/settings/app_settings.dart`, `lib/pages/home_page.dart`, `lib/pages/scanner_page.dart`, `lib/pages/camera_page.dart`, `lib/pages/preview_page.dart`, `lib/pages/history_page.dart`, `lib/pages/image_viewer_page.dart`, `lib/settings/settings_page.dart`, `lib/smb/smb.dart` (`connect(ConnectionSettings)` — same shape)
- Test: `test/app_settings_test.dart`, `test/home_page_test.dart` (update)

**Interfaces:**
- Produces: `class ConnectionSettings` (renamed from `SmbSettings`, fields/keys/behavior identical), `class AppSettings { final ConnectionSettings connection; final UploadPrefs upload; }` with `==`/`hashCode` over both, `static const defaults`, `load({store})`/`save({store})`. Every page's `settingsNotifier` becomes `ValueNotifier<AppSettings>`; SMB call sites read `.value.connection`.
- Consumes: Task 2.1's `UploadPrefs`.

- [ ] **Step 1: Write failing tests** — `app_settings_test.dart`: `AppSettings.load` on a store holding only `smb.*` values yields those + upload defaults; equality distinguishes upload-only changes. `home_page_test.dart`: add — save upload-only change (toggle folders) with History visited → History NOT remounted (spy via a counter key/`ValueListenableBuilder` rebuild count); save host change → remounted.
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — rename class (keep `smbSettingKeys`), add umbrella + load/save; in `HomePage` change `ValueNotifier<SmbSettings>` → `ValueNotifier<AppSettings>` and `ObjectKey(settings)` → `ObjectKey(settings.connection)` **updating the invariant comment** to say remount tracks connection identity only; gate becomes `s.connection.username.isEmpty`; update every `settingsNotifier` consumer (`connect(s.connection)` etc.) and all existing tests referencing `SmbSettings`.
- [ ] **Step 4: Run** `flutter test` — expect PASS (full suite).
- [ ] **Step 5: Commit** `git commit -m "feat: AppSettings umbrella; History remount narrows to connection changes"`

### Task 2.3: Sectioned Settings page

**Files:**
- Modify: `lib/settings/settings_page.dart`
- Test: `test/settings_page_test.dart` (extend)

**Interfaces:**
- Produces: SettingsPage editing `AppSettings` (both sections, one Save writing both); title `'Settings'` (first-run keeps `'Set up SMB login'`); constructor unchanged plus it now takes/updates the same `ValueNotifier<AppSettings>`.

- [ ] **Step 1: Failing tests** — section order (capture header above connection header via `find.text` indexes); toggling the folders switch and saving persists `upload.useOrderFolders` (assert via notifier value); connection fields still validate as before (existing tests keep passing).
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — state: existing five controllers + `_folders`, `_batch`, `_format`, `_quality`, `_customQuality`, `_customMaxEdge` seeded from `widget.settingsNotifier.value.upload`. Layout: `Text('Capture & upload', style: Theme.of(context).textTheme.labelLarge)`, two `SwitchListTile`s (keys `folders_toggle`, `batch_toggle`), format `SegmentedButton<ImageFormat>` (key `format_selector`), then `Text('SMB connection', …)` header above the existing five fields + test button. `_save()` builds and persists `AppSettings`.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: sectioned Settings page (Capture & upload above SMB connection)"`

### Task 2.4: JPEG quality control + PNG hides it

**Files:**
- Modify: `lib/settings/settings_page.dart`, `lib/settings/app_settings.dart` (helper below)
- Test: `test/settings_page_test.dart`, `test/upload_prefs_test.dart` (extend)

**Interfaces:**
- Produces: `({int? quality, int? maxEdge})? jpegPickParams(UploadPrefs p)` top-level in `app_settings.dart` — `null` for Original/PNG (no re-encode); `(90, null)` High; `(80, 2560)` Balanced; `(70, 1080)` Small; `(p.customQuality, p.customMaxEdgePx)` Custom. Settings-page quality block keyed `quality_section`.

- [ ] **Step 1: Failing tests** — preset mapping table test for `jpegPickParams`; widget: with JPEG selected, `quality_section` visible and Custom slider clamps 30–100; after selecting PNG (`format_selector`), `quality_section` findsNothing; switching back to JPEG restores previous selection.
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — quality block: `SegmentedButton<JpegQuality>`; when `custom`, a `Slider(min: 30, max: 100)` (key `custom_quality_slider`) + optional `TextFormField` digits for max long-edge (key `custom_max_edge_field`, blank = uncapped). Wrap the whole block in `if (_format == ImageFormat.jpeg)`.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: JPEG quality presets + custom; PNG hides quality UI"`

### Task 2.5: (folded into 2.2) Upload-only save leaves History alone — covered by the Task 2.2 home-page test; no separate task.

---

### Task 3.1: Capture-time filename builder

**Files:**
- Modify: `lib/capture/naming.dart`
- Test: `test/naming_test.dart`

**Interfaces:**
- Produces: `String buildUploadFileName({required String orderNumber, required DateTime admittedAt, required int shotIndex, required ImageFormat format})` — 4-part, `NNN` zero-padded 3-digit, ext `png`/`jpg`.

- [ ] **Step 1: Failing tests**

```dart
test('first shot indexed 001', () {
  final n = buildUploadFileName(orderNumber: '100438',
      admittedAt: DateTime(2026, 9, 8, 14, 3, 5), shotIndex: 1,
      format: ImageFormat.jpeg);
  expect(n, '100438_20260908_140305_001.jpg');
});

test('same-second shots get distinct indexes', () {
  final when = DateTime(2026, 9, 8, 14, 3, 5);
  final a = buildUploadFileName(orderNumber: '100438',
      admittedAt: when, shotIndex: 1, format: ImageFormat.jpeg);
  final b = buildUploadFileName(orderNumber: '100438',
      admittedAt: when, shotIndex: 2, format: ImageFormat.jpeg);
  expect(a, '100438_20260908_140305_001.jpg');
  expect(b, '100438_20260908_140305_002.jpg');
});

test('png extension follows format', () {
  final n = buildUploadFileName(orderNumber: '100438',
      admittedAt: DateTime(2026, 9, 8, 14, 3, 5), shotIndex: 1,
      format: ImageFormat.png);
  expect(n, '100438_20260908_140305_001.png');
});

test('index pads past 99 without truncation', () {
  final n = buildUploadFileName(orderNumber: '100438',
      admittedAt: DateTime(2026, 9, 8, 14, 3, 5), shotIndex: 123,
      format: ImageFormat.jpeg);
  expect(n, '100438_20260908_140305_123.jpg');
});
```
- [ ] **Step 2: Run** — expect FAIL (signature mismatch).
- [ ] **Step 3: Implement** — replace the 3-part legacy body with the 4-part one; keep `two()` padding helper local.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: capture-time 4-part filename builder"`

### Task 3.2: Dual-shape parser

**Files:**
- Modify: `lib/capture/naming.dart`, `lib/pages/history_page.dart`, `lib/pages/preview_page.dart` (call sites)
- Test: `test/naming_test.dart` (extend)

**Interfaces:**
- Produces: `({String order, DateTime when})? parseUploadName(String name)` — accepts 3- and 4-part stems, digits-validated, else null (caller shows raw name).

- [ ] **Step 1: Failing tests** — legacy `100438_20260901_101530.jpg` → order 100438 + 2026-09-01 10:15:30; new `100438_20260908_140305_003.png` → same order + time (index ignored); `garbage_name.jpg` → null; ordering: `['a_20260101_000000_001.jpg','a_20251231_235959.jpg','b_20260102_000000_002.jpg']` sorted desc equals newest-first (`b_20260102…`, `a_20260101…`, `a_20251231…`).
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — split stem, accept `parts.length == 3 || parts.length == 4` (4th must be 3 digits), digit-validate segments 1–2 via `RegExp(r'^\d+$')`, compose `DateTime`.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: parser accepts legacy and 4-part names"`

### Task 3.3: CaptureSession + temp-dir lifecycle

**Files:**
- Create: `lib/capture/session.dart`
- Modify: `lib/main.dart` (startup sweep)
- Test: `test/capture_session_test.dart`

**Interfaces:**
- Produces: `class Shot { final String localPath; final String fileName; const Shot(...); }`; `class CaptureSession { final String orderNumber; Directory dir; static Future<CaptureSession> create(String orderNumber); List<Shot> get shots; int get nextIndex; void add(Shot); Shot? removeLast(); Future<void> deleteLocal(Shot); Future<void> cleanupIfEmpty(); }`; `Future<void> sweepStaleSessions()` deleting `mmcpic-session-*` dirs under `Directory.systemTemp` best-effort.

- [ ] **Step 1: Failing tests** — `create('100438')` makes dir `…/mmcpic-session-100438-<epoch>`; `add` twice → `nextIndex == 3`; `removeLast` returns last shot only; `deleteLocal` removes the file; `cleanupIfEmpty` removes dir when no shots remain and keeps it otherwise; `sweepStaleSessions` removes a planted `mmcpic-session-x` dir. (Use real temp dirs under `Directory.systemTemp` with unique prefixes; clean up in `tearDown`.)
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** as specified; `main()` gains `unawaited(sweepStaleSessions());` before `runApp`.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: CaptureSession with session-owned storage and startup sweep"`

### Task 3.4: ImageProcessor seam + PNG conversion

**Files:**
- Create: `lib/capture/image_processor.dart`
- Modify: `pubspec.yaml` (`flutter pub add flutter_image_compress` — latest 2.x), `lib/pages/camera_page.dart` (pick params)
- Test: `test/image_processor_test.dart` (pick-params coverage already in 2.4)

**Interfaces:**
- Produces: `abstract class ImageProcessor { Future<String> process({required String pickedPath, required UploadPrefs prefs, required CaptureSession session}); }` returning the materialized path inside `session.dir`; `class NativeImageProcessor implements ImageProcessor` — PNG: `FlutterImageCompress.compressWithFile(pickedPath, format: CompressFormat.png)` written as `<sessionStem>.png`; JPEG (already quality-applied or Original): byte-copy. Tests use `class CopyOnlyProcessor implements ImageProcessor` (pure `File.copy`).

- [ ] **Step 1: Failing tests** — with `CopyOnlyProcessor`: process returns an existing file inside `session.dir`, named from `buildUploadFileName` with `session.nextIndex`; calling twice in the same second yields `001` then `002` filenames; a processor throwing leaves `session.shots` unchanged (admission wrapper — see Task 4.3 for the UI guard; here assert `session.nextIndex` unchanged when `process` throws before `add`).
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — seam + native impl; `CameraPage._takePhoto` computes `final params = prefs.format == ImageFormat.jpeg ? jpegPickParams(prefs) : null;` and passes `maxWidth: params?.maxEdge?.toDouble(), imageQuality: params?.quality` to `pickImage` (null = untouched, PNG path picks original JPEG for lossless conversion).
- [ ] **Step 4: Run** — expect PASS (native impl exercised only on device).
- [ ] **Step 5: Commit** `git commit -m "feat: ImageProcessor seam; JPEG pick params; PNG via flutter_image_compress"`

---

### Task 4.1: uploadSession + target paths

**Files:**
- Create: `lib/capture/uploader.dart`
- Test: `test/uploader_test.dart`

**Interfaces:**
- Produces: `String uploadTargetPath({required ConnectionSettings c, required UploadPrefs u, required String orderNumber, required String fileName})`; `typedef ShotWriter = Future<void> Function(String remotePath, Uint8List bytes); typedef FolderEnsurer = Future<void> Function(String path);` `class UploadSummary { final List<({Shot shot, bool ok, String? error})> outcomes; bool get allOk; List<Shot> get remaining; }`; `Future<UploadSummary> uploadSession(CaptureSession session, AppSettings settings, {ShotWriter? writeShot, FolderEnsurer? ensureFolder, void Function(int done, int total)? onProgress})` — defaults open ONE `connect(settings.connection)` connection; `ensureFolder` swallows errors (best-effort, share must pre-exist); per shot: write → `session.deleteLocal` on success; `onProgress` after each shot; `finally` closes the connection.

- [ ] **Step 1: Failing tests** — target-path flat vs folder; happy path with recording fakes: two shots → two writes to right paths, both locals deleted, `allOk`, progress `(1,2)(2,2)`; writer throws on 2nd of 3: shot1 local deleted, shots 2–3 kept, `remaining` == those two, `allOk` false; folder ensure called with `sharePath` and `sharePath/order` when folders on, only `sharePath` when off.
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: uploadSession — one connection, per-shot outcomes, retry-remaining"`

### Task 4.2: (folded into 4.1 + 4.3) Retry-remaining logic and progress — pure logic in 4.1's tests, UI wiring in 4.3.

### Task 4.3: PreviewPage batch UI

**Files:**
- Modify: `lib/pages/camera_page.dart`, `lib/pages/preview_page.dart`, `lib/pages/scanner_page.dart` (session creation)
- Test: `test/preview_page_test.dart`

**Interfaces:**
- Consumes: Tasks 3.3/3.4/4.1. `ScannerPage._startCapture` creates `await CaptureSession.create(orderNumber)` and passes it to `CameraPage(session:, settingsNotifier:)`; `CameraPage` picks, `processor.process(...)`, `session.add(Shot(localPath: processed, fileName: from processor))`, then `pushReplacement(PreviewPage(session:, settingsNotifier:, uploader: uploadSession /* injectable */))`.
- Produces: `PreviewPage` constructor gains `final CaptureSession session; final Future<UploadSummary> Function(CaptureSession, AppSettings)? uploader;` — in tests inject a fake; default null → real `uploadSession`.

- [ ] **Step 1: Failing tests** — batch on, session of 3 fake files (`Directory.systemTemp` PNGs not needed — any bytes; fake processor already used to build session): chip text `Order: 100438 — 3 photos`; thumbnail strip shows 3 `Image.file`s; "Add photo" button present; tap "Upload all" → injected uploader called once; simulate 2nd-shot failure → error banner + Retry tap → uploader called with a session whose `shots` are exactly the remaining two; batch off → no chip/strip/Add-photo (today's buttons only); single-shot upload success → existing done banner.
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — status enum extended with batch states; `Retake` = `session.removeLast()` + delete file + relaunch camera; `_uploadAll` sets `uploading` with `x / N` overlay driven by `onProgress`, then `done` summary (`Uploaded N photos`) with `Scan next` (`popUntil isFirst`) and `More for this order` (fresh `CaptureSession.create(orderNumber)` → CameraPage). Processing-failure guard: catch from `process` → snackbar + stay on camera, session untouched.
- [ ] **Step 4: Run** — expect PASS; full `flutter test`.
- [ ] **Step 5: Commit** `git commit -m "feat: batch capture UI — strip, retake-last, upload all, retry remaining"`

### Task 4.4: (folded into 4.3) Post-batch summary + More-for-this-order — delivered by 4.3's done-state buttons.

---

### Task 5.1: History root folder tiles

**Files:**
- Modify: `lib/pages/history_page.dart`
- Test: `test/history_page_test.dart`

**Interfaces:**
- Produces: `HistoryPage` constructor gains `final Future<List<SmbFile>> Function(String path)? listDir;` (default: real connect/listFiles/close). Root build: directories first as `ListTile(leading: Icon(Icons.folder), title: Text(name), subtitle: Text('Folder', style: grey))` sorted name-desc; then images (existing parse via `parseUploadName`) newest-first as today.

- [ ] **Step 1: Failing tests** — injected `listDir` returning fake `SmbFile`s (files: attributes `0x00000000`… use plain file attr `0x80`/archive or `0`; directory: `0x10` = `FILE_ATTRIBUTE_DIRECTORY`, with comment) + one image with order-like name: folder tile renders with `Icons.folder` + 'Folder' subtitle above images; order-like-named FILE renders as image tile (attribute-based detection).
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — split `entries` by `isDirectory()`; keep `_isImage` filter for files; pull-to-refresh unchanged.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: History folder tiles via native isDirectory"`

### Task 5.2: Drill-down order page

**Files:**
- Modify: `lib/pages/history_page.dart` (add `OrderFilesPage`)
- Test: `test/history_page_test.dart` (extend)

**Interfaces:**
- Produces: `class OrderFilesPage extends StatefulWidget` taking `folderName`, `folderPath`, `settingsNotifier`, `listDir` — same list UI as History but title = folder name, entries images-only (`_isImage`), `title: readable time`, `subtitle: filename`, trailing size; tap → existing `ImageViewerPage(file:, settingsNotifier:)` unchanged.

- [ ] **Step 1: Failing tests** — tap folder tile → `OrderFilesPage` lists that folder's injected files with time/filename/size; RefreshIndicator present; tap a photo → `ImageViewerPage` pushed with that `SmbFile`.
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement** — push `MaterialPageRoute(OrderFilesPage(...))` from folder tile `onTap`.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: History drill-down into order folders"`

---

### Task 6.1: Device matrix pass (operator)

- [ ] **Step 1:** Toggle matrix — (folders × batch) all four combos: scan → shoot (×3 in batch modes) → upload → verify share layout (`{share}/100438/…` vs flat; `_NNN` naming; same-second indexes distinct).
- [ ] **Step 2:** PNG mode — upload one shot; verify `.png` on share, correct orientation (rotate phone while shooting); if orientation wrong or conversion fails → switch `NativeImageProcessor` to pure-Dart `image` package per design D4 fallback and re-verify.
- [ ] **Step 3:** Failure/retry — disable Wi-Fi mid-batch; verify partial upload + Retry sends only remaining; verify locals cleaned after full success.
- [ ] **Step 4:** History — folder tiles, drill-down, viewer, pull-to-refresh; settings toggles don't re-list History.

### Task 6.2: CLAUDE.md updates

**Files:** Modify `CLAUDE.md`.

- [ ] **Step 1: Edit the four spots** — app name line ("OrderPic (orderpic) — a Flutter app…"); Architecture section: replace "The entire app is lib/main.dart" with the module map (`settings/`, `smb/`, `capture/`, `pages/`); SMB layer bullet "Photos are captured via image_picker with no resize/compression…" → "…with quality/format per UploadPrefs (Original = untouched bytes; PNG = lossless conversion); batch uploads reuse one connection and retry only remaining shots"; Filename contract section → new 4-part scheme + legacy-parse note + History dependency (sort + parse both shapes).
- [ ] **Step 2: Verify** — read-through; commands section still accurate.
- [ ] **Step 3: Commit** `git commit -m "docs: CLAUDE.md reflects OrderPic, module split, new filename contract"`

### Task 6.3: Final verification

- [ ] **Step 1:** `flutter analyze && flutter test` — green.
- [ ] **Step 2:** Review implementation against the six delta specs (`openspec/changes/folder-bundling/specs/`) requirement-by-requirement; note any gap as a failing follow-up task, not a silent skip.
- [ ] **Step 3:** Commit any stragglers; change is ready for `/opsx:verify`.

---

## Self-Review (performed on this plan)

1. **Spec coverage** — upload-settings reqs → 2.1–2.4 (+2.2 remunt test); batch-capture reqs → 3.3, 3.4, 4.1, 4.3 (incl. single-shot parity, durability, cleanup, summary); order-folders → 4.1 target paths, 5.1, 5.2; photo-naming → 3.1, 3.2; smb-settings MODIFIED → 2.2/2.3; manual-order-entry MODIFIED → covered by naming builder being the single path for both entry modes (Scenario 2 = new session restarts at 001 — inherent to per-session `nextIndex`). Phase-0 → 1.1–1.3; docs → 6.2. No gaps.
2. **Placeholder scan** — no TBD/TODO/later-implement steps remain; every code step carries real code or an exact command.
3. **Type consistency** — `UploadPrefs`/`AppSettings`/`ConnectionSettings` (2.1/2.2) match usage in 2.3/2.4/3.4/4.1/4.3; `buildUploadFileName({orderNumber, admittedAt, shotIndex, format})` used by 3.4; `uploadSession(session, settings, {writeShot, ensureFolder, onProgress})` matches 4.3's injected `uploader` shape (`(CaptureSession, AppSettings)`); `listDir` signature identical in 5.1/5.2.
