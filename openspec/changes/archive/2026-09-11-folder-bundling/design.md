## Context

OrderPic (today "mmcpic"/`mmcpicv4`) is a single-operator Android Flutter app
for a photo-capture workflow: scan a QR-coded order number, photograph the
item with the system camera, upload to a Windows SMB share. The entire app is
one 1,369-line `lib/main.dart`; settings live in `SmbSettings` behind the
injectable `SettingsStore` seam; uploads are flat, original-quality JPEGs
named `{Order}_{YYYYMMDD}_{HHMMSS}.jpg` (stamped at upload start); History
flat-lists the share root and parses that name.

Constraints that shaped this design:

- The filename contract is a cross-feature invariant (History sort + parse;
  `manual-order-entry` spec pins it) — both sides must move together.
- image_picker cache files are not durable across picks.
- smb_connect offers `createFile`/`openWrite` (overwrite semantics), no
  atomic multi-file operations, but native `SmbFile.isDirectory()`.
- History remounts on `ObjectKey(settings)` — any settings change re-lists
  the share today.
- Physical-device verification is mandatory for camera/SMB flows; unit and
  widget tests run against injected seams only.
- A future gallery-upload feature is desired; the design must not bend when
  it arrives.

Stakeholder: the single operator who scans, shoots, and uploads; a Windows
side consumes the share contents.

## Goals / Non-Goals

**Goals:**

- Keep multiple photos per order together: opt-in per-order folders on the
  share, and an opt-in multi-shot batch mode that accumulates shots locally
  and uploads them in one pass.
- Format/quality control: JPEG presets + custom quality, or lossless PNG
  with no quality surface at all.
- Collision-proof, retry-stable filenames stamped at capture.
- History that navigates folders and distinguishes them from photos at a
  glance.
- Restructure and rebrand (main.dart split; full OrderPic identity) **before**
  feature work, so growth lands in the final shape.

**Non-Goals:**

- ZIP bundling or append-to-archive (explored, dropped).
- Image thumbnails in History lists.
- Per-shot editing beyond retake-last in a batch.
- Background/persistent upload queue (WorkManager outbox).
- Gallery upload — designed for (source-agnostic admission), not built.
- Any server-side or share-side change; the share must already exist.

## Decisions

### D1: Bundling mechanism — per-order folders, no ZIP

- **Choice**: photos are grouped solely by writing them into
  `{sharePath}/{order}/` (opt-in). A quality/format setting controls
  re-encoding before upload; nothing is ever archived.
- **Rationale**: zipping already-compressed JPEGs saves ~nothing, and
  appending to a remote archive over SMB requires download-merge-reupload —
  the only genuinely risky machinery the feature could have included.
- **Alternatives considered**: ZIP with add-to-archive (user's original
  sketch) — rejected when the compression benefit turned out nil; the risk
  and a new `archive` dependency bought nothing folders don't already give.

### D2: Architecture — extend the existing flow with a `CaptureSession`

- **Choice**: thread a `CaptureSession { orderNumber, List<Shot> }` through
  today's `CameraPage → PreviewPage` hand-offs (they already chain via
  `pushReplacement`). Single-shot mode is a session of one; batch mode
  accumulates.
- **Rationale**: smallest surface that honors every requirement; one capture
  flow to maintain and test; the session doubles as the future gallery seam.
- **Alternatives considered**: a dedicated `BatchCapturePage` (isolation
  now, duplicated preview/error/retake logic forever); a persistent
  WorkManager outbox (robust offline, far beyond a single-operator LAN
  workflow — retry-keeps-locals covers the realistic failure).

### D3: Admission is source-agnostic and processes at pick time

- **Choice**: producers (camera now, gallery later) hand a picked file to
  `session.admit(path)`, which processes it — JPEG quality/resize via
  image_picker's own `maxWidth`/`imageQuality` pick params, `original` =
  untouched bytes — finalizes its filename, and materializes it into the
  session directory.
- **Rationale**: the preview then shows exactly what will upload (WYSIWYG);
  admission from any source gets identical naming/processing for free; zero
  new dependencies on the JPEG path.
