## Context

OrderPic's Scan screen has two entry paths into a capture — the QR-scan
confirm dialog and the "Type order number" dialog — and both converge on one
method, `ScannerPage._startCapture(orderNumber, source:)`. Immediately
re-using a just-captured order currently forces the operator back to the
physical QR tag. This change adds a third entry path: a recents picker.

Constraints that shaped the design:

- A sibling change, `settings-save-change`, works in its own worktree on the
  settings feature and its saving functionality. This change must not edit
  settings models, settings saving, or the `AppSettings` umbrella.
- Persistence in this repo goes through the injectable `SettingsStore` seam
  (flutter_secure_storage behind it; `InMemorySettingsStore` in tests). There
  is no shared_preferences dependency and none should be added.
- `manual-order-entry` (existing capability) owns the typed-entry and
  confirm-dialog requirements; this change sits beside it, references it,
  and must not modify it.
- The stored recents list must be size-capped with oldest-overwritten — no
  unbounded growth (explicit user constraint).

## Goals / Non-Goals

**Goals:**

- One-tap re-capture of a recently used order number from the Scan screen.
- Recents persist across app restarts, capped at 10, most-recent first,
  duplicates collapsing (re-use re-fronts).
- Every confirmed capture start records — QR-scanned, typed, and re-picked
  alike — through a single hook.
- Zero changes to settings models/saving, SMB, naming, upload, or History.
- Logic fully unit-testable without platform channels; picker dialog
  widget-testable without the camera.

**Non-Goals:**

- No timestamps shown in the picker, no per-entry delete, no manual clear-all.
- No recents management UI (renaming, pinning) and no settings surface for
  the cap size.
- No cross-device sync — recents are per-device (secure storage is per-device
  already).
- No changes to the History tab (it lists the share, not local recents).
- No change to which order numbers are *valid* — recents simply store what an
  entry path already accepted.

## Decisions

### D1: Recents live OUTSIDE `AppSettings` — own `RecentOrders` class over the `SettingsStore` seam

- **選擇：** New `lib/recents/recent_orders.dart` holding a small value class
  (`List<String> orders`, most-recent-first) with `load` / `record` / `save`
  taking an optional `SettingsStore`. `ScannerPage` state owns the instance.
- **理由：** Recents are session history, not preferences; keeping them out of
  `AppSettings` avoids mutating settings equality on every capture and keeps
  every write out of the code path the parallel `settings-save-change`
  worktree owns. The seam keeps the logic unit-testable.
- **已考慮 alternative：** A third half inside the `AppSettings` umbrella —
  free plumbing, but wrong concept, churns settings equality per capture, and
  collides with the sibling worktree. Rejected.

### D2: One JSON-array key, capped at write time

- **選擇：** Single key `recent.orders` holding a JSON array of the numbers,
  most-recent-first; `record()` dedups (move-to-front), inserts, then trims
  to 10 before `save()` writes the whole array. Max payload stays a few
  hundred bytes forever.
- **理由：** Satisfies the user's explicit no-bloat constraint; one read at
  startup, one write per capture; atomic whole-list replace avoids
  partial-state keys.
- **已考慮 alternatives：** Per-entry keys (`recent.0`…`recent.9`) — more
  writes, index-shifting churn, no benefit; session-only memory — rejected by
  the user (must survive restart).

### D3: Recording hook = `_startCapture`, after the capture session creates successfully

- **選擇：** `_startCapture` calls `record(orderNumber)` + best-effort
  `save()` right after `CaptureSession.create` succeeds, before pushing
  `CameraPage`.
- **理由：** `_startCapture` is the single convergence point of all three
  entry paths, so one hook covers them all and a re-pick re-fronts with no
  special case. Recording only after a successful session create keeps
  dismissed scans and failed creates out of recents — the list answers
  "what have I actually worked on".
- **已考慮 alternatives：** Recording at scan-detect time (pollutes with
  scans the operator dismissed); per-dialog hooks (three copies that drift).

### D4: Always-visible "Recent" button, disabled while the list is empty

