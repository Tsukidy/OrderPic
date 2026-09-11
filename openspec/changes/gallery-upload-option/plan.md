# gallery-upload-option Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the operator pick existing gallery photos — singly or several at once — as an upload source at capture start and during review, riding the existing session/naming/upload pipeline untouched, with an extension-contract guard so gallery-sourced bytes always match the reserved filename.

**Architecture:** No new pipeline: `admitPicked` was built source-agnostic, so the work is entry points plus one guard. `CameraPage` (the transient pick page) gains a `CaptureSource { camera, gallery }` parameter — gallery launches `pickMultiImage` with the same `jpegPickParams` mapping and admits each pick in order before the single hand-off to review. The source choice is offered inside the two capture-start confirm dialogs and on the review page via a bottom sheet on the add/continue affordances. `NativeImageProcessor` sniffs JPEG magic bytes on `.jpg` destinations and re-encodes non-JPEG sources (HEIC), keeping the filename↔bytes contract intact. Settings are untouched by design: gallery ignores the batch toggle and follows the folder toggle exactly like the camera.

**Tech Stack:** Flutter (plain StatefulWidgets, no state library), image_picker 1.2.3 (`pickImage` + `pickMultiImage` over `ImagePickerPlatform` — the existing test seam), flutter_image_compress (existing, re-encode fallback), flutter_test + existing fakes (`_FakePickerPlatform`, `CopyOnlyProcessor`, injected uploaders).

**Spec/design references (read these first):** `openspec/changes/gallery-upload-option/design.md` (decisions D1–D10), `specs/*/spec.md` in the same directory (testable requirements). Task ids below match `tasks.md`.

## Global Constraints

- Filename contract (photo-naming spec): `{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png`, stamped at admission in call order — a gallery multi-pick stamps 001/002/003 in picker order; never renumber.
- Gallery MUST NOT be gated on `upload.batchMode` anywhere (user-directed); gallery uploads MUST follow `upload.useOrderFolders` identically to camera uploads (user-directed) — which the shared session→uploader path gives for free; the spec scenario pins it.
- `CameraPage`'s transient contract is regression-critical: every outcome leaves the page; cancel (null OR empty list) → `_exit` (staged → review, empty → cleanup + pop to Scan tab); picker exception → `_abandon` snackbar + same exit. Camera-mode behavior with the default parameter must be byte-identical to today.
- Retake stays camera-only (D10). The single-shot review row keeps exactly Retake | Upload (no batch UI), even when the session holds multiple gallery picks; Upload sends every READY shot.
- JPEG preset semantics: presets apply at PICK time via `jpegPickParams` (Original = untouched bytes, PNG = null params → lossless conversion). The D8 magic-byte guard is a fallback for format-gated compression only — it must not alter the path for actual JPEG sources.
- Narrow-screen rule: no new buttons in the review action rows — the source choice is a bottom sheet (D4). The waiting-button `Flexible`/ellipsize contract stays.
- `flutter analyze` and `flutter test` green before every commit; device pass mandatory for picker/camera/SMB flows.

---

### Task 1.1: JPEG magic-byte guard in NativeImageProcessor

**Files:**
- Modify: `lib/capture/image_processor.dart` (NativeImageProcessor only)
- Test: `test/image_processor_test.dart` (extend)

**Interfaces:**
- Produces: no API change — `process({pickedPath, destPath})` keeps its signature; the guard is internal. A small testable helper (e.g. `bool _looksLikeJpeg(Uint8List head)` or a top-level `isJpegBytes`) is fine.
- Behavior: destPath ends `.jpg` + source bytes start `FF D8` → today's copy. destPath ends `.jpg` + other magic (test with PNG/HEIC-brand bytes) → `FlutterImageCompress.compressWithFile(pickedPath, minWidth/_fullSizeEdge, minHeight/_fullSizeEdge, format: jpeg, quality: 100)` written to destPath. `.png` → unchanged codec conversion. Failure → throws (existing `_settleAdmission` contract flags the entry).

