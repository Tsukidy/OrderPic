# recent-scans Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Recent" button beside "Type order number" on the Scan screen that opens a capped, persisted, most-recent-first picker of order numbers that have started a capture, flowing into the identical confirm-and-capture path.

**Architecture:** A small immutable `RecentOrders` value class (`lib/recents/recent_orders.dart`) persists through the existing injectable `SettingsStore` seam under one JSON key (`recent.orders`, capped at 10, oldest evicted at record time). `ScannerPage` owns an instance in its state: loads at init, records in `_startCapture` (the one convergence point of all entry paths) after the capture session creates successfully, and opens an extracted `RecentOrdersDialog` picker whose pick reuses the existing `CaptureSource` confirm dialog.

**Tech Stack:** Flutter (Dart ^3.13), flutter_lints 6, `flutter_secure_storage` behind the `SettingsStore` seam, `mobile_scanner` 7.4 (faked in tests via `MobileScannerPlatform` + `MockPlatformInterfaceMixin`), `flutter_test`.

**Spec:** `openspec/changes/recent-scans/specs/recent-scans/spec.md` (requirements/scenarios), `openspec/changes/recent-scans/design.md` (decisions D1–D7), `openspec/changes/recent-scans/tasks.md` (checklist this plan implements).

## Global Constraints

- **Parallel worktree boundary:** do NOT touch `AppSettings`, `UploadPrefs`, `ConnectionSettings`, `SettingsPage`, or any settings-saving code — the `settings-save-change` change owns those in its own worktree. Recents deliberately live OUTSIDE `AppSettings` (design D1).
- **Storage:** exactly one new key `recent.orders` through the injectable `SettingsStore` seam; `maxRecentOrders = 10` enforced at record time (and defensively at load). Corrupt payload → empty list, never a wipe of any key (design D2/D6).
- **Dependencies:** no new runtime dependencies. One new dev dependency: `plugin_platform_interface: ^2.1.8` (test-only; same explicit-declaration precedent as the existing `image_picker_platform_interface` entry).
- **Flutter binary is not on PATH:** use `/home/coder/flutter/bin/flutter` (the CLAUDE.md `/home/dylan` path is a different machine).
- **No blanket `dart format`** — the repo pins its current style; only touch lines this change owns.
- **UI copy (exact strings):** `Recent`, `Recent orders`, `Recent order`, `Take photo`, `Gallery`, `Cancel`.
- **Lints:** flutter_lints 6 — fire-and-forget futures go through `unawaited(...)` (`dart:async` already imported in `scanner_page.dart`).
- Every task ends with: `/home/coder/flutter/bin/flutter analyze` clean, its tests green, and a commit.

## Test mechanics proven during planning (do not skip this)

A throwaway probe test ran the real typed-entry → capture → scanner-resume flow against the current code to validate every mechanism below. These are facts about THIS test env, not speculation:

