# brainstorm — gallery-upload-option

Raw capture of the superpowers:brainstorming session for adding a gallery
(photo-picker) upload option alongside the system camera. Format: context
findings → decision chain → technical findings → trade-offs weighed.

## Background

The request arrived as a change name only: `gallery-upload-option` — let the
operator pick existing photos from the device gallery as an upload source,
instead of (or alongside) photographing the item with the system camera.

Classification: bounded — the flow it extends (ScannerPage → CameraPage →
PreviewPage → CaptureSession → uploadSession) exists in the repo to read.

Key context found during exploration:

- The folder-bundling proposal already anticipated this feature: admission
  was built "source-agnostic — camera now, gallery later"
  (`admitPicked` takes any `pickedPath`). No session/naming/upload changes
  are required by a new source.
- `CameraPage` is TRANSIENT by contract: it exists only to launch a picker
  the moment it appears, admit the pick, and exit two ways (staged →
  review via pushReplacement; empty → pop to Scan tab). Every outcome
  leaves the page; there is no idle screen.
- `PreviewPage` owns the re-entry points: "Add photo" (batch on) and the
  done-state continuations ("More for this order" / "Another photo (same
  order)") push CameraPage on the same or a fresh session.
- `image_picker` 1.2.3 is already the capture dependency;
  `pickMultiImage` exists and accepts the same `maxWidth`/`maxHeight`/
  `imageQuality` params the camera path feeds from `jpegPickParams`.
- Tests fake the picker via `ImagePickerPlatform.instance`
  (`_FakePickerPlatform` in `test/preview_page_test.dart`) — a gallery
  picker is testable through the same seam, no production testability
  work needed.
- Batch mode (`upload.batchMode`) gates only review-page UI affordances
  (strip, Add photo, count chip); the session and uploader are
  mode-agnostic — `uploadSession` uploads the READY subset either way.

## Decision chain

### Q1 — Where is gallery picking offered? (asked, multiple choice)

Options: capture start + review / review page only / capture start only.

**Decision: capture start + review.** After confirming the order number
the operator chooses camera or gallery; in review, a gallery affordance
sits next to the existing camera one. Gallery is a first-class source
everywhere the camera is.

### Q2 — Multi-select? (asked, multiple choice)

Options: multi-select via pickMultiImage / single photo per pick.

**Decision: multi-select.** One gallery visit can admit several photos;
each is admitted in picker order (001, 002, 003 …) and lands in review.

### Q3 — Single-shot mode (batch off)? (asked, multiple choice)

**Decision (user's own words, superseding the offered options): gallery is
unaffected by the setting.** Then, mid-exploration, two clarifications
arrived:

1. "Gallery mode should allow for multiple or single uploads no matter the
   settings." — the picker offers/accepts single and multi picks in BOTH
   batch modes; no `batchMode` gating anywhere in the gallery path.
2. "However it should be affected by the folder setting." — gallery
   uploads MUST honor `useOrderFolders` exactly like camera uploads.

Both are satisfied by construction (gallery picks ride the same
`CaptureSession` → `uploadSession` path) and both are made contractual in
the specs so no future gallery-specific upload path can quietly bypass
them.

### Q4 — Where exactly does the source choice live at each entry point? (derived, not asked)

The remaining forks were engineering judgment calls, resolved as follows:

- **Capture start**: the choice lives INSIDE the existing confirm dialogs
  (QR confirm and manual entry) as two positive actions — "Take photo"
  (primary) and "Gallery" (secondary) — replacing the single "Use this".
  Rejected: a second chooser dialog after "Use this" (an extra tap on the
  dominant camera path) and a chooser page (a new flow stage for a
  two-way choice).
- **Review, batch on**: "Add photo" opens a modal bottom sheet — Take
  photo / Choose from gallery. Rejected: a fourth button in the action
  row (that row already squeezes at 360 dp — the waiting button carries
  an ellipsize workaround documented in code).
- **Review, single-shot**: the idle row stays Retake | Upload — there is
  no add affordance in single-shot mode today and adding one would give
  gallery a capability the camera path lacks mid-review. Single-shot
  gallery access is at capture start and via the done-state continuation.
- **Done-state continuations** ("More for this order" batch-on, "Another
  photo (same order)" single-shot): both open the same source sheet on a
  fresh session — otherwise a single-shot operator who picked gallery
  would be forced back to the camera for their next photo of the order.
- **Retake stays camera-only** — "retake" means re-photograph THIS shot;
  replacing a bad shot from the gallery is a different action and out of
  scope.
- **One page, two sources**: `CameraPage` gains a `CaptureSource`
  parameter (default camera) instead of a sibling gallery page. The
  transient contract (immediate launch, admit, two-way exit, abandon
  snackbar) is the subtle part — it must have exactly one home.
- **Format guard** (see technical findings): `NativeImageProcessor`
  sniffs JPEG magic bytes when the reserved name ends `.jpg` and
  re-encodes non-JPEG source bytes to full-size quality-100 JPEG, so the
  uploaded file's bytes always match its extension. `.png` destinations
  already go through the codec for any decodable source.

## Technical findings that shaped the design

- `pickMultiImage` (image_picker 1.2.3) accepts `maxWidth`/`maxHeight`/
  `imageQuality`, BUT compression applies only to certain formats
  (JPEG; on Android also PNG/WebP) — for an unsupported source format the
  quality setting is silently skipped. With the Original preset (no
  params at all) a gallery pick is delivered as-is.
- Consequence: a HEIC gallery photo (some phones save HEIF by default)
  would be byte-copied under a `.jpg` name — a silently corrupted upload
  that Windows consumers of the share cannot open. Camera picks can never
  hit this (the camera always returns JPEG), which is why the guard did
  not exist yet.
- Cancel from the multi-picker surfaces as an empty list (vs `null` from
  the single picker); both map to today's cancel path.
- `uploadSession` uploads the READY subset passed to it; a multi-pick
  staged in single-shot mode therefore uploads all its shots through the
  ordinary Upload button with no new upload logic.

## What did NOT change under question

- No new settings and no storage keys — the user explicitly tied gallery
  to the EXISTING settings (unaffected by batch mode, affected by folder
  mode) rather than adding a gallery toggle.
- Naming, session lifecycle, admission, upload, retry, History — all
  unchanged; a gallery shot is indistinguishable from a camera shot once
  admitted.
