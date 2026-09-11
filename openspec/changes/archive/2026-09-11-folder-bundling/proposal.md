## Why

Orders today leave every photo in one flat share folder with
order-number-prefixed names, so related shots scatter and are hard to pull
together; capturing several photos for one order also risks same-second
filename collisions because names are stamped at upload time. This change
groups uploads into per-order folders, adds an opt-in multi-shot batch mode
that accumulates shots locally and uploads them in one pass, and adds
format/quality control (JPEG presets or lossless PNG). It also splits the
1,369-line main.dart into lib/ modules first, so this growth lands in a
maintainable structure. A ZIP-append variant was explored and dropped:
zipping already-compressed JPEGs saves nothing and forces a risky
download-merge-reupload cycle.

## What Changes

**Settings screen and model**
- From: an "SMB settings" page editing five connection fields; `SmbSettings`
  is the entire settings model
- To: a "Settings" page with two sections — "Capture & upload" (per-order
  folders toggle, multi-photo batch toggle, image format JPEG/PNG, JPEG
  quality presets + custom; the quality UI is hidden entirely when PNG is
  selected) above "SMB connection" (the five existing fields + test
  connection). Model becomes `AppSettings { ConnectionSettings, UploadPrefs }`
- Reason: the settings surface outgrew its SMB-only framing
- Impact: non-breaking — `smb.*` storage keys are unchanged (no migration);
  new `upload.*` keys default to today's behavior

**Capture and upload flow**
- From: one photo per scan, named at upload start, uploaded immediately
- To: every capture runs through a `CaptureSession` (source-agnostic
  admission — camera now, gallery later). With batch mode on, shots
  accumulate locally (processed at admission, so preview is WYSIWYG) with a
  thumbnail strip and Retake-last / Add photo / **Upload all**; the batch
  upload uses one SMB connection, tracks per-shot success, deletes each
  local file as it succeeds, and retry uploads only the remainder. With
  batch off, today's single-shot UX is unchanged (session of one)
- Reason: keep multiple photos per order together; never lose shots to a
  mid-batch failure
- Impact: behavior change behind default-off toggles; one new dependency
  (`flutter_image_compress`, PNG lossless conversion)

**Filename contract**
- From: `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg`, stamped when the upload
  starts
- To: `{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png`, stamped at
  capture (retries keep their name), `NNN` = zero-padded shot index within
  the session, extension per selected format. History parses legacy
  3-part and new 4-part names; descending-name sort stays newest-first
- Reason: same-second batch collisions (user-flagged) and name stability
  across upload retries
- Impact: non-breaking for existing files; new names carry the index suffix

**Upload targeting and History**
- From: flat writes to the share root; History flat-lists root images
- To: opt-in writes into `{sharePath}/{order}/` (folder created
  best-effort); History shows folder tiles (folder icon + small grey
  "Folder" label, via native `isDirectory()`) sorted by name descending,
  then loose images as today; tapping a folder drills into that order's
  photos, reusing the existing image viewer; pull-to-refresh at both levels
- Reason: per-order bundling, with folders visually distinct from photos
- Impact: opt-in, default off

**Repo structure and app identity (phase 0, prerequisite)**
- Pure mechanical split of `main.dart` into `settings/`, `smb/`,
  `capture/`, `pages/` files — no behavior change — gated by analyze,
  tests, and a device smoke pass before feature work begins
- Full rebrand from mmcpic to **OrderPic** in the same pass: launcher
  label and app title become "OrderPic", `MmcPicApp` → `OrderPicApp`,
  pubspec name `mmcpicv4` → `orderpic` (imports rewritten),
  `applicationId`/`namespace` → `com.mmc.magicmicro.com.orderpic`
  (MainActivity relocated to match)
- Reason: the app's identity should match its purpose before it grows
  new user-facing features
- Impact: **breaking for installed devices** — Android sees a new app:
  Keystore-stored settings do not migrate (first-run setup gate
  re-triggers once) and the old app remains installed unless removed;
  accepted deliberately

## Capabilities

### New Capabilities

- `upload-settings`: `UploadPrefs` persistence (folders, batch, format,
  JPEG quality) and the sectioned Settings page with PNG-hides-quality
  behavior
- `batch-capture`: capture sessions — admission with format/quality
  processing, local accumulation, upload-all over one connection, per-shot
  results, retry-remaining, session cleanup
- `order-folders`: per-order folder upload targeting and History
  drill-down with distinct folder tiles
- `photo-naming`: the filename contract — capture-time stamping, shot
  index, format-driven extension, legacy-name parsing, newest-first sort

### Modified Capabilities

- `smb-settings`: settings-change propagation narrows — History re-lists on
  connection changes, not upload-pref changes; the settings page gains
  section structure and the "Settings" title (first-run gate, encrypted
  persistence, and all other requirements unchanged)
- `manual-order-entry`: the "Upload naming contract preserved" requirement
  updates from the fixed 3-part `.jpg` format to the new capture-stamped
  scheme (History remains able to parse manually-entered uploads)

## Impact

- **Code**: all of `lib/main.dart` (split into ~12 files under `lib/`),
  plus test imports; `SmbSettings` renamed `ConnectionSettings` inside the
  new `AppSettings` umbrella (storage keys unchanged); Android manifest,
  Gradle `applicationId`/`namespace`, MainActivity location, and pubspec
  `name` all move to the OrderPic identity
- **Dependencies**: + `flutter_image_compress`; no removals
- **Systems**: the SMB share gains optional per-order sub-folders; existing
  flat files coexist and stay listed; installed devices see a one-time app
  identity change (settings re-entry required, previous app left in place)
- **Docs**: CLAUDE.md — filename contract, "no resize/compression" line,
  "entire app is main.dart" architecture note, and the MMCPic app name
- **Verification**: unit + widget tests via the existing
  `InMemorySettingsStore` seam and a faked `ImageProcessor`; physical-device
  pass mandatory (all toggle combinations, PNG conversion, EXIF orientation,
  retry path)
