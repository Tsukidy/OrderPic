# batch-capture Specification

## Purpose
Multi-shot capture for one order: source-agnostic admission with format/quality processing, a WYSIWYG review with background conversion, and a bounded batch upload with per-shot outcomes, in-place retry, and no-broken-files cleanup.

## Requirements

### Requirement: Multi-photo batch accumulation

With the batch toggle on, the capture flow for a scanned or typed order
number MUST allow taking multiple photos before upload: each admitted shot
MUST appear in a running batch (photo-count chip and thumbnail strip on
the review screen), an Add photo action MUST return to the camera for the
same order, and a Retake action MUST discard only the most recently
admitted shot, leaving earlier shots in the batch. Tapping a thumbnail
MUST display that shot full-screen for review.

#### Scenario: Consecutive shots accumulate in one batch

- **WHEN** the operator photographs an item, chooses Add photo, and
  photographs it twice more for the same order
- **THEN** the review screen reports 3 photos in the batch and the
  thumbnail strip shows three entries

#### Scenario: Tapping a thumbnail reviews that shot

- **WHEN** a batch holds three shots and the operator taps the first
  thumbnail in the strip
- **THEN** the full-screen preview displays the first shot, with a way to
  return to the most recent one

#### Scenario: Retake discards only the last shot

- **WHEN** a batch holds three shots and the operator chooses Retake and
  takes a replacement photo
- **THEN** the batch contains three shots — the first two unchanged plus
  the replacement — and no upload has occurred

---

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
  operator taps Retake, then re-photographs one shot with the camera
  (Retake stays camera-only)
- **THEN** the session holds three shots — the first two unchanged plus
  the newly picked one

#### Scenario: Upload in a single-shot multi-pick sends every processed shot

- **WHEN** a single-shot session holds three READY gallery-picked shots
  and the operator taps Upload
- **THEN** all three upload and the done state appears

---

### Requirement: Processing at admission with WYSIWYG preview

Every admitted shot MUST be processed according to the configured format
and quality — JPEG re-encode/resize per the quality selection, or lossless
PNG conversion — and the review screen MUST display the processed result,
so what the operator approves is what uploads. Processing runs in the
background relative to capture: a picked shot appears immediately as a
pending entry in the batch, the operator can take the next shot without
waiting, and pending conversions MUST complete (or fail, visibly flagged
for retake) before Upload all starts. If processing fails, the failed
entry MUST be flagged at review time and MUST NOT block other shots; the
rest of the batch stays intact.

#### Scenario: Preview shows the processed image

- **WHEN** a shot is admitted with JPEG quality Small
- **THEN** the review screen displays the re-encoded, dimension-capped
  file that will be uploaded

#### Scenario: PNG shots are converted without blocking capture

- **WHEN** a shot is picked with format PNG and conversion is still running
- **THEN** the shot already appears as a pending thumbnail and the operator
  can take the next photo; by review time the converted PNG is displayed

#### Scenario: Upload waits for pending conversions

- **WHEN** the operator taps Upload all while a conversion is still pending
- **THEN** the upload starts only after pending conversions settle, and a
  failed conversion is surfaced for retake instead of being uploaded

#### Scenario: Processing failure preserves the batch

- **WHEN** image processing errors while converting a fourth shot of a
  three-shot batch
- **THEN** the batch still holds the original three shots, the failed
  entry is flagged, and the operator can retake it

---

### Requirement: Session-local durability

Admitted shots MUST be materialized into app-owned session storage
immediately at admission, independent of the camera picker's cache, and
MUST remain available across subsequent camera launches within the same
capture session.

#### Scenario: Shots survive further camera launches

- **WHEN** a batch holds two shots and the operator launches the camera a
  third time before uploading
- **THEN** both earlier shots are still present and viewable when the
  third shot is admitted

---

### Requirement: Batch upload semantics

