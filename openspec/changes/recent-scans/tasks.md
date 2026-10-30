## 1. `RecentOrders` store (logic first)

- [ ] 1.1 Create `lib/recents/recent_orders.dart`: `RecentOrders` value class per design D1/D2/D6 — `List<String> orders` (most-recent-first), `static empty`, `load({SettingsStore})` reading key `recent.orders` (JSON array; try/catch → empty, no wipe, other keys untouched), `record(String)` (move-to-front if present, insert otherwise, trim to 10), `save({SettingsStore})` writing the whole array.
- [ ] 1.2 Unit tests in `test/recent_orders_test.dart` over `InMemorySettingsStore` (reuse `test/helpers/`): record-new-appends-front, duplicate-moves-to-front, 10-cap eviction of the oldest, load round-trip, corrupt/unreadable payload → empty list without touching other keys, save-failure swallowed (throwing store fake).

## 2. Scan screen: Recent button + load

- [ ] 2.1 Rework the bottom `Positioned` in `lib/pages/scanner_page.dart` into a `Row` of two `Expanded` tonal buttons: existing "Type order number" and new "Recent" (`Icons.history`) — Recent always visible, disabled while the loaded list is empty (design D4).
- [ ] 2.2 Load the persisted list once in state init (async; no await in build) and `setState` on arrival so the button flips enabled.

## 3. Recents picker dialog

- [ ] 3.1 Create the standalone `RecentOrdersDialog` widget (design D7): takes the numbers list, renders most-recent-first list tiles (ellipsis for long values), pops the picked number; null on dismiss.
- [ ] 3.2 Wire the Recent button to open the picker under the same `_processing` guard as the entry dialog; dismissing the picker re-enables detection (spec: no QR dialog above picker, dismiss resumes scanning).
- [ ] 3.3 Picking a number pops the picker, then shows the existing `CaptureSource` confirm dialog (Take photo / Gallery; Cancel in place of Rescan — design D5); confirming routes into `_startCapture`, cancelling pushes nothing and resumes detection.

## 4. Recording hook

- [ ] 4.1 In `_startCapture`, after `CaptureSession.create` succeeds and before pushing `CameraPage`: `_recent = _recent.record(orderNumber)` + best-effort `save()` (design D3/D6).
- [ ] 4.2 Tests: confirmed capture records (QR path, typed path — one representative each via the shell test harness), dismissed scan records nothing, re-picking an existing order re-fronts it, button state transitions (disabled → enabled after first capture).

## 5. Verification

- [ ] 5.1 `flutter analyze` — clean.
- [ ] 5.2 `flutter test` — all green including the new `recent_orders_test.dart` and the recents shell/widget tests.
- [ ] 5.3 Physical-device spot check (repo norm — real camera + LAN share): scan → capture → pick the same order from Recent → second capture uploads; kill + relaunch shows the Recent button enabled with the order offered.
