# Brainstorm — smb-path-settings-menu

Raw capture of the brainstorming session (2026-09-04). Decision-log format:
background → decision chain → approaches weighed → approved design.

## Background

- MMCPic (`mmcpicv4`): Flutter app, Android-primary. Flow: scan QR order
  number → photograph item with system camera → review → upload to a Windows
  SMB share. History tab lists/views images on the share.
- SMB settings are hardcoded top-level constants in `lib/main.dart:10-15`:
  host `192.168.1.29`, sharePath `/zdrive/InvoiceData`, domain `''`,
  username `opk`, password `opk`. Repointing the app at another server or
  account currently requires a rebuild.
- The constants are consumed at exactly three sites, each opening a fresh
  `SmbConnect.connectAuth` connection:
  - `PreviewPage._upload` (upload; `main.dart:337`)
  - `HistoryPage._refresh` (list; `main.dart:595`)
  - `ImageViewerPage._load` (download; `main.dart:734`)
- No persistence package in `pubspec.yaml`; no state-management library
  (deliberate, per CLAUDE.md). Architecture is plain `StatefulWidget`s in a
  single `lib/main.dart`.
- Parallel change in flight: `ordernumber-entry` (worktree
  `.claude/worktrees/ordernumber-entry`, branch `worktree-ordernumber-entry`)
  adds a "Type order number" fallback button to the Scan tab **body** (Stack
  around `MobileScanner`) and a `_startCapture` helper. It does not touch the
  app bars. Scan-screen layout may keep evolving; this change must not
  couple to it structurally.

## Decision chain

**Q1 — Which fields are configurable?**
→ All five (host, share path, domain, username, password). Fully
self-service repointing with no rebuild. Named profiles rejected as overkill
for a single-server shop tool.

**Q2 — Persistence & first run?**
→ Persist via `shared_preferences`. On first run (nothing saved), seed
**field-by-field** from the current constants so the app works out of the
box exactly as today. An empty-first-run gate was considered and rejected
(extra states, no benefit for a tool that already ships with known-good
values). *(Superseded: storage medium by Q6; credential seeding by Q7 —
  config-field seeding unchanged.)*

**Q3 — Where does settings live in the UI?**
→ Gear icon in the `actions:` of both tab app bars (Scan + History), pushing
a `SettingsPage` route — same push-on-top pattern as the capture flow. Third
bottom-nav tab rejected (clutters the daily workflow for a rare operation);
History-only rejected (undiscoverable from the scan flow). Noted that
`ordernumber-entry` is reshaping the Scan screen; the gear-in-appbar is
orthogonal to their body-level Stack change.

**Q4 — Connection testing in settings?**
→ Explicit "Test connection" action that uses the **current form values**
(unsaved): connect + list the target folder. Catches typos at configuration
time. Auto-validate-on-save was rejected — it couples saving to network
availability and blocks offline reconfiguration. Save-only (no test) was
rejected as deferring typos to the bench.

**Q5 — History behavior when settings change?**
→ Auto-refresh: if the saved value actually changed, the History tab
re-lists from the new target. Stale-share confusion isn't acceptable;
pull-to-refresh remains for the unchanged case.

**Q6 — Credential storage security (raised at spec review)?**
→ Standard practice enforced: settings persist through
`flutter_secure_storage` (Android: encrypted at rest via the Keystore;
iOS: Keychain) instead of plaintext `shared_preferences`. The initial
draft accepted plaintext prefs on a "same threat model as
plaintext-in-source" argument; overruled at review — credentials at rest
must be encrypted, and the OS keystore is the platform-standard way.

**Q7 — Credentials in the binary? (raised at spec review)**
→ None. Username and password never ship in the APK: `defaults` seeds only
host / share path / domain, and the user enters the login once on first
startup. Reverses Q2's full-constant seeding for the credential fields;
the out-of-box cost (typing the login once) is accepted.

## Approaches weighed

**A. Mutable globals, minimal diff** — today's constants become mutable
fields; `main()` loads prefs; settings screen writes memory + disk.
Smallest diff, but no change notification (Q5 needs a bolt-on anyway) and
untestable. Rejected.

**B. Immutable settings object + ValueNotifier** — `SmbSettings` value
class owned by the `HomePage` shell as a `ValueNotifier`;
`shared_preferences` for persistence; a tiny shared connect helper replaces
the three duplicated `connectAuth` blocks. Fits the plain-widget idiom
(one small new package; per Q6 that is `flutter_secure_storage` rather
than `shared_preferences`), change detection comes free,
pure-data object is trivially unit-testable. **Chosen.**

**C. State-management package (Provider/Riverpod)** — scales if the app
grows many settings-dependent features, but contradicts the project's
deliberate no-state-library stance and is ceremony for five strings.
Rejected.

## Approved design (2026-09-04)

### Model & persistence

- Immutable `SmbSettings` in `lib/main.dart`: five final fields, `copyWith`,
  `==`/`hashCode` (the `==` powers change detection). `static const
  SmbSettings defaults` seeds only the non-secret fields — host, share
  path, domain, at today's values; username and password default to empty
  and are never compiled into the binary (Q7).
- Storage: `flutter_secure_storage` (added to `pubspec.yaml`, latest
  stable). Keys `smb.host`, `smb.share_path`, `smb.domain`, `smb.username`,
  `smb.password` — all five live in the encrypted store, one code path
  (no split between "safe" and "secret" fields). On Android this is
  encrypted at rest via the Keystore; on iOS, the Keychain.