1. **The scanner's bottom-row buttons render off-screen in widget tests.** The `MobileScanner` widget degrades to its `errorBuilder`, whose `Center` shrinks under the Stack's loose constraints, landing the `Positioned(bottom:16)` row at negative Y. `tester.tap` on those two buttons fails with "would not hit test". **Invoke their `onPressed!()` callbacks directly** — the same immune-to-hit-testing pattern `home_page_test.dart` uses for the `NavigationBar` (`tester.widget<NavigationBar>(...).onDestinationSelected!(1)`). Dialogs are centered and tappable normally.
2. **mobile_scanner needs a fake platform in any test that lets real time run.** `home_page_test` passes because its pure-FakeAsync pumps never dispatch the scanner's platform calls. Any test using `tester.runAsync` (needed for `CaptureSession.create`'s real file IO) surfaces unhandled `MissingPluginException`s from the scanner's own `start()`. Fix: install `_FakeScannerPlatform` (Task 3) before pumping.
3. **Real-time settle loop:** rounds of `tester.runAsync(() => Future<void>.delayed(25ms))` + `tester.pump(Duration(milliseconds: 100))`. A zero-duration `pump()` never completes route animations or file IO — a dialog stays visibly "open" forever and its `TextField` finder keeps matching.
4. **`enterText` needs one `pump()` before dependent controls** (the confirm button's `onPressed` is built by a `ValueListenableBuilder`) are updated in the render tree.

---

### Task 1: `RecentOrders` value class (TDD)

**Files:**
- Create: `test/recent_orders_test.dart`
- Create: `lib/recents/recent_orders.dart`

**Interfaces:**
- Consumes: `SettingsStore` (`lib/settings/settings_store.dart`), `InMemorySettingsStore` (`test/helpers/in_memory_settings_store.dart`).
- Produces (later tasks rely on these exact names):
  - `const RecentOrders({List<String> orders = const []})`, `static const RecentOrders empty`
  - `List<String> get orders` — most-recent-first
  - `bool get isEmpty`
  - `RecentOrders record(String orderNumber)` — pure, returns new value
  - `static Future<RecentOrders> load({SettingsStore store = const SecureSettingsStore()})`
  - `Future<void> save({SettingsStore store = const SecureSettingsStore()})`
  - `const String recentOrdersKey = 'recent.orders'`, `const int maxRecentOrders = 10`

- [ ] **Step 1: Write the failing tests**

Create `test/recent_orders_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/recents/recent_orders.dart';
import 'package:orderpic/settings/settings_store.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  group('record', () {
    test('inserts a new order at the front', () {
      var recents = const RecentOrders.empty();
      recents = recents.record('100438');
      recents = recents.record('100439');
      expect(recents.orders, ['100439', '100438']);
    });

    test('re-recording an existing order moves it to the front without '
        'duplicating', () {
      var recents = const RecentOrders.empty();
      recents = recents.record('100438');
      recents = recents.record('100439');
      recents = recents.record('100438');
      expect(recents.orders, ['100438', '100439']);
    });

    test('an 11th distinct order evicts the oldest', () {
      var recents = const RecentOrders.empty();
      for (var i = 1; i <= 10; i++) {
        recents = recents.record('order$i');
      }
      recents = recents.record('order0');
      expect(recents.orders.length, 10);
      expect(recents.orders.first, 'order0');
      expect(recents.orders.contains('order1'), isFalse);
    });
  });

  group('load/save', () {
    test('round-trips through the store', () async {
      final store = InMemorySettingsStore();
      final recents = const RecentOrders.empty().record('100438').record(
            '100439',
          );
      await recents.save(store: store);

      final loaded = await RecentOrders.load(store: store);
      expect(loaded.orders, ['100439', '100438']);
    });

    test('missing key loads as empty', () async {
      final loaded = await RecentOrders.load(store: InMemorySettingsStore());
      expect(loaded.isEmpty, isTrue);
    });

    test('corrupt payload degrades to empty and leaves other keys untouched',
        () async {
      final store = InMemorySettingsStore();
      await store.write('smb.host', '192.168.1.29');
      await store.write(recentOrdersKey, '{not json');

      final loaded = await RecentOrders.load(store: store);

      expect(loaded.isEmpty, isTrue);
      expect(await store.read('smb.host'), '192.168.1.29');
      // No wipe — the corrupt key is left exactly as it was.
      expect(await store.read(recentOrdersKey), '{not json');
    });

    test('non-string entries are ignored', () async {
      final store = InMemorySettingsStore();
      await store.write(recentOrdersKey, jsonEncode([1, 2, 3]));
      final loaded = await RecentOrders.load(store: store);
      expect(loaded.isEmpty, isTrue);
    });

    test('save failures are swallowed', () async {
      final recents = const RecentOrders.empty().record('100438');
      // Must not throw.
      await recents.save(store: _ThrowingStore());
    });
  });
}

class _ThrowingStore implements SettingsStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('disk full');

  @override
  Future<void> delete(String key) async {}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/recent_orders_test.dart`
Expected: FAIL to compile — `package:orderpic/recents/recent_orders.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/recents/recent_orders.dart`:

```dart
import 'dart:convert';

import '../settings/settings_store.dart';

/// Storage key holding the whole recents list as a JSON array
/// (most-recent-first).
const String recentOrdersKey = 'recent.orders';

/// Maximum number of order numbers kept. Applied at record time (and
/// defensively at load) so the persisted payload never grows with usage.
const int maxRecentOrders = 10;

/// The order numbers that have started a capture on this device —
/// most-recent first, deduplicated, capped at [maxRecentOrders].
///
/// Deliberately OUTSIDE `AppSettings`: recents are session history, not
/// preferences — they mutate on every capture and must stay clear of the
/// settings-saving code paths (a parallel change owns those). Persistence
/// rides the same injectable [SettingsStore] seam as everything else; a
/// corrupt or unreadable store degrades to [empty] with no wipe, mirroring
/// `UploadPrefs.load` — nothing here is a secret worth resetting over.
class RecentOrders {
  final List<String> orders;

  const RecentOrders({this.orders = const []});

  static const RecentOrders empty = RecentOrders();

  bool get isEmpty => orders.isEmpty;

  /// Moves [orderNumber] to the front (or inserts it, if new), then trims
  /// to [maxRecentOrders]. Pure — returns the new value; `this` unchanged.
  RecentOrders record(String orderNumber) {
    final next = <String>[
      orderNumber,
      ...orders.where((existing) => existing != orderNumber),
    ];
    return RecentOrders(
      orders: next.length > maxRecentOrders
          ? next.sublist(0, maxRecentOrders)
          : next,
    );
  }

  /// Reads the list; a missing key, an undecodable payload, or non-string
  /// entries yield [empty] (entries capped defensively). Never throws.
  static Future<RecentOrders> load({
    SettingsStore store = const SecureSettingsStore(),
  }) async {
    try {
      final raw = await store.read(recentOrdersKey);
      if (raw == null || raw.isEmpty) return empty;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return empty;
      final orders = decoded
          .whereType<String>()
          .where((order) => order.isNotEmpty)
          .take(maxRecentOrders)
          .toList();
      return RecentOrders(orders: orders);
    } catch (_) {
      return empty;
    }
  }

  /// Writes the whole list as one JSON array. Failures are swallowed — the
  /// in-memory copy already reflects the new state, and a storage error
  /// must never fail the capture that is about to start.
  Future<void> save({
    SettingsStore store = const SecureSettingsStore(),
  }) async {
    try {
      await store.write(recentOrdersKey, jsonEncode(orders));
    } catch (_) {
      /* best effort */
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/recent_orders_test.dart`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Analyze and commit**

Run: `/home/coder/flutter/bin/flutter analyze` — expect `No issues found!`

```bash
git add lib/recents/recent_orders.dart test/recent_orders_test.dart
git commit -m "feat: recent-scans — RecentOrders store (capped, persisted, LRU)"
```

---

### Task 2: `RecentOrdersDialog` picker widget (TDD)

**Files:**
- Create: `test/recent_orders_dialog_test.dart`
- Create: `lib/recents/recent_orders_dialog.dart`

**Interfaces:**
- Consumes: nothing from Task 1 (takes a plain `List<String>`).
- Produces: `RecentOrdersDialog({required List<String> orders})` — a dialog widget; tapping a list entry pops with that order number (`Navigator.of(context).pop(orderNumber)`); Cancel pops null.

- [ ] **Step 1: Write the failing tests**

Create `test/recent_orders_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/recents/recent_orders_dialog.dart';

void main() {
  testWidgets('lists orders most-recent first and pops the tapped number', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                picked = await showDialog<String>(
                  context: context,
                  builder: (_) =>
                      const RecentOrdersDialog(orders: ['100111', '100438']),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Recent orders'), findsOneWidget);
    final firstTile = tester.widget<ListTile>(find.byType(ListTile).first);
    expect((firstTile.title as Text).data, '100111'); // newest first

    await tester.tap(find.text('100438'));
    await tester.pumpAndSettle();
    expect(picked, '100438');
  });

  testWidgets('Cancel pops null', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                picked = await showDialog<String>(
                  context: context,
                  builder: (_) => const RecentOrdersDialog(orders: ['100438']),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/recent_orders_dialog_test.dart`
Expected: FAIL to compile — `recent_orders_dialog.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/recents/recent_orders_dialog.dart`:

```dart
import 'package:flutter/material.dart';

/// Picker over the recorded order numbers, most-recent first. Pops the
/// picked number; null on dismiss.
///
/// Standalone (not an inline builder in ScannerPage) so it is
/// widget-testable without the MobileScanner platform view.
class RecentOrdersDialog extends StatelessWidget {
  const RecentOrdersDialog({super.key, required this.orders});

  final List<String> orders;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Recent orders'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: orders.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final orderNumber = orders[index];
            return ListTile(
              leading: const Icon(Icons.qr_code),
              title: Text(
                orderNumber,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).pop(orderNumber),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/recent_orders_dialog_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Analyze and commit**

Run: `/home/coder/flutter/bin/flutter analyze` — expect `No issues found!`

```bash
git add lib/recents/recent_orders_dialog.dart test/recent_orders_dialog_test.dart
git commit -m "feat: recent-scans — RecentOrdersDialog picker"
```

---

### Task 3: Recent button on the Scan screen + recents load

**Files:**
- Modify: `pubspec.yaml` (dev_dependencies)
- Create: `test/helpers/fake_mobile_scanner_platform.dart`
- Create: `test/scanner_recents_test.dart`
- Modify: `lib/pages/scanner_page.dart`

**Interfaces:**
- Consumes: `RecentOrders.empty` / `.load()` / `.isEmpty` / `.orders` (Task 1), `recentOrdersKey` (Task 1).
- Produces: `ScannerPage` state field `RecentOrders _recent`; the bottom row's `Row` of two `Expanded` `FilledButton.tonalIcon`s; test helper `pumpShell(tester, {recents})` and `recentButton()` finder reused by Tasks 4–5.

- [ ] **Step 1: Add the test-only dev dependency**

In `pubspec.yaml`, extend the existing test-seam comment block in `dev_dependencies`:

```yaml
  # Test seam for mobile_scanner: the recents shell tests swap in a fake
  # MobileScannerPlatform (with MockPlatformInterfaceMixin) so the real-time
  # settle rounds never hit the platform channels. Declared explicitly so
  # the test import satisfies depend_on_referenced_packages.
  plugin_platform_interface: ^2.1.8
```

Then run `/home/coder/flutter/bin/flutter pub get`.

- [ ] **Step 2: Create the fake scanner platform**

Create `test/helpers/fake_mobile_scanner_platform.dart` (mechanics proven by the planning probe — start/stop complete, streams never yield, camera view is an inert box):

```dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Inert mobile_scanner platform for widget tests: the scanner widget
/// initializes and starts without touching any platform channel, so tests
/// that let real time run (runAsync rounds for file IO) surface no
/// MissingPluginExceptions.
class FakeMobileScannerPlatform extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();

  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        numberOfCameras: 1,
        size: Size(1920, 1080),
      );

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<Set<CameraLensType>> getSupportedLenses({
    CameraFacing? facing,
  }) async => {CameraLensType.normal};

  @override
  Widget buildCameraView() => const SizedBox.expand();
}
```

- [ ] **Step 3: Write the failing shell tests**

Create `test/scanner_recents_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:orderpic/main.dart';
import 'package:orderpic/recents/recent_orders.dart';

