# Manual Order-Number Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo, execution flows through `/opsx:apply` for change `ordernumber-entry`, which walks `tasks.md`; this plan is the micro-step decomposition of those tasks.

**Goal:** Let an operator start the existing capture flow by typing a numeric order number on the Scan screen when the QR code won't scan.

**Architecture:** Everything lands in `_ScannerPageState` in `lib/main.dart` (single-file idiom, design.md D6). A "Type order number" button overlays the camera preview; it opens an `AlertDialog` whose `TextField` is constrained to digits (≤16) so the upload filename contract is safe by construction. The existing `_processing` flag suppresses barcode detection while the dialog is open. Confirming reuses the QR path's stop/push/restart sequence, extracted into a shared `_startCapture()` helper.

**Tech Stack:** Flutter (Material 3 widgets), `flutter/services` input formatters. No new packages.

## Global Constraints

- Order number input: digits 0–9 only, typed **and** pasted, max 16 chars (`FilteringTextInputFormatter.digitsOnly` + `LengthLimitingTextInputFormatter(16)`).
- Confirm action ("Use this") disabled while the trimmed value is empty; dismiss (cancel/backdrop) = cancel.
- No second confirmation after entry (design.md D5).
- No changes outside `_ScannerPageState` in `lib/main.dart`: `CameraPage`, `PreviewPage`, `HistoryPage`, SMB constants, and the `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg` filename contract are untouched.
- QR-scan behavior must remain identical after the `_onDetect` refactor (spec: detection works after cancel, QR path unchanged).
- Automated gate: `flutter analyze` clean (repo testing stance: main flow needs camera + SMB hardware; no new tests — `test/widget_test.dart` is a deliberate placeholder).

---

### Task 1: Entry button and dialog, end to end (tasks.md 1.1, 1.2, 1.3, 2.1)

**Files:**
- Modify: `lib/main.dart` (top import block; `_ScannerPageState`)

**Interfaces:**
- Consumes: `CameraPage(orderNumber: String)` (exists, main.dart:184), `_controller` / `_processing` (exist, main.dart:93–96), `_onDetect` (exists, main.dart:112).
- Produces: `Future<void> _startCapture(String orderNumber)` and `Future<void> _showEntryDialog()` as members of `_ScannerPageState` — Task 2 reuses `_startCapture` from `_onDetect`.

- [ ] **Step 1: Add the services import**

At the top of `lib/main.dart`, after the other `dart:` imports and before `package:flutter/material.dart`:

```dart
import 'package:flutter/services.dart';
```

- [ ] **Step 2: Add the `_startCapture` helper to `_ScannerPageState`**

Insert after `_onDetect`'s closing brace (below main.dart:153). This is the QR path's existing stop/push/restart sequence, lifted verbatim into a method:

```dart
  /// Stop scanning, run the capture flow for [orderNumber], then resume
  /// scanning when it finishes. Shared by the QR and manual entry paths.
  Future<void> _startCapture(String orderNumber) async {
    await _controller.stop();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CameraPage(orderNumber: orderNumber)),
    );
    if (!mounted) return;
    _processing = false;
    unawaited(_controller.start());
  }
```

- [ ] **Step 3: Add `_showEntryDialog` to `_ScannerPageState`**

> **Amended during apply (2026-09-04, commit fa0ad8b):** the original block
> created a local `TextEditingController` and disposed it right after
> `showDialog` returned — but `Route.didPop` completes that future *before*
> the dialog's exit animation runs (flutter `navigator.dart:433–480`), so the
> dispose fired under a still-mounted TextField and crashed on device
> ("A TextEditingController was used after being disposed" + duplicate-GlobalKeys
> cascade; reproduced on the manual path only, QR dialog has no controller).
> The controller is now a `_ScannerPageState` field whose lifetime spans the
> exit animation. Code below matches the shipped fix.

Add the field next to `_controller`/`_processing`, and dispose it in the
existing `dispose()`:

```dart
  final TextEditingController _entryController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _entryController.dispose();
    super.dispose();
  }
```

Insert the method directly below `_startCapture`:

```dart
  /// Fallback entry: type an order number when the QR code won't scan.
  /// `_processing` suppresses barcode detection while the dialog is open;
  /// confirming starts the same capture flow a scanned code does.
  Future<void> _showEntryDialog() async {
    if (_processing) return;
    _processing = true;
    _entryController.clear();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Type order number'),
        content: TextField(
          controller: _entryController,
          autofocus: true,
          keyboardType: TextInputType.number,
          // Digits-only input keeps the upload filename contract safe by
          // construction — '_' and SMB-hostile characters are untypable,
          // including via paste (formatters run on pasted text too).
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(16),
          ],
          decoration: const InputDecoration(hintText: 'Order number'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _entryController,
            builder: (context, value, _) => FilledButton(
              // Disabled while the trimmed value is empty.
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Use this'),
            ),
          ),
        ],
      ),
    );

    final orderNumber = _entryController.text.trim();

    if (!mounted) return;
    if (confirmed == true && orderNumber.isNotEmpty) {
      await _startCapture(orderNumber);
    } else {
      // Cancelled — nothing was pushed, just resume detecting.
      _processing = false;
    }
  }
```

- [ ] **Step 4: Overlay the entry button on the scanner**

