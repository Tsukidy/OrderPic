## Why

Right after finishing a capture for an order, operators often need more photos
for the *same* order — but today the only way back in is re-scanning the same
QR tag (or re-typing the number). The number was already confirmed minutes ago;
making the operator find the tag again is pure friction on the hottest path.
A capped, persisted list of recently used order numbers, one tap away beside
the "Type order number" button, turns "another shot for order X" into two taps
with no tag handling at all.

## What Changes

**Scan screen entry points**
- From: two entry paths into a capture — QR scan confirm dialog and the
  "Type order number" dialog — both converging on `_startCapture`.
- To: a third entry path — a "Recent" button beside the type button opens a
  most-recent-first picker; picking a number flows into the same
  Take photo / Gallery confirm dialog and identical capture path.
- Reason: re-capture for a recently used order must not require re-scanning.
- Impact: non-breaking; purely additive alongside the existing paths.

**Persisted recents store**
- From: nothing records which order numbers have started a capture.
- To: every confirmed capture start (QR, typed, or re-picked) records its
  order number into a deduplicated, most-recent-first list capped at 10 —
  oldest overwritten as new orders arrive, so the stored payload never grows.
  Persists across app restarts via the existing injectable `SettingsStore`
  seam (one JSON key); corrupt store degrades to an empty list.
- Reason: the list must survive a restart to cover a whole workday, without
  unbounded storage growth.
- Impact: additive; lives OUTSIDE the `AppSettings` umbrella — deliberate, so
  the parallel `settings-save-change` work (own worktree) is untouched.

**Recents picker dialog**
- From: no recents UI exists.
- To: an always-visible "Recent" button (disabled while the list is empty)
  opens a picker dialog listing the capped numbers; tap one to confirm the
  capture source exactly as a scanned code does.
- Reason: discoverability before first use (matches the always-findable Type
  button precedent) and reuse of the existing confirm-dialog contract.
- Impact: additive; no changes to the existing dialogs' behavior.

## Capabilities

### New Capabilities

- `recent-scans`: the capped, persisted recents list of order numbers that
  have started a capture, the always-visible Recent button on the Scan
  screen, and the pick → confirm → capture flow. Recording semantics
  (any confirmed capture start re-fronts and caps the list) are owned here.

### Modified Capabilities

*(none — `manual-order-entry` keeps owning the type-entry and confirm-dialog
requirements; this change references them, it does not modify them.)*

## Impact

- **Code (new):** `lib/recents/recent_orders.dart` — `RecentOrders` value
  class (load / record / save) over the injectable `SettingsStore` seam, one
  key `recent.orders` holding a JSON array (most-recent-first, capped at 10).
- **Code (edited):** `lib/pages/scanner_page.dart` — bottom row gains the
  always-visible Recent button; async load in state init; recording hook in
  `_startCapture` after the capture session creates successfully; extracted
  `RecentOrdersDialog` picker widget.
- **Tests:** new `test/recent_orders_test.dart` (record/dedup/cap/persist/
  corrupt-fallback), new picker-dialog widget test, shell-level assertions on
  the new button.
- **Untouched:** settings models and saving (`AppSettings`/`UploadPrefs`/
  `ConnectionSettings`/`settings_page.dart`), SMB layer, naming, upload,
  History. No new package dependencies; no schema or external contract
  changes.
