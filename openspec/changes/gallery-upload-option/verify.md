# gallery-upload-option — verification report

Verified 2026-09-12 on branch `worktree-gallery-upload-option` (HEAD `9ece12b`),
against base `013114b` (main). Evidence: controller's in-session 5.1
requirement walk, five task-scoped reviews, one final whole-branch review
(opus) plus an accepted scoped fix re-review, `flutter analyze` clean and
`flutter test` 173/173 green at the code-identical state.

## Summary

| Dimension    | Status |
|--------------|--------|
| Completeness | 10/11 tasks — the one open task (5.2) is the operator device pass; 6/6 delta requirements implemented |
| Correctness  | 6/6 requirements implemented; 15/15 delta scenarios covered (13 test-pinned, 2 structural/device) |
| Coherence    | D1–D10 followed; two intentional, documented, test-pinned deviations; patterns consistent |

## Completeness

Tasks 1.1, 2.1, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3, 5.1, 5.3 complete and reviewed.
Production diff touches exactly `lib/capture/image_processor.dart`,
`lib/pages/camera_page.dart`, `lib/pages/preview_page.dart`,
`lib/pages/scanner_page.dart` — `uploader.dart`, `session.dart`,
`naming.dart`, `history_page.dart` untouched, making the order-folders and
History requirements structural (design D6).

- **CRITICAL (blocks archive):** Task 5.2 (device pass) is unchecked — it
  requires a physical device + LAN share and cannot be executed in this
  environment. Recommendation: operator performs the pass (scan → Gallery →
  3-pick → upload with folders ON (`{share}/{order}/`) and OFF (flat);
  single-shot gallery pick; Add photo → gallery mid-batch; camera regression;
  HEIC sample with Original preset → valid `.jpg`), or explicitly defers it —
  archive waits on that decision.

## Correctness

Requirement → implementation → test mapping (full walk in the SDD ledger):

1. **batch-capture / Gallery as an alternative capture source** — dialogs
   (`scanner_page.dart`, both confirms → `_startCapture(source:)`),
   `CameraPage` gallery branch (`pickMultiImage` via the pinned
   `getMultiImageWithOptions`, admits in picker order, single hand-off),
   extension-contract guard (`image_processor.dart` sniff + full-size
   quality-100 re-encode). Pinned: QR+entry Gallery suites,
   3-pick ordering × both batch modes (001/002/003), staged-cancel → review,
   empty-cancel → shell + dir reclaim, thrower → abandon.
2. **batch-capture / Source choice on review add and continue** —
   `_pickSource` sheet (keys `source_sheet` / `sheet_take_photo` /
   `sheet_gallery`) on Add photo (same session) and both done-state rows
   (fresh session after choice; dismissal = zero trace, disk-witnessed);
   Retake camera-only (call-site audit + suite). Pinned: sheet suites ×4,
   done-state suites ×4 incl. single-shot × gallery.
3. **batch-capture / Source availability independent of the batch toggle** —
   no `batchMode` read anywhere in the gallery path (reviewer grep-verified
   at three tasks); batch-off CameraPage pin proven to bite via a temporary
   regression; single-shot multi-pick review group (no chip/strip/Add photo,
   newest full-screen, Retake drops only newest, uploader receives all READY
   via `only:`).
4. **batch-capture MODIFIED / Single-shot parity** — pre-existing single-shot
   suites green untouched; absence assertions by key AND label; fresh-session
   numbering restart pinned (`_001`).
5. **manual-order-entry MODIFIED / Hand-off** — `Cancel` / `Take photo` /
   `Gallery` behind ONE shared empty-value gate; digits-only formatters
   untouched (context lines); scanner stop/resume + `_processing` lifecycle
   unchanged; scanning-resumes-after-flow is pre-existing untouched behavior
   verified by context lines + the reopen-proves-lock suite.
6. **order-folders MODIFIED / Folder-targeted upload** — uploader untouched;
   placement source-independent by construction. Scenario "gallery-sourced
   photos follow the folder setting": structural + device pass (5.2).

Scenario coverage notes: the "Gallery shots upload like camera shots"
scenario's History-listing clause is structural (untouched code); the
"Backing out of the photo picker cancels" shape is pinned for the multi-picker's
real cancel shape (empty list) — a null multi-pick result cannot surface
through the installed platform interface (non-nullable `Future<List<XFile>>`),
verified against the installed package source.

## Coherence

- D1–D10 followed. Final review: "faithful to all six delta requirements and
  D1–D10 … no code changes are needed."
- Intentional deviations, documented and test-pinned: (a) multi-pick passes
  `maxWidth`+`imageQuality` only, mirroring today's camera call (plan text
  wrote `maxHeight`; the camera leg never passed one); (b) dialogs return
  `CaptureSource?` directly instead of a private `_ConfirmedSource` enum
  (plan's "e.g." shape).
- Parked `autoFixOrientation` concern CLOSED with evidence: the installed
  flutter_image_compress defaults `autoCorrectionAngle` to true and bakes EXIF
  orientation into re-encoded pixels; `keepExif: false` is correct (no stale
  orientation tag on upright output). The 5.2 HEIC sample remains the
  empirical confirmation.
- Final-review fix wave (accepted by scoped re-review): delta-spec Retake
  scenario reworded to camera semantics (D10); `ImageProcessor.process`
  interface doc states the real `.jpg` contract; CLAUDE.md documents the
  guard.

## Final assessment

No critical issues **except the operator-gated 5.2 device pass**; one
deliberate process gate, not an implementation defect. All code, spec, and
doc findings from the final review are fixed and re-reviewed. **Ready for
archive once 5.2 is performed by the operator or explicitly deferred.**

## Overall Decision

- [ ] ✅ PASS — 可進入 finishing-a-development-branch 與 archive
- [x] ⚠️ PASS WITH WARNINGS — 可進入後續步驟但需注意：implementation,
      specs, and docs all pass every check executable in this environment
      (173/173 tests, analyze clean, final whole-branch review clean after an
      accepted fix wave); the single open item is the operator-gated 5.2
      device pass — archive waits on the operator performing it (or
      explicitly deferring)
- [ ] ❌ FAIL — 返回失敗的 artifact 修正後重跑 verify

**下一步**：operator performs Task 5.2 on this branch (folders ON/OFF
upload, single-shot gallery pick, mid-batch gallery add, camera regression,
HEIC sample) → then retrospective → archive → PR.
