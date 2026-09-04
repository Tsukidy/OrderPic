# SMB Settings Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded SMB constants in `lib/main.dart` with an encrypted, user-editable settings screen (gear icon in both app bars) plus a first-run login gate — no credentials in the binary.

**Architecture:** An immutable `SmbSettings` value class owned by `_HomePageState` as a `ValueNotifier`; persistence through `flutter_secure_storage` behind an injectable `SettingsStore` seam; a shared `connect()` helper (with unconfigured guard) replaces the three inline `connectAuth` blocks; one dual-mode `SettingsPage` (normal + first-run); History re-keys on actual settings change.

**Tech Stack:** Flutter (Dart, Material 3), `flutter_secure_storage` (new), existing `smb_connect` / `mobile_scanner` / `image_picker`. Plain `StatefulWidget`s — no state-management library, everything stays in `lib/main.dart` (established repo pattern).

## Global Constraints

- Filename contract untouched: uploads stay `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg`; `HistoryPage._parseName` unchanged.
- The `openRead` + `BytesBuilder` chunk-copy in `ImageViewerPage._load` (currently `lib/main.dart:741-748`) is preserved verbatim — smb_connect reuses one buffer per chunk.
- All five settings persist ONLY via `flutter_secure_storage` (never `shared_preferences`).
- `SmbSettings.defaults` contains empty `username`/`password` — credentials are never compiled into the binary.
- Guard message string, verbatim: `SMB login not configured — open Settings`.
- `flutter analyze` clean (flutter_lints 6) after every task.
- Every commit message ends with `Co-Authored-By: Claude <noreply@anthropic.com>`.
- Execute on a fresh branch off `main` (e.g. `worktree-smb-path-settings-menu`); merge with `worktree-ordernumber-entry` is take-both (Task 9).
- Line numbers below reference `main` before the `ordernumber-entry` merge; anchor edits by the named symbols (`smbHost`, `_upload`, etc.), not line numbers.

---

### Task 1: `SmbSettings` value class

**Files:**
- Modify: `lib/main.dart` (top of file — replace lines 10-15, the five `smb*` constants)
- Test: `test/smb_settings_test.dart` (new)

**Interfaces:**
- Consumes: nothing (leaf).
- Produces: `class SmbSettings` with `final String host, sharePath, domain, username, password;`, a `const` constructor taking all five as named required params, `copyWith({String? host, String? sharePath, String? domain, String? username, String? password})`, `==`/`hashCode` over all five fields, and `static const SmbSettings defaults` = host `'192.168.1.29'`, sharePath `'/zdrive/InvoiceData'`, domain `''`, username `''`, password `''`.

- [ ] **Step 1: Write the failing tests**

Create `test/smb_settings_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

void main() {
  group('SmbSettings', () {
    test('defaults seed config fields but never credentials', () {
      expect(SmbSettings.defaults.host, '192.168.1.29');
      expect(SmbSettings.defaults.sharePath, '/zdrive/InvoiceData');
      expect(SmbSettings.defaults.domain, '');
      expect(SmbSettings.defaults.username, ''); // never in the binary
      expect(SmbSettings.defaults.password, ''); // never in the binary
    });

    test('equality covers all five fields', () {
      const a = SmbSettings(
          host: 'h', sharePath: '/s', domain: '', username: 'u', password: 'p');
      final b = a.copyWith();
      final c = a.copyWith(password: 'other');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('copyWith only changes given fields', () {
      final s = SmbSettings.defaults.copyWith(username: 'opk');
      expect(s.username, 'opk');
      expect(s.host, SmbSettings.defaults.host);
      expect(s.sharePath, SmbSettings.defaults.sharePath);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/smb_settings_test.dart`
Expected: FAIL — `Error: Isn't defined: SmbSettings` / compile error.

- [ ] **Step 3: Implement the class**

In `lib/main.dart`, delete the five constants (`smbHost`, `smbSharePath`, `smbDomain`, `smbUsername`, `smbPassword` — lines 10-15) and put in their place:

