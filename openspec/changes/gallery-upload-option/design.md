# gallery-upload-option — design

## Context

The capture flow is `ScannerPage` (QR scan or manual entry) → confirm →
`_startCapture` creates the `CaptureSession` → `CameraPage` (transient:
launches the system camera the moment it appears) → `admitPicked` reserves
name/index and stages a PENDING shot whose conversion runs in the
background → `pushReplacement` to `PreviewPage` (review / retake / add /
upload). Admission was deliberately built source-agnostic —
`admitPicked({pickedPath, ...})` takes any picked file — and
folder-bundling's proposal named this change as the planned "gallery
later".

Constraints that shape the design:

- `CameraPage`'s transient contract (no idle screen; every outcome leaves
  the page; two-way exit — staged → review, empty → Scan tab) is the most
  subtle part of the flow and must not be duplicated.
- The review action row is width-fragile at 360 dp (the waiting button
  already ellipsizes via a documented workaround) — a fourth button is not
  a safe way to add an affordance there.
- The filename contract (`{Order}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png`)
  binds the uploaded BYTES to the name's extension; History and the
  Windows consumers depend on it.
- image_picker 1.2.3: `pickMultiImage` accepts the same
  `maxWidth`/`maxHeight`/`imageQuality` params as `pickImage`, but
  pick-time compression is format-gated (JPEG; on Android also PNG/WebP) —
  unsupported sources (HEIC) pass through untranscoded, and the Original
  preset passes no params at all.
- Tests fake the picker via `ImagePickerPlatform.instance`
  (`_FakePickerPlatform`) — the seam already exists for a multi-pick fake.

User-directed constraints (from the brainstorming session):

- Gallery allows single or multiple picks **no matter the settings** — no
  `batchMode` gating anywhere in the gallery path.
- Gallery uploads **are** affected by the per-order folders setting —
  identical placement rules to camera uploads.

## Goals / Non-Goals

**Goals:**

- The operator can pick existing gallery photos as the upload source at
  capture start (both entry dialogs) and during review (add / continue),
  choosing several photos in one visit.
- A gallery shot is indistinguishable from a camera shot once admitted:
  same naming, session lifecycle, WYSIWYG processing, review, upload,
  retry, and History behavior.
- Uploaded bytes always match the reserved name's extension, whatever the
  gallery delivered.
- Zero regression risk on the camera path: shared code paths, camera
  behavior byte-identical when the new parameter is left at its default.

**Non-Goals:**

- No new settings and no storage keys — the gallery reuses the existing
  batch/folder/format/quality settings per the user's direction.
- No camera replacement in Retake — "retake" stays re-photograph.
- No multi-pick cap (`limit` stays unset) and no gallery-only review UI —
  picked shots use the existing review surface.
- No picker-source abstraction beyond the one enum parameter — YAGNI; a
  future source (file picker) can add another enum value.

## Decisions

### D1: Source choice lives inside the existing confirm dialogs

- **Choice**: the QR confirm dialog and the manual entry dialog each grow
  a second positive action. QR: `Rescan` / `Take photo` (filled, primary)
  / `Gallery` (tonal). Manual entry: `Cancel` / `Take photo` / `Gallery`
  (confirm stays disabled while the field is empty — both confirm actions
  share the existing gate). Either confirm starts `_startCapture` with the
  chosen source; the session is created exactly as today.
- **Why**: the operator already confirms the order at that moment; the
  source is a one-tap qualifier on that confirmation, and the camera stays
  the primary action on the dominant path.
- **Alternatives considered**: a second "Camera or gallery?" dialog after
  "Use this" — rejected (an extra tap on every capture, and the hot path
  is the camera); a chooser page pushed instead of `CameraPage` — rejected
  (a new flow stage and route for a two-way choice).

### D2: One transient page, parameterized source

- **Choice**: `CameraPage` gains `final CaptureSource source` (enum
  `{ camera, gallery }`, default `camera`; class and file keep their
  names). Gallery mode calls `pickMultiImage` with the same
  `jpegPickParams` mapping, admits each returned file in picker order via
  `admitPicked` (indexes advance 001, 002, … automatically), then does the
  single `pushReplacement` to review. The launch caption follows the
  source ("Opening camera…" / "Opening gallery…").
