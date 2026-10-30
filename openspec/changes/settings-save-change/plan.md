# Write-through capture & upload prefs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture & upload preferences on the Settings page apply live and persist at the moment of change, while the SMB connection section keeps its explicit Save/back-discard form semantics.

**Architecture:** The page's prefs controls stop mirroring state locally and read the shell's shared `ValueNotifier<AppSettings>` (wrapped in a `ValueListenableBuilder`); every change goes through one serialized commit queue that persists the new `UploadPrefs` via the `SettingsStore` seam and only then advances the notifier — so a failed write leaves the control untouched (revert for free) plus the existing snackbar. `_save()` slims to connection-only persistence.

**Tech Stack:** Flutter (StatefulWidget, no state-management library), `flutter_secure_storage` behind the injectable `SettingsStore` seam, widget tests with `InMemorySettingsStore` fakes. No new dependencies.

**Spec:** `openspec/changes/settings-save-change/specs/upload-settings/spec.md` (delta on `upload-settings`); design rationale in `openspec/changes/settings-save-change/design.md` (D1–D7).

## Global Constraints

- Flutter SDK lives at `/home/coder/flutter` (not on PATH — use `/home/coder/flutter/bin/flutter` or export PATH).
- Repo is pre-3.7 short dart style: never run a blanket `dart format`; keep edits formatted like the surrounding code.
- No new packages; storage keys unchanged (`upload.*`, `smb.*`); no changes outside `lib/settings/settings_page.dart`, `test/settings_page_test.dart`, `test/helpers/in_memory_settings_store.dart`.
- Invariants that must survive every task: prefs writes never construct a `ConnectionSettings` (History's `ObjectKey(settings.connection)` compares by `identical()`); `UploadPrefs.copyWith` cannot set `customMaxEdgePx` back to null (its `??` swallows null) — null-clearing constructs `UploadPrefs` fresh.
- Run tests for one file: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`; whole suite: `/home/coder/flutter/bin/flutter test`.

---

### Task 1: Commit queue + write-through toggles

**Files:**
- Modify: `lib/settings/settings_page.dart` (state fields, `initState`, `build`, new `_commitUpload`)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: existing `UploadPrefs.save({SettingsStore store})`, `AppSettings.copyWith({ConnectionSettings? connection, UploadPrefs? upload})`, `InMemorySettingsStore` with `.data` map.
- Produces: `Future<bool> _commitUpload(UploadPrefs Function(UploadPrefs current) change, {VoidCallback? onFailure})` — resolves `true` when persisted AND applied to the notifier, `false` on store failure. Later tasks call it with mutators like `(u) => u.copyWith(format: s.first)` and pass `onFailure` only for controls holding gesture-local state.

- [ ] **Step 1: Write the failing test**

Add to `main()` in `test/settings_page_test.dart` (top level, before the `sectioned layout` group is fine):

```dart
testWidgets('folders toggle persists immediately without Save', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _tapScrolled(tester, find.byKey(const Key('folders_toggle')));
  await tester.pumpAndSettle();
  expect(notifier.value.upload.useOrderFolders, isTrue);
  expect(store.data['upload.use_order_folders'], 'true');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "folders toggle persists immediately"`
Expected: FAIL — `store.data['upload.use_order_folders']` is null (today nothing persists without Save).

- [ ] **Step 3: Implement — commit engine, notifier-reading page, toggles**

In `lib/settings/settings_page.dart`:

1. Add `import 'dart:async';` at the top.
2. In `_SettingsPageState`, delete the fields `_folders`, `_batch` and their seeding in `initState` (the toggles are the last consumers; `_format`/`_quality` stay until Task 2, and `_customQuality`/`_customMaxEdge` stay for Tasks 4/5). Add:

```dart
/// Serialized prefs commit queue (design D5): every write-through change
/// funnels through here so quick successive changes can't interleave
/// whole-object writes and resurrect a stale key.
Future<void> _pending = Future.value();

/// Persists and applies one upload-prefs change. [change] is applied to
/// the turn-time snapshot — NOT the value at call time — so each queued
/// commit lands on top of the previous one (last-tap-wins is structural).
/// Resolves true when the new value was persisted AND applied to the
/// notifier; false when the store write failed (notifier untouched).
Future<bool> _commitUpload(
  UploadPrefs Function(UploadPrefs current) change, {
  VoidCallback? onFailure,
}) {
  final done = Completer<bool>();
  _pending = _pending.then((_) async {
    final current = widget.settingsNotifier.value;
    final next = change(current.upload);
    if (next == current.upload) {
      done.complete(true); // no-op: skip the store write entirely
      return;
    }
    try {
      await next.save(store: widget.store);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save settings')),
        );
        onFailure?.call();
      }
      done.complete(false);
      return;
    }
    // Safe after dispose: the notifier outlives this page (HomePage owns
    // it), and a close-time flush must still land.
    widget.settingsNotifier.value = current.copyWith(upload: next);
    done.complete(true);
  });
  return done.future;
}
```

3. In `build`, wrap the `Form` in a `ValueListenableBuilder<AppSettings>` listening to `widget.settingsNotifier`, and read the upload half from the notification:

```dart
body: ValueListenableBuilder<AppSettings>(
  valueListenable: widget.settingsNotifier,
  builder: (context, settings, _) => Form(
    key: _formKey,
    child: ListView(
      // ... everything as today, with these substitutions:
```

Inside the builder, at the top: `final upload = settings.upload;`. Then:

```dart
SwitchListTile(
  key: const Key('folders_toggle'),
  title: const Text('Upload into per-order folders'),
  value: upload.useOrderFolders,
  onChanged: (v) =>
      unawaited(_commitUpload((u) => u.copyWith(useOrderFolders: v))),
),
SwitchListTile(
  key: const Key('batch_toggle'),
  title: const Text('Multi-photo batch capture'),
  value: upload.batchMode,
  onChanged: (v) =>
      unawaited(_commitUpload((u) => u.copyWith(batchMode: v))),
),
```

Leave the format/quality segments reading `_format`/`_quality` for now (Task 2 owns them); everything else in `build` is untouched.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`
Expected: the new test PASSES and the whole file is green EXCEPT the old save-gated toggle tests are expected to still pass or fail — rewrite any that assert the toggle needs Save (delete `toggling folders and saving updates notifier and persists`; its coverage is now the new test).

- [ ] **Step 5: Commit**

```bash
git add lib/settings/settings_page.dart test/settings_page_test.dart
git commit -m "feat: write-through engine + folders/batch toggles persist on tap"
```

---

### Task 2: Format & quality segments write through; visibility follows the notifier

**Files:**
- Modify: `lib/settings/settings_page.dart` (`build` only)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `_commitUpload` from Task 1.
- Produces: segments fully notifier-driven; `_format`/`_quality` no longer exist anywhere.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('format segment persists png on tap without Save', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _tapScrolled(tester, find.text('PNG'));
  await tester.pumpAndSettle();
  expect(notifier.value.upload.format, ImageFormat.png);
  expect(store.data['upload.format'], 'png');
  // The JPEG⇄PNG visibility flip is driven by the notifier (design D3).
  expect(find.byKey(const Key('quality_section')), findsNothing);
});

testWidgets('quality preset persists on tap without Save', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _tapScrolled(tester, find.text('Balanced'));
  await tester.pumpAndSettle();
  expect(notifier.value.upload.jpegQuality, JpegQuality.balanced);
  expect(store.data['upload.jpeg_quality'], 'balanced');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "without Save"`
Expected: both FAIL (segments still local state; nothing persisted without Save).

- [ ] **Step 3: Implement**

In `build`, switch the two segments to the notifier values and commits:

```dart
SegmentedButton<ImageFormat>(
  key: const Key('format_selector'),
  segments: const [
    ButtonSegment(value: ImageFormat.jpeg, label: Text('JPEG')),
    ButtonSegment(value: ImageFormat.png, label: Text('PNG')),
  ],
  selected: {upload.format},
  onSelectionChanged: (selection) => unawaited(
    _commitUpload((u) => u.copyWith(format: selection.first)),
  ),
),
```

```dart
SegmentedButton<JpegQuality>(
  key: const Key('quality_selector'),
  // ... segments unchanged ...
  selected: {upload.jpegQuality},
  onSelectionChanged: (selection) => unawaited(
    _commitUpload((u) => u.copyWith(jpegQuality: selection.first)),
  ),
),
```

Change both mount tests to notifier state: `if (_format == ImageFormat.jpeg)` → `if (upload.format == ImageFormat.jpeg)` and `if (_quality == JpegQuality.custom)` → `if (upload.jpegQuality == JpegQuality.custom)`. Delete the `_format`/`_quality` usages that remain (the fields were already removed in Task 1 — this is the last consumer).

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`
Expected: ALL PASS, including the rewritten `quality block` group's "visible for JPEG, hidden for PNG, selection survives" (the round-trip now rides notifier state).

- [ ] **Step 5: Commit**

```bash
git add lib/settings/settings_page.dart test/settings_page_test.dart
git commit -m "feat: format/quality segments write through; visibility follows notifier"
```

---

### Task 3: Store-write failure reverts control + snackbar; later commit recovers

**Files:**
- Modify: `test/helpers/in_memory_settings_store.dart` (add write-failure flag)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `InMemorySettingsStore` (house fake), the snackbar text `'Could not save settings'`.
- Produces: `InMemorySettingsStore.failWritesLeft` (int, 0 default) — used by Tasks 4 and 5 too.

- [ ] **Step 1: Extend the store helper**

In `test/helpers/in_memory_settings_store.dart`, add to `InMemorySettingsStore`:

```dart
/// When > 0, the next [failWritesLeft] writes throw — simulates a
/// keystore failure; later writes succeed (fail-once recovery testing).
int failWritesLeft = 0;
```

and replace `write`:

```dart
@override
Future<void> write(String key, String value) async {
  if (failWritesLeft > 0) {
    failWritesLeft--;
    throw Exception('write failed');
  }
  data[key] = value;
}
```

- [ ] **Step 2: Write the failing tests**

```dart
testWidgets('failed store write leaves control and notifier unchanged', (
  tester,
) async {
  final store = InMemorySettingsStore()..failWritesLeft = 1;
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _tapScrolled(tester, find.byKey(const Key('folders_toggle')));
  await tester.pump(); // snackbar entrance
  expect(
    tester
        .widget<SwitchListTile>(find.byKey(const Key('folders_toggle')))
        .value,
    isFalse,
  );
  expect(notifier.value.upload.useOrderFolders, isFalse);
  expect(store.data.containsKey('upload.use_order_folders'), isFalse);
  expect(find.text('Could not save settings'), findsOneWidget);
  await tester.pump(const Duration(seconds: 4)); // snackbar auto-dismiss timer
  await tester.pumpAndSettle(); // exit animation
});

testWidgets('a later commit after failure lands the then-current values', (
  tester,
) async {
  final store = InMemorySettingsStore()..failWritesLeft = 1;
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _tapScrolled(tester, find.byKey(const Key('folders_toggle'))); // fails
  await tester.pumpAndSettle();
  await _tapScrolled(tester, find.byKey(const Key('batch_toggle'))); // succeeds
  await tester.pumpAndSettle();
  expect(notifier.value.upload.batchMode, isTrue);
  expect(notifier.value.upload.useOrderFolders, isFalse); // stayed reverted
  expect(store.data['upload.batch_mode'], 'true');
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "failure"`
Expected: first test FAILS (today a failed write is impossible on this path — the toggle already flipped optimistically).

- [ ] **Step 4: Implement (verify, don't change)**

Task 1's `_commitUpload` already implements this contract: the notifier is assigned only after `save` succeeds, and toggles read the notifier so they never moved. If either test fails, fix `_commitUpload` (a common bug: assigning the notifier before `await next.save(...)`). Nothing new to write beyond the helper flag.

- [ ] **Step 5: Run the suite; Commit**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart` — ALL PASS.

```bash
git add test/helpers/in_memory_settings_store.dart test/settings_page_test.dart
git commit -m "test: store-write failure reverts control, snackbar, later-commit recovery"
```

---

### Task 4: Custom quality slider persists on release; failure snaps it back

**Files:**
- Modify: `lib/settings/settings_page.dart` (slider only)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `_commitUpload(change, {onFailure})` from Task 1 — this is the first control that needs `onFailure`, because the slider's value/label are gesture-local (`_customQuality`).

- [ ] **Step 1: Write the failing test**

```dart
testWidgets('slider persists the released value on release', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _tapScrolled(tester, find.text('Custom'));
  await tester.pump();
  final sliderRect = tester.getRect(
    find.byKey(const Key('custom_quality_slider')),
  );
  await tester.dragFrom(
    Offset(sliderRect.left + sliderRect.width * 0.5, sliderRect.center.dy),
    Offset(-sliderRect.width, 0),
  );
  await tester.pumpAndSettle();
  expect(notifier.value.upload.jpegQuality, JpegQuality.custom);
  expect(notifier.value.upload.customQuality, 30); // dragged to the far left
  expect(store.data['upload.custom_quality'], '30');
  expect(await UploadPrefs.load(store: store), notifier.value.upload);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "slider persists the released value"`
Expected: FAIL — `store.data['upload.custom_quality']` is null (slider had no `onChangeEnd`).

- [ ] **Step 3: Implement**

Replace the `Slider` in `build`:

```dart
Slider(
  key: const Key('custom_quality_slider'),
  min: 30,
  max: 100,
  divisions: 70,
  value: _customQuality.clamp(30, 100).toDouble(),
  label: '$_customQuality',
  onChanged: (v) => setState(() => _customQuality = v.round()),
  onChangeEnd: (v) => unawaited(_commitUpload(
    (u) => u.copyWith(customQuality: v.round()), // slider bounds are 30–100
    onFailure: () => setState(() {
      _customQuality = widget
          .settingsNotifier
          .value
          .upload
          .customQuality
          .clamp(30, 100);
    }),
  )),
),
```

Then add the failure-revert test:

```dart
testWidgets('failed slider commit snaps the thumb and label back', (
  tester,
) async {
  final store = InMemorySettingsStore()..failWritesLeft = 100;
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      upload: const UploadPrefs(
        jpegQuality: JpegQuality.custom,
        customQuality: 65,
      ),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  final sliderRect = tester.getRect(
    find.byKey(const Key('custom_quality_slider')),
  );
  await tester.dragFrom(
    Offset(sliderRect.left + sliderRect.width * 0.65, sliderRect.center.dy),
    Offset(-sliderRect.width, 0),
  );
  await tester.pumpAndSettle();
  expect(notifier.value.upload.customQuality, 65); // unchanged
  expect(find.text('JPEG quality: 65'), findsOneWidget); // snapped back
  expect(find.text('Could not save settings'), findsOneWidget);
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
});
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`
Expected: ALL PASS (rewrite the old `custom reveals slider clamped 30-100 and persists via save` to drop its Save press — the drag itself now persists; keep its min/max/divisions and clamp-floor assertions).

- [ ] **Step 5: Commit**

```bash
git add lib/settings/settings_page.dart test/settings_page_test.dart
git commit -m "feat: custom quality slider persists onChangeEnd; failure snaps back"
```

---

### Task 5: Max-edge field commits on focus loss / Done; null-clearing; failure revert

**Files:**
- Modify: `lib/settings/settings_page.dart` (the `custom_max_edge_field` TextFormField)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `_commitUpload(change, {onFailure})`.
- Produces: `void _commitMaxEdgeField()` — the field's commit path, reused by Task 6's close-flush.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('max edge persists when focus leaves the field', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      upload: const UploadPrefs(jpegQuality: JpegQuality.custom),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await tester.enterText(
    find.byKey(const Key('custom_max_edge_field')),
    '2048',
  );
  tester.binding.focusManager.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  expect(notifier.value.upload.customMaxEdgePx, 2048);
  expect(store.data['upload.custom_max_edge'], '2048');
});

testWidgets('blanking the max edge clears it to null on commit', (
  tester,
) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      upload: const UploadPrefs(
        jpegQuality: JpegQuality.custom,
        customQuality: 65,
        customMaxEdgePx: 2048,
      ),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await tester.enterText(find.byKey(const Key('custom_max_edge_field')), '');
  tester.binding.focusManager.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  expect(notifier.value.upload.customMaxEdgePx, isNull);
  expect(store.data['upload.custom_max_edge'], '');
  expect(await UploadPrefs.load(store: store), notifier.value.upload);
});

testWidgets('keyboard Done commits the max edge', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      upload: const UploadPrefs(jpegQuality: JpegQuality.custom),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await tester.enterText(
    find.byKey(const Key('custom_max_edge_field')),
    '1024',
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  expect(notifier.value.upload.customMaxEdgePx, 1024);
  expect(store.data['upload.custom_max_edge'], '1024');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "max edge"`
Expected: FAIL — the field has no commit path yet.

- [ ] **Step 3: Implement**

Add the commit method to `_SettingsPageState`:

```dart
/// The max-edge field's commit path: focus loss, keyboard Done, and the
/// close-flush (Task 6) all land here. Fresh construction instead of
/// copyWith — copyWith can't set customMaxEdgePx back to null (its ??
/// swallows the null).
void _commitMaxEdgeField() {
  final t = _customMaxEdge.text.trim();
  final px = t.isEmpty ? null : int.tryParse(t);
  unawaited(_commitUpload(
    (u) => UploadPrefs(
      useOrderFolders: u.useOrderFolders,
      batchMode: u.batchMode,
      format: u.format,
      jpegQuality: u.jpegQuality,
      customQuality: u.customQuality,
      customMaxEdgePx: px,
    ),
    onFailure: () => setState(() {
      _customMaxEdge.text =
          widget.settingsNotifier.value.upload.customMaxEdgePx?.toString() ??
          '';
    }),
  ));
}
```

Wrap the field in a `Focus` for focus loss and add `onFieldSubmitted`:

```dart
Focus(
  onFocusChange: (hasFocus) {
    if (!hasFocus) _commitMaxEdgeField();
  },
  child: TextFormField(
    key: const Key('custom_max_edge_field'),
    controller: _customMaxEdge,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onFieldSubmitted: (_) => _commitMaxEdgeField(),
    // ... decoration unchanged ...
  ),
),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`
Expected: ALL PASS. Rewrite the old `blanking the max edge clears it back to null on save` to drop its Save press (the unfocus itself commits; keep its fresh-construction rationale comment). Add the failure-revert test:

```dart
testWidgets('failed max-edge commit restores the previous text', (
  tester,
) async {
  final store = InMemorySettingsStore()..failWritesLeft = 100;
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      upload: const UploadPrefs(
        jpegQuality: JpegQuality.custom, // field only mounts for Custom
        customMaxEdgePx: 2048,
      ),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await tester.enterText(
    find.byKey(const Key('custom_max_edge_field')),
    '512',
  );
  tester.binding.focusManager.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  expect(
    tester
        .widget<TextFormField>(
          find.byKey(const Key('custom_max_edge_field')),
        )
        .controller!
        .text,
    '2048', // previous value restored
  );
  expect(notifier.value.upload.customMaxEdgePx, 2048);
  expect(find.text('Could not save settings'), findsOneWidget);
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
});
```

- [ ] **Step 5: Commit**

```bash
git add lib/settings/settings_page.dart test/settings_page_test.dart
git commit -m "feat: max-edge field commits on focus loss/Done; null-clearing; failure revert"
```

---

### Task 6: Close-flush — back and Save can't drop uncommitted field text

**Files:**
- Modify: `lib/settings/settings_page.dart` (`PopScope` in `build`)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `_commitMaxEdgeField()` from Task 5.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('back flushes uncommitted max-edge text', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      upload: const UploadPrefs(jpegQuality: JpegQuality.custom),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await tester.enterText(
    find.byKey(const Key('custom_max_edge_field')),
    '2048',
  );
  // Gear mode: system back pops (same channel a gesture uses).
  await WidgetsBinding.instance.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.byType(SettingsPage), findsNothing);
  expect(store.data['upload.custom_max_edge'], '2048');
});

testWidgets('Save also flushes the uncommitted field while saving the connection', (
  tester,
) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
      upload: const UploadPrefs(jpegQuality: JpegQuality.custom),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await tester.enterText(
    find.byKey(const Key('custom_max_edge_field')),
    '2048',
  );
  await _tapScrolled(tester, find.text('Save'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsPage), findsNothing);
  expect(store.data['upload.custom_max_edge'], '2048'); // flushed
  expect(store.data['smb.username'], 'tester'); // and the connection saved
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "flushes"`
Expected: FAIL — no flush hook exists.

- [ ] **Step 3: Implement**

```dart
return PopScope(
  canPop: !widget.firstRun, // setup mode: no escape before a valid save
  onPopInvokedWithResult: (didPop, result) {
    if (didPop) _commitMaxEdgeField(); // fires for back AND programmatic pop
  },
  child: Scaffold(...
```

(The commit path reads the controller text synchronously here — before route disposal — so the write lands even though the page is going away; the snackbar branch is already `mounted`-guarded, and the notifier assignment is safe post-dispose because HomePage owns the notifier.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/settings/settings_page.dart test/settings_page_test.dart
git commit -m "feat: close-flush commits pending max-edge text on back and Save"
```

---

### Task 7: Save persists the connection only

**Files:**
- Modify: `lib/settings/settings_page.dart` (`_save`)
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `ConnectionSettings.save({SettingsStore store})` (already on the model).

- [ ] **Step 1: Write the failing test**

```dart
testWidgets('Save persists the connection and leaves upload keys untouched', (
  tester,
) async {
  final store = InMemorySettingsStore();
  // A stored pref value Save must NOT rewrite.
  store.data['upload.format'] = 'png';
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
      upload: const UploadPrefs(format: ImageFormat.png),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _enterTextScrolled(tester, find.byKey(const Key('host_field')), '10.0.0.5');
  await _tapScrolled(tester, find.text('Save'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsPage), findsNothing); // popped
  expect(store.data['smb.host'], '10.0.0.5');
  expect(store.data['smb.username'], 'tester');
  expect(store.data['upload.format'], 'png'); // Save didn't touch prefs
  expect(store.data['upload.use_order_folders'], isNull); // ...and never wrote
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "leaves upload keys untouched"`
Expected: FAIL — today's `_save` persists the whole `AppSettings`, so `upload.use_order_folders: 'false'` lands in the store and the `isNull` assertion trips.

- [ ] **Step 3: Implement**

Replace `_save` with:

```dart
Future<void> _save() async {
  if (!(_formKey.currentState?.validate() ?? false)) return;
  final s = _formSettings();
  final current = widget.settingsNotifier.value;
  try {
    await s.save(store: widget.store); // connection ONLY (design D6)
  } catch (_) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save settings')),
      );
    }
    return; // stay on the page
  }
  // Instance discipline unchanged: ObjectKey(settings.connection) compares
  // with identical(), so unchanged values reuse the LIVE instance — only a
  // real change swaps identity and remounts History. Prefs are NOT Save's
  // business anymore (write-through owns them).
  widget.settingsNotifier.value = current.copyWith(
    connection: s == current.connection ? current.connection : s,
  );
  if (mounted) Navigator.of(context).pop(true);
}
```

Also rewrite the old test `upload-only save reuses the live connection instance` — its Save no longer carries the upload half; replace with the toggle-driven version:

```dart
testWidgets('pref toggle reuses the live connection instance', (tester) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  final liveConnection = notifier.value.connection;
  await _tapScrolled(tester, find.byKey(const Key('folders_toggle')));
  await tester.pumpAndSettle();
  expect(notifier.value.upload.useOrderFolders, isTrue);
  expect(identical(notifier.value.connection, liveConnection), isTrue);
});
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart`
Expected: ALL PASS — including the existing `save persists, updates notifier, and pops` and `blank password is allowed` (connection semantics unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/settings/settings_page.dart test/settings_page_test.dart
git commit -m "feat: Save persists the connection only; prefs owned by write-through"
```

---

### Task 8: Back discards connection edits; first-run prefs write through

**Files:**
- Modify: `lib/settings/settings_page.dart` (only if a test exposes a gap)
- Test: `test/settings_page_test.dart`

- [ ] **Step 1: Write the tests** (these should mostly pass already — they pin the contract)

```dart
testWidgets('back discards connection edits but keeps written-through prefs', (
  tester,
) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(
    AppSettings.defaults.copyWith(
      connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
    ),
  );
  await _openSettings(
    tester,
    SettingsPage(settingsNotifier: notifier, store: store),
  );
  await _enterTextScrolled(
    tester,
    find.byKey(const Key('host_field')),
    '10.0.0.5',
  );
  await _tapScrolled(tester, find.byKey(const Key('folders_toggle'))); // sticks
  await tester.pumpAndSettle();
  await WidgetsBinding.instance.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.byType(SettingsPage), findsNothing);
  expect(store.data['smb.host'], isNull); // connection edit discarded
  expect(notifier.value.connection.host, '192.168.1.29');
  expect(store.data['upload.use_order_folders'], 'true'); // pref stuck
  expect(notifier.value.upload.useOrderFolders, isTrue);
});

testWidgets('first-run: prefs write through while the gate is up', (
  tester,
) async {
  final store = InMemorySettingsStore();
  final notifier = ValueNotifier(AppSettings.defaults);
  await _openSettings(
    tester,
    SettingsPage(
      settingsNotifier: notifier,
      firstRun: true,
      store: store,
    ),
  );
  await _tapScrolled(tester, find.byKey(const Key('folders_toggle')));
  await tester.pumpAndSettle();
  expect(store.data['upload.use_order_folders'], 'true'); // no save needed
  expect(find.byType(SettingsPage), findsOneWidget); // gate still up
  await tester.enterText(find.byKey(const Key('username_field')), 'tester');
  await _tapScrolled(tester, find.text('Save'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsPage), findsNothing); // valid save dismisses
});
```

- [ ] **Step 2: Run tests**

Run: `/home/coder/flutter/bin/flutter test test/settings_page_test.dart --plain-name "back discards"` and `--plain-name "first-run: prefs"`
Expected: PASS (first-run `Save`'s programmatic pop passes through `PopScope` regardless of `canPop`; if the second test fails on the gate-not-dismissed point, verify `_save` still calls `Navigator.of(context).pop(true)` — do NOT weaken `canPop`).

- [ ] **Step 3: Commit**

```bash
git add test/settings_page_test.dart lib/settings/settings_page.dart
git commit -m "test: pin back-discards-connection and first-run write-through contracts"
```

---

### Task 9: Doc comments, orphan sweep, full-suite verification

**Files:**
- Modify: `lib/settings/settings_page.dart` (comments only)

- [ ] **Step 1: Update stale doc comments**

- Class header comment: "gear-invoked ... back discards edits" → add that capture & upload prefs now write through immediately and back-discard applies to the connection section only.
- `_save`'s comment block: drop the upload-half fresh-construction rationale (moved to `_commitMaxEdgeField`); keep the live-instance/`ObjectKey` paragraph.
- Grep for orphans: `grep -n "_folders\|_batch\|_format\|_quality" lib/settings/settings_page.dart` → expect no hits (except `_customQuality`); same grep in the test file for references to the removed save-gated flow.

- [ ] **Step 2: Whole-suite verification**

Run: `/home/coder/flutter/bin/flutter analyze && /home/coder/flutter/bin/flutter test`
Expected: analyze clean; ALL tests pass — including `test/home_page_test.dart`'s History remount group (notifier-driven, untouched by design D7) and the model tests (`app_settings_test.dart`, `upload_prefs_test.dart` — the model layer didn't change).

- [ ] **Step 3: Commit**

```bash
git add lib/settings/settings_page.dart
git commit -m "docs: describe write-through prefs and connection-only Save in settings page"
```

- [ ] **Step 4: Device pass (operator-gated, from tasks.md 4.2)**

Hand to the operator: toggle each control → force-stop + relaunch → values persist; leave via back AND via Save → prefs never lost, connection edits discard on back; flip a pref while History was already visited → History neither remounts nor re-lists; one end-to-end capture with the changed prefs.
