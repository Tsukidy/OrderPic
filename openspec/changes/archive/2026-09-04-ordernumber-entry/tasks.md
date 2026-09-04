## 1. Entry affordance and dialog (ScannerPage)

- [x] 1.1 Add a "Type order number" button in a semi-transparent bar pinned
  to the bottom of the `ScannerPage` camera preview, visible whenever the
  scanner is active
- [x] 1.2 Add `_showEntryDialog()` to `_ScannerPageState`: set `_processing`
  for the dialog's lifetime, then show an `AlertDialog` with an autofocus
  `TextField` — `TextInputType.number`,
  `FilteringTextInputFormatter.digitsOnly` (covers typed and pasted input),
  16-digit cap
- [x] 1.3 Gate the "Use this" confirm action on a non-empty trimmed value;
  cancel or backdrop dismiss clears `_processing` and returns to scanning
  with no route pushed

## 2. Hand-off into the capture flow

- [x] 2.1 On confirm: pop the dialog, stop the camera controller, and push
  `CameraPage(orderNumber: value)`; when the flow returns, clear
  `_processing` and restart the controller — mirroring `_onDetect`'s
  stop/push/restart sequence
- [x] 2.2 Confirm the typed number appears in the order chip on the camera
  and preview screens with no edits to `CameraPage`/`PreviewPage`

## 3. Verification

- [x] 3.1 Run `flutter analyze` — must be clean
- [x] 3.2 Manual on-device pass of the acceptance list in design.md
  §Migration Plan: dialog opens with number keyboard and focus; non-digit
  type/paste impossible; empty confirm disabled; cancel leaves detection
  working; QR in view during dialog does not stack dialogs; confirm starts
  the flow with the right chip; upload yields
  `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg` parseable in History; QR path
  unchanged
