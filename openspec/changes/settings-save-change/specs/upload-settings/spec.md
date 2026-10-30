## MODIFIED Requirements

### Requirement: Upload preferences persistence

The upload preferences — per-order folders toggle, multi-photo batch toggle,
image format (JPEG/PNG), and JPEG quality selection — MUST be editable
in-app and MUST persist across app restarts through the same
platform-encrypted store seam as the connection settings, under `upload.*`
keys. Each preference change MUST be persisted at the moment it is made:
toggles and segment selections on tap, the custom JPEG quality slider on
release (gesture end), and the custom maximum-long-edge field on edit
completion (focus leaving the field, keyboard Done, or the settings page
closing with uncommitted text). The in-app shared settings value MUST
update only after the corresponding store write succeeds; if a store write
fails, the affected control MUST remain at its previous value, the shared
settings value MUST NOT change, and the app MUST surface a save-failure
message. On fresh install or when no values are stored, the preferences
SHALL default to: folders off, batch off, format JPEG, quality Original —
which preserves the pre-change capture and upload behavior.

#### Scenario: Fresh install loads behavior-preserving defaults

- **WHEN** the app runs for the first time with nothing stored under
  `upload.*`
- **THEN** the loaded preferences are folders off, batch off, format JPEG,
  and quality Original, and uploads behave exactly as before this change

#### Scenario: Changing a preference persists without a save action

- **WHEN** the user taps a toggle or segment in the Capture & upload
  section (e.g. switches the format to PNG) and then immediately leaves
  the page without pressing Save
- **THEN** the change is already written to the encrypted store under its
  `upload.*` key and the in-app shared settings value reflects it

#### Scenario: Slider persists on release

- **WHEN** the user drags the custom JPEG quality slider and releases it
- **THEN** the released value is written to the store (and intermediate
  in-drag values are not)

#### Scenario: Edge field persists on edit completion and page close

- **WHEN** the user types a valid maximum-long-edge value and moves focus
  out of the field (or presses Done), or closes the settings page while
  the field holds uncommitted text
- **THEN** the parsed value — or the cleared null for blank text — is
  written to the store in both cases

#### Scenario: Failed store write reverts the control

- **WHEN** a preference's store write fails after the user changes that
  preference
- **THEN** the control displays its previous value, the shared settings
  value is unchanged, and a save-failure message is shown

#### Scenario: Saved preferences survive restart

- **WHEN** the user changes any upload preference and fully restarts the
  app
- **THEN** the changed values are loaded and used for every subsequent
  capture

---

### Requirement: Upload preference changes leave History alone

Changing any upload preference — by whatever interaction persists it —
MUST NOT cause the History tab to re-list or remount; only connection
settings changes do (see the smb-settings capability).

#### Scenario: Folder toggle save does not re-list the share

- **WHEN** the user toggles per-order folders on in Settings and returns
  to an already-visited History tab
- **THEN** History is not remounted and its current listing is unchanged