import 'helpers/fake_mobile_scanner_platform.dart';
import 'helpers/in_memory_settings_store.dart';

void main() {
  setUp(() {
    MobileScannerPlatform.instance = FakeMobileScannerPlatform();
  });

  Finder recentButton() => find.widgetWithText(FilledButton, 'Recent');

  /// Pumps the real shell with a configured (gate-free) in-memory store,
  /// optionally seeded with a recents payload, and settles the loads.
  Future<InMemorySettingsStore> pumpShell(
    WidgetTester tester, {
    List<String> recents = const [],
  }) async {
    final store = InMemorySettingsStore()
      ..data['smb.username'] = 'tester'
      ..data['smb.host'] = '192.168.1.29';
    if (recents.isNotEmpty) {
      store.data[recentOrdersKey] = jsonEncode(recents);
    }
    await tester.pumpWidget(OrderPicApp(store: store));
    await tester.pump(); // settings load resolves
    await tester.pump(); // recents load resolves
    return store;
  }

  testWidgets('Recent button is visible and disabled before the first '
      'capture', (tester) async {
    await pumpShell(tester);

    expect(find.text('Recent'), findsOneWidget);
    expect(tester.widget<FilledButton>(recentButton()).onPressed, isNull);
    // The neighbor is untouched:
    expect(find.text('Type order number'), findsOneWidget);
  });

  testWidgets('Recent button enables once the store holds recents', (
    tester,
  ) async {
    await pumpShell(tester, recents: ['100438']);

    expect(tester.widget<FilledButton>(recentButton()).onPressed, isNotNull);
  });
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/scanner_recents_test.dart`
Expected: FAIL — `find.text('Recent')` finds nothing (the button does not exist yet).

- [ ] **Step 5: Implement the button and the load**

Edit `lib/pages/scanner_page.dart`:

Add imports (after the existing `../route_observer.dart` import, keeping alphabetical grouping with the relatives):

```dart
import '../recents/recent_orders.dart';
import '../recents/recent_orders_dialog.dart';
```

Add the state field next to `_entryController`:

```dart
  final TextEditingController _entryController = TextEditingController();
  RecentOrders _recent = RecentOrders.empty;
  bool _processing = false;
```

In `initState`, after `WidgetsBinding.instance.addObserver(this);`, kick off the load:

```dart
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadRecents());
```

Add the loader method (anywhere among the private methods, e.g. before `_onDetect`):

```dart
  /// Load the persisted recents once at startup; the Recent button flips
  /// enabled when a non-empty list arrives. Guarded: if a capture already
  /// recorded (state non-empty) the late-arriving disk copy must not
  /// clobber it.
  Future<void> _loadRecents() async {
    final recents = await RecentOrders.load();
    if (!mounted || _recent.orders.isNotEmpty) return;
    setState(() => _recent = recents);
  }