- [ ] **Step 1: Failing tests** — write a real JPEG-headed temp file → process to `.jpg` → dest bytes identical to source (copy path unchanged). Write a file headed with non-JPEG magic → process to `.jpg` → dest exists and differs from a raw copy (re-encode ran; assert via a compress-call spy or by byte inequality + decodability is device-only, so spy). `.png` dest with same non-JPEG source → unchanged conversion path (spy asserts png format). Compress returning null → throws.
- [ ] **Step 2: Run** `flutter test test/image_processor_test.dart` — expect FAIL.
- [ ] **Step 3: Implement** — read the first 2–3 bytes via `File.openRead(0, 3)`, branch, re-encode fallback with the existing `_fullSizeEdge` sentinel and `quality: 100`.
- [ ] **Step 4: Run** full `flutter analyze && flutter test` — PASS.
- [ ] **Step 5: Commit** `feat: extension-contract guard — re-encode non-JPEG gallery sources under .jpg names`

### Task 2.1: CaptureSource enum + multi-pick admission in CameraPage

**Files:**
- Modify: `lib/pages/camera_page.dart`
- Test: `test/preview_page_test.dart` (the CameraPage suites live there)

**Interfaces:**
- Produces: `enum CaptureSource { camera, gallery }` (camera_page.dart); `CameraPage({..., this.source = CaptureSource.camera})`. Gallery mode: `pickMultiImage(maxWidth:, maxHeight:, imageQuality: per the same params logic)`; admits each `XFile` in returned order via `admitPicked`; single `pushReplacement` to `_reviewPage()` after the loop. Caption: `source == camera ? 'Opening camera…' : 'Opening gallery…'`.
- Consumes: existing `admitPicked`, `jpegPickParams`, `_exit`/`_abandon` unchanged.

