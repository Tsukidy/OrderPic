# batch-capture delta — folder-bundling

## ADDED Requirements

### Requirement: Multi-photo batch accumulation

With the batch toggle on, the capture flow for a scanned or typed order
number MUST allow taking multiple photos before upload: each admitted shot
MUST appear in a running batch (photo-count chip and thumbnail strip on
the review screen), an Add photo action MUST return to the camera for the
same order, and a Retake action MUST discard only the most recently
admitted shot, leaving earlier shots in the batch.

#### Scenario: Consecutive shots accumulate in one batch

- **WHEN** the operator photographs an item, chooses Add photo, and
  photographs it twice more for the same order
- **THEN** the review screen reports 3 photos in the batch and the
  thumbnail strip shows three entries

#### Scenario: Retake discards only the last shot

- **WHEN** a batch holds three shots and the operator chooses Retake and
  takes a replacement photo
- **THEN** the batch contains three shots — the first two unchanged plus
  the replacement — and no upload has occurred

---

### Requirement: Single-shot parity when batch is off

With the batch toggle off, the capture flow MUST behave exactly as the
pre-change single-shot flow: one photo, review, upload; no batch chip,
thumbnail strip, or Add photo affordance SHALL appear.

#### Scenario: Batch off produces the single-shot experience

- **WHEN** the operator scans an order and takes a photo with batch mode
  disabled
- **THEN** the review screen offers only the pre-change actions (Retake,
  Upload, and post-upload next steps) with no batch UI

---

### Requirement: Processing at admission with WYSIWYG preview

Every admitted shot MUST be processed according to the configured format
and quality at admission time — JPEG re-encode/resize per the quality
selection, or lossless PNG conversion — and the review screen MUST display
the processed result, so what the operator approves is what uploads. If
processing fails, the shot MUST be rejected, the existing batch MUST
remain intact, and the camera relaunches.

#### Scenario: Preview shows the processed image

- **WHEN** a shot is admitted with JPEG quality Small
- **THEN** the review screen displays the re-encoded, dimension-capped
  file that will be uploaded

#### Scenario: PNG shots are converted at admission

- **WHEN** a shot is admitted with format PNG
- **THEN** the session stores a losslessly converted PNG file and the
  preview displays it

#### Scenario: Processing failure preserves the batch

- **WHEN** image processing errors while admitting a fourth shot to a
  three-shot batch
- **THEN** the batch still holds the original three shots and the operator
  can retry the fourth

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
SMB connection, track each shot's outcome individually, show progress as
completed/total, and delete a shot's local file only after that shot's
upload succeeds. If any shot fails, the un-uploaded shots MUST remain in
the session and a Retry action MUST upload only those remaining shots.
After every shot succeeds, the flow MUST show a completion summary with a
Scan next action and a More-for-this-order action that starts a fresh
empty session for the same order number.

#### Scenario: Successful batch uploads and cleans up

- **WHEN** a three-shot batch is uploaded and all writes succeed
- **THEN** the share contains all three files, the local session files are
  deleted, and the summary offers Scan next and More for this order

#### Scenario: Mid-batch failure retries only the remainder

- **WHEN** a three-shot batch uploads and the second write fails
- **THEN** the first shot's local file is deleted and marked uploaded, the
  second and third shots remain locally, and Retry uploads exactly those
  two

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