```

Replace the bottom `Positioned` (currently a single `FilledButton.tonalIcon`):

```dart
          // Fallback for a missing or damaged QR code — always visible so
          // it's findable after a failed scan attempt.
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.keyboard),
                    label: const Text('Type order number'),
                    onPressed: _showEntryDialog,
                  ),
                ),
                const SizedBox(width: 12),
                // Third entry path: pick a recently used order number.
                // Always visible (findable before the first capture, like
                // the Type button), disabled until a capture has recorded.
                Expanded(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.history),
                    label: const Text('Recent'),
                    onPressed: _recent.isEmpty ? null : _showRecentDialog,
                  ),
                ),
              ],
            ),
          ),
```

(`_showRecentDialog` does not exist yet — add a temporary stub so this task compiles standalone; Task 4 replaces the stub body:

```dart
  /// Stub — implemented in Task 4 (picker dialog + confirm hand-off).
  Future<void> _showRecentDialog() async {}
```

)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/scanner_recents_test.dart`
Expected: PASS (both tests).

- [ ] **Step 7: Analyze and commit**

Run: `/home/coder/flutter/bin/flutter analyze` — expect `No issues found!` (delete the stub comment if analyze flags nothing; keep the stub until Task 4).

```bash
git add pubspec.yaml pubspec.lock lib/pages/scanner_page.dart test/helpers/fake_mobile_scanner_platform.dart test/scanner_recents_test.dart
git commit -m "feat: recent-scans — Recent button beside Type order number"
```

