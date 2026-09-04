# Proposal — smb-path-settings-menu

## Why

SMB connection settings are hardcoded constants in `lib/main.dart`, so
pointing the app at a different server or account requires a developer
rebuild — and the credentials ship in plaintext inside the APK binary and
would sit in plaintext on disk. This change makes all five connection
settings editable in an in-app settings screen, persists them encrypted
via the OS keystore, and removes credentials from the binary entirely
(one-time entry on first startup). Server or account changes become
self-service, and credential handling reaches platform-standard security.

## What Changes

**SMB connection settings source**
- From: Hardcoded top-level constants in `lib/main.dart` (host, share
  path, domain, username, password); any server/account change requires a
  rebuild.
- To: All five settings editable in an in-app Settings screen, opened
  from a gear icon in the Scan and History app bars, persisted per device.
- Reason: Server/account repointing must be self-service.
- Impact: Non-breaking; the capture flow is unchanged.

**Credential storage**
- From: Username and password compiled into the APK in plaintext.
- To: Credentials entered by the user once on first startup, stored
  encrypted at rest via `flutter_secure_storage` (Android Keystore /
  iOS Keychain), excluded from cloud backups; never present in the
  binary. Host / share path / domain remain pre-seeded.
- Reason: Standard security practice for stored login credentials.
- Impact: Breaking for out-of-box use — first launch requires a one-time
  login entry (host / share path / domain pre-filled).

**Settings change propagation**
- From: Settings are static; History and uploads always target the
  compiled-in server.
- To: Settings are runtime state (`ValueNotifier` owned by the shell).
  History auto re-lists when saved settings actually change; in-flight
  SMB operations complete against the settings they started with.
- Reason: Prevents a stale History listing after repointing the app.
- Impact: Non-breaking.

**SMB connection handling** (additions)
- The three duplicated `connectAuth` call sites (upload, History list,
  image download) are replaced by one shared connect helper that
  snapshots current settings.
- A "Test connection" action in Settings validates the unsaved form
  values against the share before saving (offered, not required).
- Unconfigured guard: any SMB operation with no username configured
  surfaces "SMB login not configured — open Settings" instead of a raw
  auth error.

## Capabilities

### New Capabilities

- `smb-settings`: In-app management of SMB connection settings —
  encrypted persistence, settings UI with connection testing, first-run
  login setup, change propagation to History, and the unconfigured
  operation guard.

### Modified Capabilities

None — `openspec/specs/` is empty (this is the first spec'd change in
the repo). Existing behaviors (filename contract, upload/list/download
semantics) are unchanged.

## Impact

- **Code** (`lib/main.dart`): `SmbSettings` value class + injectable
  storage seam; `SettingsPage` (dual-mode: normal + first-run setup);
  gear actions in both tab app bars; `ValueNotifier` in `_HomePageState`;
  shared `connect()` helper replacing the three `connectAuth` blocks;
  first-run modal push; `HistoryPage` re-key on settings change.
- **Dependencies**: `+ flutter_secure_storage` in `pubspec.yaml`.
- **Android manifest**: `allowBackup` / `dataExtractionRules` excluding
  credential data from backups.
- **Docs**: CLAUDE.md "SMB layer" section (currently describes hardcoded
  constants) is updated.
- **Tests**: new `test/smb_settings_test.dart`; the repo's first widget
  tests (SettingsPage validation, first-run gate); `flutter analyze`
  stays clean.
- **Parallel work**: `ordernumber-entry` edits the same
  `_ScannerPageState.build` (body) this change edits (app bar) — a
  textual conflict is expected for whichever lands second; merge order
  is stated in the implementation plan.

Out of scope: named profiles, auto-validate-on-save, unsaved-changes
guard, a third bottom-nav destination, and any change to the filename
contract or upload/list/download semantics.
