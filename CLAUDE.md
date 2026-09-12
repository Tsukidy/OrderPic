# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OrderPic (`orderpic`) — a Flutter app, Android-primary, for a photo-capture workflow: scan a QR-coded order number, photograph the item with the system camera app, review the shot(s), and upload them to a Windows SMB share — optionally into a per-order folder, optionally as a multi-shot batch (accumulate → upload all in one pass, retry only the failed shots), with configurable format/quality (JPEG presets or custom quality/edge cap, or lossless PNG). A History tab lists and views the images already on the share.

## Commands

- `flutter pub get` — fetch dependencies
- `flutter devices` / `flutter run -d <device-id>` — run on a device. The core flow needs real camera hardware and an SMB server on the LAN, so test on a physical device rather than an emulator.
- `flutter analyze` — static analysis (flutter_lints 6; platform dirs are already excluded in `analysis_options.yaml`)
- `flutter test` — run all tests; single file: `flutter test test/widget_test.dart`
- `flutter build apk` — release APK; currently signed with debug keys (see `android/app/build.gradle.kts`)

The Flutter SDK lives at `/home/dylan/Files/Develop/flutter` (useful when debugging the Gradle build).

## Architecture

The app is split into plain `StatefulWidget`s with no state-management library (a `ValueNotifier<AppSettings>` flows down from the shell):

- `lib/main.dart` — entry point + `OrderPicApp`; `lib/route_observer.dart` — the shared `RouteObserver<PageRoute>` pages subscribe to
- `lib/settings/` — `app_settings.dart` (`AppSettings` umbrella: `ConnectionSettings` + `UploadPrefs`, plus `jpegPickParams` mapping the JPEG presets onto image_picker args), `settings_store.dart` (the injectable `SettingsStore` seam over `flutter_secure_storage`), `settings_page.dart` (sectioned Settings / first-run form)
- `lib/smb/smb.dart` — the shared `connect(ConnectionSettings)` helper (refuses to dial when no username is configured)
- `lib/capture/` — `naming.dart` (filename builder + dual-shape parser), `session.dart` (`CaptureSession` staging + the startup stale-session sweep), `image_processor.dart` (the injectable `ImageProcessor` seam; `NativeImageProcessor` does PNG conversion via flutter_image_compress), `uploader.dart` (`uploadSession` — one connection per batch, per-shot outcomes)
- `lib/pages/` — `home_page.dart` (tab shell), `scanner_page.dart`, `camera_page.dart`, `preview_page.dart`, `history_page.dart` (includes `OrderFilesPage` folder drill-down), `image_viewer_page.dart`

### Navigation model

- `HomePage` is the root shell: an `IndexedStack` holding the Scan (`ScannerPage`) and History (`HistoryPage`) tabs behind a `NavigationBar`. The History tab is built lazily (`_historyVisited`).
- The capture flow (`CameraPage` → `PreviewPage`) is pushed on top of the tab shell as separate routes. `popUntil((route) => route.isFirst)` returns to scanning; `pushReplacement` moves between capture stages so the stack stays shallow.
- `ScannerPage.paused` is set by the shell while the History tab is on top, stopping the camera via `didUpdateWidget`. `_onDetect` guards re-entry with `_processing` while the confirm dialog is in flight, and ignores any detection while a page route covers the shell (`_covered`, set in `didPushNext`/cleared in `didPopNext`).
- Settings and the capture flow are pushed as page routes over the tab shell; `ScannerPage` is `RouteAware` (shared observer in `lib/route_observer.dart`) and stops its camera in `didPushNext` while any page route is on top — `paused` alone only covers tab switches, and dialogs don't count. `pushReplacement` between capture stages fires neither event, which keeps `_covered` correctly true through the whole multi-photo loop. The `MobileScanner` widget's lifecycle auto-restart is disabled (`useAppLifecycleState: false` — it restarts the camera on EVERY app resume, including the return from the system camera mid-capture-flow); the page owns lifecycle handling route-awarely instead.
- `HistoryPage` takes an `active` prop from the shell and re-lists the share every time its tab becomes the presented one (`didUpdateWidget` sees `false → true`), so uploads made since the last visit appear without pull-to-refresh.

