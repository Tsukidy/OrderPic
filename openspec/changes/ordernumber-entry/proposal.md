## Why

Today an order number can only enter the capture workflow through a
successful QR scan. When a code is missing, damaged, or simply won't read,
the workflow is blocked with no workaround — the operator must skip the
order or abandon the flow mid-shift. Manual entry gives operators an escape
hatch that starts the identical capture flow, so unreadable codes stop being
a single point of failure in the field.

## What Changes

**Starting the capture flow**
- From: The capture flow (camera → review → upload) can only be started by
  scanning a QR code that encodes the order number.
- To: The flow can also be started by typing the order number manually from
  the Scan screen.
- Reason: QR codes are sometimes missing, damaged, or unreadable, which
  currently blocks the whole workflow.
- Impact: non-breaking, additive; scanning remains the primary path.

Specifics (all additive, on the Scan screen):

- A "Type order number" button pinned at the bottom of the camera preview,
  always visible while scanning.
- Tapping it opens a dialog with one numeric-only text field (number
  keyboard, digits-only input, 16-digit cap). Confirm is disabled while the
  value is empty; dismissing the dialog cancels.
- Confirming goes straight into the existing camera flow for that order
  number — no second confirmation dialog, since typing is deliberate.
- Barcode detection is suppressed while the dialog is open, reusing the
  scanner's existing re-entry guard.

## Capabilities

### New Capabilities

- `manual-order-entry`: typing an order number on the Scan screen as a
  fallback way to start the capture flow — entry affordance, numeric-only
  input constraints, and direct hand-off into the existing camera flow.

### Modified Capabilities

(none — scanning behavior, the upload filename contract, the SMB layer, and
History requirements are all unchanged)

## Impact

- **Code:** `lib/main.dart`, `ScannerPage` only — entry button, entry
  dialog, detection guard, and the push into `CameraPage`.
  `CameraPage`, `PreviewPage`, `HistoryPage`, and the SMB constants are
  untouched; the order number remains an opaque string downstream.
- **Dependencies:** none — uses Flutter SDK widgets/input formatters only.
- **Filename contract:** untouched, and protected by construction: a
  digits-only order number cannot contain the `_` or Windows-hostile
  characters that would break `HistoryPage` name parsing.
- **Systems:** no new external systems; uploads land on the existing SMB
  share in the existing `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg` format.
- **Verification:** manual on a physical device (camera + LAN share
  required), per the repo's testing stance; `flutter analyze` stays clean.
