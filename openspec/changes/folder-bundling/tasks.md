# folder-bundling — implementation tasks

## 1. Phase 0 — repo split & OrderPic rebrand (no behavior change)

- [x] 1.1 Split `lib/main.dart` into the target layout (`settings/`, `smb/`, `capture/naming.dart` placeholder-free, `pages/`, thin `main.dart`); update test imports; `flutter analyze` + `flutter test` green
- [x] 1.2 Full rebrand: pubspec `name: orderpic` + `package:` import rewrites, manifest `android:label="OrderPic"`, `MaterialApp.title`/`OrderPicApp` class, `applicationId`/`namespace` → `com.mmc.magicmicro.com.orderpic` with MainActivity relocated to the matching directory
- [x] 1.3 Device smoke pass on the new identity: scan → shoot → upload → History; confirm the first-run gate re-triggers (new app identity, no stored credentials)
- [x] 1.4 (user-directed, found in 1.3) Pause the scanner camera while any route is pushed on top of the tab shell (Settings currently keeps grabbing QR codes)
- [x] 1.5 (user-directed, found in 1.3) Refresh the History listing each time the History tab is presented, so uploads appear without manual pull-to-refresh

## 2. Settings model & sectioned page

- [x] 2.1 `UploadPrefs` value class — fields (`useOrderFolders`, `batchMode`, `format`, `jpegQuality`), behavior-preserving defaults, `==`/`hashCode`, `upload.*` keys, load/save via `SettingsStore`; unit tests for defaults + round-trip
- [x] 2.2 `AppSettings { ConnectionSettings, UploadPrefs }` umbrella (`SmbSettings` renamed `ConnectionSettings`), one `ValueNotifier`; History remount key narrows to `ObjectKey(settings.connection)` with updated invariant comment; first-run gate reads `connection.username`
- [x] 2.3 Settings page sections: title "Settings" (first-run keeps "Set up SMB login"), "Capture & upload" above "SMB connection"; toggles/format/quality wired into the unified save
- [x] 2.4 JPEG quality control: Original/High/Balanced/Small presets + Custom (slider 30–100, optional max long-edge px); selecting PNG hides the entire quality UI and restores it on switch-back; widget tests for both
- [x] 2.5 Widget test: an upload-only save (e.g. folders toggle) does not remount History; a connection change does

## 3. Naming & capture-session core

- [x] 3.1 `capture/naming.dart` builder: `{Order}_{YYYYMMDD}_{HHMMSS}_{NNN}.{jpg|png}` — admission-time stamp, zero-padded 3-digit session index; unit tests (001 padding, same-second distinct indexes, extension per format)
- [x] 3.2 History parser accepts legacy 3-part and new 4-part names into (order, readable time); unit tests incl. mixed-scheme newest-first ordering
- [x] 3.3 `CaptureSession`/`Shot`: session-owned temp dir (`mmcpic-session-{order}-{epoch}`), `admit()` materializes the file and locks its final name, per-shot delete on upload success, dir removal when emptied, best-effort stale-session sweep at app start
- [x] 3.4 `ImageProcessor` seam + `flutter_image_compress` dependency (lossless PNG conversion); JPEG presets applied via image_picker `maxWidth`/`imageQuality` (Original = untouched bytes); processing failure rejects the shot with the batch intact — unit tests against a fake processor

## 4. Upload flow

- [x] 4.1 `uploadSession()`: single SMB connection; best-effort `createFolder` of `sharePath` then `{sharePath}/{order}` when folders on; target-path builder flat vs folder (unit tests for both)
- [x] 4.2 Per-shot outcome tracking: success deletes its local file, failure keeps it; Retry uploads only the remaining shots; progress reported as completed/total
- [x] 4.3 PreviewPage batch UI: "Order N — k photos" chip, display-only thumbnail strip, Retake (last shot only), Add photo, Upload all; batch-off renders exactly today's single-shot actions (widget tests)
- [x] 4.4 Post-batch summary banner with Scan next QR and More for this order (fresh empty session, same order number)

## 5. History drill-down

- [x] 5.1 Root listing: directory tiles via `SmbFile.isDirectory()` — `Icons.folder` leading, small grey "Folder" label, name-descending, placed before loose images (newest-first as today)
- [x] 5.2 Order folder page: lists that folder's images (readable time title, filename subtitle, size trailing), reuses `ImageViewerPage` unchanged, pull-to-refresh at both levels; widget tests for tiles + drill-down

## 6. Verification & docs

- [ ] 6.1 Device pass across all four toggle combinations end-to-end; PNG conversion with EXIF-orientation check (decision point: swap `ImageProcessor` to pure-Dart `image` if the plugin misbehaves — design D4 fallback); induced-failure retry-remaining on hardware
- [x] 6.2 CLAUDE.md updates: filename contract (new scheme + legacy note), "no resize/compression" line superseded by quality settings, architecture map post-split, app name OrderPic
- [ ] 6.3 Full `flutter analyze` + `flutter test` green; final review of implementation against the six delta specs
- [x] 6.4 (user-directed, from 6.1 device pass) Tappable thumbnails: tapping a strip thumbnail swaps the full-screen preview to that shot (view any batch shot, not just the last)
- [x] 6.5 (user-directed, from 6.1 device pass) CameraPage becomes a transient launching state; backing out of the system camera cancels the capture and pops back to the scanner; the idle "Take a photo" screen with the manual Open camera button is removed
- [x] 6.6 (user-directed, from 6.1 device pass) Background PNG conversion: after a pick the shot appears as a pending thumbnail immediately; conversions run concurrently with capture; processing failures are flagged at review time for retake; Upload all waits for pending conversions
- [x] 6.7 (user-directed, from 6.1 device pass) SMB write timeout: a stalled shot write fails after a bounded timeout into the existing per-shot failure path (Retry re-writes it — partial remote files get overwritten); upload UI never hangs on 0/N
- [x] 6.8 (user-directed, device re-pass) Fix overflow on the "Waiting for N conversions…" button (debug yellow/black stripes = RenderFlex overflow ~24px): label must wrap/ellipsize within the button row
- [ ] 6.9 (user-directed, device re-pass) Fail-fast + auto-retry on dead connections: a write timeout marks the SMB connection dead — remaining shots are skipped immediately (no serial 30s grinds); after a timeout the uploader automatically redials a fresh connection and resumes remaining shots (bounded attempts, short backoff, progress-gated); manual Retry unchanged