### SMB layer

- All persisted settings live in the `AppSettings` umbrella (`lib/settings/app_settings.dart`): the SMB `ConnectionSettings` plus the `UploadPrefs` capture/upload preferences behind a single `ValueNotifier` held by the shell. Settings are edited in one sectioned page (`settings_page.dart` — "Capture & upload" section above the "SMB connection" section), persisted per-device via `flutter_secure_storage` behind the injectable `SettingsStore` seam. Credentials are never compiled into the binary — first startup opens a required setup form (`ConnectionSettings.load` wipes an unreadable store; `UploadPrefs.load` just falls back to defaults). Edit settings via the gear icon in either tab's app bar; the share itself must already exist, sub-folders are created at upload time. Note: `HomePage` re-keys `HistoryPage` on `ObjectKey(settings.connection)` only — an upload-pref save never remounts/re-lists History, a connection change always does.
- Every operation (batch upload in `uploadSession`, listing in `HistoryPage`/`OrderFilesPage`, download in `ImageViewerPage._load`) opens a fresh connection via the shared `connect(...)` helper (which refuses to dial when no username is configured) and closes it in a `finally` — the one exception being `uploadSession`, which holds ONE connection for the whole batch and redials only after a write timeout kills it.
- Photos are captured via `image_picker` with pick-time JPEG quality/resize applied per `UploadPrefs` (`jpegPickParams`; `Original` = untouched bytes for JPEG-headed sources — the processor re-encodes non-JPEG bytes under a `.jpg` name to keep bytes matching the extension, since gallery picks can arrive e.g. HEIC). PNG format converts losslessly at full size via `flutter_image_compress` behind the injectable `ImageProcessor` seam (`lib/capture/image_processor.dart`). Every capture admits through a `CaptureSession` (session-owned temp dir under `mmcpic-session-*`, plus a stale-session sweep at startup); batch uploads track per-shot outcomes — each success deletes its local file, a failed shot is retried once in place before the batch moves on (fresh redial after a write timeout), still-failed shots get one end-of-pass re-attempt, and a final failure deletes the broken remote partial (when the server refuses — its dead-session handle locks the file for a minute or two — the shot's error says so). A retry that stalls on the fresh connection marks the shot server-held (the dial proved the network fine — the file's lock is the blocker); no further attempts that pass, Retry after the window overwrites. Retry re-uploads exactly the remaining shots.
- The capture source is a `CaptureSource { camera, gallery }` param on `CameraPage` (default camera — Retake stays camera-only), chosen at the scanner's confirm dialogs (Take photo / Gallery) and on the review page's Add photo / done-state continuations via a bottom sheet. Gallery = ONE `pickMultiImage` call, every returned pick admitted in picker order with sequential session indexes. A magic-byte sniff keeps the filename↔bytes contract for gallery picks: a `.jpg` destination whose source bytes don't open with the `FF D8` JPEG magic is re-encoded full-size at quality 100 rather than byte-copied. Admission, ordering and upload are source-independent — a gallery shot is indistinguishable from a camera shot once admitted, so gallery shots ride the identical session→upload path and `useOrderFolders` placement plus every retry behavior above are source-independent by construction.
- When downloading, the `openRead` stream must be copied chunk-by-chunk into a `BytesBuilder` — smb_connect reuses one buffer for every chunk it yields. Don't "simplify" this.

### Filename contract (cross-feature invariant)

Uploads are named `{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png` (`lib/capture/naming.dart` `buildUploadFileName`), stamped at CAPTURE time (when the shot is admitted into the `CaptureSession` — not at upload). `NNN` is the zero-padded 3-digit shot index within the session (001-based; `padLeft(3, '0')` so it grows past 99 naturally), and the extension follows the configured format. `HistoryPage` depends on this format in two places: descending-name sort = newest first, and `parseUploadName` splits the name back into (order number, readable date/time). The parser accepts BOTH the legacy 3-part shape (`ORDER_YYYYMMDD_HHMMSS.ext`) and the current 4-part shape — anything else returns null and the UI falls back to the raw filename. Change both sides together or History breaks.

## Tests

