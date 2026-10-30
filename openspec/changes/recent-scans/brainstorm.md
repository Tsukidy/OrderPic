<!--
Raw capture of superpowers:brainstorming output.

本檔原樣捕捉 brainstorming skill 的產出，不強制結構。
Skill 的自然產出通常是 decision log 格式（背景 → 決議鏈 Q1-Qn → 設計取捨），
但依對話內容可能有不同組織方式。

design.md 從本檔萃取並重新整理為結構化設計文件。

不要將本檔的內容複製到 design.md — design.md 是獨立的重組產物，
兩者互補但不重疊。
-->

# Brainstorm — recent-scans

## Background / request

Operators scan a QR-coded order number, photograph, upload. A common beat:
moments after finishing order X, another photo for the *same* order is needed —
re-scanning the same QR tag is friction. Request: a button alongside the
"Type order number" button on the Scan screen that lists recently used order
numbers, so one tap re-selects instead of a re-scan.

Classification: bounded feature on an existing flow (the scanner's confirm
dialog path already exists and is readable), with one new concern — a recents
store. Taken at the architectural path's artifact depth because the
superpowers-bridge schema prescribes the full chain anyway.

## Constraint: parallel worktree

A sibling change, `settings-save-change`, works in its own worktree on the
settings feature and its saving functionality. This change must not touch
settings-saving code paths. This constraint directly shaped the architecture
choice (recents live OUTSIDE the `AppSettings` umbrella).

## Code exploration findings (grounding)

- `ScannerPage` (`lib/pages/scanner_page.dart`) owns both existing entry
  paths: `_onDetect` (QR → confirm dialog → `_startCapture`) and
  `_showEntryDialog` (typed → confirm dialog → `_startCapture`).
  `_startCapture(orderNumber, source:)` is THE convergence point — the
  single place every confirmed capture flows through.
- Confirm dialogs pop a `CaptureSource?` (camera / gallery / null) —
  both dialogs already share this output shape; `_processing` suppresses
  barcode detection while any dialog is up.
- The "Type order number" button is a `FilledButton.tonalIcon` in a
  `Positioned` row at the bottom of the scanner Stack (left/right 16,
  bottom 16).
- Persistence pattern in this repo: the injectable `SettingsStore` seam
  (flutter_secure_storage behind it), namespaced string keys
  (`smb.*`, `upload.*`), `InMemorySettingsStore` test helper. `UploadPrefs.load`
  degrades corrupt values to defaults without wiping; `ConnectionSettings.load`
  wipes. No shared_preferences dependency exists.
- Existing capability specs: `manual-order-entry` (the typed path — its dialog
  behaviors mirror what recents need), `photo-naming`, `batch-capture`,
  `smb-settings`, `upload-settings`, `order-folders`.
- Test surface: no `scanner_page_test.dart` exists (MobileScanner needs a
  camera), but `home_page_test.dart` pumps the real shell and ScannerPage
  renders with its errorBuilder — shell-level assertions on the scanner's
  buttons are feasible. Logic tests ride the `SettingsStore` seam.

## Decision chain

### Q1 — Which order numbers get recorded?

Options: (a) any confirmed capture — QR-scanned, typed, re-picked; one hook
at the shared convergence point; (b) QR-scanned only — typed numbers never
appear, and the re-pick path still records, making typing a second-class
citizen in a feature about reuse.

**Decision: (a) any confirmed capture.** Record at the moment the capture
flow actually starts (`_startCapture`, after `CaptureSession.create`
succeeds), so a dismissed dialog or a failed session-create never pollutes
recents, and re-picking an order re-fronts it by the same mechanism.
User confirmed.

### Q2 — Persistence lifetime?

Options: (a) persisted across restarts; (b) session-only in-memory.
User chose **persisted** — and added a constraint: the store must have a max
size with the oldest entry overwritten as new ones arrive, so the stored
payload can never bloat.

**Decision: persisted via the existing injectable `SettingsStore` seam, one
JSON-array key (`recent.orders`), capped at 10 entries at write time.** Max
payload ~ a few hundred bytes forever. Corrupt/unreadable store → empty
list, no wipe (mirrors `UploadPrefs.load`; nothing secret, and wiping must
not be able to touch the SMB keys).

### Q3 — List cap?

Options: 5 / 10 / 20.

**Decision: 10.** Single-scroll list, most-recent first, duplicates collapse
(re-use moves the order to the front). Comfortably covers a day's work
without becoming a second History tab. User confirmed.

### Q4 — Empty state?

Options: (a) hidden when empty; (b) always visible, disabled; (c) always
visible, opens an explanatory empty list.

**Decision: (b) always visible, disabled while the list is empty.** User's
call, overriding the facilitator's "hidden" recommendation — matches the
Type button's always-findable precedent, and there is no disabled-state
styling question since Material's disabled tonal button reads clearly.

### Q5 — Interaction after picking a number?

Not user-facing-questioned; design decision. Tapping a recent number shows
the **same Take photo / Gallery confirm dialog** a scanned code gets
(Cancel in place of Rescan — there is nothing to rescan), then
`_startCapture`. Consistent with both existing entry paths; two taps total,
same as scan → confirm. The alternative (inline camera/gallery icon buttons
per row, one tap fewer) was rejected: crowded rows, hidden affordance.

## Approaches considered (architecture)

**A. Scanner-owned `RecentOrders` store — CHOSEN.** New small value class
`lib/recents/recent_orders.dart` (load/record/save over the `SettingsStore`
seam), owned by `ScannerPage` state; one recording hook in `_startCapture`.
No new dependencies, unit-testable via `InMemorySettingsStore`, and it keeps
recents out of `AppSettings` — deliberate, because the parallel
`settings-save-change` worktree owns settings-saving code.

**B. Third half inside the `AppSettings` umbrella — rejected.** Free plumbing
(the `ValueNotifier<AppSettings>` already flows everywhere), but recents
aren't preferences, they'd mutate settings equality on every capture, every
capture would write through exactly the code the sibling worktree is
changing, and `AppSettings.save` semantics (user-initiated saves) would
silently become "also persists history on every capture".

**C. In-memory only — rejected by user** (Q2).

## Design trade-offs noted

- Recency recorded at capture start, not scan-detect time: dismissed scans
  and failed creates stay out of recents; the list answers "what have I
  actually worked on".
- Dedup + move-to-front (LRU) rather than FIFO append: re-using an order is
  itself the strongest recency signal, and the cap-drops-oldest behavior the
  user asked for falls out naturally.
- A picked number re-records through the same `_startCapture` hook — no
  special case.
- Best-effort `save()`: a storage write failure must never fail a capture
  that is about to start; the in-memory copy already reflects the new state.
- The picker dialog is extracted as its own widget (`RecentOrdersDialog`)
  so it is widget-testable without the MobileScanner platform view; the
  source-confirm dialog reuse stays inline in the scanner page.
- Spec placement: NEW capability `recent-scans`; the shared dialog behaviors
  stay owned by `manual-order-entry` and are referenced, not duplicated or
  modified.

## Scope sentence

One button beside "Type order number" opens a capped, persisted, most-recent-
first list of order numbers that have started a capture; picking one flows
into the identical confirm-and-capture path. No history browsing, no
timestamps in the list, no manual delete of individual recents, no settings
surface — none of that is in scope.
