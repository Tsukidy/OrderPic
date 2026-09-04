# Brainstorm — ordernumber-entry (manual order-number entry)

> Raw capture of the brainstorming session for change `ordernumber-entry`,
> conducted 2026-09-04. All decision-chain answers were confirmed by the
> user in conversation. `design.md` reorganizes this into Context / Goals /
> Decisions / Risks / Migration; the two files complement, not overlap.

## Background

MMCPic's capture flow starts from an order number, and today the only source
of one is a successful QR scan (`ScannerPage` → confirm dialog →
`CameraPage` → `PreviewPage` → SMB upload). If a QR code is missing,
damaged, or won't scan, the workflow is blocked with no way forward.

This change adds manual entry of the order number as a second way to start
the same capture flow.

Existing invariants that bear on this:

- **Filename contract (cross-feature):** uploads are named
  `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg`; `HistoryPage._parseName` splits
  on `_` and expects exactly 3 parts (order / 8-digit date / 6-digit time).
  A `_` inside the order number makes History fall back to showing the raw
  filename with no readable date — degraded, not crashed, but wrong.
- The QR path does zero validation today: scanned text goes into the
  filename verbatim. Manual typing is strictly more error-prone than
  scanning, so input constraint is where this feature earns its keep.
- `CameraPage` and `PreviewPage` take an opaque `orderNumber` string.
  Anything that produces a contract-safe string can feed the identical
  downstream flow — no changes needed past the entry point.

## Decision chain

### Q1 — What role does manual entry play? → **Fallback** (user-confirmed)

Scanning stays the primary path; manual entry is an escape hatch on the Scan
screen for an unreadable or missing QR code.

Rejected alternatives:
- *Equal primary path* (prominent button/tab of its own) — no evidence that
  orders routinely lack QR codes; adds weight to the most-used screen for a
  rare case.
- *Replace scanning* — contradicts the app's whole architecture.

If typed entries turn out to be common, the affordance can be promoted
later without touching anything else in this design.

### Q2 — Where does entry live? → **Bottom overlay button → dialog** (user-confirmed)

A "Type order number" button in a semi-transparent bar pinned to the bottom
of the camera preview, opening an `AlertDialog` with one `TextField`.

- Always visible while scanning, so a user who has failed to scan a code
  for 30 seconds finds the escape hatch without hunting.
- Reuses the app's existing dialog idiom (the QR path already confirms
  through an `AlertDialog`) and keeps the navigation stack shallow.

Rejected alternatives:
- *App-bar action* — tidier but not discoverable by someone who doesn't
  already know the feature exists.
- *Separate full route* — nav depth for a single text field; premature.
- *Third bottom-nav tab* — fragments one workflow into two homes; heaviest
  change.

### Q3 — What format are order numbers? → **Purely numeric** (user-confirmed)

Number keyboard (`TextInputType.number`) with
`FilteringTextInputFormatter.digitsOnly`.

Consequence: every contract-hostile character (`_`, `/ \ : * ? " < > |`,
control chars) is **untypable** rather than rejected after the fact — the
input constraint *is* the validation. Length cap of **16 digits**
(Claude-proposed default, flagged for override in design review; user
proceeded without objection).

### Q4 — How is the scanner guarded while the dialog is open?

Reuse the existing `_processing` flag for the dialog's lifetime, exactly as
`_onDetect` already does — a stray QR in camera view cannot fire a second
dialog underneath. The camera itself keeps running; only the pushed capture
flow needs it stopped.

### Q5 — What happens after a valid entry? → **Straight into the capture flow**

The dialog's confirm action *is* the confirmation — the user typed the value
deliberately, whereas the QR path confirms because scans can misread. Pop
the dialog → `push CameraPage(orderNumber: value)`. Downstream (Camera →
Preview → upload → filename) is untouched; the order number stays opaque to
it. When the flow finishes, the existing `popUntil`-to-scanner lifecycle
resumes scanning, identical to the QR path.

## Approved design summary

1. `ScannerPage`: "Type order number" button pinned at the bottom of the
   camera preview in a semi-transparent bar.
2. Tap → set `_processing`, show `AlertDialog` with an autofocus
   `TextField` (number keyboard, digits-only formatter, 16-digit cap).
   Confirm ("Use this", matching QR-dialog wording) disabled while the
   trimmed value is empty. Backdrop/dismiss = cancel.
3. Confirm → pop dialog → stop the camera controller → push
   `CameraPage(orderNumber: value)`. When the flow returns, clear
   `_processing` and restart the controller — the same stop/push/restart
   sequence `_onDetect` performs after its confirm dialog. (While the entry
   dialog itself is open the camera keeps running; `_processing` alone
   suppresses detection.)
4. No changes to: filename contract, SMB layer, History, `CameraPage`,
   `PreviewPage`.

**Error handling:** the dialog structurally cannot emit an invalid value
(digits-only input + non-empty gate). No inline-error machinery needed.

**Verification:** manual on a physical device — the flow needs camera
hardware and an SMB share, matching the repo's stated testing stance
(`test/widget_test.dart` is a deliberate placeholder). `flutter analyze`
must stay clean.

## Scope

- **In:** entry button on the Scan screen; entry dialog with input
  constraints; hand-off into the existing capture flow.
- **Out:** validating the QR path; changing the filename contract; any SMB
  layer change; History changes; recent-order memory/suggestions
  (no demonstrated need — YAGNI).

## Design trade-offs summary

| Option | Pros | Cons |
|---|---|---|
| Bottom overlay button + dialog (chosen) | Discoverable mid-frustration; matches existing dialog idiom; shallow stack; scanner guard contained | Cramped if manual entry later becomes a primary path |
| App-bar action + dialog | Tidiest | Least discoverable for users who don't know it exists |
| Separate route/page | Room to grow (e.g., recent-order picker) | Nav depth + a full page for one field; premature |
| Third nav tab | Most discoverable | Splits one workflow across two homes; heaviest change |
