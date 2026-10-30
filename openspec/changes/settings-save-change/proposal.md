# settings-save-change — proposal

## Why

Every control on the Settings page — capture/upload preferences included
— persists only when the Save button is pressed, and back discards
everything. An operator who flips the format segment or the folders
toggle and leaves the page silently loses the choice. Android preference
screens apply changes immediately; discard-without-save should be a
deliberate behavior reserved for the connection form (a half-entered
credential set is exactly what must not persist), not a side effect of
toggling a checkbox.

## What Changes

**Capture & upload prefs — write-through**
- From: local edit state only; the prefs half persists solely via the
  Save button (which persists the whole `AppSettings`)
- To: controls read the shared `ValueNotifier<AppSettings>`; each change
  persists immediately — toggles/segments on tap, quality slider on
  release, custom max-edge field on edit complete (plus a flush when the
  page closes); a failed store write leaves the control unchanged and
  shows the existing "Could not save settings" snackbar
- Reason: no silent loss on back; applied-live and persisted can never
  diverge; process-death safe
- Impact: `lib/settings/settings_page.dart` state model and its widget
  tests; observable to the rest of the app only through the existing
  notifier (which now updates mid-edit rather than at save)

**SMB connection section — Save persists the connection only**
- From: Save persists the whole `AppSettings` (connection + upload
  halves together)
- To: Save validates and persists the five connection fields exactly as
  today; upload prefs no longer ride Save
- Reason: the explicit form stays the deliberate, validated,
  first-run-gating path for credentials
- Impact: none for connection behavior (validation, Test connection,
  back-discards in gear mode, first-run gate all unchanged); History's
  remount key and the live-instance discipline are preserved verbatim

## Capabilities

### New Capabilities

(none — the write-through behavior lives inside the existing
upload-settings capability)

### Modified Capabilities

- `upload-settings`: "Upload preferences persistence" becomes
  persist-at-the-moment-of-change (per-control timing, failure → revert
  + snackbar) instead of persist-on-save; "Upload preference changes
  leave History alone" keeps its invariant with the trigger reworded
  from saving to changing

## Impact

- Code: `lib/settings/settings_page.dart` (state model: prefs read the
  notifier; a serialized persist-commit queue; Save calls
  `ConnectionSettings.save` only). No other lib file moves — HomePage,
  the store seam, and the model classes are untouched.
- Tests: `test/settings_page_test.dart` (save-gated pref tests rewritten
  to write-through; new failure/revert, slider-release, edit-complete,
  flush-on-close, connection-only-save, back-discards-connection cases)
- Specs: delta on `openspec/specs/upload-settings/` only
- Dependencies: none added; storage keys unchanged; no migration