---

### Task 4: Picker dialog wiring + confirm hand-off (no-recording paths)

**Files:**
- Modify: `lib/pages/scanner_page.dart`
- Modify: `test/scanner_recents_test.dart`

**Interfaces:**
- Consumes: `RecentOrdersDialog` (Task 2), `_recent.orders` / `_recent.isEmpty` (Task 1/3), `CaptureSource` and `_startCapture` (existing code).
- Produces: `_showRecentDialog()` — full behavior: `_processing` guard → picker → pick → `CaptureSource` confirm dialog (Take photo / Gallery / **Cancel**, not Rescan) → `_startCapture`; dismiss/cancel re-enables detection with no push.

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/scanner_recents_test.dart`:

```dart
  testWidgets('picker lists recents most-recent first and dismisses cleanly',
      (tester) async {
    await pumpShell(tester, recents: ['100111', '100438']);

    tester.widget<FilledButton>(recentButton()).onPressed!();
    await tester.pumpAndSettle(); // picker dialog opens

    expect(find.text('Recent orders'), findsOneWidget);
    final firstTile = tester.widget<ListTile>(find.byType(ListTile).first);
    expect((firstTile.title as Text).data, '100111'); // newest first

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle(); // dialog exit needs simulated time
    expect(find.text('Recent orders'), findsNothing);
  });

  testWidgets('picking then cancelling starts no flow and records nothing',
      (tester) async {
    final store = await pumpShell(tester, recents: ['100111']);

    tester.widget<FilledButton>(recentButton()).onPressed!();
    await tester.pumpAndSettle();

    await tester.tap(find.text('100111'));
    await tester.pumpAndSettle();
    expect(find.text('Recent order'), findsOneWidget);
    expect(find.text('100111'), findsNWidgets(2)); // tile behind + dialog

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(CameraPage), findsNothing);
    expect(store.data.containsKey(recentOrdersKey), isFalse);

    // The guard released: the picker reopens.
    tester.widget<FilledButton>(recentButton()).onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Recent orders'), findsOneWidget);
  });