- [ ] **Step 1: Failing tests** — extend the picker-platform fake with the multi-pick method (`getMultiImageWithOptions`/`pickImageMulti` — match the platform-interface version's actual name) returning canned files: 3 picks → 3 staged shots named with sequential indexes in order, review pushed once; empty list → staged-session cancel goes to review / empty-session cancel pops to shell; thrower → snackbar + exit. Camera-mode suites must pass untouched (default param).
- [ ] **Step 2: Run** — expect FAIL (no source param yet).
- [ ] **Step 3: Implement** — branch on `widget.source` inside `_takePhoto` (single-pick path verbatim for camera; loop for gallery); keep `_launching` guard shared.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: CameraPage source parameter — gallery multi-pick admission`

### Task 3.1: QR confirm dialog source choice

**Files:**
- Modify: `lib/pages/scanner_page.dart` (`_onDetect` dialog + `_startCapture`)
- Test: `test/home_page_test.dart` (or the scanner's existing harness)

**Interfaces:**
- Produces: `_startCapture(String orderNumber, {required CaptureSource source})` pushing `CameraPage(source: source, ...)`; dialog actions `Rescan` (text) / `Take photo` (FilledButton, today's confirm semantics) / `Gallery` (FilledButton.tonal). Scanner stop/resume and `_processing` lifecycle untouched.

- [ ] **Step 1: Failing tests** — Gallery confirm → CameraPage opened with gallery source (assert via the picker fake receiving the multi-pick call, order chip text matches); Take photo confirm → camera path as today; Rescan → no flow.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — dialog returns an enum (`_ConfirmedSource { camera, gallery }` or null) instead of bool.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: QR confirm offers Take photo / Gallery`

### Task 3.2: Manual entry dialog source choice

**Files:**
- Modify: `lib/pages/scanner_page.dart` (`_showEntryDialog`)
- Test: same harness as 3.1

**Interfaces:**
- Produces: same `_ConfirmedSource` shape; actions `Cancel` / `Take photo` / `Gallery`, both confirms gated on non-empty trimmed value (share the existing `ValueListenableBuilder` enable logic); digits-only formatting untouched.

- [ ] **Step 1: Failing tests** — both confirms start the flow with their source when the field holds digits; both stay disabled while empty; Cancel starts nothing.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — mirror 3.1's dialog shape.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: manual entry confirms Take photo / Gallery`

### Task 4.1: Add-photo bottom sheet (batch on)

**Files:**
- Modify: `lib/pages/preview_page.dart`
- Test: `test/preview_page_test.dart`

**Interfaces:**
- Produces: `Future<void> _openCamera({required bool removeLast})` keeps its name/semantics for Retake; Add photo switches to `Future<void> _pickSource({required bool freshSession})` — shows `showModalBottomSheet` with Take photo / Choose from gallery, then either `_pushCamera()` on the same session or (4.2) fresh-session push with the chosen source. Keys: `source_sheet`, `sheet_take_photo`, `sheet_gallery`.

- [ ] **Step 1: Failing tests** — batch on, shots staged: tap Add photo → sheet visible (no navigation yet); choose camera → CameraPage pushed, staged shots intact; choose gallery → multi-pick fake fires, new shots join the same session with continuing indexes.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — sheet + wiring; Retake rows untouched.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: Add photo opens a Take photo / Choose from gallery sheet`

### Task 4.2: Done-state continuations open the sheet

**Files:**
- Modify: `lib/pages/preview_page.dart`
- Test: `test/preview_page_test.dart`

**Interfaces:**
- Consumes: 4.1's `_pickSource`. Produces: `_moreForThisOrder()` awaits the source choice first, then `CaptureSession.create` + push with that source; used by both "More for this order" (batch) and "Another photo (same order)" (single-shot). Dismissing the sheet cancels with no session created.

- [ ] **Step 1: Failing tests** — done state, batch on: More for this order → sheet → gallery → fresh session (index 001) opens picker; single-shot done: Another photo (same order) → sheet → camera → fresh session opens camera; sheet dismissed → no route pushed, page stays done.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — fold both buttons onto the shared path.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: done-state continuations offer the source choice`

### Task 4.3: Single-shot multi-pick through the existing review

**Files:**
- Modify: none expected (this task pins existing machinery to the new path; adjust only if an assertion fails)
- Test: `test/preview_page_test.dart`

**Interfaces:**
- Verifies: batch off + a session staged with 3 READY shots (via the gallery fake at capture start) → no chip/strip/Add-photo in the widget tree; newest shown full-screen; Retake removes exactly the newest and re-picks; Upload (injected fake) receives all three.

- [ ] **Step 1: Failing tests** (should mostly pass already — write them to lock the contract): the three assertions above; any failure is a real integration gap to fix here, not a test to weaken.
- [ ] **Step 2: Run** — PASS expected; fix code if not.
- [ ] **Step 3: Commit** `test: single-shot multi-pick review contract pinned`

### Task 5.1: Full verification walk

- [ ] **Step 1:** `flutter analyze && flutter test` — green.
- [ ] **Step 2:** Walk every delta-spec scenario (batch-capture: 10 scenarios across 4 requirements; manual-order-entry: 3; order-folders: 3) against the implementation; gaps become follow-up tasks, never silent skips.

### Task 5.2: Device pass (operator)

- [ ] **Step 1:** Scan → Gallery → 3-photo multi-pick → review → upload, folders ON: all three in `{share}/{order}/`, names sequential; repeat folders OFF: flat.
- [ ] **Step 2:** Single-shot gallery pick; Add photo → gallery mid-batch (indexing continues); More for this order via sheet.
- [ ] **Step 3:** Camera regression: capture start, Add photo, Retake, cancel from camera, cancel from gallery (both staged and empty sessions).
- [ ] **Step 4:** A HEIC (or known non-JPEG) gallery photo with Original preset → uploads as a valid `.jpg` openable on Windows.

### Task 5.3: CLAUDE.md updates

- [ ] **Step 1:** Capture-flow bullets: mention the gallery source, `CaptureSource`, the sheet affordances, and that admission/ordering/upload are source-independent; SMB layer note stays true (gallery shots ride the identical path); Tests section: multi-pick picker fake.
- [ ] **Step 2:** Read-through; commit `docs: gallery capture source`.

---

## Self-Review (performed on this plan)

1. **Spec coverage** — batch-capture "Gallery as an alternative capture source" → 2.1 (admission, multi-pick order, cancel), 3.1 (capture-start choice); "Source choice on review add and continue" → 4.1, 4.2 (both continuations); "Source availability independent of the batch toggle" → 2.1/4.2 (no batchMode branch anywhere) + 4.3 (single-shot multi-pick pinned); "Single-shot parity (MODIFIED)" → 4.3; manual-order-entry "Hand-off (MODIFIED)" → 3.2; order-folders "Folder-targeted upload (MODIFIED)" → no code by design (D6), scenario verified on device in 5.2 — the shared uploader path makes it structural. No gaps.
2. **Placeholder scan** — no TBD/TODO steps; every task names its files, test seam, and verify command.
3. **Type consistency** — `CaptureSource` (2.1) consumed by 3.1/3.2/4.1/4.2; `_startCapture(..., {required CaptureSource source})` consistent across 3.1/3.2; `_pickSource` (4.1) reused by 4.2; processor seam unchanged per D8 so `CopyOnlyProcessor` and existing fakes stay valid; the platform-interface multi-pick method name is pinned against the installed `image_picker_platform_interface` in 2.1 Step 1 (its exact name is version-dependent — the test must match what the app code calls).