In `_ScannerPageState.build` (main.dart:156–178), wrap the `MobileScanner` in a `Stack` and pin the button above the bottom edge:

```dart
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera error: ${error.errorCode.name}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          // Fallback for a missing or damaged QR code — always visible so
          // it's findable after a failed scan attempt.
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.keyboard),
              label: const Text('Type order number'),
              onPressed: _showEntryDialog,
            ),
          ),
        ],
      ),
```

(The `errorBuilder` body is unchanged — only the wrapping `Stack`/`Positioned` is new.)

- [ ] **Step 5: Run the analyzer**

Run: `flutter analyze`
Expected: "No issues found!"

- [ ] **Step 6: Smoke-test on device**

Run: `flutter run -d <device-id>` and check:
- "Type order number" button visible over the preview; tapping opens the dialog with number keyboard and focus.
- Typing letters/pasting "abc_12/" yields digits only; 17th digit ignored.
- "Use this" disabled when empty, enabled after typing.
- Cancel → dialog closes; presenting a QR code still triggers the QR confirm dialog (guard released).
- With the dialog open, presenting a QR code does NOT open the QR dialog.
- Confirm with e.g. `100438` → camera flow opens, order chip shows `100438`; back out and scanning resumes.

- [ ] **Step 7: Commit**

```bash
git add lib/main.dart
git commit -m "feat: manual order-number entry as fallback on Scan screen"
```

---

### Task 2: QR path reuses the shared hand-off (tasks.md 2.2)

**Files:**
- Modify: `lib/main.dart:140–152` (the confirmed/rescan branches of `_onDetect`)

**Interfaces:**
- Consumes: `_startCapture(String orderNumber)` from Task 1.
- Produces: nothing new — `_onDetect` behavior must remain identical.

- [ ] **Step 1: Replace `_onDetect`'s confirmed branch with the helper call**

In `_onDetect`, replace the two branches (main.dart:140–152) with:

```dart
    if (confirmed == true) {
      // Push the capture flow on top of the tab shell; when it eventually
      // pops (upload finished / cancelled), resume scanning.
      await _startCapture(orderNumber);
    } else {
      _processing = false;
      unawaited(_controller.start());
    }
```

(Sequence note: `_onDetect` stops the controller *before* its confirm dialog, so the rescan branch must still restart it — only the push-and-resume block is delegated to `_startCapture`.)

- [ ] **Step 2: Run the analyzer**

Run: `flutter analyze`
Expected: "No issues found!"

- [ ] **Step 3: Regression-check the QR path on device**

Run: `flutter run -d <device-id>` and check:
- Scan a QR code → confirm dialog → "Use this" → camera flow with the scanned number in the chip (identical to before).
- "Rescan" → dialog closes, scanning resumes.
- Complete an upload end to end; after "Scan next QR code", scanner is active again.
- Downstream diff check: `git diff main.dart` shows no changes outside `_ScannerPageState`.

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "refactor: QR path shares _startCapture with manual entry"
```

---

### Task 3: Full acceptance pass (tasks.md 3.1, 3.2)

**Files:**
- Modify: `openspec/changes/ordernumber-entry/tasks.md` (tick checkboxes)

**Interfaces:**
- Consumes: the finished feature from Tasks 1–2.
- Produces: ticked `tasks.md` checkboxes recording completed work.

- [ ] **Step 1: Run the analyzer**

Run: `flutter analyze`
Expected: "No issues found!"

- [ ] **Step 2: Walk the acceptance list on device**

Verify each item from design.md §Migration Plan:
1. "Type order number" visible on Scan screen; opens dialog with number keyboard + focus.
2. Non-digit input impossible (type and paste); confirm disabled when empty.
3. Cancel (button or backdrop) → no route pushed, scanning still works, no double-dialog from a QR in view.
4. Confirm → camera flow with typed number in the chip; upload produces `{typed}_{YYYYMMDD}_{HHMMSS}.jpg`; History lists it with parsed order number and readable date/time.
5. QR scan path behaves exactly as before (Task 2's regression checks).
6. `flutter analyze` clean (Step 1).

- [ ] **Step 3: Tick tasks.md and commit**

Mark tasks 1.1–3.2 complete in `openspec/changes/ordernumber-entry/tasks.md`, then:

```bash
git add openspec/changes/ordernumber-entry/tasks.md
git commit -m "chore: complete ordernumber-entry task checklist"
```

---

## Self-Review

- **Spec coverage:** affordance (Task 1.4) → Requirement 1; digits-only + 16 cap with paste (Task 1.3) → Requirement 2; empty gate (Task 1.3) → Requirement 3; cancel resumes + detection-after-cancel (Tasks 1.3/1.6) → Requirement 4; suppression during dialog (Task 1.6) → Requirement 5; hand-off + chip + resume (Tasks 1.2/1.6, 2.3) → Requirement 6; filename/History parse (Task 3.2 item 4) → Requirement 7. No gaps.
- **Placeholder scan:** all code blocks are complete implementations; every step names exact commands and expected outcomes.
- **Type consistency:** `_startCapture(String orderNumber)` and `_showEntryDialog()` names/signatures are identical in Tasks 1 and 2; dialog builder uses nested `context` per Flutter idiom (matches existing code in `_onDetect`).