- `SmbSettings.load()` — any missing key falls back to `defaults`
  field-by-field. `save()` — writes all five keys. Both are async and go
  through an injectable storage seam (a thin wrapper over the plugin) so
  unit tests run against an in-memory fake, no platform channels.
- Loading happens in `_HomePageState.initState`; until it completes the
  value is `defaults` (= today's behavior; fastest human path to an SMB op
  is seconds). No splash gate.
- Out of the box the app is unconfigured: host / share path / domain come
  pre-seeded, the login does not exist anywhere until first startup (see
  Wiring). An APK dump no longer yields a working login.

### Wiring

- `_HomePageState` owns `ValueNotifier<SmbSettings>`; gear icons in both
  tab app bars push `SettingsPage` which updates the notifier on save.
- Shared helper `Future<SmbConnect> connect(SmbSettings)` replaces the
  three identical `connectAuth` blocks. The `openRead`/`BytesBuilder`
  chunk-copy in `ImageViewerPage._load` is untouched (smb_connect reuses
  one buffer per chunk — do not "simplify").
- First-run gate: once settings load, if the username is empty (never
  configured), `HomePage` pushes the setup form modally — host / share
  path / domain pre-seeded, username field focused, back disabled until a
  valid save (username required; password may stay blank). One-time.
- Unconfigured guard: the shared `connect()` helper refuses to dial when
  the username is empty, throwing a user-readable "SMB login not
  configured — open Settings" error; the three op sites surface it in
  their existing banners. Covers credentials cleared in settings later.
- History auto-refresh: `HomePage` re-keys `HistoryPage` on an actual value
  change (`ObjectKey`) → remount → `initState` re-runs `_refresh()`. ~3
  lines, no new coupling.
- Settings changed mid-operation: each SMB op snapshots settings at connect
  time; the in-flight op completes against the old server, the next op uses
  the new one. Accepted.

### SettingsPage UI

- Pushed route, `AppBar('SMB settings')`, `Form` with five fields seeded
  from the current value. Password obscured with a visibility toggle.
  The same widget serves both entry modes: gear-invoked (back discards)
  and first-run setup (back disabled until a valid save).
- Validation: host non-empty (trimmed); share path non-empty and starts
  with `/`; username non-empty; domain and password may be empty
  (blank-password accounts are legal SMB).
- **Test connection**: connects with the form's current (unsaved) values,
  then lists the target folder — verifies auth *and* share existence
  (matches the "share must already exist" contract; sub-folders are still
  created at upload time). Inline result: success with file count, or the
  error text. Disabled while running.
- **Save**: enabled when the form validates; persists, updates the
  notifier, pops. Test is offered but not required before save.
- Back navigation discards unsaved edits — no unsaved-changes dialog
  (YAGNI for a shop tool).

### Error handling

- Test failure → inline error text; retry by pressing Test again.
- Save failure (storage write throws) → SnackBar "Could not save
  settings", stay on the page.
- Notifier change triggers History remount only when the value actually
  differs (guard on `==`).
- Unconfigured state (empty username) → the `connect()` guard message
  above; the test-connection action shows the same wording.
- Startup storage load failure → catch, fall back to `defaults`. If the
  secure store exists but cannot be decrypted (e.g. data restored from a
  cloud backup onto different hardware), clear stored settings and fall
  back to `defaults` (`resetOnError`-style behavior) rather than crash.

### Security practices (consolidated)

1. **No credentials in the binary** — username and password are never
   compiled into the APK (Q7); they exist only in secure storage after
   user entry.
2. **Encrypted at rest** — all five settings, credentials included, go
   through `flutter_secure_storage` (Android Keystore / iOS Keychain).
   Never plaintext `shared_preferences`.
3. **Excluded from backups** — Android cloud backup / device transfer
   would carry an encrypted blob that is undecryptable on any other
   device (the Keystore key never travels), so credential keys are
   excluded via `allowBackup` / `dataExtractionRules` in the manifest.
4. **Obscured entry** — password field renders as dots; the visibility
   toggle is an explicit user action.
5. **No secret leakage in errors/logs** — the app has no logging; SMB
   exception text is surfaced as-is and does not embed the password.
   Keep it that way as code evolves.

### Testing

- `test/smb_settings_test.dart` (pure Dart): per-field seed fallback
  (config fields → defaults, credentials → empty); save/load round-trip
  against the injectable in-memory storage fake.
- Widget test for `SettingsPage` — the first meaningful widget test in this
  repo (no camera/network needed): validation errors on empty host/username
  and malformed share path, password visibility toggle, save updates the
  notifier and pops the route; `HomePage` pushes the first-run setup form
  when settings are unconfigured.
- Real SMB test-connection remains manual on device, like the rest of the
  SMB layer. `flutter analyze` must stay clean (flutter_lints 6).

### Sequencing vs. parallel work

- `ordernumber-entry` edits `_ScannerPageState.build` (body); this change
  edits the same widget's `AppBar` — logically orthogonal, but a textual
  conflict in `lib/main.dart` is expected for whichever lands second. The
  implementation plan must state merge order and the conflict resolution
  (take both: their body Stack + our app-bar actions).
- CLAUDE.md describes the SMB settings as hardcoded constants — that
  section is updated as part of this change's implementation.

## Out of scope

- Named profiles / multiple server configurations
- Auto-validate-on-save; unsaved-changes guard dialog
- Third bottom-nav destination for settings
- Any change to the filename contract or upload/list/download semantics