- **Alternatives considered**: processing at upload time (preview would lie
  about quality; retry would need reprocessing); a shared "image pipeline"
  module (unnecessary until a second producer exists).

### D4: PNG via `flutter_image_compress` behind an `ImageProcessor` seam

- **Choice**: when format = PNG, the picked JPEG is losslessly converted
  with `flutter_image_compress` (native). The conversion lives behind an
  injectable `ImageProcessor` interface, mirroring the `SettingsStore` seam.
- **Rationale**: native speed for full-resolution conversion; the seam keeps
  widget/unit tests platform-channel-free and makes swapping the
  implementation (e.g. pure-Dart `image` package) a one-file change if the
  plugin misbehaves on the target device.
- **Alternatives considered**: pure-Dart `image` package (no platform
  channels but multi-second 12MP decodes and big memory spikes); PNG output
  directly from image_picker (not supported for camera captures).

### D5: Filename — capture-time stamp + in-session shot index, always

- **Choice**: `{Order}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png` for **every**
  upload, single-shot included. `NNN` = zero-padded shot index within the
  session; the timestamp is taken when the shot is admitted; extension
  follows the format at admission. History's parser accepts legacy 3-part
  and new 4-part names; descending-name sort stays newest-first.
- **Rationale**: same-second batch shots can no longer collide (the user
  independently flagged the current scheme's collision risk); a retried
  upload keeps its name instead of restamping; one code path instead of two
  naming schemes.
- **Alternatives considered**: collision detection by listing the target
  before each write (extra SMB round-trips, still racy); sub-second
  timestamps (parser churn, no ordering benefit).

### D6: Settings model — `AppSettings` umbrella, remount narrows to connection

- **Choice**: `AppSettings { ConnectionSettings connection; UploadPrefs
  upload; }` under one `ValueNotifier`; `SmbSettings` is renamed
  `ConnectionSettings`. Storage keys stay `smb.*` (no migration) plus new
  `upload.*`. History's remount key narrows to
  `ObjectKey(settings.connection)` so capture/upload pref changes never
  re-list the share. First-run gate stays `connection.username.isEmpty`.
- **Rationale**: the settings surface outgrew SMB-only framing (user
  request); the narrowing preserves the existing remount invariant's intent
  while new toggles churn.
- **Alternatives considered**: extending `SmbSettings` with the new fields
  (god-object; every quality tweak would remount History and re-list the
  share); separate notifiers for connection vs prefs (two plumbings through
  the same tree for no behavioral gain).

### D7: Settings page — two sections, capture above connection, PNG hides quality

- **Choice**: page retitled "Settings" (first-run keeps "Set up SMB
  login"); "Capture & upload" section (folders toggle, batch toggle, format
  picker, JPEG quality presets Original/High/Balanced/Small + Custom
  slider) sits above "SMB connection" (five fields + test). Selecting PNG
  hides the entire quality UI. Presets: high = q90 uncapped, balanced = q80
  + 2560px long edge, small = q70 + 1080px; custom = quality 30–100 +
  optional max long-edge px.
- **Rationale**: user-specified ordering; PNG is by definition uncompressed,
  so exposing knobs would be a lie.
- **Alternatives considered**: single quality slider without presets
  (operator-unfriendly); PNG quality options (meaningless — PNG is
  lossless).

### D8: Session storage — app-owned temp dir, per-shot cleanup, startup sweep

- **Choice**: each shot is copied/converted into
  `{systemTemp}/mmcpic-session-{order}-{epoch}/`. Successfully uploaded
  shots delete their local file immediately; the whole dir goes when the
  session empties. On app start, stale `mmcpic-session-*` dirs are swept
  best-effort.
- **Rationale**: image_picker cache paths are not durable across picks;
  killed-app leftovers shouldn't accumulate forever.
- **Alternatives considered**: holding picker paths directly (shots would
  vanish or be overwritten mid-batch); app-documents storage (needs
  `path_provider` dependency for no benefit — these are transient files).

### D9: Batch upload — one connection, per-shot results, in-place retry + no broken files

- **Choice**: `uploadSession()` opens one SMB connection; creates
  `sharePath` then `{sharePath}/{order}` best-effort (folders on); writes
  each shot sequentially; tracks per-shot ok/fail; deletes each local file
  on its own success; reports progress "x / N". Failure leaves the
  un-uploaded shots in the session — Retry re-runs only those.
- **Addendum (6.10, from the 6.1 device re-pass)**: the round-based
  auto-retry (3s/8s redial rounds) always raced a window it could not win
  — when a write times out because the TCP connection died, the server
  keeps the dead session's open handle on the half-written file until its
  own keepalive reaps it (observed ~1–2 min on Windows; nothing
  client-side can release it sooner — `SmbConnect.close()` is a graceful
  FIN behind the transport's send mutex, and there is no `destroy()`).
  The operator-approved policy instead: a failed shot is retried ONCE in
  place before the batch moves on (fresh redial after a write timeout,
  same connection for a server-answered error); still-failed shots get
  one end-of-pass re-attempt; a final failure probes and DELETES the
  broken remote partial so the share never keeps a half-written image —
  and when the server refuses that delete (the lock window), the shot's
  error says so plainly instead of surfacing a raw "file in use".
  Bounds are preserved: two write timeouts with no success between them,
  or a redial that cannot come up, abort the pass with instant
  skip-marks (no serial 30s grinds). Abandoned write/close futures no
  longer leak unhandled zone errors (`_bounded` awaits with a done-guard;
  `Future.timeout` drops late source errors into the zone — the device
  log's `Bad state: StreamSink is closed` spam).
- **Addendum (6.11, same re-pass)**: against real Windows shares the
  retry under a held lock does not fast-fail — the server BLOCKS the
  create behind the dead session's handle, so the retry burns its own
  timeout and the "two timeouts = dead network" rule aborted passes the
  dial had just proven healthy. Refinement: a retry that stalls on a
  FRESH connection (dial succeeded, same file) is the ghost-lock
  signature — the shot is marked server-held with the lock-window
  message, exempt from the rescue and the cleanup probe (both would hang
  the same way), does not count toward the abort, and the batch
  continues; the dead-network abort now requires a timeout on a NEW
  shot. Retry writes are bounded at 15s (a healthy LAN retry answers in
  a fraction of that), the exists/delete probes carry the write bound,
  and raw sharing-violation text ("being used by another process")
  always carries the lock-window guidance.
- **Rationale**: SMB has no multi-file transaction, so isolation granularity
  is the file; an operator should never re-shoot because one write failed.
- **Alternatives considered**: all-or-nothing semantics (impossible without
  a transaction; would force full re-upload on any single failure);
  per-shot connections (N× handshake latency for zero benefit); round-based
  redial/resume (superseded — the skipped shots resume fast enough via the
  in-place retry, and the timed-out shot itself cannot win a sub-minute
  race against the server's session reaping).

### D10: History — drill-down with native folder detection

- **Choice**: root listing shows folder tiles first (via
  `SmbFile.isDirectory()`), each with `Icons.folder` and a small grey
  "Folder" label, sorted by name descending; loose images follow as today
  (newest-first). Tapping a folder pushes an order page listing that
  folder's photos (title = readable time, subtitle = filename, trailing
  size); the existing `ImageViewerPage` is reused unchanged — it downloads
  by each file's own path. Pull-to-refresh on both levels.
- **Rationale**: matches the "orders kept together" mental model at one SMB
  listing per screen; folder/photo confusion was a stated user concern;
  native attribute check beats name heuristics.
- **Alternatives considered**: recursive flat list (one listing per order
  folder per refresh — slow as orders accumulate); real image thumbnails
  (would download every full-size photo just to decorate the list).

### D11: Phase 0 first — mechanical split + full OrderPic rebrand

- **Choice**: before any feature work, split `main.dart` into focused files
  and fully rebrand to OrderPic (launcher label + app title "OrderPic",
  `MmcPicApp` → `OrderPicApp`, pubspec `mmcpicv4` → `orderpic` with import
  rewrites, `applicationId`/`namespace` → `com.mmc.magicmicro.com.orderpic`
  with MainActivity relocated). No behavior change; gated by analyze,
  tests, and a device smoke pass.

  ```
  lib/
    main.dart                  main() + OrderPicApp only
    settings/                  app_settings.dart, settings_store.dart, settings_page.dart
    smb/                       smb.dart (connect, SmbNotConfiguredException)
    capture/                   naming.dart (builder + parser, the contract's one home)
    pages/                     home, scanner, camera, preview, history, image_viewer
  ```

- **Rationale**: user-directed sequencing — "adding more before doing so
  will make it more difficult"; the rebrand rides the same mechanical pass
  so imports and identity change exactly once.
- **Alternatives considered**: splitting after the features (deeper
  monolith to dissect); display-name-only rename (rejected by user in favor
  of the full identity change, accepting the migration cost).

## Risks / Trade-offs

- [Risk] `flutter_image_compress` mishandles EXIF orientation or
  misbehaves on the target device → Mitigation: mandatory device pass
  covers PNG conversion and orientation explicitly; the `ImageProcessor`
  seam makes swapping to the pure-Dart `image` package a one-file change.
- [Risk] Mid-batch connection loss strands a half-uploaded set →
  Mitigation: per-shot tracking; locals retained; Retry uploads only the
  remainder; nothing is deleted unless its upload succeeded.
- [Risk] Remount invariant regression (History re-listing on every pref
  tweak) after the `AppSettings` merge → Mitigation: narrowing documented
  here and in `HomePage`'s invariant comment; widget test asserts History
  is not remounted by an upload-pref-only save.
- [Risk] App-identity change strands stored credentials → Mitigation:
  accepted deliberately (user decision, full rebrand); the first-run gate
  re-triggers once and re-collects settings; the previous app remains
  installed for reference until manually removed.
- [Risk] Legacy and new names mixing in one listing → Mitigation: parser
  accepts both shapes; sort remains lexical-descending, which is
  newest-first for both.
- [Trade-off] PNG files are several times larger than JPEG → accepted:
  lossless is the point of the option; JPEG remains the default.
- [Trade-off] `createFile` overwrites silently on name collision →
  accepted: capture-time stamps + session indexes make collisions
  impossible by construction rather than detected.
- [Trade-off] Retake drops only the last shot of a batch → accepted:
  per-shot editing deferred; the common correction is "redo the shot I
  just took."
- [Trade-off] No thumbnails in History lists → accepted: SMB download cost
  per list item outweighs the visual aid; folder tiles get icon + label
  instead.

## Migration Plan

Deploy order (each step lands as verified commits before the next begins):

1. **Phase 0** — split + rebrand, no behavior change. Acceptance:
   `flutter analyze` clean, `flutter test` green, device smoke pass (scan →
   shoot → upload → History) on the new identity.
2. **Settings** — `AppSettings`/`UploadPrefs` model + sectioned Settings
   page. Acceptance: unit + widget tests (persistence, defaults,
   PNG-hides-quality, remount narrowing); stored `smb.*` values still load
   unchanged.
3. **Naming + session + processing** — `capture/naming.dart`,
   `CaptureSession`, `ImageProcessor`. Acceptance: unit tests for builder
   (stamp, index, extension) and parser (legacy + new).
4. **Upload flow** — batch UI + `uploadSession()`. Acceptance: widget
   tests for per-shot results/retry-remaining semantics; device pass on
   all four toggle combinations.
5. **History drill-down** — folder tiles + order page. Acceptance: widget
   tests for tiles/drill-down; device pass.
6. **Docs** — CLAUDE.md updated (contract, compression line, architecture
   map, app name).

Rollback: the app is a single installed APK with no server component —
rollback is reinstalling the previous APK. Because phase 0 changes the app
identity, the pre-change app remains installed side-by-side and functional
(its own credentials, its own flat uploads). Share contents written by the
new version are plain files/folders — nothing to undo.

## Open Questions

- Verify during the phase-4 device pass that `flutter_image_compress`
  preserves EXIF orientation on the target hardware; if not, swap the
  `ImageProcessor` implementation to the pure-Dart `image` package
  (decision D4's documented fallback). No design change either way.

No other open questions — all forks were resolved during brainstorming
(see brainstorm.md Q1–Q8).
