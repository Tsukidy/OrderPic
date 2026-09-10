# batch-capture delta — folder-bundling

## ADDED Requirements

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