An Upload all action MUST upload every shot in the session over a single
SMB connection while it stays healthy, track each shot's outcome
individually, show progress as completed/total, and delete a shot's local
file only after that shot's upload succeeds. A shot write that stalls
MUST fail after a bounded write timeout rather than hanging indefinitely.

Retry policy: a shot whose write fails MUST be retried once in place —
on the same connection for a server-returned error, or on a freshly
redialed connection when the failure was a write timeout (the old
connection is dead) — before the batch moves on to the next shot. After
the pass over all shots, every still-failed shot MUST get one final
re-attempt; if that also fails, the uploader MUST probe the shot's
remote target and delete any partial file it finds, so the share never
retains a broken image. When the server refuses that delete — a dead
session's open handle keeps the partial file locked until the server
reaps it, typically a minute or two — the shot's error MUST say so
rather than surfacing the raw refusal.

Bounds: two write timeouts with no successful write between them, or a
redial that cannot come up, MUST abort the pass — every unattempted shot
is skip-marked immediately rather than each waiting out its own timeout.
A ghost-locked shot does not count toward that bound: when a shot's
retry write stalls on a FRESH connection (the dial succeeded — the
network is fine; the server is blocking the write behind the dead
session's handle), the shot MUST be marked server-held with guidance to
press Retry after the lock window, MUST NOT be re-attempted or probed
again during the call (no attempt inside the window can win), and the
remaining shots MUST continue unaffected. The manual Retry action
remains: failed, timed-out, and skipped shots stay staged locally and
re-upload with a fresh connection. If any shot fails, the un-uploaded
shots MUST remain in the session. After every shot succeeds, the flow
MUST show a completion summary with a Scan next action and a
More-for-this-order action that starts a fresh empty session for the
same order number.

#### Scenario: Successful batch uploads and cleans up

- **WHEN** a three-shot batch is uploaded and all writes succeed
- **THEN** the share contains all three files, the local session files are
  deleted, and the summary offers Scan next and More for this order

#### Scenario: Mid-batch failure retries only the remainder

- **WHEN** a three-shot batch uploads and the second write fails
- **THEN** the first shot's local file is deleted and marked uploaded, the
  second and third shots remain locally, and Retry uploads exactly those
  two

#### Scenario: Stalled write is retried in place before the batch moves on

- **WHEN** the network drops under a shot's write and the write times out
- **THEN** the uploader closes the dead connection, redials a fresh one,
  and retries that same shot before uploading the later shots

#### Scenario: Final failure never leaves a broken remote file

- **WHEN** a shot fails its write, its in-place retry, and the end-of-pass
  re-attempt, and a partial file exists on the share
- **THEN** the partial file is deleted from the share, the shot stays
  staged locally, and its error states the partial copy was removed (or
  that the server briefly still holds it, when the delete is refused)

#### Scenario: A retry stalled on a fresh connection is a held file, not a dead network

- **WHEN** a shot times out, the redial succeeds, and the retry write on
  the fresh connection also stalls
- **THEN** the shot fails with a message naming the server's held-file
  lock window (press Retry after it clears), is not re-attempted during
  the call, and the remaining shots upload normally

#### Scenario: A dead network aborts without serial timeouts

- **WHEN** two consecutive writes time out with no successful write
  between them, or a redial cannot come up
- **THEN** the remaining shots are skip-marked without further write
  attempts, all shots stay staged locally, and the manual Retry uploads
  them once connectivity returns

---

### Requirement: Session storage cleanup

A session's local directory MUST be removed once all of its shots have
been uploaded and deleted, and session directories left behind by a killed
app MUST be swept best-effort at next app start.

#### Scenario: Emptied session directory is removed

- **WHEN** the last shot of a session uploads successfully and its local
  file is deleted
- **THEN** the session's directory no longer exists on the local
  filesystem

#### Scenario: Orphaned session swept on startup

- **WHEN** the app starts and a session directory remains from a previous
  killed run with no upload in progress
- **THEN** that directory is deleted best-effort

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
