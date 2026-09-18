# gallery-upload-option — proposal

## Why

Every upload today must be photographed live with the system camera, but
the item photos an operator needs sometimes already exist on the device —
shot earlier the same day, shared by a colleague, or saved from another
app. Forcing a re-shoot wastes time and can produce a worse photo than the
one already in the gallery. The capture pipeline was built source-agnostic
for exactly this (`admitPicked` takes any picked file; folder-bundling's
proposal says "camera now, gallery later"), so adding the gallery is now a
UI entry-point change plus one format-safety guard — no session, naming,
or upload rework.

## What Changes

**Capture start (QR confirm and manual entry dialogs)**
- From: one confirm action ("Use this") that always opens the system camera
- To: two confirm actions — "Take photo" (primary) and "Gallery"
  (secondary) — either starts the flow for the confirmed order number with
  the chosen source, no further confirmation step
- Reason: the operator should choose the source where they already confirm
  the order, not through an extra dialog
- Impact: one extra visible action in both dialogs; the camera path stays
  the default/primary

**CameraPage — one transient picker page, two sources**
- From: `CameraPage` always launches `pickImage(source: camera)` and
  admits one shot
- To: `CameraPage` takes a `CaptureSource` (default camera); gallery
  launches `pickMultiImage` with the same quality/edge params and admits
  every pick in order (001, 002, …) before review opens
- Reason: the transient contract (immediate launch, admission, two-way
  exit) must have exactly one home; a sibling page would drift
- Impact: cancel/throw/exit behavior is shared unchanged; launch caption
  reflects the source ("Opening gallery…")

**Review page — source choice on add and continue**
- From: "Add photo" (batch on) always reopens the camera; done-state
  continuations ("More for this order" / "Another photo (same order)")
  always reopen the camera on a fresh session
- To: both open a bottom sheet — Take photo / Choose from gallery — on the
  same or fresh session respectively
- Reason: keeps the three-button action row (already tight at 360 dp)
  while making the gallery reachable mid-batch and on the next pass
- Impact: one extra tap for camera users on these two affordances; the
  capture-start and retake paths are unchanged

**Settings interaction (explicit, no new settings)**
- From: n/a — behavior clarification, not a toggle
- To: gallery picking is available and multi-select-capable regardless of
  the batch toggle, and gallery uploads follow the per-order folders
  toggle exactly like camera uploads
- Reason: user-directed — the gallery is a source, not a mode; folder
  placement must not depend on how a photo was obtained
- Impact: none in code (same session → uploader path); spec scenarios make
  both contractual

**Format safety for gallery sources**
- From: the JPEG path byte-copies picks (safe: the camera always returns
  JPEG)
- To: the processor sniffs the source's magic bytes when the reserved name
  ends `.jpg` and re-encodes non-JPEG bytes (e.g. HEIC, which the photo
  picker can deliver because pick-time compression is format-gated) to
  full-size quality-100 JPEG — uploaded bytes always match the extension
- Reason: a HEIC file named `.jpg` uploads silently and is unopenable on
  the Windows side — a broken filename contract
- Impact: `NativeImageProcessor` only; the `ImageProcessor` seam and test
  fakes are unchanged; failures land in the existing flagged-retake path

## Capabilities

### New Capabilities

(none — the gallery is a new source inside the existing capture
capability, not a new behavior family)

### Modified Capabilities

- `batch-capture`: gallery as an alternative capture source at capture
  start and on review add/continue; source and multi-select availability
  independent of the batch toggle; the single-shot parity requirement is
  narrowed to the review UI (a single-shot session may hold several
  gallery picks)
- `manual-order-entry`: the entry dialog's confirm action becomes two
  per-source confirm actions; either starts the flow with the typed
  number
- `order-folders`: an explicit scenario pinning that gallery-sourced
  photos follow the folder setting

## Impact

- Code: `lib/pages/scanner_page.dart` (two dialogs), `lib/pages/camera_page.dart`
  (source parameter, multi-pick admission), `lib/pages/preview_page.dart`
  (bottom sheet on add/continue), `lib/capture/image_processor.dart`
  (JPEG magic-byte guard)
- Tests: `test/preview_page_test.dart` (picker platform seam extended with
  a multi-pick fake), `test/image_processor_test.dart` (format guard)
- Dependencies: none added
- No storage keys, no migration, no server/SMB changes; fully
  feature-flag-free additive UI with an existing-settings contract
