# folder-bundling — brainstorm decision log

Date: 2026-09-08 · Status: design approved by user, ready for proposal/design artifacts.

## Background

MMCPic's capture flow uploads one original-quality JPEG per scan, flat into the
configured share path, named `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg` (stamped at
upload start). History flat-lists the share root and parses that name format.
The user wants multiple photos per order kept together more easily, and asked
for two settings: per-order folders, and a multi-shot mode that saves locally,
compresses, then uploads — appending to an existing ZIP if one was present.

Codebase facts established during exploration (lib/main.dart, 1369 lines,
single file):

- `SmbSettings` (connection) is persisted via the injectable `SettingsStore`
  seam; `HomePage` remounts History via `ObjectKey(settings)` on any settings
  change; first-run gate is `username.isEmpty`.
- The filename contract is a cross-feature invariant: History sorts
  descending-name = newest-first and `_parseName` splits it into (order, time).
- Upload stamps the name at upload start — a multi-photo batch would stamp
  several files within the same second and overwrite each other (user flagged
  this independently).
- smb_connect 0.0.9 `SmbFile.isDirectory()` exists (attribute-flag based) —
  History can distinguish folders natively, no name heuristics.
- image_picker's `maxWidth`/`imageQuality` pick-time params cover JPEG quality
  presets with zero new dependencies; PNG conversion needs a new package.
- image_picker cache files are not durable across picks — an accumulating
  batch must copy each shot into a session-owned directory.

## Decision chain

**Q1 — What does "compressed" mean in the multi-shot flow?**
User: quality setting preferred; JPEG is already compressed so re-zipping buys
nothing; "if there is no benefit to zipping we should probably skip it so we
don't have to download and rezip."
→ **ZIP dropped entirely.** Zipping already-compressed JPEGs saves ~nothing and
it was the only part forcing the risky download-merge-reupload append cycle.
Bundling now happens purely via per-order folders; a quality setting controls
re-encoding before upload. (My pushback on PNG — lossless re-encode of a camera
JPEG is strictly larger — was heard; user still wants PNG as a format option,
an informed fidelity/format choice.)

**Q2 — With the ZIP gone, what does multi-shot do?**
User: batch session — with the note that date/time-only naming "may cause
conflicts and would need to be resolved."
→ **Batch session**: accumulate shots locally per order, one "Upload all" over
one SMB connection, cleanup per-shot on success. Naming collision resolved by
capture-time stamping + in-session shot index (see design §2).

**Q3 — Shape of the quality setting?**
User: format picker + quality knobs alongside presets; **JPEG gets compression
options; PNG is separate and always uncompressed — when PNG is selected, no
quality options are shown at all** (defaults to no compression).
→ Format picker JPEG/PNG; JPEG → presets + custom; PNG → lossless full-size
conversion, quality UI hidden.

**Q4 — History handling for folder-resident photos?**
User: drill-down — plus folders must be visually distinct: folder icon, and/or
small grey "folder" text near the date/time, because an order-folder and an
order-numbered photo could otherwise be confused.
→ Drill-down navigation; folder tiles get `Icons.folder` + grey "Folder" label
via native `isDirectory()`. Real image thumbnails rejected: they'd download
every full-size photo over SMB just to decorate the list.

**Q5 — Overall architecture?**
User picked **Approach A (extend the existing flow)** — "as long as it is the
option that keeps our codebase clean the longest" — and asked that a possible
future **gallery-upload feature** be taken into account.
→ `CaptureSession` with source-agnostic admission: camera today, gallery later
feeds the same `session.admit()`; image_picker already supports
`ImageSource.gallery` / multi-pick, so nothing in the core bends.

**Q6 — Settings naming?**
User: rename `SmbSettings` — "this is becoming more than an SMB settings menu" —
and add **section headers**, with compression/image settings **above** SMB.
→ `AppSettings` umbrella (`ConnectionSettings` renamed from `SmbSettings` +
`UploadPrefs`), one notifier, keys unchanged (`smb.*` + new `upload.*`);
Settings page retitled "Settings" with sections "Capture & upload" over
"SMB connection"; History remount narrows to `ObjectKey(settings.connection)`.

