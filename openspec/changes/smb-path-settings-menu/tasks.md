# Tasks — smb-path-settings-menu

Dependency-ordered. References: `specs/smb-settings/spec.md` for WHAT,
`design.md` for HOW (decisions D1–D9).

## 1. Model & storage seam

- [x] 1.1 Add `flutter_secure_storage` (latest stable) to `pubspec.yaml`
      and run `flutter pub get`; note any Android setup its current major
      requires (design Open Question)
- [x] 1.2 Replace the five top-level SMB constants in `lib/main.dart`
      with the immutable `SmbSettings` class: five fields, `copyWith`,
      `==`/`hashCode`, and `static const defaults` seeding ONLY host /
      share path / domain (credentials default to empty — D3)
- [x] 1.3 Create the injectable storage seam: a thin async wrapper over
      `FlutterSecureStorage` (read/write/delete per key, keys
      `smb.host` / `smb.share_path` / `smb.domain` / `smb.username` /
      `smb.password`) plus an in-memory fake for tests (D2)
- [x] 1.4 Implement `SmbSettings.load()` (per-field fallback: config
      fields → `defaults`, credentials → empty) and `save()` (writes all
      five) through the seam, both taking an injectable store
- [x] 1.5 Unit tests in `test/smb_settings_test.dart`: per-field seed
      fallback on missing keys, credentials fall back to empty,
      save/load round-trip against the in-memory fake

## 2. SMB connect consolidation

- [x] 2.1 Add shared `Future<SmbConnect> connect(SmbSettings)` helper
      with the unconfigured guard: throws a readable "SMB login not
      configured — open Settings" error when username is empty, before
      any network dial (D4)
- [x] 2.2 Replace the three inline `connectAuth` blocks
      (`PreviewPage._upload`, `HistoryPage._refresh`,
      `ImageViewerPage._load`) with the helper; keep the
      `openRead` + `BytesBuilder` chunk-copy in `ImageViewerPage`
      verbatim (D8)

## 3. Settings UI

- [x] 3.1 Build `SettingsPage` form: five `TextFormField`s seeded from
      the current settings; password obscured with an explicit
      visibility toggle; validation — host non-empty (trimmed), share
      path non-empty with leading `/`, username non-empty, domain and
      password optional (D5)
- [x] 3.2 Add the Test connection action: connect + list the target
      folder using current unsaved form values; inline success (file
      count) or error; disabled while running; unconfigured form shows
      the guard wording (D6)
- [x] 3.3 Add Save: enabled when the form validates; persists via
      `SmbSettings.save()`, updates the notifier, pops; storage write
      failure → SnackBar "Could not save settings" and stay on page
- [x] 3.4 Dual-mode behavior: gear-invoked mode lets back discard
      edits; first-run mode (setup) disables back until a valid save
      (`PopScope`) (D3, D5)

## 4. Shell wiring

- [x] 4.1 `_HomePageState`: own `ValueNotifier<SmbSettings>`
      (initially `defaults`), load stored settings in `initState`,
      dispose the notifier (D1)
- [x] 4.2 Add gear actions to the Scan and History app bars pushing
      `SettingsPage` with the notifier (D5)
- [x] 4.3 First-run gate: once settings load, if username is empty push
      `SettingsPage` modally in setup mode (post-frame; username
      focused, config fields pre-seeded) (D3)
- [x] 4.4 History auto-refresh: listen to the notifier and re-key
      `HistoryPage` (`ObjectKey`) only on an actual value change (D7)
- [x] 4.5 Startup recovery: load failure → fall back to `defaults`;
      undecryptable store → clear stored settings then `defaults` (the
      empty username re-triggers the gate) (D9)

## 5. Platform hardening

- [x] 5.1 Android manifest: exclude credential storage from cloud
      backup / device transfer (`allowBackup` / `dataExtractionRules`)
      (D9)

## 6. Tests & verification

- [x] 6.1 Widget tests — SettingsPage: validation errors (empty host,
      empty username, share path without leading `/`), password
      visibility toggle, Save updates the notifier and pops the route
- [x] 6.2 Widget tests — first-run gate: `HomePage` pushes setup when
      unconfigured; starts clean (no gate) when configured
- [x] 6.3 `flutter analyze` clean and `flutter test` green
- [ ] 6.4 On-device manual pass: first-run entry, save + restart
      persistence, Test connection against the real share,
      upload / History list / download unchanged, History auto-refresh
      after repointing the share

## 7. Docs & merge

- [x] 7.1 Update CLAUDE.md "SMB layer" section: settings are a
      `SmbSettings` object persisted via `flutter_secure_storage` with
      an in-app settings screen (no longer hardcoded constants)
- [x] 7.2 Merge with `ordernumber-entry` per the implementation plan's
      stated order; resolve the `_ScannerPageState.build` conflict
      take-both (their body Stack + our app-bar actions)
      (resolved trivially: base already contained the merged ordernumber-entry change; verification-only, no conflict)