Unit tests cover the value/logic layers — settings (`test/smb_settings_test.dart`, `test/app_settings_test.dart`, `test/upload_prefs_test.dart`), naming (`test/naming_test.dart`), sessions (`test/capture_session_test.dart`), and uploads (`test/uploader_test.dart`), plus the `ImageProcessor` seam (`test/image_processor_test.dart`) — using the injectable seams (`test/helpers/in_memory_settings_store.dart`, `CopyOnlyProcessor`, scripted `UploadConnection`/`listDir` fakes), so no platform channels are needed. Widget tests cover `settings_page_test.dart`, `home_page_test.dart`, `preview_page_test.dart` (including the CameraPage admission flow via a fake processor/picker — the `ImagePickerPlatform.instance` fake also scripts the multi-pick method `getMultiImageWithOptions`, covering gallery admission/cancel/abandon and batch-mode independence), and `history_page_test.dart` (fake `SmbFile` entries). `test/widget_test.dart` remains a placeholder: the real camera + SMB capture flow itself requires a physical device and a LAN share.

<!-- BEGIN OPENSPEC SUPERPOWERS BRIDGE -->
<!-- Source: superpowers-bridge/templates/adopters/CLAUDE.md.fragment.md -->
<!-- Drop this section into your project's CLAUDE.md so Claude routes future work using this schema correctly. -->
<!-- Adjust the schema name and bridge repo URL if you customized them; otherwise keep as-is. -->

## Workflow routing (read on session start)

This repo uses [`superpowers-bridge`](https://github.com/JiangWay/openspec-schemas/tree/main/superpowers-bridge) to bridge OpenSpec and Superpowers. Integration rules (language, artifact paths, PRECHECK) follow that bridge's README; this section is the routing guidance for Claude.

### Entry routing

| Trigger you observe | What to do |
|---|---|
| User starts a narrative "design discussion / let's brainstorm" | Run verbal `superpowers:brainstorming`, but **do NOT** write to `docs/superpowers/specs/`. Once the conversation converges per the 5 criteria below, promote to `/opsx:propose` |
| User invokes `/opsx:new` / `/opsx:ff` / `/opsx:propose` directly | Follow the schema's flow; artifact instructions inject at each step |
| User explicitly says bug fix / typo / config tweak / doc update | Direct PR — **do NOT** open a change (see skip rules below) |
| User is mid-change | Advance with `/opsx:continue`, `/opsx:apply`, `/opsx:verify`, or `/opsx:archive` |

### When NOT to use opsx (direct PR)

| Scenario | Direct PR? |
|---|---|
| New feature / new capability / architectural change / breaking change | ❌ Use opsx |
| Bug fix (no contract change) / test backfill / linter tweak / non-breaking upgrade / typo / docs / config value tweak | ✅ Direct PR |

Principle: **process ceremony scales with risk**. External contracts / schema / cross-system integration / compliance → opsx. Otherwise → direct PR.

### Verbal brainstorm → opsx promotion criteria

All 5 must hold before promoting (any missing → keep brainstorming, **never** write to `docs/superpowers/specs/`):

1. **Scope locked** — one sentence describes what's in / out
2. **Major design forks resolved** — alternatives weighed; remaining TBDs have an owner and impact-scope statement
3. **Cross-system dependencies mapped** — ready / mockable / genuinely unknown — pick one per dep
4. **Acceptance criteria stateable** — concrete pass conditions (e.g., `./mvnw clean verify` passes + N deliverables)
5. **Conversation converging** — recent turns are confirmations, not new alternatives

When all 5 hold → proactively suggest "ready to `/opsx:propose`?" — wait for user ack. Never auto-trigger.

### Front-door anti-patterns (don't do)

- Letting brainstorming write to `docs/superpowers/specs/`
- Letting writing-plans write to `docs/superpowers/plans/`
- Promoting to opsx with unresolved blocking TBDs
- Opening a change for bug fix / typo

Full detail: [superpowers-bridge README §Entry & exit gates](https://github.com/JiangWay/openspec-schemas/blob/main/superpowers-bridge/README.md#entry--exit-gates).

<!-- END OPENSPEC SUPERPOWERS BRIDGE -->