**Q7 — Fold the main.dart split in?**
User: yes — "it needs to be done and adding more before doing so will make it
more difficult. This should be done before our changes."
→ **Phase 0**: pure mechanical split of lib/main.dart into lib/ files, no
behavior change, gated by analyze + tests + device smoke before feature work.

**Q8 — Rename the program to OrderPic?**
User: "change the name of the program from 'mmcpic' to 'OrderPic'" — and on
being shown the fork between display-name-only and full identity rebrand,
chose **full rebrand**, accepting the stated migration cost.
→ Phase 0 also rebrands: launcher label and MaterialApp title become
"OrderPic"; `MmcPicApp` → `OrderPicApp`; pubspec `name: mmcpicv4` → `orderpic`
(all `package:mmcpicv4/` imports rewritten); `applicationId`/`namespace`
`com.mmc.magicmicro.com.mmcpicv4` → `com.mmc.magicmicro.com.orderpic`
(MainActivity moves to the matching directory). **Accepted consequence:**
Android treats the result as a new app — Keystore-stored settings do not
migrate, so the first-run setup gate re-triggers once, and the old app
remains installed unless removed manually.

## Approaches weighed

- **A — Extend the existing flow (chosen):** thread a `CaptureSession` through
  today's `CameraPage → PreviewPage` hand-offs. Smallest surface honoring all
  requirements; one capture flow to maintain; the session concept doubles as
  the future gallery seam. Cost: every existing page is touched, PreviewPage
  gets busier.
- **B — Dedicated batch screen:** single-shot flow frozen, new
  `BatchCapturePage` owns loop/strip/upload. Isolation now, duplication
  forever (two previews, two error/retake paths). Rejected.
- **C — Persistent upload queue (WorkManager outbox):** most robust offline,
  far more machinery than a single-operator on-LAN workflow needs. Rejected as
  YAGNI; A's retry-keeps-locals covers the realistic failure mode.

## Approved design

### 0. Repo restructure (phase 0, before feature work)

Pure mechanical split — no behavior change; verified by `flutter analyze`,
`flutter test`, device smoke:

```
lib/
  main.dart                  main() + MmcPicApp only
  settings/
    app_settings.dart        AppSettings, ConnectionSettings, UploadPrefs, keys, load/save
    settings_store.dart      SettingsStore + SecureSettingsStore
    settings_page.dart       SettingsPage
  smb/
    smb.dart                 connect(), SmbNotConfiguredException
  capture/
    naming.dart              filename builder + parser (the contract's one home)
  pages/
    home_page.dart  scanner_page.dart  camera_page.dart
    preview_page.dart  history_page.dart  image_viewer_page.dart
```

Tests keep working via updated imports. `capture/session.dart` and
`capture/image_processor.dart` arrive with phase 1.

### 1. Settings model

`AppSettings { ConnectionSettings connection; UploadPrefs upload; }` — one
`ValueNotifier`, one load/save via `SettingsStore`; storage keys `smb.*`
(unchanged, no migration) + `upload.*`. First-run gate stays
`connection.username.isEmpty`. History remount key narrows to
`ObjectKey(settings.connection)` so quality/folder toggles never re-list the
share (invariant comment in `HomePage` updated to say so).

`UploadPrefs` fields and defaults (defaults preserve today's capture/upload
behavior — original bytes, flat, single-shot; the one upgrade-visible
difference regardless of settings is the filename scheme gaining its shot
index, §2, which History parses alongside legacy names):

| Field | Values | Default |
|---|---|---|
| `useOrderFolders` | bool | `false` |
| `batchMode` | bool | `false` |
| `format` | `jpeg` / `png` | `jpeg` |
| `jpegQuality` | `original` / `high` / `balanced` / `small` / `custom` | `original` |

Preset mapping: high = q90 uncapped; balanced = q80 + 2560px long edge;
small = q70 + 1080px long edge; `custom` = quality slider 30–100 + optional
max long-edge dimension in px. **PNG hides the quality UI entirely** — always
lossless full-size conversion.

Settings page ("Settings"; first-run title stays "Set up SMB login"), sections
ordered per user: **Capture & upload** (folders toggle, batch toggle, format,
JPEG quality — quality hidden when PNG) above **SMB connection** (host, share
path, domain, username, password, test connection).

