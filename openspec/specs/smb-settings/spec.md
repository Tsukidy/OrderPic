# smb-settings Specification

## Purpose

In-app management of MMCPic's SMB connection settings (host, share path,
domain, username, password): encrypted persistence via the OS keystore, a
settings screen with optional connection testing, first-run login setup,
change propagation to History, and the unconfigured-operation guard.

## Requirements

### Requirement: Settings editing and encrypted persistence

All five SMB connection settings — host, share path, domain, username,
password — MUST be editable in-app, and saved values MUST persist across
app restarts. Persistence MUST go through the platform-encrypted store
(`flutter_secure_storage`: Android Keystore / iOS Keychain); plaintext
preferences storage MUST NOT be used for any of the five settings.

#### Scenario: Saved settings survive restart

- **WHEN** the user edits any of the five fields in Settings and saves
- **THEN** the app, after a full restart, loads and uses the saved values
  for every SMB operation

#### Scenario: Persistence goes through the encrypted store

- **WHEN** settings are saved
- **THEN** all five values are written via the encrypted storage seam, and
  no plaintext preferences file contains any of them

---

### Requirement: No credentials in the binary

Username and password MUST NOT be compiled into the app binary or any
shipped asset. Default settings SHALL seed only the non-secret fields —
host, share path, domain — with their current values; username and
password SHALL default to empty strings.

#### Scenario: Fresh install has no stored login

- **WHEN** the app runs for the first time with nothing stored
- **THEN** the loaded settings contain the seeded host, share path, and
  domain, and an empty username and password

---

### Requirement: First-run setup gate

On startup, if the loaded settings have an empty username, the app MUST
present the settings form modally with host / share path / domain
pre-seeded and the username field focused. Back navigation MUST be
disabled until a valid save; a save MUST require a non-empty username and
MAY allow a blank password. After a valid save, the gate SHALL NOT be
shown again on subsequent launches.

#### Scenario: Fresh launch shows the gate

- **WHEN** the app starts with an empty username
- **THEN** the setup form is pushed modally over the tab shell with
  config fields pre-seeded and back disabled

#### Scenario: Save without a username is blocked

- **WHEN** the user attempts to save with an empty username
- **THEN** validation rejects the save and the gate remains

#### Scenario: Valid save dismisses the gate permanently

- **WHEN** the user saves a valid username (password optional)
- **THEN** the form closes, settings persist, and the next launch starts
  directly on the Scan tab

---

### Requirement: Settings entry and form validation

Settings MUST be reachable from a gear action in the app bar of both the
Scan and History tabs. The form SHALL validate that the host is non-empty
after trimming, the share path is non-empty and begins with `/`, and the
username is non-empty; domain and password SHALL be optional. The password
field MUST obscure input, with visibility behind an explicit toggle. In
gear-invoked mode, back navigation discards unsaved edits.

#### Scenario: Settings reachable from both tabs

- **WHEN** the user taps the gear icon in the Scan or History app bar
- **THEN** the Settings page opens with all five fields seeded from the
  current settings

#### Scenario: Malformed share path is rejected

- **WHEN** the share path field does not start with `/` (or is empty)
- **THEN** the field shows a validation error and Save is disabled

#### Scenario: Password visibility toggle

- **WHEN** the user toggles visibility on the password field
- **THEN** the field switches between obscured and plain text

---

### Requirement: Connection testing before save

Settings MUST offer a Test connection action that connects and lists the
target folder using the form's current unsaved values. The result SHALL
display inline: success with the number of files found, or the error
text. The action MUST be disabled while a test is running, and running a
test MUST NOT be required before saving.

#### Scenario: Successful test reports file count

- **WHEN** the user runs Test connection with valid form values that
  reach a working share
- **THEN** an inline success message shows the number of files in the
  target folder

#### Scenario: Failed test shows the error inline

- **WHEN** Test connection cannot connect or authenticate
- **THEN** an inline error message shows the failure text and the form
  remains editable

#### Scenario: Saving without testing is allowed

- **WHEN** the user saves valid form values without running Test
  connection
- **THEN** the settings persist and the page pops

---

### Requirement: Unconfigured operation guard

Any SMB operation — upload, History listing, image download, or a
settings connection test — attempted while the username is empty MUST
fail fast with the message "SMB login not configured — open Settings"
without attempting a network connection.

#### Scenario: Upload attempt while unconfigured

- **WHEN** the user confirms an upload with no username configured
- **THEN** the upload error banner shows the guard message instead of an
  SMB authentication error

#### Scenario: History listing while unconfigured

- **WHEN** the History tab loads with no username configured
- **THEN** the error view shows the guard message

---

### Requirement: Settings change propagation

When saved settings actually change (per value equality), the History tab
SHALL re-list from the new target on next presentation; re-saving
unchanged values SHALL NOT remount History. Every SMB operation SHALL use
the settings snapshot taken when the operation connects; a settings change
mid-operation MUST NOT affect the in-flight operation.

#### Scenario: History follows a repointed share

- **WHEN** settings are saved with a different host or share path and the
  user opens (or is on) the History tab
- **THEN** History lists from the new target

#### Scenario: Unchanged save leaves History alone

- **WHEN** settings are re-saved with identical values
- **THEN** History is not remounted and keeps its current listing

#### Scenario: In-flight upload is unaffected

- **WHEN** settings change while an upload is in progress
- **THEN** the upload completes against the target it connected to, and
  the next operation uses the new settings

---

### Requirement: Backup exclusion and store recovery

Credential data MUST be excluded from Android cloud backup and device
transfer (via `allowBackup` / `dataExtractionRules`). If stored settings
cannot be read or decrypted at startup, the app MUST clear stored
settings and fall back to defaults — which re-triggers the first-run
gate — instead of crashing.

#### Scenario: Credentials excluded from backup

- **WHEN** the Android manifest and backup rules are inspected
- **THEN** the credential storage keys are excluded from cloud backup and
  device transfer

#### Scenario: Undecryptable store recovers gracefully

- **WHEN** startup finds stored settings that cannot be decrypted (e.g.
  data restored from another device)
- **THEN** stored settings are cleared, defaults apply, and the first-run
  gate is presented
