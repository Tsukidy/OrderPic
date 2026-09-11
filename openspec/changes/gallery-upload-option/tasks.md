# gallery-upload-option — implementation tasks

## 1. Format-safety guard (processor core, no UI)

- [x] 1.1 JPEG magic-byte guard in `NativeImageProcessor`: when the reserved name ends `.jpg` and the source's leading bytes are not `FF D8`, re-encode to JPEG (full-size sentinel, quality 100) and write those bytes; JPEG sources and `.png` destinations keep today's exact behavior; unit tests in `test/image_processor_test.dart` — copy path unchanged for JPEG bytes, re-encode path invoked (fake the compress call or test the sniff helper) for HEIC-magic bytes, failure thrown into the existing flagged-retake contract (`flutter analyze` + `flutter test` green)

## 2. CameraPage as the one transient picker page (two sources)

- [x] 2.1 `CaptureSource { camera, gallery }` enum + `CameraPage.source` parameter (default camera, all existing call sites untouched); gallery mode calls `pickMultiImage` with the same `jpegPickParams` mapping (null params for PNG/Original), admits every returned file in order via `admitPicked`, then does the single `pushReplacement` to review; launch caption follows the source ("Opening camera…" / "Opening gallery…")
- [x] 2.2 Cancel/throw semantics for the multi-picker: empty list OR null → today's cancel path (`_exit`: staged → review, empty → cleanup + pop to Scan tab); picker exception → `_abandon` snackbar + two-way exit; widget tests via the `ImagePickerPlatform` seam — extend the fake with a multi-pick method returning a canned list / empty list / thrower; cover staged-session cancel, empty-session cancel, crash abandon, and 3-pick admission ordering (001/002/003)

## 3. Capture-start source choice (scanner dialogs)

- [x] 3.1 QR confirm dialog grows the second positive action: `Rescan` / `Take photo` (filled) / `Gallery` (tonal); either confirm runs `_startCapture` with the chosen source — session creation, scanner stop/resume, and `_processing` handling unchanged; widget tests in `test/home_page_test.dart`-style harness for both confirm actions launching the matching source
- [x] 3.2 Manual entry dialog: `Cancel` / `Take photo` / `Gallery`, both confirms behind the existing empty-value gate and digits-only input; widget tests for both confirm actions and the shared gate

## 4. Review source sheet (add + continue)

- [ ] 4.1 Batch-on "Add photo" opens a modal bottom sheet — Take photo / Choose from gallery — then pushes `CameraPage` with the chosen source on the SAME session (no retake-rollback); widget tests: sheet appears, camera choice preserves staged shots, gallery choice admits into the same session with continuing indexes
- [ ] 4.2 Done-state continuations open the same sheet before creating the fresh session: "More for this order" (batch on) and "Another photo (same order)" (batch off); either source starts `CaptureSession.create(orderNumber)` and pushes the chosen source; widget tests for both rows × both sources
- [ ] 4.3 Single-shot multi-pick through the existing review: with batch off, a session holding 3 gallery picks shows the newest full-screen with no batch chip/strip/Add-photo, Retake drops only the newest, Upload uploads all READY shots (existing `_uploadAll` covers it — assert via injected uploader); the done-state sheet from 4.2 is the only single-shot gallery re-entry point

## 5. Verification & docs

- [ ] 5.1 Full `flutter analyze && flutter test` green; walk the six delta-spec requirements against the implementation (batch-capture ×3, manual-order-entry ×1, order-folders ×1 scenarios) and note gaps as follow-up tasks, not silent skips
- [ ] 5.2 Device pass (operator): scan → Gallery → 3-photo multi-pick → review → upload with folders ON (`{share}/{order}/` gets all three) and OFF (flat); single-shot gallery pick; Add photo → gallery mid-batch; camera regression pass (capture start, Add photo, retake, cancel); HEIC sample from gallery with Original preset → uploads as a valid `.jpg`
- [ ] 5.3 CLAUDE.md updates: capture-flow bullet mentions the gallery source + `CaptureSource` parameter; SMB layer note that gallery shots ride the identical session→upload path; tests section notes the multi-pick picker fake
