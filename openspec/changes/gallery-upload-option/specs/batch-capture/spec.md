# batch-capture delta — gallery-upload-option

## ADDED Requirements

### Requirement: Gallery as an alternative capture source

At capture start, after the operator confirms an order number (scanned or
typed), the flow MUST offer two sources — camera (primary) and gallery —
and choosing the gallery MUST open the system photo picker instead of the
system camera for that order's session. Every photo the operator picks
MUST be admitted exactly as a camera shot: processed per the configured
format and quality, named per the capture-time filename scheme with the
next session index, staged for review, and uploaded like any other shot.
Picking several photos in one visit MUST admit all of them in the picker's
returned order with sequential session indexes. Backing out of the photo
picker without picking MUST cancel exactly as backing out of the camera
does: return to review when shots are already staged, otherwise leave the
capture flow.

#### Scenario: Gallery choice opens the photo picker for the order

- **WHEN** the operator scans an order, confirms it with the Gallery
  action, and picks two photos from the photo picker
- **THEN** the review screen opens showing those two shots staged for
  order `<order number>`, admitted like camera shots

#### Scenario: Multi-pick admits photos in order

- **WHEN** the operator picks three photos in one gallery visit
- **THEN** the session stages three shots whose filenames carry three
  sequential session indexes (001, 002, 003) in the picker's returned
  order, and all three are processed per the configured format and quality

#### Scenario: Gallery shots upload like camera shots

- **WHEN** the operator uploads a session that contains gallery-picked
  shots
- **THEN** the uploaded files appear on the share named per the
  capture-time filename scheme with the configured extension and are
  listed by History like camera uploads

#### Scenario: Backing out of the photo picker cancels

- **WHEN** the operator opens the gallery from capture start and returns
  without picking any photo
- **THEN** the flow exits as it does when backing out of the system
  camera: review if shots are already staged, otherwise back to the Scan
  screen

---

### Requirement: Source choice on review add and continue

The review screen's add and continuation affordances MUST offer both
sources. With the batch toggle on, Add photo MUST present Take photo and
Choose from gallery, and either choice MUST return to the picker page on
the same session. The post-upload continuations — More for this order
(batch on) and Another photo (same order) (batch off) — MUST present the
same source choice and start the fresh session with the chosen source.
Retake MUST keep launching the camera.

#### Scenario: Add photo offers both sources

- **WHEN** the operator taps Add photo during a batch review and chooses
  Choose from gallery, then picks two photos
- **THEN** those two shots join the existing session (numbering continues
  from where it stood) and the review screen shows the grown batch

#### Scenario: More for this order starts fresh with the chosen source

- **WHEN** a batch upload completes and the operator taps More for this
  order, then chooses Take photo
- **THEN** a fresh session for the same order number opens the system
  camera with its index restarted at 001

#### Scenario: Another photo (same order) offers the gallery in single-shot mode

- **WHEN** a single-shot upload completes and the operator taps Another
  photo (same order), then chooses Choose from gallery and picks one photo
- **THEN** a fresh session for the same order number opens the photo
  picker and the picked shot is staged for review

---

### Requirement: Source availability independent of the batch toggle

The gallery source and its multi-select capability MUST be available in
both batch modes: no part of the gallery path (capture-start choice,
review source sheet, picker selection count) MAY be gated on the batch
toggle. A multi-photo gallery pick in single-shot mode MUST stage every
picked photo in the session; the single-shot review screen MUST keep its
non-batch presentation while doing so.

#### Scenario: Single-shot multi-pick stages and uploads everything

- **WHEN** the batch toggle is off and the operator picks three gallery
  photos at capture start, then taps Upload
- **THEN** all three processed shots upload, with no batch chip,
  thumbnail strip, or Add photo affordance shown at any point

#### Scenario: Gallery availability does not read the batch toggle

- **WHEN** the operator starts a capture in either batch mode
- **THEN** the same source choice (camera or gallery) is offered, and the
  gallery accepts one or several photos regardless of the mode

---

## MODIFIED Requirements

### Requirement: Single-shot parity when batch is off

With the batch toggle off, the review screen MUST keep the single-shot
experience: no batch chip, thumbnail strip, or Add photo affordance SHALL
appear, and the newest staged shot is reviewed full-screen. The
capture-start source choice and the post-upload continuation's source
choice MUST remain available in single-shot mode (see the gallery-source
requirements), and a gallery pick MAY stage multiple photos in a
single-shot session. When it does, Retake MUST discard only the most
recently staged shot and Upload MUST upload every processed (READY) shot.

#### Scenario: Batch off produces the single-shot experience

- **WHEN** the operator scans an order and takes a photo with batch mode
  disabled
- **THEN** the review screen offers only the single-shot actions (Retake,
  Upload, and post-upload next steps) with no batch UI

#### Scenario: Retake in a single-shot multi-pick drops only the newest

- **WHEN** a single-shot session holds three gallery-picked shots and the
  operator taps Retake, then re-picks one gallery photo
- **THEN** the session holds three shots — the first two unchanged plus
  the newly picked one

#### Scenario: Upload in a single-shot multi-pick sends every processed shot

- **WHEN** a single-shot session holds three READY gallery-picked shots
  and the operator taps Upload
- **THEN** all three upload and the done state appears

---