- **Why**: the transient contract — immediate launch, admission, two-way
  exit, abandon snackbar — is the subtle, regression-prone part; it must
  have exactly one home. A sibling `GalleryPage` would copy it and drift.
- **Alternatives considered**: a separate `GalleryPage` class — rejected
  (duplicated exit/abandon contract); extracting a shared base class —
  rejected for now (one enum parameter achieves the same single-home
  property with less machinery; revisit only if a third source arrives).

### D3: Cancel and error semantics for the multi-picker

- **Choice**: the multi-picker's cancel surfaces as an empty list (the
  single picker returns null) — both map to today's cancel path
  (`_exit`: staged → review, empty → cleanup + pop to Scan tab). A picker
  exception keeps the `_abandon` contract (snackbar + two-way exit). If
  some files were picked, admission is all-or-nothing only in the sense
  that a throw before any pick is handled by `_abandon`; a throw cannot
  occur mid-list because `pickMultiImage` returns only after the picker
  closes.
- **Why**: keeps the page's outcome contract verbatim — every outcome
  leaves the page; nothing new to learn.
- **Alternatives considered**: partial-admission recovery UI — rejected
  (unreachable state per the plugin's return shape).

### D4: Review add/continue affordances open a source bottom sheet

- **Choice**: batch-on "Add photo" opens a modal bottom sheet —
  "Take photo" / "Choose from gallery" — then pushes `CameraPage` with the
  chosen source on the same session. The done-state continuations
  ("More for this order" batch-on, "Another photo (same order)"
  single-shot) open the same sheet, then create the fresh session and push
  the chosen source (today they push the camera directly).
- **Why**: adds the gallery without a fourth button in an action row that
  already squeezes at 360 dp, and it is the platform-idiomatic pattern for
  a two-way source choice.
- **Alternatives considered**: a fourth compact icon button — rejected
  (documented narrow-row overflow pain in `_bottomButtons`); renaming
  "Add photo" to "Add" with both actions in the sheet only — rejected
  (keeps an extra tap on the common camera case).

### D5: Source availability independent of the batch toggle (user-directed)

- **Choice**: no `batchMode` branch anywhere in the gallery path. The
  capture-start choice and the done-state sheet exist in both modes, and
  `pickMultiImage` is used in both modes — a single-shot operator may
  stage several shots in one pick. The single-shot review row itself is
  unchanged (Retake | Upload): it shows the newest shot full-screen
  (no strip — that stays batch UI), Retake drops the newest, and the
  ordinary Upload already uploads the whole READY subset, which is exactly
  the multi-pick semantics.
- **Why**: the user said "multiple or single uploads no matter the
  settings"; the session/uploader machinery is mode-agnostic already, so
  gating the picker would add a branch with no protective value.
- **Alternatives considered**: single-select in single-shot mode (the
  brainstorm's original suggestion) — overridden by the user's
  clarification.

### D6: Folder and upload settings apply unchanged (user-directed)

- **Choice**: gallery shots ride `CaptureSession` → `uploadSession` like
  camera shots, so `useOrderFolders` placement, format/quality, one-connection
  batching, per-shot retry, and History rendering are source-independent
  by construction. The only deliverable is a spec scenario pinning it (no
  code).
- **Why**: the user explicitly tied the gallery to the folder setting;
  making it contractual prevents a future gallery-specific upload path
  from quietly bypassing it.
- **Alternatives considered**: none — this is the existing architecture.

### D7: Same pick-time processing params for gallery

- **Choice**: `_takePhoto`'s params logic (`format == jpeg ?
  jpegPickParams(prefs) : null`) feeds `pickMultiImage`'s
  `maxWidth`/`maxHeight`/`imageQuality` exactly as it feeds `pickImage`'s
  today; PNG mode keeps passing null and relies on the lossless
  conversion.
- **Why**: identical WYSIWYG semantics — the reviewed file is the
  processed file, whatever the source.
- **Alternatives considered**: skipping pick-time params for gallery and
  re-encoding in the processor — rejected (duplicates the plugin's
  well-tested pick-time path and would change Original-preset semantics
  for ordinary JPEGs).

### D8: Extension-contract guard in the processor (JPEG magic-byte sniff)

- **Choice**: in `NativeImageProcessor.process`, when the reserved name
  ends `.jpg`, read the source's first bytes; if they are not the JPEG
  magic (`FF D8`), re-encode via `FlutterImageCompress.compressWithFile`
  to JPEG at full size (`minWidth`/`minHeight` = the existing
  `_fullSizeEdge` sentinel) and quality 100 — the closest thing to
  "Original" for a file that must become JPEG — and write those bytes.
  `.png` destinations are unchanged (the codec already converts any
  decodable source). `ImageProcessor`'s seam signature, `CopyOnlyProcessor`,
  and all existing fakes are untouched; a decode failure throws into the
  existing failed-conversion path (flagged entry, retake offer, batch
  intact).
- **Why**: pick-time compression is format-gated and Original passes no
  params, so a HEIC gallery photo would otherwise be byte-copied under a
  `.jpg` name — a silently corrupted upload that Windows cannot open. The
  camera can never hit this (it always returns JPEG), which is why the
  guard arrives with this change and not before.
- **Alternatives considered**: trusting the plugin to always transcode —
  rejected (documented format-gating; silent failure mode); always
  re-encoding every gallery pick — rejected (needlessly re-compresses
  ordinary JPEGs under the Original preset); a pre-pick format check in
  the page — rejected (the processor is where bytes become the named file;
  the check belongs next to the write).

### D9: Multi-pick ordering and count

- **Choice**: admission order = the picker's returned order; `nextIndex`
  stamps 001, 002, 003 … across the batch, including when a gallery pick
  mixes with later camera adds in the same session. No cap is imposed
  (`limit` unset).
- **Why**: `admitPicked` already reserves names synchronously in call
  order; timestamps distinguish same-second files and the per-shot index
  keeps ordering deterministic. A cap would be an arbitrary policy the
  user did not ask for.
- **Alternatives considered**: capping at some batch size — rejected
  (YAGNI; the upload gate already waits for all pending conversions).

### D10: Retake stays camera-only

- **Choice**: "Retake" / "Retake this photo" / "Retake failed photo" keep
  launching the camera.
- **Why**: "retake" semantically means re-photograph THIS shot; replacing
  it from the gallery is a different action (with different expectations
  about which shot gets replaced) and out of scope.
- **Alternatives considered**: gallery-replacement on retake — deferred
  (a separate request if wanted).

## Risks / Trade-offs

- [Risk] Photo-picker UX and HEIC decode support vary by Android
  version/model → Mitigation: the picker is the system's own (no custom
  UI to drift); any decode failure lands in the existing
  failed-conversion path — visible flag, retake offer, batch intact.
- [Risk] A large multi-pick queues many background conversions and the
  upload gate waits for all of them → Mitigation: conversions are already
  concurrent-safe and cancellable per entry; the count chip and waiting
  button surface progress; accepted as user-directed (no cap).
- [Trade-off] The add/continue bottom sheet adds one tap for camera users
  on those two affordances → Accepted: keeps the 360 dp action row stable
  and the pattern matches platform conventions for source choice.
- [Trade-off] D8's fallback re-encode is quality-100 full-size, which can
  exceed a chosen preset's size when the plugin skipped compression for
  an exotic format → Accepted: correctness of the extension contract
  outweighs size fidelity in an edge case; ordinary JPEGs never enter
  this path.
- [Risk] The multi-picker cancel shape (empty list vs null) differs
  across plugin versions → Mitigation: D3 treats both as cancel; the
  fake-based tests pin the contract.

## Migration Plan

N/A — no deployment, storage, or dependency changes. Rollback is a plain
revert: the only touched shared code is `CameraPage` (new parameter,
default preserves today's behavior byte-for-byte) and
`NativeImageProcessor` (guard is a no-op for JPEG sources). Acceptance:
`flutter analyze` + `flutter test` green; device pass covering scan →
gallery multi-pick → review → upload with folders on and off, plus the
camera regression paths.

## Open Questions

None — all forks were resolved in the brainstorming session (entry
points, multi-select, settings interaction) or by the decisions above.