```

Add the import at the top of the file (the Task 1 `recent_orders.dart` import is already there from Task 3):

```dart
import 'package:orderpic/pages/camera_page.dart';
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/scanner_recents_test.dart`
Expected: FAIL — the stub `_showRecentDialog` never opens a dialog (`Recent orders` not found).

- [ ] **Step 3: Implement `_showRecentDialog`**

In `lib/pages/scanner_page.dart`, replace the Task 3 stub with:

```dart
  /// Third entry path: pick a recently used order number instead of
  /// re-scanning. Same `_processing` guard as the entry dialog — the camera
  /// keeps running underneath (detection is suppressed by the guard), so
  /// unlike `_onDetect` nothing restarts on the cancel paths. A picked
  /// number continues through the SAME source-confirm dialog a scanned code
  /// gets — Cancel, not Rescan: there is nothing to rescan.
  Future<void> _showRecentDialog() async {
    if (_processing) return;
    _processing = true;

    final picked = await showDialog<String>(
      context: context,
      builder: (_) => RecentOrdersDialog(orders: _recent.orders),
    );

    if (!mounted) return;
    if (picked == null) {
      // Dismissed — nothing was pushed, just release the guard.
      _processing = false;
      return;
    }

    // Same output shape as the QR/entry dialogs: WHICH source launches, or
    // null for Cancel/dismiss.
    final confirmed = await showDialog<CaptureSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recent order'),
        content: Text(picked),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(CaptureSource.camera),
            child: const Text('Take photo'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(CaptureSource.gallery),
            child: const Text('Gallery'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (confirmed != null) {
      await _startCapture(picked, source: confirmed);
    } else {
      _processing = false;
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/scanner_recents_test.dart`
Expected: PASS (all four tests — Tasks 3's two still green).

- [ ] **Step 5: Analyze and commit**

Run: `/home/coder/flutter/bin/flutter analyze` — expect `No issues found!`

```bash
git add lib/pages/scanner_page.dart test/scanner_recents_test.dart
git commit -m "feat: recent-scans — picker dialog + confirm hand-off"
```

---

### Task 5: Recording hook in `_startCapture` (TDD)

**Files:**
- Modify: `lib/pages/scanner_page.dart`
- Modify: `test/scanner_recents_test.dart`

**Interfaces:**
- Consumes: `_recent` field (Task 3), `RecentOrders.record` / `.save` (Task 1), existing `_startCapture`.
- Produces: the recording side effect — every successful capture start re-fronts its order number in memory and persists best-effort.

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/scanner_recents_test.dart`, plus the settle helper above the tests (real-IO rounds — see "Test mechanics" #3):

```dart
  /// Real-time settle rounds until [done] turns true: file IO the flow
  /// triggers (session create, cleanup) completes only on the real event
  /// loop; each round also advances simulated time so route animations
  /// finish. Bounded so a regression fails instead of hanging.
  Future<bool> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var round = 0; round < 40 && !done(); round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    return done();
  }

  testWidgets('a picked order records and re-fronts in the store', (
    tester,
  ) async {
    final store = await pumpShell(tester, recents: ['100111', '100438']);

    tester.widget<FilledButton>(recentButton()).onPressed!();
    await tester.pumpAndSettle(); // picker
    await tester.tap(find.text('100438')); // second in list
    await tester.pumpAndSettle(); // confirm dialog

    await tester.tap(find.widgetWithText(FilledButton, 'Take photo'));
    final recorded = await settleUntil(
      tester,
      // Witness: the store payload changed from its seeded value. The
      // session create's real IO can only complete on runAsync rounds.
      () => store.data[recentOrdersKey] != jsonEncode(['100111', '100438']),
    );
    expect(recorded, isTrue, reason: 'recents store never updated');
    expect(
      jsonDecode(store.data[recentOrdersKey]! as String),
      ['100438', '100111'], // recorded AND moved to the front
    );
  });

  testWidgets('typed entry records the order and enables the Recent button',
      (tester) async {
    final store = await pumpShell(tester);
    expect(tester.widget<FilledButton>(recentButton()).onPressed, isNull);

    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Type order number'),
        )
        .onPressed!(); // bottom-row buttons are off-screen in tests
    await tester.pumpAndSettle(); // entry dialog
    await tester.enterText(find.byType(TextField), '100555');
    await tester.pump(); // confirm enables
    await tester.tap(find.widgetWithText(FilledButton, 'Take photo'));

    final recorded = await settleUntil(
      tester,
      () => store.data.containsKey(recentOrdersKey),
    );
    expect(recorded, isTrue, reason: 'typed capture never recorded');
    expect(jsonDecode(store.data[recentOrdersKey]! as String), ['100555']);
    // The empty → enabled transition is visible without leaving the screen.
    expect(tester.widget<FilledButton>(recentButton()).onPressed, isNotNull);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/home/coder/flutter/bin/flutter test test/scanner_recents_test.dart`
Expected: FAIL — both new tests' `recorded` witnesses never turn true (no recording exists yet). The flow itself still runs (CameraPage pushes, picker-less exit pops back) — that is the proven probe path.

- [ ] **Step 3: Implement the hook**

In `lib/pages/scanner_page.dart`, inside `_startCapture`, insert after the `if (!mounted) return;` that follows the `CaptureSession.create` try/catch, and before `await Navigator.of(context).push(`:

```dart
    // Record AFTER the session exists: dismissed scans and failed creates
    // never pollute recents, and a re-picked order re-fronts through this
    // same hook (design D3). Save is best-effort — a storage failure must
    // not fail the capture that is about to start (design D6).
    final updated = _recent.record(orderNumber);
    setState(() => _recent = updated);
    unawaited(updated.save());
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/home/coder/flutter/bin/flutter test test/scanner_recents_test.dart`
Expected: PASS (all six tests).

- [ ] **Step 5: Analyze and commit**

Run: `/home/coder/flutter/bin/flutter analyze` — expect `No issues found!`

```bash
git add lib/pages/scanner_page.dart test/scanner_recents_test.dart
git commit -m "feat: recent-scans — record every confirmed capture start"
```

---

### Task 6: Full verification

**Files:** none (verification only). Maps to tasks.md 5.1–5.3.

- [ ] **Step 1: Whole-suite static analysis + tests**

Run: `/home/coder/flutter/bin/flutter analyze`
Expected: `No issues found!`

Run: `/home/coder/flutter/bin/flutter test`
Expected: all files green — including the pre-existing suites (`home_page_test`, `preview_page_test`, etc.; the pubspec dev-dep addition must not disturb them).

- [ ] **Step 2: Physical-device spot check (operator-gated)**

Per repo norm the capture flow needs a real camera + LAN share; this step is operator-performed, as with the gallery-upload-option change:
scan a QR → capture + upload → tap Recent → pick the same order → second capture uploads → kill + relaunch the app → the Recent button is enabled and offers the order; a QR-confirm dismissal adds nothing to the list.

- [ ] **Step 3: Record the outcome**

Note the result of both steps (and any operator finding) in the change's verify notes when `/opsx:verify` runs — that artifact belongs to the verify phase, not this plan.