### 2. Capture session & naming

- `CaptureSession { orderNumber, List<Shot> }`; `Shot` = local path +
  finalized filename. **Admission is source-agnostic** (`session.admit(path)`)
  — camera today, gallery as a second producer later.
- **Processing at admission, not upload**: JPEG presets ride image_picker
  `maxWidth`/`imageQuality` (preview is WYSIWYG; `original` = untouched bytes =
  today's path). PNG conversion via new dependency `flutter_image_compress`
  (native), wrapped in an injectable `ImageProcessor` seam so tests fake it.
  PNG files will be several times larger — inherent to lossless, accepted.
- Shots materialize into a session-owned dir
  (`{systemTemp}/mmcpic-session-{order}-{epoch}/`) because image_picker cache
  files aren't durable across picks. Per-shot delete on upload success;
  best-effort sweep of stale `mmcpic-session-*` dirs on app start.
- **Naming**: `{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png` — stamped at
  **capture** (retried uploads keep their name; no same-second collisions),
  `NNN` = zero-padded shot index within the session, extension per format at
  admission. New scheme always (single-shot included — one code path);
  History parser accepts legacy 3-part and new 4-part names. Descending-name
  sort stays newest-first.

### 3. Flow & upload

- Batch off = today's UX unchanged (session of one).
- Batch on: PreviewPage shows the shot, an "Order N — k photos" chip, a
  thumbnail strip (display-only). Buttons: **Retake** (drops the last shot
  only — per-shot editing is a future nicety), **Add photo**, **Upload all**.
- `uploadSession()`: one SMB connection; best-effort `createFolder` of
  `sharePath` then `{sharePath}/{order}` when folders are on; per-shot writes
  to `{sharePath}/{order}/` or flat per the toggle; per-shot ok/fail tracked;
  each success deletes its local file; progress shown as "x / N".
- **Retry uploads only failed/remaining shots** — the session keeps what
  didn't succeed; nothing is lost silently.
- After a successful batch: summary banner → *Scan next QR* / *More for this
  order* (fresh empty session).

### 4. History — drill-down

Root listing: folder tiles first (`Icons.folder` + small grey "Folder" label,
native `isDirectory()`), sorted by name descending (order numbers — highest
first), then loose images as today (newest-first). Tap folder
→ pushed order page listing that folder's photos (title = readable time,
subtitle = filename, trailing size). `ImageViewerPage` reused as-is — it
downloads by the file's own path, so nested files just work. Pull-to-refresh
at both levels.

### 5. Error handling

Pick failure → existing snackbar path. Processing failure (e.g. PNG
conversion) → shot rejected, session intact, camera relaunches. Upload:
per-shot failures isolated; connection loss keeps remaining shots local for
retry. Folder-creation errors surface as write errors, same as today.

### 6. Testing & docs

- Unit: prefs load/save/defaults; filename builder (stamp + NNN + extension);
  parser legacy + new; target-path builder.
- Widget (InMemorySettingsStore + faked `ImageProcessor`): settings sections
  incl. "PNG hides quality UI"; History folder tiles + drill-down.
- Device pass mandatory (project rule): all four toggle combinations, PNG
  conversion, EXIF orientation, retry path.
- CLAUDE.md: filename-contract section and "no resize/compression" line
  updated; "entire app is main.dart" retired by phase 0.

## Explicitly out of scope

- ZIP bundling / append-to-archive (dropped in Q1).
- Image thumbnails in History lists.
- Per-shot editing in a batch beyond retake-last.
- Background/persistent upload queue.
- Gallery upload — designed for (source-agnostic admission), not built now.

## Risks & notes

- PNG size inflation (several × JPEG) — accepted deliberately.
- `flutter_image_compress` is a new platform dependency; verify orientation
  handling on a physical device (memory: reviews passing ≠ working on
  hardware).
- The History remount invariant must narrow to `connection` — easy to miss,
  would cause needless share re-listings on every quality tweak.
- Folder-create semantics stay best-effort (share must pre-exist) — unchanged
  from today, documented in CLAUDE.md.
