# Design — smb-path-settings-menu

## Context

MMCPic is a Flutter app (Android-primary, plain `StatefulWidget`s in a
single `lib/main.dart`, deliberately no state-management library) for a
photo-capture workflow: scan a QR order number → photograph the item →
upload to a Windows SMB share; a History tab lists/views share images.

Today the SMB connection is five hardcoded top-level constants
(`lib/main.dart:10-15`): host, share path, domain, username, password —
including credentials in plaintext in the binary. They are consumed at
three sites, each opening a fresh `SmbConnect.connectAuth` connection
(upload in `PreviewPage`, listing in `HistoryPage`, download in
`ImageViewerPage`). Repointing the app at another server or account
requires a rebuild.

Stakeholders: shop-floor users (scan/photo/upload daily), and whoever
maintains the SMB server. A parallel change (`ordernumber-entry`, active
worktree) is reshaping the Scan screen body concurrently.

## Goals / Non-Goals

**Goals:**

- All five SMB settings editable in-app; server/account changes without a
  rebuild.
- Credentials encrypted at rest (OS keystore) and excluded from backups.
- No credentials in the APK binary; one-time login entry on first startup.
- Validate configuration before saving via an optional connection test.
- History reflects the current settings target automatically.
- First unit and widget tests in the repo, enabled by an injectable
  storage seam.

**Non-Goals:**

- Named profiles / multiple server configurations.
- Auto-validation coupled to saving; unsaved-changes guard dialog.
- A third bottom-nav destination for settings.
- Changes to the filename contract or upload/list/download semantics.
- iOS/desktop polish (Android-primary; plugin supports them, untested here).

## Decisions

### D1: State architecture — immutable `SmbSettings` + `ValueNotifier`
- **選擇**: An immutable five-field value class (`copyWith`, `==`,
  `hashCode`) held by `_HomePageState` as a `ValueNotifier<SmbSettings>`.
- **理由**: Fits the plain-widget idiom; `==` gives change detection for
  free (D7); pure data is trivially unit-testable; no new architecture
  concepts in a single-file app.
- **已考慮 alternative**: Mutable top-level globals (smallest diff, but no
  change notification and untestable — rejected); Provider/Riverpod
  (scales, but contradicts the project's deliberate no-state-library
  stance for five strings — rejected).

### D2: Persistence — `flutter_secure_storage`, all five fields, injectable seam
- **選擇**: All five settings in `flutter_secure_storage` under keys
  `smb.host`, `smb.share_path`, `smb.domain`, `smb.username`,
  `smb.password` (Android Keystore encryption at rest / iOS Keychain).
  `load()`/`save()` are async static methods that take an injectable thin
  storage wrapper, defaulting to the real plugin; unit tests run against
  an in-memory fake.
- **理由**: Platform-standard encrypted credential storage; one code path
  (no "safe vs secret" field split); the seam keeps the model testable
  without platform channels.
- **已考慮 alternative**: `shared_preferences` (plaintext XML on disk —
  rejected at review; sandboxing stops other apps, not at-rest exposure,
  rooted devices, or backup leakage).