```dart
/// SMB share settings. Credentials default to empty and are never
/// compiled into the binary — the user enters them on first startup
/// (settings persist via flutter_secure_storage).
class SmbSettings {
  final String host;
  final String sharePath; // <share>/<sub-folder> (sub-folder is created if missing)
  final String domain;
  final String username;
  final String password;

  const SmbSettings({
    required this.host,
    required this.sharePath,
    required this.domain,
    required this.username,
    required this.password,
  });

  /// Seeds ONLY the non-secret fields; username/password stay empty (Q7).
  static const SmbSettings defaults = SmbSettings(
    host: '192.168.1.29',
    sharePath: '/zdrive/InvoiceData',
    domain: '',
    username: '',
    password: '',
  );

  SmbSettings copyWith({
    String? host,
    String? sharePath,
    String? domain,
    String? username,
    String? password,
  }) =>
      SmbSettings(
        host: host ?? this.host,
        sharePath: sharePath ?? this.sharePath,
        domain: domain ?? this.domain,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  @override
  bool operator ==(Object other) =>
      other is SmbSettings &&
      other.host == host &&
      other.sharePath == sharePath &&
      other.domain == domain &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode =>
      Object.hash(host, sharePath, domain, username, password);
}
```

Do NOT fix the three `connectAuth` callers yet — they break compile in this task only if referenced; they still reference deleted constants, so also update them minimally NOW to keep the build green: replace every `smbHost`/`smbSharePath`/`smbDomain`/`smbUsername`/`smbPassword` use in `_upload`, `_refresh`, `_load` with `SmbSettings.defaults.host` etc. (three sites; final wiring lands in Task 3/6).

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/smb_settings_test.dart && flutter analyze`
Expected: 3 tests PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/smb_settings_test.dart
git commit -m "feat: SmbSettings value class replaces hardcoded SMB constants

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Storage seam, `load()`/`save()`, recovery

**Files:**
- Modify: `lib/main.dart` (below `SmbSettings`; add the `flutter_secure_storage` import at the top)
- Modify: `pubspec.yaml`
- Create: `test/helpers/in_memory_settings_store.dart`
- Test: `test/smb_settings_test.dart` (extend)

**Interfaces:**
- Consumes: `SmbSettings` (Task 1).
- Produces:
  - `abstract class SettingsStore { Future<String?> read(String key); Future<void> write(String key, String value); Future<void> delete(String key); }`
  - `class SecureSettingsStore implements SettingsStore` with a `const` constructor (wraps `FlutterSecureStorage`).
  - `const List<String> smbSettingKeys = ['smb.host', 'smb.share_path', 'smb.domain', 'smb.username', 'smb.password'];`
  - `static Future<SmbSettings> SmbSettings.load({SettingsStore store = const SecureSettingsStore()})`
  - `Future<void> SmbSettings.save({SettingsStore store = const SecureSettingsStore()})`
  - Test fake `InMemorySettingsStore` / `UnreadableSettingsStore` (in test helpers, NOT in main.dart).

- [ ] **Step 1: Add the dependency**

Run: `flutter pub add flutter_secure_storage`
Note the resolved version in the commit message (design Open Question).

- [ ] **Step 2: Write the failing tests**

Create `test/helpers/in_memory_settings_store.dart`:

```dart
import 'package:mmcpicv4/main.dart';

/// In-memory SettingsStore for tests — no platform channels.
class InMemorySettingsStore implements SettingsStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Simulates an undecryptable secure store (e.g. restored backup).
class UnreadableSettingsStore implements SettingsStore {
  @override
  Future<String?> read(String key) async => throw Exception('unreadable');

  @override
  Future<void> write(String key, String value) async => throw Exception('unreadable');