- **選擇：** The bottom `Positioned` row becomes a `Row` of two `Expanded`
  buttons: the existing "Type order number" tonal button and a new "Recent"
  tonal button (`Icons.history`), same position. Recent is disabled until the
  loaded list is non-empty; the async load resolves with the button disabled
  and flips enabled on arrival.
- **理由：** User's explicit choice — matches the Type button's
  always-findable precedent; no dead-empty-dialog state to explain.
- **已考慮 alternatives：** Hidden-until-nonempty (rejected by user);
  always-visible-but-opens-empty-list (a third dialog state for no gain).
  Display note: long scanned values render in a standard list tile with
  ellipsis so a pathological QR string cannot blow out the dialog layout.

### D5: Picking a number reuses the existing source-confirm contract

- **選擇：** Tap a number in the picker → picker pops with the number → the
  same `CaptureSource` confirm dialog a scanned code gets (Take photo /
  Gallery; **Cancel** in place of Rescan — nothing to rescan) →
  `_startCapture`.
- **理由：** Reuses both dialogs' existing output shape (`CaptureSource?`)
  and the `_processing` guard unchanged; consistent two-tap flow, identical
  to scan → confirm.
- **已考慮 alternative：** Inline camera/gallery icons per picker row (one
  tap fewer) — crowded rows, hidden affordance, and the confirm step would
  no longer match the other two entry paths. Rejected.

### D6: Corrupt store degrades to an empty list; saves are best-effort

- **選擇：** `load` try/catches decode failures → empty list, no wipe;
  `save` failures are swallowed (the in-memory copy already reflects the new
  state).
- **理由：** Mirrors `UploadPrefs.load` — nothing in recents is secret or
  setup-gating, so a wipe (the `ConnectionSettings` pattern) would only
  destroy useful data. A storage failure must never fail the capture that is
  about to start.
- **已考慮 alternative：** Wipe-and-defaults like `ConnectionSettings.load` —
  rejected: there is no "setup" to re-trigger here.

### D7: `RecentOrdersDialog` is a standalone widget

- **選擇：** The picker is its own widget taking the numbers list and popping
  the picked number (null on dismiss).
- **理由：** Widget-testable without the MobileScanner platform view; keeps
  `scanner_page.dart` from growing another inline dialog builder.

## Risks / Trade-offs

- [Risk] Two devices on the same share keep independent recents lists →
  **Mitigation / accepted:** recents are per-device by design; the share's
  History remains the cross-device record.
- [Risk] A QR payload can be an arbitrary string (typed entry is
  digits-limited; scanned values are not length-limited today) →
  **Mitigation:** recents store whatever the entry path already accepted (no
  new validity rule); display uses ellipsis; the 10-cap bounds payload size
  regardless.
- [Risk] Async load races the first user tap → **Mitigation:** the button is
  disabled until load completes, so an empty-list tap cannot open a broken
  dialog.
- [Risk] `_processing`/camera-controller state bugs around the new dialog →
  **Mitigation:** the picker follows the exact `_processing`-guard +
  resume-on-cancel pattern of the existing entry dialog; cancel path
  re-enables detection.
- [Trade-off] No timestamps in the picker → accepted: two similar numbers are
  rare in a 10-entry same-day list; timestamps add UI noise now and can be
  added later without a storage-format break (append-only change).
- [Trade-off] Last-writer-wins on concurrent writes within one device →
  accepted: writes are serialized by the single-user capture flow; each write
  replaces the whole array.

## Migration Plan

N/A — pure additive app feature: no schema/endpoint/DB changes, no settings
keys renamed, no data to migrate. Rollback = revert the commit. First launch
after the change simply starts with an empty recents list (button disabled)
and fills as captures happen.

Acceptance: `flutter analyze` clean; full `flutter test` green including the
new `recent_orders_test.dart`, the picker widget test, and shell-level button
assertions; on-device spot check of scan → capture → recent re-capture (the
repo norm: capture flow verified on a physical device with a LAN share).

## Open Questions

None blocking. Cap size (10) is a constant, not a setting — revisiting it
later is a one-line change and deliberately kept out of Settings to stay
clear of the parallel `settings-save-change` work.
