# upload-settings Specification

## Purpose
The capture/upload preferences — per-order folders, batch mode, image format, JPEG quality — persisted like the connection settings and edited in the Settings page's "Capture & upload" section.

## Requirements

### Requirement: Upload preferences persistence

The upload preferences — per-order folders toggle, multi-photo batch toggle,
image format (JPEG/PNG), and JPEG quality selection — MUST be editable
in-app and MUST persist across app restarts through the same
platform-encrypted store seam as the connection settings, under `upload.*`
keys. On fresh install or when no values are stored, the preferences SHALL
default to: folders off, batch off, format JPEG, quality Original — which
preserves the pre-change capture and upload behavior.

#### Scenario: Fresh install loads behavior-preserving defaults

- **WHEN** the app runs for the first time with nothing stored under
  `upload.*`
- **THEN** the loaded preferences are folders off, batch off, format JPEG,
  and quality Original, and uploads behave exactly as before this change

#### Scenario: Saved preferences survive restart

- **WHEN** the user changes any upload preference, saves, and fully
  restarts the app
- **THEN** the changed values are loaded and used for every subsequent
  capture

---

### Requirement: Sectioned Settings page

The settings page MUST be titled "Settings" (first-run setup keeps the
"Set up SMB login" title) and MUST present two labeled sections in this
order: "Capture & upload" first, containing the per-order folders toggle,
the multi-photo batch toggle, the image format picker, and the JPEG
quality control; "SMB connection" second, containing the five connection
fields and the Test connection action.

#### Scenario: Sections appear in the specified order

- **WHEN** the user opens Settings from the gear action on either tab
- **THEN** the page shows a "Capture & upload" section above an
  "SMB connection" section, with all capture controls in the former and
  all five connection fields plus Test connection in the latter

---

### Requirement: PNG format hides quality controls

When the image format is set to PNG, the Settings page MUST NOT show any
quality or resize controls, and captures in PNG mode MUST be converted
losslessly at full size with no re-encoding quality loss. When the format
is switched back to JPEG, the quality controls MUST reappear with their
previous selection.

#### Scenario: Selecting PNG hides the quality controls

- **WHEN** the user selects PNG as the image format in Settings
- **THEN** no quality or dimension controls are visible on the page

#### Scenario: Switching back to JPEG restores quality controls

- **WHEN** the user switches the format from PNG back to JPEG
- **THEN** the JPEG quality selection reappears showing the previously
  saved JPEG quality value

---

### Requirement: JPEG quality options

The JPEG quality control MUST offer the presets Original, High, Balanced,
and Small, plus a Custom option consisting of a quality percentage
(30–100) and an optional maximum long-edge dimension in pixels. Presets
SHALL map deterministically: Original = no re-encode of the picked file;
High = quality 90 with no dimension cap; Balanced = quality 80 with a
2560px long-edge cap; Small = quality 70 with a 1080px long-edge cap.
Custom values below 30 or above 100 MUST NOT be settable.

#### Scenario: Preset maps to deterministic processing parameters

- **WHEN** the JPEG quality selection is Balanced and a photo is admitted
  to a capture session
- **THEN** the shot is re-encoded at quality 80 with its long edge capped
  at 2560 pixels

#### Scenario: Original preset leaves bytes untouched

- **WHEN** the JPEG quality selection is Original and a photo is admitted
- **THEN** the shot's bytes are identical to the picked file (no
  re-encode, no resize)

#### Scenario: Custom quality stays within bounds

- **WHEN** the user drags the Custom quality slider
- **THEN** the selectable range is clamped to 30–100

---

### Requirement: Upload preference changes leave History alone

Saving a change to any upload preference MUST NOT cause the History tab to
re-list or remount; only connection settings changes do (see the
smb-settings capability).

#### Scenario: Folder toggle save does not re-list the share

- **WHEN** the user toggles per-order folders on, saves, and returns to an
  already-visited History tab
- **THEN** History is not remounted and its current listing is unchanged
