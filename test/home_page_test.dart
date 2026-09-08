import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/main.dart';
import 'package:orderpic/pages/history_page.dart';
import 'package:orderpic/pages/home_page.dart';
import 'package:orderpic/pages/scanner_page.dart';
import 'package:orderpic/settings/app_settings.dart';
import 'package:orderpic/settings/settings_page.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  testWidgets('first run (no stored login) opens the setup gate', (
    tester,
  ) async {
    await tester.pumpWidget(OrderPicApp(store: InMemorySettingsStore()));
    await tester.pump(); // load() future resolves
    await tester.pump(); // post-frame callback pushes the gate
    await tester.pump(); // route builds
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Set up SMB login'), findsOneWidget);
  });

  testWidgets('configured app starts on Scan without the gate', (tester) async {
    final store = InMemorySettingsStore()
      ..data['smb.username'] = 'tester'
      ..data['smb.host'] = '192.168.1.29';
    await tester.pumpWidget(OrderPicApp(store: store));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('Scan QR code'), findsOneWidget);
    // Gear in the Scan app bar opens settings (History's gear is the same
    // callback — covered by the manual pass).
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget); // not setup mode
  });

  // Remount narrowing: the History KeyedSubtree key is
  // ObjectKey(settings.connection). ObjectKey compares by INSTANCE
  // identity (identical()), not ==, so the narrowing contract is: an
  // upload-only mutation must reuse the SAME ConnectionSettings instance
  // (AppSettings.copyWith does), while any connection change produces a
  // new one. Upload-only → History rebuilds in place (same State);
  // connection change → remount (fresh State → fresh list).
  //
  // Observation strategy: State identity via tester.state(). A remount
  // swaps the State object; a rebuild never does. Determinism: these
  // tests run with an empty username, so every HistoryPage refresh
  // bounces off connect()'s unconfigured guard (a synchronous throw —
  // no socket, no timers). The empty username also opens the first-run
  // gate route over the shell; that only makes the shell offstage — the
  // elements stay mounted and still rebuild — so the finders here pass
  // skipOffstage: false, and the History visit is driven via the
  // NavigationBar callback directly (immune to the gate's barrier).
  group('History remount key tracks connection identity only', () {
    Finder historyPage() => find.byType(HistoryPage, skipOffstage: false);

    /// Pumps the shell, switches to History, lets the load + first-run
    /// gate settle, and returns the shared settings notifier (grabbed
    /// from the always-mounted ScannerPage).
    Future<ValueNotifier<AppSettings>> pumpAppWithHistoryVisited(
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: HomePage(store: InMemorySettingsStore())),
      );
      final notifier =
          tester
              .widget<ScannerPage>(find.byType(ScannerPage))
              .settingsNotifier;
      // Flip to the History tab synchronously — the first-run gate's
      // route/barrier may already be in play, but this callback path
      // doesn't care about hit-testing.
      tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .onDestinationSelected!
          (1);
      await tester.pump(); // History mounts; gate route builds
      await tester.pump(const Duration(milliseconds: 400)); // transition done
      return notifier;
    }

    testWidgets('upload-only change does NOT remount History', (
      tester,
    ) async {
      final notifier = await pumpAppWithHistoryVisited(tester);
      final before = tester.state(historyPage());

      // Upload-only mutation: same connection INSTANCE (copyWith reuses
      // it), flipped folders toggle — the shape a real upload-only save
      // produces.
      notifier.value = notifier.value.copyWith(
        upload: notifier.value.upload.copyWith(useOrderFolders: true),
      );
      await tester.pump();
      expect(tester.state(historyPage()), same(before)); // rebuilt in place
    });

    testWidgets('connection change DOES remount History', (tester) async {
      final notifier = await pumpAppWithHistoryVisited(tester);
      final before = tester.state(historyPage());

      // Host change (username stays empty → the remounted History's
      // refresh still fails at the connect() guard, nothing dials).
      notifier.value = notifier.value.copyWith(
        connection: notifier.value.connection.copyWith(host: '10.9.9.9'),
      );
      await tester.pump();
      await tester.pump(); // remounted History's initState refresh settles
      expect(tester.state(historyPage()), isNot(same(before))); // remounted
    });

    testWidgets('unchanged connection re-save does NOT remount History', (
      tester,
    ) async {
      final notifier = await pumpAppWithHistoryVisited(tester);
      final before = tester.state(historyPage());

      // No-op re-save shape (SettingsPage._save with untouched form
      // fields): copyWith() builds a FRESH ==-equal connection instance —
      // instance identity WOULD differ, but the whole AppSettings is
      // ==-equal (connection by value, upload same instance), so
      // ValueNotifier suppresses the notification entirely: History
      // neither rebuilds nor remounts. Pins the third leg of the
      // invariant alongside the two above.
      notifier.value = notifier.value.copyWith(
        connection: notifier.value.connection.copyWith(),
      );
      await tester.pump();
      expect(tester.state(historyPage()), same(before)); // not even rebuilt
    });
  });
}