  @override
  Future<void> delete(String key) async {}
}
```

Append to `test/smb_settings_test.dart` (inside `main()`, new group; add imports `import 'package:mmcpicv4/main.dart';` already present, plus `import 'helpers/in_memory_settings_store.dart';`):

```dart
  group('SmbSettings persistence', () {
    test('missing keys fall back per-field: config seeded, credentials empty', () async {
      final store = InMemorySettingsStore(); // nothing stored
      final s = await SmbSettings.load(store: store);
      expect(s.host, SmbSettings.defaults.host);
      expect(s.sharePath, SmbSettings.defaults.sharePath);
      expect(s.username, '');
    });

    test('save/load round-trips through the store', () async {
      final store = InMemorySettingsStore();
      final s = SmbSettings.defaults.copyWith(
          host: '10.0.0.5', sharePath: '/photos/shop', username: 'opk', password: 'pw');
      await s.save(store: store);
      expect(store.data['smb.username'], 'opk');
      expect(await SmbSettings.load(store: store), s);
    });

    test('unreadable store is wiped and falls back to defaults', () async {
      final store = UnreadableSettingsStore();
      final s = await SmbSettings.load(store: store);
      expect(s, SmbSettings.defaults); // empty username re-triggers first-run
    });
  });
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `flutter test test/smb_settings_test.dart`
Expected: FAIL — `SettingsStore` / `load` / `save` not defined.

- [ ] **Step 4: Implement the seam and load/save**

In `lib/main.dart`, add `import 'package:flutter_secure_storage/flutter_secure_storage.dart';` to the imports and, below the `SmbSettings` class:

```dart
/// Storage keys for the five settings (all live in the encrypted store).
const List<String> smbSettingKeys = [
  'smb.host', 'smb.share_path', 'smb.domain', 'smb.username', 'smb.password',
];

/// Minimal async key-value contract so settings logic is testable
/// without platform channels.
abstract class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production store: flutter_secure_storage (Android Keystore / iOS Keychain).
class SecureSettingsStore implements SettingsStore {
  const SecureSettingsStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
```

Then extend the `SmbSettings` class itself:

```dart
  /// Per-field fallback: config fields → defaults, credentials → empty.
  /// An unreadable/undecryptable store is wiped and falls back to
  /// defaults (the empty username then re-triggers first-run setup).
  static Future<SmbSettings> load(
      {SettingsStore store = const SecureSettingsStore()}) async {
    try {
      Future<String> field(String key, String fallback) async =>
          (await store.read(key)) ?? fallback;
      return SmbSettings(
        host: await field('smb.host', defaults.host),
        sharePath: await field('smb.share_path', defaults.sharePath),
        domain: await field('smb.domain', defaults.domain),
        username: await field('smb.username', ''),
        password: await field('smb.password', ''),
      );
    } catch (_) {
      for (final key in smbSettingKeys) {
        try {
          await store.delete(key);
        } catch (_) {/* best effort wipe */}
      }
      return defaults;
    }
  }

  Future<void> save({SettingsStore store = const SecureSettingsStore()}) async {
    await store.write('smb.host', host);
    await store.write('smb.share_path', sharePath);
    await store.write('smb.domain', domain);
    await store.write('smb.username', username);
    await store.write('smb.password', password);
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/smb_settings_test.dart && flutter analyze`
Expected: 6 tests PASS; analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart pubspec.yaml pubspec.lock test/smb_settings_test.dart test/helpers/in_memory_settings_store.dart
git commit -m "feat: encrypted SMB settings persistence with injectable store seam

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Shared `connect()` helper + unconfigured guard

**Files:**
- Modify: `lib/main.dart` (`SmbNotConfiguredException` + `connect()` top-level, below the store classes; then the three call sites in `_PreviewPageState._upload`, `_HistoryPageState._refresh`, `_ImageViewerPageState._load`)
- Test: `test/smb_settings_test.dart` (extend)

**Interfaces:**
- Consumes: `SmbSettings` (Task 1).
- Produces:
  - `class SmbNotConfiguredException implements Exception` — `toString()` returns `'SMB login not configured — open Settings'` and exposes `static const String message` with the same value.
  - `Future<SmbConnect> connect(SmbSettings s)` — throws `SmbNotConfiguredException` before dialing if `s.username.isEmpty`; otherwise `SmbConnect.connectAuth(host: s.host, domain: s.domain, username: s.username, password: s.password)`.

- [ ] **Step 1: Write the failing test**

Append to `test/smb_settings_test.dart`:

```dart
  group('connect guard', () {
    test('refuses to dial when username is empty', () async {
      await expectLater(
        connect(SmbSettings.defaults), // username is ''
        throwsA(isA<SmbNotConfiguredException>()),
      );
    });

    test('guard message is user-readable', () {
      expect(SmbNotConfiguredException().toString(),
          'SMB login not configured — open Settings');
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/smb_settings_test.dart`
Expected: FAIL — `connect` / `SmbNotConfiguredException` not defined.

