## Context

MMCPic is a single-file Flutter app (`lib/main.dart`, plain
`StatefulWidget`s, no state-management library) for an Android
photo-capture workflow: scan a QR-coded order number → photograph the item
with the system camera → review → upload to a Windows SMB share. A History
tab lists and views uploaded images.

Today the capture flow can only be started by a successful QR scan. When a
code is missing, damaged, or unreadable, the workflow is blocked — that is
the problem this change removes.

Constraints that shape the design:

- **Filename contract:** uploads are `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg`;
  `HistoryPage._parseName` splits on `_` expecting exactly 3 parts. An order
  number containing `_` (or SMB-hostile characters) degrades History.
- `CameraPage` / `PreviewPage` treat `orderNumber` as an opaque string, so
  any contract-safe source can feed the same downstream flow.
- Repo conventions: single-file architecture, hardcoded SMB constants,
  manual on-device verification (widget tests are a deliberate placeholder).

## Goals / Non-Goals

**Goals:**

- Let an operator start the identical capture flow by typing the order
  number when the QR code won't scan.
- Guarantee typed numbers are filename-contract-safe *by construction*.
- Keep scanning the primary path, with its behavior completely unchanged.
- Contain the change to `ScannerPage` in `lib/main.dart`.

**Non-Goals:**

- Validating or constraining the QR-scan path (stays verbatim, as today).
- Changing the filename contract, SMB layer, History, `CameraPage`, or
  `PreviewPage`.
- Recent-order memory, autocomplete, or any multi-field entry.

## Decisions

### D1: Entry is a fallback affordance on the Scan screen
- **Choice:** A "Type order number" button in a semi-transparent bar pinned
  to the bottom of the camera preview — no new tab, no new route.
- **Rationale:** Scanning is the common case; the button's job is to be
  found by an operator who has already failed to scan for 30 seconds, so it
  must be visible on the scanner itself without adding navigation weight.
- **Alternatives rejected:** third bottom-nav tab (fragments one workflow
  into two homes); separate route/page (nav depth for one field, premature).

### D2: Entry UI is an `AlertDialog` with one field
- **Choice:** Tapping the button opens a dialog (autofocus `TextField`,
  "Use this" confirm — matching the QR dialog's wording — and dismiss =
  cancel).
- **Rationale:** Reuses the app's existing dialog idiom (the QR path already
  confirms via `AlertDialog`) and keeps the nav stack shallow; the capture
  flow is pushed from the dialog exactly as it is from the QR confirm.
- **Alternatives rejected:** app-bar action opening the same dialog (less
  discoverable); inline bottom-sheet form (adds a new UI idiom to the app
  for no gain).

### D3: Validation is an input constraint, not post-hoc rejection
- **Choice:** `TextInputType.number` +
  `FilteringTextInputFormatter.digitsOnly` + `maxLength: 16`. Confirm is
  disabled while the trimmed value is empty.
- **Rationale:** Digits-only makes every contract-hostile character (`_`,
  `/ \ : * ? " < > |`, control chars) *untypable* — and input formatters
  also run on pasted text, so paste cannot smuggle them in either. No
  validator or inline-error machinery is needed; the empty-check is a
  button-state, not an error path.
- **Alternatives rejected:** free-form field + reject-on-submit validator
  (more code, worse UX, residual risk that an IME quirk lets a bad
  character through).

### D4: Scanner lifecycle mirrors `_onDetect`
- **Choice:** Set `_processing` for the dialog's lifetime (suppresses
  detection so a stray QR can't stack a second dialog). Keep the camera
  running while the dialog is open. On confirm: pop dialog → stop
  controller → push `CameraPage`; when the flow returns: clear
  `_processing`, restart controller — the same stop/push/restart sequence
  `_onDetect` uses after its confirm dialog.
- **Rationale:** Reuses the established re-entry guard pattern; stopping the
  camera only when the capture flow actually needs exclusive use avoids
  restart latency on a cancelled entry.
- **Alternatives rejected:** stop camera for the dialog too (unnecessary —
  `_processing` alone is sufficient; adds restart cost to every cancel);
  separate `_dialogOpen` flag (duplicates `_processing`'s exact purpose).

### D5: Dialog confirm *is* the confirmation
- **Choice:** Confirm → push `CameraPage(orderNumber: value)` directly; no
  second confirmation step.
- **Rationale:** The QR path confirms because a scan can misread; typing a
  number is deliberate. The order number remains visible on the chip in
  `CameraPage`/`PreviewPage`, so a typo is still catchable before upload.
- **Alternatives rejected:** reuse the QR confirm dialog after entry
  (pure ceremony for a value the user just typed).

### D6: Code stays in `ScannerPage`, single-file idiom preserved
- **Choice:** The button, `_showEntryDialog()` helper, and hand-off live in
  `_ScannerPageState` alongside `_onDetect`; no new files or extracted
  widgets.
- **Rationale:** Matches the repo's deliberate single-file architecture;
  the addition is ~50 lines. Extraction becomes worth it only if
  `main.dart` growth forces a split — not this change's problem.
- **Alternatives rejected:** separate `OrderEntryDialog` widget/file
  (introduces a second idiom for a small gain).

## Risks / Trade-offs

- [Trade-off] A typo'd order number uploads against a nonexistent order →
  Accepted: the same risk exists for QR misreads today; the number is shown
  in the order chip on the camera and preview screens before upload, and
  History review is the backstop.
- [Risk] Some Android IMEs render non-digit characters on number keyboards,
  or allow arbitrary paste → Mitigation: `digitsOnly` is an input formatter
  and strips non-digits from typed *and* pasted input; `maxLength` caps
  total length regardless.
- [Risk] A real order number longer than 16 digits would be untypable →
  Mitigation: the cap is a single constant; raise it if the business system
  ever produces longer numbers (see Open Questions).
- [Trade-off] Dialog is cramped if manual entry later becomes a primary
  path → Accepted per D1's fallback role; promotion to a full route changes
  nothing downstream (the hand-off contract is just an order-number
  string).

## Migration Plan

N/A — no deployment, endpoint, or data changes; a single additive code
change to `lib/main.dart`. Rollback = revert the commit.

Acceptance (manual, on a physical device with the LAN share):

1. "Type order number" visible on the Scan screen; tapping opens the
   dialog with number keyboard and focus.
2. Non-digit input impossible (type/paste); confirm disabled when empty.
3. Cancel (button or backdrop) → dialog closes, scanning still works, no
   double-dialog from a QR in view.
4. Confirm → camera flow starts with the typed number in the order chip;
   upload produces `{typed}_{date}_{time}.jpg`; History shows it with
   parsed order number and readable date.
5. QR scan path behaves exactly as before.
6. `flutter analyze` clean.

## Open Questions

- Confirm 16 digits is ≥ the longest real order number (default accepted
  during design review without objection; it is one constant to change).
