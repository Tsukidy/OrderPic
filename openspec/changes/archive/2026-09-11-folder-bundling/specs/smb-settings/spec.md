# smb-settings delta — folder-bundling

## MODIFIED Requirements

### Requirement: Settings entry and form validation

Settings MUST be reachable from a gear action in the app bar of both the
Scan and History tabs. The settings page MUST be titled "Settings" (the
first-run setup mode keeps the title "Set up SMB login") and MUST present
two labeled sections in this order: "Capture & upload" (managed by the
upload-settings capability) above "SMB connection". The five connection
fields — host, share path, domain, username, password — MUST live in the
SMB connection section, and the form SHALL validate that the host is
non-empty after trimming, the share path is non-empty and begins with `/`,
and the username is non-empty; domain and password SHALL be optional. The
password field MUST obscure input, with visibility behind an explicit
toggle. In gear-invoked mode, back navigation discards unsaved edits.

#### Scenario: Settings reachable from both tabs

- **WHEN** the user taps the gear icon in the Scan or History app bar
- **THEN** the Settings page opens with all five connection fields seeded
  from the current settings

#### Scenario: Malformed share path is rejected

- **WHEN** the share path field does not start with `/` (or is empty)
- **THEN** the field shows a validation error and Save is disabled

#### Scenario: Password visibility toggle

- **WHEN** the user toggles visibility on the password field
- **THEN** the field switches between obscured and plain text

#### Scenario: Connection fields sit below the capture section

- **WHEN** the Settings page is open
- **THEN** the "Capture & upload" section appears above the
  "SMB connection" section containing the five fields and Test connection

---

### Requirement: Settings change propagation

When saved connection settings actually change (per value equality on the
connection settings alone), the History tab SHALL re-list from the new
target on next presentation; re-saving unchanged connection values SHALL
NOT remount History. Saving changes that affect only the upload
preferences (folders, batch, format, quality) MUST NOT remount or re-list
History. Every SMB operation SHALL use the settings snapshot taken when
the operation connects; a settings change mid-operation MUST NOT affect
the in-flight operation.

#### Scenario: History follows a repointed share

- **WHEN** settings are saved with a different host or share path and the
  user opens (or is on) the History tab
- **THEN** History lists from the new target

#### Scenario: Unchanged save leaves History alone

- **WHEN** settings are re-saved with identical values
- **THEN** History is not remounted and keeps its current listing

#### Scenario: Upload-only save leaves History alone

- **WHEN** settings are saved with identical connection values but a
  changed upload preference (e.g. the folders toggle)
- **THEN** History is not remounted and keeps its current listing

#### Scenario: In-flight upload is unaffected

- **WHEN** settings change while an upload is in progress
- **THEN** the upload completes against the target it connected to, and
  the next operation uses the new settings