### D3: Credential lifecycle — nothing in the binary, first-run entry
- **選擇**: `SmbSettings.defaults` seeds only host / share path / domain
  (today's values). Username and password default to empty and are never
  compiled in. On startup, if the loaded username is empty, `HomePage`
  pushes the setup form modally — config fields pre-seeded, username
  focused, back disabled until a valid save (username required, password
  may stay blank).
- **理由**: An APK dump yields no working login; the one-time entry cost
  is acceptable for a device configured once.
- **已考慮 alternative**: Full constant seeding incl. credentials
  (out-of-box zero-touch, but ships secrets in the binary — reversed at
  review); empty seed for all fields (more first-run typing for no
  security gain — config values aren't secret).

### D4: Unconfigured guard — shared `connect()` refuses cleanly
- **選擇**: The shared connect helper throws a user-readable "SMB login
  not configured — open Settings" error when username is empty; the three
  op sites surface it in their existing error banners. Settings'
  test-connection action shows the same wording.
- **理由**: Covers credentials-cleared-later with one check in one place;
  no per-site changes; friendly message instead of a raw SMB auth error.
- **已考慮 alternative**: Pre-flight checks at each call site (three
  copies of the same guard — rejected).

### D5: Settings UI — gear icons + dual-mode `SettingsPage`
- **選擇**: Gear action in both tab app bars pushes a `SettingsPage`
  route (same push-on-top pattern as the capture flow). One `Form` with
  five fields; password obscured with a visibility toggle. The same
  widget serves gear-invoked mode (back discards) and first-run mode
  (back disabled until valid save). Validation: host non-empty (trimmed),
  share path non-empty with leading `/`, username non-empty; domain and
  password may be empty.
- **理由**: Rare operation, always reachable from either tab; one widget,
  two entry modes, no duplication; stays orthogonal to `ordernumber-entry`'s
  body-level Scan changes (app bars are untouched there).
- **已考慮 alternative**: Third bottom-nav destination (clutters daily
  workflow — rejected); History-only entry (undiscoverable from scan
  flow — rejected); separate first-run wizard widget (duplicates the form
  — rejected).

### D6: Connection testing — optional, uses unsaved form values
- **選擇**: "Test connection" dials with the form's current values,
  then lists the target folder — verifying auth and share existence
  (share must already exist; sub-folders are still created at upload).
  Inline success (file count) or error; disabled while running. Offered
  but not required before Save.
- **理由**: Catches typos at configuration time without coupling saving
  to network availability.
- **已考慮 alternative**: Auto-validate on save (blocks offline
  reconfiguration — rejected); no test at all (defers typos to the bench
  — rejected).

### D7: Change propagation — re-key History; snapshot in-flight ops
- **選擇**: `HomePage` listens to the notifier; on an actual value change
  (`==` guard) it re-keys `HistoryPage` (`ObjectKey`) so the tab remounts
  and re-lists. Each SMB operation snapshots settings at connect time;
  in-flight operations complete against the old target.
- **理由**: ~3 lines, no new coupling; lazy History construction works
  unchanged (a tab first visited after a change builds fresh anyway).
- **已考慮 alternative**: Manual pull-to-refresh only (silently stale
  after repointing — rejected); cancelling in-flight ops on change
  (complexity for no practical benefit — rejected).

### D8: SMB connect consolidation — one helper, three call sites
- **選擇**: A shared `Future<SmbConnect> connect(SmbSettings)` replaces
  the three identical `connectAuth` blocks. The `openRead` +
  `BytesBuilder` chunk-copy in `ImageViewerPage` is preserved verbatim
  (smb_connect reuses one buffer for every yielded chunk — copying is
  mandatory, not an optimization).
- **理由**: Deduplicates; makes "settings at connect time" (D7) explicit;
  single place for the D4 guard.
- **已考慮 alternative**: Keep three inline `connectAuth` calls (drifts
  from the settings object — rejected).

### D9: Platform hardening — backups, entry, recovery
- **選擇**: Android manifest excludes credential data from cloud backup /
  device transfer (`allowBackup` / `dataExtractionRules`) — an encrypted
  blob is undecryptable on other hardware anyway (the Keystore key never
  travels). Startup load failure → catch, fall back to `defaults`;
  undecryptable store → clear and fall back (`resetOnError`-style) —
  which naturally re-triggers the first-run gate, since username is then
  empty. No logging; SMB exception text (which never embeds the
  password) is surfaced as-is.
- **理由**: Each measure closes a concrete leakage or bricking path with
  ~one line of config or one catch clause.
- **已考慮 alternative**: Relying on sandbox isolation alone (rejected
  with D2); crashing on corrupt store (rejected — the gate recovers
  gracefully).

## Risks / Trade-offs

- [Risk] `flutter_secure_storage` Keystore quirks on some Android
  devices/OEMs → Mitigation: `resetOnError`-style recovery to defaults +
  first-run gate; verify on the actual shop device during the verify
  phase before archiving.
- [Risk] Textual merge conflict with `ordernumber-entry` in
  `_ScannerPageState.build` (their body Stack vs our app-bar actions) →
  Mitigation: implementation plan states merge order; resolution is
  "take both" — the edits don't overlap semantically.
- [Risk] First-run gate on a shared device where nobody knows the login
  yet → Mitigation: gate shows testable form values (host/path/domain
  pre-seeded); test connection can be run before saving; nothing is
  locked out permanently (app kill/relaunch returns to the gate).
- [Trade-off] Settings are not backed up — device replacement/reinstall
  re-enters login once → accepted: credentials never leave the device;
  config fields re-seed automatically.
- [Trade-off] Test-before-save is optional — a typo'd config can still be
  saved → accepted: offline reconfiguration stays possible; typos surface
  via existing upload-failed/retry UX.
- [Trade-off] SMB auth on the wire is only as encrypted as the
  server/smb_connect negotiation → accepted: out of scope; LAN shop
  network, unchanged from today.
- [Trade-off] Blank passwords allowed (username is the required field) →
  accepted: blank-password accounts are legal SMB; validation matches
  reality.

## Migration Plan

No server, endpoint, or data deployment — app-only change.

1. Implement in dependency order: model + storage seam → connect helper +
   guard → SettingsPage (both modes) → shell wiring (notifier, gear
   actions, first-run gate, History re-key) → manifest backup rules →
   CLAUDE.md SMB-layer section update.
2. Verify: `flutter analyze` clean; `flutter test` (unit + widget) green;
   on-device manual pass — first-run gate, save, test connection, restart
   persistence, upload/history/download against the real share, History
   auto-refresh after repointing.
3. Merge with `ordernumber-entry` per the plan's stated order; conflict
   resolution is take-both.
4. Existing installs updating to this build: no stored settings exist, so
   the first-run gate appears once after update. Rollback = redeploy the
   previous APK (constants return); any settings stored by the new build
   are simply ignored by the old one.

## Open Questions

- Merge order with `ordernumber-entry` — which branch lands on `main`
  first? (Scheduling decision; either order works, the second lander
  resolves the textual conflict.)
- Exact `flutter_secure_storage` version — pin latest stable at
  implementation time; majors have changed platform config requirements
  historically, so the plan should note the AndroidManifest minSdk/
  setup step if the current major requires one.