- [ ] **Step 3: Implement the helper and swap the three call sites**

In `lib/main.dart`, below the store classes:

```dart
/// Thrown (before any network dial) when an SMB operation is attempted
/// with no configured login. toString() is shown verbatim in error
/// banners, so it must stay user-readable.
class SmbNotConfiguredException implements Exception {
  static const String message = 'SMB login not configured — open Settings';

  @override
  String toString() => message;
}

/// Opens an SMB connection with [s]. Every operation goes through here so
/// the unconfigured guard and settings snapshot live in one place.
Future<SmbConnect> connect(SmbSettings s) async {
  if (s.username.isEmpty) throw SmbNotConfiguredException();
  return SmbConnect.connectAuth(
    host: s.host,
    domain: s.domain,
    username: s.username,
    password: s.password,
  );
}
```

Then in `_PreviewPageState._upload`, `_HistoryPageState._refresh`, and `_ImageViewerPageState._load`, replace the `SmbConnect.connectAuth(...)` block with `connect(<settings>)` where `<settings>` is the settings value the page holds (Task 1's temporary `SmbSettings.defaults` — final wiring is Task 6). KEEP the `openRead`/`BytesBuilder` chunk-copy in `_load` exactly as is.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/smb_settings_test.dart && flutter analyze`
Expected: 8 tests PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/smb_settings_test.dart
git commit -m "refactor: shared connect() helper with unconfigured guard

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: `SettingsPage` form + validation + password toggle

**Files:**
- Modify: `lib/main.dart` (new `SettingsPage` widget, placed after `HomePage`)
- Create: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `SmbSettings`, `SettingsStore` (Tasks 1-2).
- Produces: `class SettingsPage extends StatefulWidget` with constructor
  `const SettingsPage({super.key, required this.settingsNotifier, this.firstRun = false, this.store = const SecureSettingsStore()})` where `settingsNotifier` is `ValueNotifier<SmbSettings>`, `firstRun` is `bool`, `store` is `SettingsStore`. Form fields carry `Key`s: `host_field`, `share_path_field`, `domain_field`, `username_field`, `password_field`.

- [ ] **Step 1: Write the failing widget tests**

Create `test/settings_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

import 'helpers/in_memory_settings_store.dart';

Future<void> _openSettings(WidgetTester tester, SettingsPage page) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fields are seeded from current settings', (tester) async {
    final notifier =
        ValueNotifier(SmbSettings.defaults.copyWith(username: 'opk'));
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    expect(find.widgetWithText(TextFormField, '192.168.1.29'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '/zdrive/InvoiceData'), findsOneWidget);
  });

  testWidgets('password visibility toggle reveals text', (tester) async {
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    await tester.enterText(find.byKey(const Key('password_field')), 'secret');
    final field = tester.widget<TextFormField>(
        find.byKey(const Key('password_field')));
    expect(field.obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(
      tester.widget<TextFormField>(
          find.byKey(const Key('password_field'))).obscureText,
      isFalse,
    );
  });
}
```

Remove the unused `_host` helper if the analyzer flags it.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/settings_page_test.dart`
Expected: FAIL — `SettingsPage` not defined.

- [ ] **Step 3: Implement the page shell (form + validators + toggle only)**

Add to `lib/main.dart` (after `_HomePageState`). Test connection and Save behavior land in Task 5 — include their buttons now as disabled stubs (`onPressed: null`) so the layout exists:

```dart
/// Settings / first-run setup for the SMB share connection. One widget,
/// two entry modes: gear-invoked (back discards edits) and first-run
/// (back disabled until a valid save — see PopScope).
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settingsNotifier,
    this.firstRun = false,
    this.store = const SecureSettingsStore(),
  });

  final ValueNotifier<SmbSettings> settingsNotifier;
  final bool firstRun;
  final SettingsStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _sharePath;
  late final TextEditingController _domain;
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _obscured = true;

  @override
  void initState() {
    super.initState();
    final s = widget.settingsNotifier.value;
    _host = TextEditingController(text: s.host);
    _sharePath = TextEditingController(text: s.sharePath);
    _domain = TextEditingController(text: s.domain);
    _username = TextEditingController(text: s.username);
    _password = TextEditingController(text: s.password);
  }

  @override
  void dispose() {
    _host.dispose();
    _sharePath.dispose();
    _domain.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  SmbSettings _formSettings() => SmbSettings(
        host: _host.text.trim(),
        sharePath: _sharePath.text.trim(),
        domain: _domain.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
      );

  String? _required(String? v) =>
      (v ?? '').trim().isEmpty ? 'Required' : null;

  String? _sharePathValidator(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Required';
    if (!t.startsWith('/')) return 'Must start with / (share/sub-folder)';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.firstRun, // setup mode: no escape before a valid save
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.firstRun ? 'Set up SMB login' : 'SMB settings'),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                key: const Key('host_field'),
                controller: _host,
                decoration: const InputDecoration(labelText: 'Host'),
                validator: _required,
              ),
              TextFormField(
                key: const Key('share_path_field'),
                controller: _sharePath,
                decoration: const InputDecoration(
                    labelText: 'Share path (/share/sub-folder)'),
                validator: _sharePathValidator,
              ),
              TextFormField(
                key: const Key('domain_field'),
                controller: _domain,
                decoration:
                    const InputDecoration(labelText: 'Domain (optional)'),
              ),
              TextFormField(
                key: const Key('username_field'),
                controller: _username,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: _required,
              ),
              TextFormField(
                key: const Key('password_field'),
                controller: _password,
                decoration: InputDecoration(
                  labelText: 'Password (optional)',
                  suffixIcon: IconButton(
                    icon: Icon(_obscured
                        ? Icons.visibility
                        : Icons.visibility_off),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  ),
                ),
                obscureText: _obscured,
              ),
              const SizedBox(height: 16),
              // Test result area + buttons — wired in Task 5.
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: null, // Task 5
                    child: const Text('Test connection'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: null, // Task 5
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/settings_page_test.dart && flutter analyze`
Expected: 2 tests PASS; analyzer clean. (Validation-rejection tests come with Task 5 — validation is only observable through `_save`.)

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/settings_page_test.dart
git commit -m "feat: SettingsPage form with validation and obscured password

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Test connection, Save, first-run mode

**Files:**
- Modify: `lib/main.dart` (`_SettingsPageState` — replace the two stub buttons)
- Test: `test/settings_page_test.dart` (extend)

**Interfaces:**
- Consumes: `connect()`, `SmbNotConfiguredException` (Task 3); `save()` (Task 2).
- Produces: behavior — Save persists via `widget.store`, sets `widget.settingsNotifier.value`, pops; Test connection dials with unsaved form values, shows inline `Connected — N files in <path>` or the error text; both disabled/busy while testing; unconfigured form shows `SmbNotConfiguredException.message`.

- [ ] **Step 1: Write the failing tests**

Append to `test/settings_page_test.dart`:

```dart
  testWidgets('share path without leading slash is rejected', (tester) async {
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    await tester.enterText(find.byKey(const Key('share_path_field')), 'zdrive/x');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Must start with / (share/sub-folder)'), findsOneWidget);
    expect(find.byType(SettingsPage), findsOneWidget); // did not pop
  });

  testWidgets('empty username is rejected', (tester) async {
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    await tester.enterText(find.byKey(const Key('username_field')), '');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Required'), findsAtLeastNWidgets(1));
    expect(find.byType(SettingsPage), findsOneWidget); // did not pop
  });

  testWidgets('save persists, updates notifier, and pops', (tester) async {
    final store = InMemorySettingsStore();
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(tester,
        SettingsPage(settingsNotifier: notifier, store: store));
    await tester.enterText(find.byKey(const Key('username_field')), 'opk');
    await tester.enterText(find.byKey(const Key('password_field')), 'pw');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing); // popped
    expect(notifier.value.username, 'opk');
    expect(store.data['smb.username'], 'opk');
    expect(store.data['smb.password'], 'pw');
  });

  testWidgets('blank password is allowed', (tester) async {
    final store = InMemorySettingsStore();
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(tester,
        SettingsPage(settingsNotifier: notifier, store: store));
    await tester.enterText(find.byKey(const Key('username_field')), 'opk');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(store.data['smb.password'], '');
  });

  testWidgets('test connection shows guard wording when unconfigured',
      (tester) async {
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    await tester.enterText(find.byKey(const Key('host_field')), '10.9.9.9');
    await tester.tap(find.text('Test connection'));
    await tester.pump();
    expect(find.text(SmbNotConfiguredException.message), findsOneWidget);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/settings_page_test.dart`
Expected: New tests FAIL (buttons inert).

- [ ] **Step 3: Implement the actions**

In `_SettingsPageState`, add state fields and methods:

```dart
  bool _testing = false;
  int? _testCount;
  String? _testError;

  Future<void> _testConnection() async {
    final s = _formSettings();
    if (s.username.isEmpty) {
      setState(() {
        _testing = false;
        _testCount = null;
        _testError = SmbNotConfiguredException.message;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testCount = null;
      _testError = null;
    });
    try {
      final conn = await connect(s);
      try {
        final folder = await conn.file(s.sharePath);
        final entries = await conn.listFiles(folder);
        if (!mounted) return;
        setState(() {
          _testing = false;
          _testCount = entries.length;
        });
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testing = false;
          _testError = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final s = _formSettings();
    try {
      await s.save(store: widget.store);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save settings')),
        );
      }
      return; // stay on the page
    }
    widget.settingsNotifier.value = s;
    if (mounted) Navigator.of(context).pop(true);
  }
```

Replace the placeholder result area and the two stub buttons with:

```dart
              if (_testError != null)
                Text(_testError!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              if (_testCount != null)
                Text('Connected — $_testCount files in ${_sharePath.text.trim()}'),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _testing ? null : _testConnection,
                    child: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: const Text('Save')),
                ],
              ),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/settings_page_test.dart && flutter analyze`
Expected: 7 tests PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/settings_page_test.dart
git commit -m "feat: settings test-connection and save with first-run mode

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Shell wiring — notifier, gear actions, first-run gate, History re-key

**Files:**
- Modify: `lib/main.dart` (`MmcPicApp`, `_HomePageState`, `ScannerPage`, `CameraPage`, `PreviewPage`, `HistoryPage`, `ImageViewerPage`)
- Create: `test/home_page_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces:
  - `MmcPicApp` gains optional `this.store` (`SettingsStore`, default `const SecureSettingsStore()`), forwarded to `HomePage`.
  - `HomePage` gains optional `this.store`; `_HomePageState` owns `final ValueNotifier<SmbSettings> _settingsNotifier = ValueNotifier(SmbSettings.defaults);` and `void _openSettings({bool firstRun = false})`.
  - `ScannerPage({required this.settingsNotifier, this.onOpenSettings, this.paused})` — `settingsNotifier` is `ValueNotifier<SmbSettings>`, `onOpenSettings` is `VoidCallback?`; its app bar gains a gear `IconButton(icon: Icon(Icons.settings))`.
  - `CameraPage({required this.orderNumber, required this.settingsNotifier})`; `PreviewPage({required this.orderNumber, required this.imagePath, required this.settingsNotifier})` — `_upload` snapshots `widget.settingsNotifier.value` at call time.
  - `HistoryPage({required this.settingsNotifier, this.onOpenSettings})` — `_refresh` snapshots `widget.settingsNotifier.value`; app bar gains the gear action.
  - `ImageViewerPage({required this.file, required this.settingsNotifier})` — `_load` snapshots at call time; the `BytesBuilder` copy stays verbatim.

- [ ] **Step 1: Write the failing tests**

Create `test/home_page_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  testWidgets('first run (no stored login) opens the setup gate',
      (tester) async {
    await tester.pumpWidget(MmcPicApp(store: InMemorySettingsStore()));
    await tester.pump(); // load() future + post-frame push
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Set up SMB login'), findsOneWidget);
  });

  testWidgets('configured app starts on Scan without the gate',
      (tester) async {
    final store = InMemorySettingsStore()
      ..data['smb.username'] = 'opk'
      ..data['smb.host'] = '192.168.1.29';
    await tester.pumpWidget(MmcPicApp(store: store));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('Scan QR code'), findsOneWidget);
    // Gear in the Scan app bar opens settings (History's gear is the same
    // callback — covered by the manual pass).
    await tester.tap(find.byTooltip('SMB settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('SMB settings'), findsOneWidget); // not setup mode
  });
}
```

(If `MobileScanner` makes these unstable in the test env, replace `pumpAndSettle` usage with fixed `pump()` calls as above before any other change — the camera surfaces errors through its `errorBuilder` and must not fail the test.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/home_page_test.dart`
Expected: FAIL — `MmcPicApp` has no `store` parameter / gate not implemented.

- [ ] **Step 3: Implement the wiring**

In `lib/main.dart`:

1. `MmcPicApp`: add `const MmcPicApp({super.key, this.store});` with `final SettingsStore store;` defaulting via constructor `this.store = const SecureSettingsStore()`, pass to `home: HomePage(store: store)`.

2. `_HomePageState`:

```dart
  late final SettingsStore _store;
  final ValueNotifier<SmbSettings> _settingsNotifier =
      ValueNotifier(SmbSettings.defaults);

  @override
  void initState() {
    super.initState();
    _store = widget.store;
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final s = await SmbSettings.load(store: _store); // recovery inside load()
    if (!mounted) return;
    _settingsNotifier.value = s;
    if (s.username.isEmpty) {
      // First-run gate — push once the frame is up.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSettings(firstRun: true);
      });
    }
  }

  void _openSettings({bool firstRun = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          settingsNotifier: _settingsNotifier,
          firstRun: firstRun,
          store: _store,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _settingsNotifier.dispose();
    super.dispose();
  }
```

3. `_HomePageState.build` — wrap the `IndexedStack` in a `ValueListenableBuilder<SmbSettings>` and re-key History on actual change:

```dart
    return Scaffold(
      body: ValueListenableBuilder<SmbSettings>(
        valueListenable: _settingsNotifier,
        builder: (context, settings, _) => IndexedStack(
          index: _tab,
          children: [
            ScannerPage(
              paused: _tab != 0,
              settingsNotifier: _settingsNotifier,
              onOpenSettings: () => _openSettings(),
            ),
            // Re-key on settings value: remount → initState → fresh list.
            _historyVisited
                ? KeyedSubtree(
                    key: ObjectKey(settings),
                    child: HistoryPage(
                      settingsNotifier: _settingsNotifier,
                      onOpenSettings: () => _openSettings(),
                    ),
                  )
                : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: /* unchanged NavigationBar code */,
    );
```

4. `ScannerPage` / `_ScannerPageState`: add `settingsNotifier` + `onOpenSettings` fields/params; app bar gains `actions: [IconButton(icon: const Icon(Icons.settings), tooltip: 'SMB settings', onPressed: widget.onOpenSettings)]`. Everywhere it pushes `CameraPage(orderNumber: ...)`, add `settingsNotifier: widget.settingsNotifier`. (`paused` camera logic untouched.)

5. `CameraPage`: add `settingsNotifier` field/param; its `pushReplacement` to `PreviewPage` forwards it.

6. `PreviewPage`: add `settingsNotifier` field/param; in `_upload`, replace the Task-3 temporary default with `final s = widget.settingsNotifier.value;` and `connect(s)`.

7. `HistoryPage` / `_HistoryPageState`: add `settingsNotifier` + `onOpenSettings`; app bar `actions:` gear; `_refresh` starts with `final s = widget.settingsNotifier.value;` then `connect(s)` and `conn.file(s.sharePath)`; the error view text uses `s` (`'Could not list \\\\${s.host}${s.sharePath}'`). Pushes to `ImageViewerPage` forward `settingsNotifier`.

8. `ImageViewerPage`: add `settingsNotifier`; `_load` snapshots `final s = widget.settingsNotifier.value;`, uses `connect(s)`; the `openRead` + `BytesBuilder` loop is untouched.

- [ ] **Step 4: Run the full suite**

Run: `flutter test && flutter analyze`
Expected: ALL tests PASS (17 total across three files); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/home_page_test.dart
git commit -m "feat: wire settings through the app shell with first-run gate

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Android backup exclusion

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: nothing.
- Produces: `<application android:allowBackup="false" ...>` — no app data (credentials included) in cloud backup or device transfer. Stronger and simpler than per-key exclusion rules; nothing in this app needs backup.

- [ ] **Step 1: Edit the manifest**

In `android/app/src/main/AndroidManifest.xml`, change the `<application>` tag: set `android:allowBackup="false"` (keep `android:label` etc. as they are). If `android:allowBackup` is absent, add it.

- [ ] **Step 2: Verify**

Run: `grep -n 'allowBackup' android/app/src/main/AndroidManifest.xml`
Expected: one line showing `android:allowBackup="false"`.
Run: `flutter build apk --debug` — Expected: BUILD SUCCESSFUL (manifest sanity).

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml
git commit -m "chore: disable Android backup for credential data

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Docs, full verification, manual pass

**Files:**
- Modify: `CLAUDE.md` (section "SMB layer", first bullet)
- Modify: `openspec/changes/smb-path-settings-menu/tasks.md` (tick boxes)

**Interfaces:**
- Consumes: Tasks 1-7.
- Produces: updated docs + the on-device verification record.

- [ ] **Step 1: Update CLAUDE.md**

Replace the first bullet under "### SMB layer" (the one describing hardcoded constants) with:

```markdown
- Connection settings (host, `<share>/<sub-folder>` path, domain, user, password) live in the `SmbSettings` value class at the top of `main.dart`, persisted per-device via `flutter_secure_storage` behind the injectable `SettingsStore` seam. Credentials are never compiled into the binary — first startup opens a required setup form. Edit settings via the gear icon in either tab's app bar; the share itself must already exist, sub-folders are created at upload time.
```

Also replace the second bullet's "Every operation (upload in `PreviewPage._upload`, listing in `HistoryPage._refresh`, download in `ImageViewerPage._load`) opens a fresh `SmbConnect.connectAuth` connection" with "…opens a fresh connection via the shared `connect(SmbSettings)` helper (which refuses to dial when no username is configured)".

- [ ] **Step 2: Full automated verification**

Run: `flutter analyze && flutter test`
Expected: analyzer clean, all tests pass.

- [ ] **Step 3: On-device manual pass** (physical device + LAN share; check off `tasks.md` 6.4 as each passes)

1. Fresh install (or clear app data) → setup gate appears on launch; back does nothing; username required, blank password accepted.
2. Save → gate gone; kill + relaunch → straight to Scan (persistence).
3. Gear from Scan and from History → settings open seeded.
4. Test connection with correct values → `Connected — N files …`; with a bad host → inline error.
5. Upload / History list / image download behave exactly as before (filename contract, chunk-copy download).
6. Repoint share path → History re-lists from the new target; re-save unchanged → History does NOT reload.
7. Clear stored username via settings → next upload shows "SMB login not configured — open Settings".
8. `adb shell run-as mmcpicv4 ls shared_prefs` → no settings file exists (data is in encrypted storage, not prefs).

- [ ] **Step 4: Tick tasks.md and commit**

Tick every completed box in `openspec/changes/smb-path-settings-menu/tasks.md`.

```bash
git add CLAUDE.md openspec/changes/smb-path-settings-menu/tasks.md
git commit -m "docs: CLAUDE.md SMB layer reflects settings menu

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Merge with `ordernumber-entry`

**Files:**
- Merge: branch `worktree-ordernumber-entry` (or its PR) with this branch.

**Interfaces:**
- Consumes: both landed branches.
- Produces: `main` containing both features.

- [ ] **Step 1: Merge and resolve take-both**

Whichever branch lands second rebases/merges onto the other. The conflict is confined to `_ScannerPageState.build`: keep BOTH `ordernumber-entry`'s body `Stack` (with the "Type order number" button) AND this change's app-bar `actions:` gear. No other overlap exists (they verified: app bar vs body).

- [ ] **Step 2: Post-merge verification**

Run: `flutter analyze && flutter test`
Expected: clean/green. Manually smoke the two features together on device: type-order-number capture flow still pushes to camera; gear still opens settings; first-run gate (if fresh data) still precedes everything.

- [ ] **Step 3: Commit the merge**

```bash
git commit -m "merge: ordernumber-entry + smb-path-settings-menu (take-both)

Co-Authored-By: Claude <noreply@anthropic.com>"
```
